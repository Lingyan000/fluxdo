//! Exercise cooperative limits through stream/body entry points, not only the budget helper.

use std::{
    assert_matches,
    future::Future,
    pin::{Pin, pin},
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    task::{Context, Poll, Wake, Waker},
};

use rama_core::bytes::Bytes;
use rama_http_types::{
    Body,
    body::{Frame, StreamingBody},
    proto::h3::Code,
};

use crate::h3::{
    Error, body,
    connection::{Config, Shared},
    control::Role,
    cooperative::OPERATIONS_PER_QUANTUM,
    frame::FrameEvent,
    quic::{RecvStream, SendStream, Writer},
    stream::{Phase, Reader},
};

#[derive(Default)]
struct WakeCount(AtomicUsize);
impl Wake for WakeCount {
    fn wake(self: Arc<Self>) {
        self.0.fetch_add(1, Ordering::Relaxed);
    }

    fn wake_by_ref(self: &Arc<Self>) {
        self.0.fetch_add(1, Ordering::Relaxed);
    }
}

struct ReadyRecv(Bytes);
impl RecvStream for ReadyRecv {
    fn poll_chunk(
        &mut self,
        _: &mut Context<'_>,
        limit: usize,
    ) -> Poll<Result<Option<Bytes>, Error>> {
        Poll::Ready(Ok(
            (!self.0.is_empty()).then(|| self.0.split_to(limit.min(self.0.len())))
        ))
    }

    fn stop(&mut self, _: Code) {}
}

#[test]
fn ignored_frame_flood_yields_and_preserves_following_data() {
    let shared = Shared::new(Config::default(), Role::Server, Default::default()).unwrap();
    // 0x21 is an unknown frame type. All bytes are immediately available.
    let mut wire = [0x21, 0].repeat(OPERATIONS_PER_QUANTUM * 4);
    wire.extend_from_slice(b"\x00\x07payload");
    let wire = Bytes::from(wire);
    let payload_pointer = wire.as_ptr().wrapping_add(wire.len() - 7);
    let mut reader = Reader::new(ReadyRecv(wire), shared, 0);
    reader.phase = Phase::Body;
    let wakes = Arc::new(WakeCount::default());
    let waker = Waker::from(wakes.clone());
    let mut cx = Context::from_waker(&waker);
    assert!(reader.poll_event(&mut cx).is_pending());
    assert!(wakes.0.load(Ordering::Relaxed) > 0);
    let mut data_header = false;
    let mut payload = None;
    let mut complete = false;
    for _ in 0..OPERATIONS_PER_QUANTUM {
        match reader.poll_event(&mut cx) {
            Poll::Pending => (),
            Poll::Ready(Ok(Some(FrameEvent::DataHeader { len }))) => {
                assert_eq!(len, 7);
                data_header = true;
            }
            Poll::Ready(Ok(Some(FrameEvent::DataChunk(bytes)))) => payload = Some(bytes),
            Poll::Ready(Ok(None)) => {
                complete = true;
                break;
            }
            other @ Poll::Ready(_) => panic!("unexpected stream event: {other:?}"),
        }
    }
    assert!(complete && data_header);
    let payload = payload.unwrap();
    assert_eq!(payload, b"payload".as_slice());
    assert_eq!(payload.as_ptr(), payload_pointer);
}

struct EmptyFrames {
    remaining: usize,
    polls: Arc<AtomicUsize>,
    tail: Option<Bytes>,
}

impl StreamingBody for EmptyFrames {
    type Data = Bytes;
    type Error = std::convert::Infallible;
    fn poll_frame(
        mut self: Pin<&mut Self>,
        _: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, Self::Error>>> {
        self.polls.fetch_add(1, Ordering::Relaxed);
        if self.remaining > 0 {
            self.remaining -= 1;
            Poll::Ready(Some(Ok(Frame::data(Bytes::new()))))
        } else {
            Poll::Ready(self.tail.take().map(|bytes| Ok(Frame::data(bytes))))
        }
    }
}

#[derive(Default)]
struct Written {
    bytes: Vec<u8>,
    finished: bool,
    reset: bool,
    delay_acknowledgement: bool,
}

struct ReadySend(Arc<parking_lot::Mutex<Written>>);
impl SendStream for ReadySend {
    fn acknowledged(&self) -> impl Future<Output = Result<(), Error>> + Send + Sync + 'static {
        let written = self.0.clone();
        std::future::poll_fn(move |_| {
            let written = written.lock();
            if written.finished && !written.delay_acknowledgement {
                Poll::Ready(Ok(()))
            } else {
                Poll::Pending
            }
        })
    }

    fn poll_chunks(
        &mut self,
        _: &mut Context<'_>,
        chunks: &mut [Bytes],
    ) -> Poll<Result<(), Error>> {
        let mut written = self.0.lock();
        for chunk in chunks {
            written.bytes.extend_from_slice(chunk);
            *chunk = Bytes::new();
        }
        Poll::Ready(Ok(()))
    }

    fn finish(&mut self) -> Result<(), Error> {
        self.0.lock().finished = true;
        Ok(())
    }

    fn reset(&mut self, _: Code) {
        self.0.lock().reset = true;
    }

    fn priority(&mut self, _: i32) -> Result<(), Error> {
        Ok(())
    }
}

#[test]
fn immediately_ready_empty_body_frames_yield_before_reaching_payload() {
    let shared = Shared::new(Config::default(), Role::Server, Default::default()).unwrap();
    shared.schedule.register(0, Default::default()).unwrap();
    let polls = Arc::new(AtomicUsize::new(0));
    let body = EmptyFrames {
        remaining: OPERATIONS_PER_QUANTUM * 4,
        polls: polls.clone(),
        tail: Some(Bytes::from_static(b"payload")),
    };
    let written = Arc::new(parking_lot::Mutex::new(Written::default()));
    let mut send = pin!(body::send(
        Writer::new(ReadySend(written.clone())),
        body,
        shared,
        0,
        Some(7),
        None,
    ));
    let wakes = Arc::new(WakeCount::default());
    let waker = Waker::from(wakes.clone());
    let mut cx = Context::from_waker(&waker);
    assert!(send.as_mut().poll(&mut cx).is_pending());
    assert!(polls.load(Ordering::Relaxed) <= OPERATIONS_PER_QUANTUM);
    assert!(wakes.0.load(Ordering::Relaxed) > 0);
    assert!(written.lock().bytes.is_empty());
    let mut complete = false;
    for _ in 0..OPERATIONS_PER_QUANTUM {
        if let Poll::Ready(result) = send.as_mut().poll(&mut cx) {
            result.unwrap();
            complete = true;
            break;
        }
    }
    assert!(complete);
    let written = written.lock();
    assert_eq!(written.bytes, b"\x00\x07payload");
    assert!(written.finished && !written.reset);
}

#[test]
fn finished_upload_waits_for_fin_acknowledgement() {
    let shared = Shared::new(Config::default(), Role::Server, Default::default()).unwrap();
    shared.schedule.register(0, Default::default()).unwrap();
    let written = Arc::new(parking_lot::Mutex::new(Written {
        delay_acknowledgement: true,
        ..Written::default()
    }));
    let mut send = pin!(body::send(
        Writer::new(ReadySend(written.clone())),
        Body::empty(),
        shared,
        0,
        Some(0),
        None,
    ));
    let mut cx = Context::from_waker(Waker::noop());
    assert!(send.as_mut().poll(&mut cx).is_pending());
    assert!(written.lock().finished, "FIN must already be queued");
    // A poll after queueing still cannot release the response's admission lease.
    assert!(send.as_mut().poll(&mut cx).is_pending());
    written.lock().delay_acknowledgement = false;
    assert_matches!(send.as_mut().poll(&mut cx), Poll::Ready(Ok(())));
}

#[test]
fn cancelling_upload_after_queued_fin_resets_unacknowledged_stream() {
    let shared = Shared::new(Config::default(), Role::Server, Default::default()).unwrap();
    shared.schedule.register(0, Default::default()).unwrap();
    let written = Arc::new(parking_lot::Mutex::new(Written {
        delay_acknowledgement: true,
        ..Written::default()
    }));
    {
        let mut send = pin!(body::send(
            Writer::new(ReadySend(written.clone())),
            Body::empty(),
            shared,
            0,
            Some(0),
            None,
        ));
        let mut cx = Context::from_waker(Waker::noop());
        assert!(send.as_mut().poll(&mut cx).is_pending());
        assert!(written.lock().finished);
        assert!(!written.lock().reset);
    }
    assert!(
        written.lock().reset,
        "cancellation must reset even after FIN was queued"
    );
}
