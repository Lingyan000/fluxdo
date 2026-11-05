//! Private-layer benchmark fixtures, available only with `test-utils`.
//!
//! Queue cases execute production admission, enqueue, dequeue and permit destruction. Packet
//! metadata is synthetic, sized to the production slot; parsing and engine work are excluded.
//! Static payload cases isolate queue allocations. Owned payload cases include one payload copy.
#![expect(
    clippy::expect_used,
    reason = "benchmark fixtures fail immediately on invalid setup or lost work"
)]

use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    task::{Context, Poll, Wake, Waker},
    thread::{self, JoinHandle},
    time::Duration,
};

use rama_core::bytes::Bytes;

use crate::{
    PacketQueueStats, ReceiveQueueLimits,
    driver::{
        QueuedPacket,
        queue::{
            BoundedReceiver, BoundedSender, PACKET_OVERHEAD, PacketBudget, PacketPermit,
            bounded_queue,
        },
    },
};

pub use crate::proto::benchmarks::{Assembly, SendRecovery};

const PAYLOAD: &[u8; 1200] = &[0x5a; 1200];
const LIMIT: usize = 128;
const METADATA: usize = std::mem::size_of::<QueuedPacket>()
    - std::mem::size_of::<PacketPermit>()
    - std::mem::size_of::<Bytes>();

#[derive(Debug)]
struct Packet {
    payload: Bytes,
    _metadata: [u8; METADATA],
    _permit: PacketPermit,
}

fn budget(entries: usize) -> PacketBudget {
    PacketBudget::new(
        ReceiveQueueLimits::new(entries, entries * (PAYLOAD.len() + PACKET_OVERHEAD))
            .expect("valid benchmark limits"),
    )
}

fn send(
    sender: &BoundedSender<Packet>,
    endpoint: &PacketBudget,
    connection: &PacketBudget,
    owned: bool,
) {
    let permit = endpoint
        .reserve(PAYLOAD.len())
        .expect("endpoint capacity")
        .for_connection(connection)
        .expect("connection capacity");
    sender
        .send(Packet {
            payload: if owned {
                Bytes::copy_from_slice(PAYLOAD)
            } else {
                Bytes::from_static(PAYLOAD)
            },
            _metadata: [0; METADATA],
            _permit: permit,
        })
        .expect("queue capacity");
}

/// Reusable connection queues sharing the same endpoint admission budget.
#[derive(Debug)]
pub struct Queues {
    endpoint: PacketBudget,
    channels: Vec<(PacketBudget, BoundedSender<Packet>, BoundedReceiver<Packet>)>,
    burst: usize,
}

impl Queues {
    /// Construct empty queues; allocation of queue slots remains lazy.
    pub fn new(connections: usize, burst: usize) -> Self {
        assert!((1..=128).contains(&connections));
        assert!((1..=LIMIT).contains(&burst));
        Self {
            endpoint: budget(connections * LIMIT),
            channels: (0..connections)
                .map(|_| {
                    let (sender, receiver) = bounded_queue(LIMIT);
                    (budget(LIMIT), sender, receiver)
                })
                .collect(),
            burst,
        }
    }

    /// Fill every queue, then drain every queue. Permits release after each packet is consumed.
    pub fn round(&mut self, owned_payload: bool) -> usize {
        for (connection, sender, _) in &self.channels {
            for _ in 0..self.burst {
                send(sender, &self.endpoint, connection, owned_payload);
            }
        }
        let mut consumed = 0;
        let mut cx = Context::from_waker(Waker::noop());
        for (_, _, receiver) in &mut self.channels {
            for _ in 0..self.burst {
                let Poll::Ready(Some(packet)) = receiver.poll_recv(&mut cx) else {
                    unreachable_packet();
                };
                consumed += std::hint::black_box(packet.payload.len());
                drop(packet);
            }
            assert!(receiver.poll_recv(&mut cx).is_pending());
        }
        consumed
    }

    /// Current accounting and retained slot capacity, for checks outside the timed closure.
    pub fn observe(&self) -> (PacketQueueStats, usize) {
        (
            self.endpoint.stats(),
            self.channels
                .iter()
                .map(|(_, _, receiver)| receiver.capacity())
                .sum(),
        )
    }

    /// Verify final occupancy on both admission levels without adding locks to timed rounds.
    pub fn verify_drained(&self) {
        assert_eq!(self.endpoint.stats().queued_datagrams, 0);
        assert_eq!(self.endpoint.stats().queued_bytes, 0);
        assert_eq!(self.endpoint.stats().dropped_datagrams, 0);
        for (connection, _, _) in &self.channels {
            assert_eq!(connection.stats().queued_datagrams, 0);
            assert_eq!(connection.stats().queued_bytes, 0);
            assert_eq!(connection.stats().dropped_datagrams, 0);
        }
    }
}

#[expect(
    clippy::panic,
    reason = "missing benchmark work invalidates the measurement"
)]
fn unreachable_packet() -> ! {
    panic!("admitted benchmark packet was lost")
}

struct Unpark(thread::Thread);

impl Wake for Unpark {
    fn wake(self: Arc<Self>) {
        self.0.unpark();
    }

    fn wake_by_ref(self: &Arc<Self>) {
        self.0.unpark();
    }
}

/// One producer with persistent consumer threads and a shared endpoint budget.
///
/// Timings include per-round command/completion channels and OS scheduling. Thread creation and
/// joining occur outside timing. Consumers use real stored wakers and `park`, not busy polling.
#[derive(Debug)]
pub struct ConcurrentQueues {
    endpoint: PacketBudget,
    senders: Vec<(PacketBudget, BoundedSender<Packet>)>,
    commands: Vec<mpsc::Sender<usize>>,
    completed: mpsc::Receiver<usize>,
    workers: Vec<JoinHandle<()>>,
    stopping: Arc<AtomicBool>,
    burst: usize,
}

impl ConcurrentQueues {
    /// Start one consumer per connection; limits admit a complete round without retries.
    pub fn new(connections: usize, burst: usize) -> Self {
        assert!((1..=16).contains(&connections));
        assert!((1..=LIMIT).contains(&burst));
        let (completed_tx, completed) = mpsc::channel();
        let mut result = Self {
            endpoint: budget(connections * LIMIT),
            senders: Vec::new(),
            commands: Vec::new(),
            completed,
            workers: Vec::new(),
            stopping: Arc::new(AtomicBool::new(false)),
            burst,
        };
        for _ in 0..connections {
            let (sender, mut receiver) = bounded_queue::<Packet>(LIMIT);
            let (command, commands) = mpsc::channel::<usize>();
            let completed = completed_tx.clone();
            let stopping = result.stopping.clone();
            result.senders.push((budget(LIMIT), sender));
            result.commands.push(command);
            result.workers.push(thread::spawn(move || {
                let waker = Waker::from(Arc::new(Unpark(thread::current())));
                let mut cx = Context::from_waker(&waker);
                while let Ok(count) = commands.recv() {
                    let mut consumed = 0;
                    for _ in 0..count {
                        loop {
                            if stopping.load(Ordering::Relaxed) {
                                return;
                            }
                            match receiver.poll_recv(&mut cx) {
                                Poll::Ready(Some(packet)) => {
                                    consumed += std::hint::black_box(packet.payload.len());
                                    drop(packet);
                                    break;
                                }
                                Poll::Ready(None) => return,
                                Poll::Pending => thread::park_timeout(Duration::from_millis(50)),
                            }
                        }
                    }
                    completed
                        .send(consumed)
                        .expect("benchmark coordinator lives");
                }
            }));
        }
        result
    }

    /// Admit and consume one round; packet payload allocations are excluded.
    pub fn round(&mut self) -> usize {
        for command in &self.commands {
            command.send(self.burst).expect("consumer lives");
        }
        for (connection, sender) in &self.senders {
            for _ in 0..self.burst {
                send(sender, &self.endpoint, connection, false);
            }
        }
        (0..self.senders.len())
            .map(|_| {
                self.completed
                    .recv_timeout(Duration::from_secs(30))
                    .expect("consumer completed within 30 seconds")
            })
            .sum()
    }

    /// Verify accounting after the last completed round.
    pub fn verify_drained(&self) {
        assert_eq!(self.endpoint.stats().queued_datagrams, 0);
        assert_eq!(self.endpoint.stats().queued_bytes, 0);
        assert_eq!(self.endpoint.stats().dropped_datagrams, 0);
        for (connection, _) in &self.senders {
            assert_eq!(connection.stats().queued_datagrams, 0);
            assert_eq!(connection.stats().queued_bytes, 0);
            assert_eq!(connection.stats().dropped_datagrams, 0);
        }
    }
}

impl Drop for ConcurrentQueues {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::Relaxed);
        self.commands.clear();
        // A failed producer can leave a consumer awaiting packets. Closing its sender wakes it.
        self.senders.clear();
        for worker in self.workers.drain(..) {
            worker.join().expect("consumer did not panic");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queue_fixture_tracks_real_slot_size_and_drains_every_burst() {
        assert_eq!(
            std::mem::size_of::<Packet>(),
            std::mem::size_of::<QueuedPacket>()
        );
        for connections in [1, 8] {
            for burst in [1, 16, 32, 64, 128] {
                let mut queues = Queues::new(connections, burst);
                for _ in 0..3 {
                    assert_eq!(queues.round(false), connections * burst * PAYLOAD.len());
                    queues.verify_drained();
                    assert!(queues.observe().1 <= connections * LIMIT);
                }
            }
        }
    }

    #[test]
    fn concurrent_fixture_delivers_and_releases_every_packet() {
        for connections in [1, 4] {
            let mut queues = ConcurrentQueues::new(connections, 128);
            for _ in 0..3 {
                assert_eq!(queues.round(), connections * 128 * PAYLOAD.len());
                queues.verify_drained();
            }
        }
    }
}
