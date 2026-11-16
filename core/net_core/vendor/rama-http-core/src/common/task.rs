use std::task::{Context, Poll};

/// A function to help "yield" a future, such that it is re-scheduled immediately.
///
/// Useful for spin counts, so a future doesn't hog too much time.
#[expect(clippy::needless_pass_by_ref_mut)]
pub(crate) fn yield_now(cx: &mut Context<'_>) -> Poll<std::convert::Infallible> {
    cx.waker().wake_by_ref();
    Poll::Pending
}
