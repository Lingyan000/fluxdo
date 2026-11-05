//! The socket a backpressure case pauses, on its own.
//!
//! What makes a pause safe is that a read seeing it set and that read registering are one
//! step: a resume cannot land between them and take nothing. These exercise that from both
//! orderings, and that an unpaused socket is the one it wraps.
//!
//! Only the read path is paused, so that is what is covered here; sending is passed straight
//! on with no state of its own.

mod common;

use std::{
    io::IoSliceMut,
    sync::{
        Arc, Barrier,
        atomic::{AtomicUsize, Ordering},
    },
    task::{Context, Poll, Wake, Waker},
    thread,
};

use common::{Counted, Deaf, bound_socket};
use quinn::{AsyncUdpSocket, udp::RecvMeta};

/// A waker that says how often it was woken, and nothing else.
#[derive(Debug, Default)]
struct Counting(AtomicUsize);

impl Counting {
    fn wakes(&self) -> usize {
        self.0.load(Ordering::Acquire)
    }
}

impl Wake for Counting {
    fn wake(self: Arc<Self>) {
        self.0.fetch_add(1, Ordering::AcqRel);
    }

    fn wake_by_ref(self: &Arc<Self>) {
        self.0.fetch_add(1, Ordering::AcqRel);
    }
}

/// A paused socket over a counting one, so what the pause withheld from the socket below can
/// be told from what it delivered. Wrapping asks quinn for the runtime it will poll on, so
/// each of these runs inside one.
fn paused_over_a_counted_socket() -> (Arc<Deaf>, Arc<Counted>) {
    let runtime = quinn::default_runtime().expect("an async runtime");
    let counted = Counted::around(
        runtime
            .wrap_udp_socket(bound_socket())
            .expect("the socket is wrapped"),
    );
    (Deaf::around(counted.clone()), counted)
}

/// One read, with a waker of the caller's own.
fn read(socket: &Deaf, waker: &Arc<Counting>) -> Poll<usize> {
    let mut buffer = [0u8; 2048];
    let mut bufs = [IoSliceMut::new(&mut buffer)];
    let mut meta = [RecvMeta::default()];
    let waker = Waker::from(waker.clone());
    socket
        .poll_recv(&mut Context::from_waker(&waker), &mut bufs, &mut meta)
        .map(|taken| taken.expect("the socket is readable"))
}

#[tokio::test]
async fn a_resume_between_the_pause_check_and_registration_cannot_lose_the_wake() {
    let (socket, _) = paused_over_a_counted_socket();
    socket.stop_reading();
    let counter = Arc::new(Counting::default());
    let waker = Waker::from(counter.clone());
    let mut buffer = [0; 2048];
    let mut bufs = [IoSliceMut::new(&mut buffer)];
    let mut meta = [RecvMeta::default()];
    let resumed = std::cell::Cell::new(false);
    let result = socket.poll_recv_at_registration(
        &mut Context::from_waker(&waker),
        &mut bufs,
        &mut meta,
        || resumed.set(socket.try_read_again()),
    );
    assert!(result.is_pending());
    // A resume blocked by the read's lock completes as soon as that read releases it.
    if !resumed.get() {
        socket.read_again();
    }
    assert_eq!(
        counter.wakes(),
        1,
        "the resumed reader must be scheduled again"
    );
}

/// A resume wakes the read that is waiting on the pause.
#[tokio::test]
async fn a_resume_wakes_a_read_that_the_pause_left_waiting() {
    let (socket, _) = paused_over_a_counted_socket();
    let waker = Arc::new(Counting::default());
    socket.stop_reading();
    assert!(
        read(&socket, &waker).is_pending(),
        "a paused socket delivers nothing"
    );
    assert_eq!(waker.wakes(), 0, "and nothing has woken the read yet");
    socket.read_again();
    assert_eq!(waker.wakes(), 1, "the resume woke it");
}

/// And takes the waker with it, rather than leaving one to be woken again later.
#[tokio::test]
async fn a_resume_takes_the_waker_it_woke() {
    let (socket, _) = paused_over_a_counted_socket();
    let waker = Arc::new(Counting::default());
    socket.stop_reading();
    assert!(read(&socket, &waker).is_pending());
    socket.read_again();
    socket.read_again();
    assert_eq!(waker.wakes(), 1, "the second resume had nothing to wake");
}

/// The other ordering: the resume has already happened when the read arrives, so the read goes
/// to the socket instead of waiting for a wake that will never come.
#[tokio::test]
async fn a_read_after_a_resume_reaches_the_socket() {
    let (socket, counted) = paused_over_a_counted_socket();
    let waker = Arc::new(Counting::default());
    socket.stop_reading();
    socket.read_again();
    let _ = read(&socket, &waker);
    assert_eq!(
        counted.polls(),
        1,
        "the read was passed to the socket rather than parked"
    );
}

/// While paused, nothing reaches the socket at all: the pause is at this layer, so what
/// arrives stays where it is rather than being read and dropped.
#[tokio::test]
async fn a_paused_read_never_reaches_the_socket() {
    let (socket, counted) = paused_over_a_counted_socket();
    let waker = Arc::new(Counting::default());
    socket.stop_reading();
    assert!(read(&socket, &waker).is_pending());
    assert_eq!(counted.polls(), 0, "the socket below was not touched");
}

/// An unpaused socket is the one it wraps: the read goes straight through, and what the
/// socket says about itself is what the one below says.
#[tokio::test]
async fn an_unpaused_socket_is_the_one_it_wraps() {
    let (socket, counted) = paused_over_a_counted_socket();
    let waker = Arc::new(Counting::default());
    let _ = read(&socket, &waker);
    assert_eq!(counted.polls(), 1, "the read reached the socket");
    assert_eq!(waker.wakes(), 0, "and no pause woke anything");
    assert_eq!(
        socket.local_addr().expect("its address"),
        counted.local_addr().expect("the address below"),
        "it answers for the socket it wraps"
    );
    assert_eq!(
        socket.max_transmit_segments(),
        counted.max_transmit_segments(),
        "and passes on what that socket can do"
    );
    assert_eq!(socket.may_fragment(), counted.may_fragment());
}

/// A resume running at the same time as a read registering. Whichever order the two take, the
/// read is not left parked: either the resume woke it, or the read went to the socket.
///
/// One round, and the assertion holds for either outcome, so nothing here depends on timing.
/// What it does not do is drive the interleaving: with the check and the registration in one
/// critical section there is no moment between them for a test to suspend in.
#[tokio::test]
async fn a_resume_beside_a_registering_read_leaves_no_one_parked() {
    let (socket, counted) = paused_over_a_counted_socket();
    let waker = Arc::new(Counting::default());
    socket.stop_reading();

    let both = Arc::new(Barrier::new(2));
    let resuming = thread::spawn({
        let (socket, both) = (socket.clone(), both.clone());
        move || {
            both.wait();
            socket.read_again();
        }
    });
    both.wait();
    let read = read(&socket, &waker);
    resuming.join().expect("the resume finished");

    assert!(
        waker.wakes() == 1 || read.is_ready() || counted.polls() == 1,
        "the read was woken or it reached the socket, rather than being left parked"
    );
}
