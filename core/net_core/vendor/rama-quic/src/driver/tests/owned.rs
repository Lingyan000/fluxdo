//! A task a test owns, shared by the test modules that spawn one.

use std::future::Future;

use tokio::task::JoinHandle;

/// A task the case owns: it is aborted if the case ends without waiting for it, and its panics
/// come back through the wait.
pub(super) struct Owned<T>(Option<JoinHandle<T>>);

impl<T: Send + 'static> Owned<T> {
    pub(super) fn spawn(task: impl Future<Output = T> + Send + 'static) -> Self {
        Self(Some(tokio::spawn(task)))
    }

    pub(super) async fn join(mut self) -> T {
        let handle = self.0.as_mut().expect("waited on once");
        let outcome = handle.await;
        self.0 = None;
        match outcome {
            Ok(value) => value,
            Err(error) if error.is_panic() => std::panic::resume_unwind(error.into_panic()),
            Err(error) => panic!("the server task ended: {error}"),
        }
    }
}

impl<T> Drop for Owned<T> {
    fn drop(&mut self) {
        if let Some(handle) = self.0.take() {
            handle.abort();
        }
    }
}
