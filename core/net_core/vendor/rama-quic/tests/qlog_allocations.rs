#![allow(
    unsafe_code,
    reason = "an isolated integration binary measures the public admission allocation contract"
)]
#![expect(
    clippy::unwrap_used,
    reason = "test setup and recorder completion must succeed"
)]

use core::{
    alloc::{GlobalAlloc, Layout},
    cell::Cell,
};
use rama_quic::{
    TransportConfig,
    qlog::{
        NamedQlogEventView, QlogConfig, QlogEventView, QlogOutput, QlogSink, QueueLimits,
        TraceInfo,
        event::{
            LifecycleEventView,
            lifecycle::{ConnectionClosedView, ReasonView},
        },
    },
};
use rama_quic_proto::ConnectionId;
use rama_utils::octets;
use std::{
    alloc::System,
    io,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::Notify;

struct CountingAllocator;

thread_local! {
    static COUNTING: Cell<bool> = const { Cell::new(false) };
    static ALLOCATIONS: Cell<usize> = const { Cell::new(0) };
}

/// Never panics: a destroyed thread-local is skipped, not unwrapped.
fn allocated() {
    if COUNTING.try_with(Cell::get) == Ok(true) {
        let _thread_exited = ALLOCATIONS.try_with(|n| n.set(n.get().saturating_add(1)));
    }
}

// SAFETY: every block this allocator returns comes from `System`, and every free or
// resize passes the same pointer and layout on to `System`, so `System`'s `GlobalAlloc`
// impl meets the contract. The bookkeeping uses only `LocalKey::try_with` on
// const-initialized `Cell`s and `saturating_add`, none of which panic, so no method unwinds.
unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        allocated();
        // SAFETY: `System.alloc` has this method's contract (`layout` has non-zero size),
        // which the caller upholds.
        unsafe { System.alloc(layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        allocated();
        // SAFETY: `System.alloc_zeroed` has this method's contract (`layout` has non-zero
        // size), which the caller upholds.
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        allocated();
        // SAFETY: as for `dealloc`, `pointer` is a `System` block allocated with `layout`;
        // `new_size` meets `realloc`'s size rules by the caller's contract.
        unsafe { System.realloc(pointer, layout, new_size) }
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        // SAFETY: the caller passes a block this allocator returned for `layout`; every
        // such block comes from `System` with that same layout, as `dealloc` requires.
        unsafe { System.dealloc(pointer, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

struct CountingGuard;

impl Drop for CountingGuard {
    fn drop(&mut self) {
        COUNTING.set(false);
    }
}

fn measured<T>(operation: impl FnOnce() -> T) -> (T, usize) {
    assert!(!COUNTING.get());
    ALLOCATIONS.set(0);
    COUNTING.set(true);
    let guard = CountingGuard;
    let result = operation();
    drop(guard);
    (result, ALLOCATIONS.get())
}

fn borrowed_close(reason: &str) -> QlogEventView<'_> {
    QlogEventView {
        group_id: ConnectionId::try_from_bytes(b"allocation-test").unwrap(),
        time: Instant::now(),
        fields: LifecycleEventView::Closed(ConnectionClosedView {
            reason: Some(ReasonView::Text(reason)),
            ..Default::default()
        })
        .into(),
    }
}

#[tokio::test(flavor = "current_thread")]
async fn borrowed_rejections_never_allocate_even_after_size_inspection() {
    let reason = "x".repeat(octets::kib(8));
    let event = borrowed_close(&reason);
    let limits = QueueLimits {
        max_queued_events: 1,
        max_queued_bytes: octets::kib(4),
        max_event_bytes: octets::kib(4),
    };
    let recorder = QlogConfig::default()
        .with_writer(tokio::io::sink())
        .with_queue_limits(limits)
        .start()
        .unwrap();
    recorder.flush().await.unwrap();

    let (accepted, allocations) = measured(|| {
        (0..100)
            .filter(|_| QlogSink::emit(&recorder, &event))
            .count()
    });
    assert_eq!(accepted, 0);
    assert_eq!(
        allocations, 0,
        "oversized borrowed fields must not be copied"
    );
    assert_eq!(recorder.stats().oversized_events, 100);
    recorder.shutdown().await.unwrap();

    let recorder = QlogConfig::default()
        .with_writer(tokio::io::sink())
        .with_queue_limits(QueueLimits {
            max_queued_events: 1,
            max_queued_bytes: octets::kib(64),
            max_event_bytes: octets::kib(64),
        })
        .start()
        .unwrap();
    recorder.flush().await.unwrap();
    let (accepted, allocations) = measured(|| QlogSink::emit(&recorder, &event));
    assert!(accepted);
    assert!(
        allocations > 0,
        "accepted borrowed data must reach owned storage"
    );

    // No await occurs here: the current-thread worker cannot drain the single queued event.
    let (accepted, allocations) = measured(|| QlogSink::emit(&recorder, &event));
    assert!(!accepted);
    assert_eq!(
        allocations, 0,
        "full admission must not promote borrowed fields"
    );
    recorder.set_enabled(false);
    let (accepted, allocations) = measured(|| QlogSink::emit(&recorder, &event));
    assert!(!accepted);
    assert_eq!(allocations, 0, "disabled admission must not allocate");
    recorder.set_enabled(true);
    recorder.shutdown().await.unwrap();
    let (accepted, allocations) = measured(|| QlogSink::emit(&recorder, &event));
    assert!(!accepted);
    assert_eq!(allocations, 0, "closed admission must not allocate");
}

struct FinishNotice(Arc<Notify>);

impl QlogOutput for FinishNotice {
    async fn named_event(&mut self, _event: &NamedQlogEventView<'_>) -> io::Result<()> {
        Ok(())
    }

    async fn begin(&mut self, _info: &TraceInfo) -> io::Result<()> {
        Ok(())
    }

    async fn event(&mut self, _event: &QlogEventView<'_>) -> io::Result<()> {
        Ok(())
    }

    async fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }

    async fn finish(&mut self) -> io::Result<()> {
        self.0.notify_one();
        Ok(())
    }
}

#[tokio::test]
async fn replacing_the_last_attached_recorder_finishes_its_worker() {
    let finished = Arc::new(Notify::new());
    let recorder = QlogConfig::default()
        .with_output(FinishNotice(finished.clone()))
        .start()
        .unwrap();
    let mut transport = TransportConfig::default().with_qlog_recorder(recorder);
    transport.unset_qlog_sink();
    tokio::time::timeout(Duration::from_secs(2), finished.notified())
        .await
        .unwrap();
}
