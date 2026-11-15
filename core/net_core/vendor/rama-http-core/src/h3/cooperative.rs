//! Cooperative scheduling for loops whose I/O can remain immediately ready.
//!
//! A quantum counts bounded frames/chunks or transport polls, not bytes: payload
//! sizes are capped separately. 32 operations amortize wakeups while preventing
//! empty frames and tiny writes from monopolizing an executor worker.

pub(super) const OPERATIONS_PER_QUANTUM: usize = 32;

#[derive(Default)]
pub(super) struct Budget {
    operations: usize,
}

impl Budget {
    pub(super) async fn consume(&mut self) {
        self.operations += 1;
        if self.operations == OPERATIONS_PER_QUANTUM {
            self.operations = 0;
            tokio::task::yield_now().await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        cell::Cell,
        future::Future,
        task::{Context, Waker},
    };

    #[test]
    fn immediately_ready_work_yields_once_per_quantum() {
        let completed = Cell::new(0);
        let mut work = std::pin::pin!(async {
            let mut budget = Budget::default();
            for _ in 0..OPERATIONS_PER_QUANTUM * 2 {
                budget.consume().await;
                completed.set(completed.get() + 1);
            }
        });
        let mut cx = Context::from_waker(Waker::noop());
        assert!(work.as_mut().poll(&mut cx).is_pending());
        assert_eq!(completed.get(), OPERATIONS_PER_QUANTUM - 1);
        assert!(work.as_mut().poll(&mut cx).is_pending());
        assert_eq!(completed.get(), OPERATIONS_PER_QUANTUM * 2 - 1);
        assert!(work.as_mut().poll(&mut cx).is_ready());
        assert_eq!(completed.get(), OPERATIONS_PER_QUANTUM * 2);
    }
}
