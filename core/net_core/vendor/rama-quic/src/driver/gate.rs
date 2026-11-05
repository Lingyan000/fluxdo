//! Stream and datagram gates: a stream moves its bytes, and a datagram moves at all, only as
//! the gates added to its connection admit.

use std::{
    fmt,
    sync::Arc,
    task::{Context, Poll},
};

use rama_net::{
    gate::{DatagramGates, GateDirection, GatedStream, Initiator, StreamGate, StreamGates},
    stream::layer::{ThrottleConfig, ThrottleGates, Throttleable},
};
use rama_quic_proto::{Dir, Side, StreamId};
use rama_utils::collections::smallvec::SmallVec;

use crate::driver::{Connection, RecvStream, SendStream};

/// [`StreamGates`] of any gate type, opening boxed gates.
trait ErasedGates: Send + Sync {
    fn open(&self, stream: GatedStream) -> Option<Box<dyn StreamGate>>;
}

impl<G: StreamGates> ErasedGates for G {
    fn open(&self, stream: GatedStream) -> Option<Box<dyn StreamGate>> {
        let gate = StreamGates::open(self, stream)?;
        Some(Box::new(gate))
    }
}

/// The gates added to a connection.
#[derive(Clone)]
pub(crate) struct ConnectionGates(Arc<[Arc<dyn ErasedGates>]>);

impl ConnectionGates {
    /// `current` with `gates` added.
    pub(crate) fn add(current: Option<&Self>, gates: impl StreamGates) -> Self {
        let added: Arc<dyn ErasedGates> = Arc::new(gates);
        Self(
            current
                .into_iter()
                .flat_map(|current| current.0.iter().cloned())
                .chain([added])
                .collect(),
        )
    }

    /// The gates of the `direction` of stream `id` on a connection of `side`, if any opens one.
    pub(crate) fn open(
        &self,
        id: StreamId,
        side: Side,
        direction: GateDirection,
    ) -> Option<GateStack> {
        let initiator = if id.initiator() == side {
            Initiator::Local
        } else {
            Initiator::Peer
        };
        let stream = GatedStream {
            id: id.into(),
            direction,
            bidirectional: id.dir() == Dir::Bi,
            initiator,
        };
        let stack: SmallVec<[Box<dyn StreamGate>; 1]> = self
            .0
            .iter()
            .filter_map(|gates| gates.open(stream))
            .collect();
        (!stack.is_empty()).then_some(GateStack(stack))
    }
}

impl fmt::Debug for ConnectionGates {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("ConnectionGates")
            .field(&self.0.len())
            .finish()
    }
}

/// The gates one stream direction moves its bytes through; every one of them applies.
pub(crate) struct GateStack(SmallVec<[Box<dyn StreamGate>; 1]>);

impl GateStack {
    /// Up to `want` bytes all gates admit.
    pub(crate) fn poll_admit(&mut self, cx: &mut Context<'_>, want: u64) -> Poll<u64> {
        let mut admitted = want;
        for index in 0..self.0.len() {
            match self.0[index].poll_admit(cx, admitted) {
                Poll::Ready(granted) => {
                    debug_assert!(granted > 0, "a gate admits at least one byte");
                    // Admitting nothing would leave the stream waiting on no event at all.
                    admitted = admitted.min(granted).max(1);
                }
                Poll::Pending => {
                    // Gates that admitted must not hold their budget while this one waits.
                    for gate in &mut self.0[..index] {
                        gate.settle(0);
                    }
                    return Poll::Pending;
                }
            }
        }
        Poll::Ready(admitted)
    }

    /// `used` of the admitted bytes moved.
    pub(crate) fn settle(&mut self, used: u64) {
        for gate in &mut self.0 {
            gate.settle(used);
        }
    }
}

impl fmt::Debug for GateStack {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("GateStack").field(&self.0.len()).finish()
    }
}

/// The datagram gates added to a connection; every one of them must admit.
#[derive(Clone)]
pub(crate) struct ConnectionDatagramGates(Arc<[Arc<dyn DatagramGates>]>);

impl ConnectionDatagramGates {
    /// `current` with `gates` added.
    pub(crate) fn add(current: Option<&Self>, gates: impl DatagramGates) -> Self {
        let added: Arc<dyn DatagramGates> = Arc::new(gates);
        Self(
            current
                .into_iter()
                .flat_map(|current| current.0.iter().cloned())
                .chain([added])
                .collect(),
        )
    }

    /// Whether every gate admits a datagram of `len` bytes; the first refusal stops, and the
    /// gates asked before it keep what they charged.
    pub(crate) fn admit(&self, direction: GateDirection, len: usize) -> bool {
        self.0.iter().all(|gates| gates.admit(direction, len))
    }
}

impl fmt::Debug for ConnectionDatagramGates {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("ConnectionDatagramGates")
            .field(&self.0.len())
            .finish()
    }
}

impl Throttleable for Connection {
    type Throttled = Self;

    fn throttle(self, config: &ThrottleConfig) -> Self {
        if config.read().is_some() || config.write().is_some() {
            // One budget per direction for the streams and the datagrams alike.
            let gates = ThrottleGates::new(config);
            self.add_stream_gates(gates.clone());
            self.add_datagram_gates(gates);
        }
        self
    }
}

// Stream handles stay shareable whatever gates they hold.
const _: () = {
    const fn shareable<T: Send + Sync>() {}
    shareable::<RecvStream>();
    shareable::<SendStream>();
};

#[cfg(test)]
mod tests {
    use std::{sync::Arc, task::Waker};

    use parking_lot::Mutex;

    use super::*;

    /// What a gate was asked and told, shared with the test.
    #[derive(Debug, Default)]
    struct Log {
        asked: Vec<u64>,
        admitted: Vec<u64>,
        settled: Vec<u64>,
    }

    struct Scripted {
        grant: Option<u64>,
        log: Arc<Mutex<Log>>,
    }

    impl StreamGate for Scripted {
        fn poll_admit(&mut self, _: &mut Context<'_>, want: u64) -> Poll<u64> {
            self.log.lock().asked.push(want);
            match self.grant {
                Some(grant) => {
                    let grant = grant.min(want);
                    self.log.lock().admitted.push(grant);
                    Poll::Ready(grant)
                }
                None => Poll::Pending,
            }
        }

        fn settle(&mut self, used: u64) {
            self.log.lock().settled.push(used);
        }
    }

    fn scripted(grant: Option<u64>) -> (Box<dyn StreamGate>, Arc<Mutex<Log>>) {
        let log = Arc::new(Mutex::new(Log::default()));
        (
            Box::new(Scripted {
                grant,
                log: log.clone(),
            }),
            log,
        )
    }

    #[test]
    fn a_waiting_gate_releases_what_the_gates_before_it_admitted() {
        let (first, first_log) = scripted(Some(10));
        let (second, second_log) = scripted(None);
        let mut stack = GateStack([first, second].into_iter().collect());
        let mut cx = Context::from_waker(Waker::noop());

        assert!(stack.poll_admit(&mut cx, 100).is_pending());
        assert_eq!(first_log.lock().admitted, [10]);
        assert_eq!(first_log.lock().settled, [0]);
        assert!(second_log.lock().settled.is_empty());
    }

    #[test]
    fn every_gate_admits_and_settles_what_the_stack_moves() {
        let (first, first_log) = scripted(Some(10));
        let (second, second_log) = scripted(Some(5));
        let mut stack = GateStack([first, second].into_iter().collect());
        let mut cx = Context::from_waker(Waker::noop());

        assert_eq!(stack.poll_admit(&mut cx, 100), Poll::Ready(5));
        stack.settle(3);
        assert_eq!(first_log.lock().asked, [100]);
        assert_eq!(
            second_log.lock().asked,
            [10],
            "a later gate is asked for what earlier ones admitted"
        );
        assert_eq!(first_log.lock().admitted, [10]);
        assert_eq!(second_log.lock().admitted, [5]);
        assert_eq!(first_log.lock().settled, [3]);
        assert_eq!(second_log.lock().settled, [3]);
    }
}
