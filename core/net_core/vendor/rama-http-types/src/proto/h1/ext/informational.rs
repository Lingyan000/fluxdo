//! Register callbacks for 1xx HTTP/1 responses on the client.

use rama_core::extensions::Extension;
use std::sync::Arc;

#[derive(Clone, Extension)]
#[extension(tags(http))]
pub struct OnInformational(Arc<dyn OnInformationalCallback + Send + Sync>);

impl OnInformational {
    /// Create a function callback for 1xx informational responses.
    ///
    /// To be inserted in the request extensions for usage at response time.
    #[must_use]
    pub fn new_fn(callback: impl Fn(Response<'_>) + Send + Sync + 'static) -> Self {
        Self(Arc::new(OnInformationalClosure(callback)))
    }
}

impl std::fmt::Debug for OnInformational {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("OnInformational").finish()
    }
}

// Sealed, not actually nameable bounds
pub(crate) trait OnInformationalCallback {
    fn on_informational(&self, res: crate::Response<()>);
}

impl OnInformational {
    /// This function is only meant for the http backend to be called.
    ///
    /// As a user of this extensions you have usually no need to do that yourself.
    pub fn call(&self, res: crate::Response<()>) {
        self.0.on_informational(res);
    }
}

struct OnInformationalClosure<F>(F);

impl<F> OnInformationalCallback for OnInformationalClosure<F>
where
    F: Fn(Response<'_>) + Send + Sync + 'static,
{
    fn on_informational(&self, res: crate::Response<()>) {
        let res = Response(&res);
        (self.0)(res);
    }
}

/// A facade over [`crate::Response`].
///
/// It purposefully hides being able to move the response out of the closure,
/// while also not being able to expect it to be a reference `&Response`.
/// (Otherwise, a closure can be written as `|res: &_|`, and then be broken if
/// we make the closure take ownership.)
///
/// With the type not being nameable, we could change from being a facade to
/// being either a real reference, or moving the [`crate::Response`] into the closure,
/// in a backwards-compatible change in the future.
#[derive(Debug)]
pub struct Response<'a>(&'a crate::Response<()>);

impl Response<'_> {
    #[inline]
    pub fn status(&self) -> crate::StatusCode {
        self.0.status()
    }

    #[inline]
    pub fn version(&self) -> crate::Version {
        self.0.version()
    }

    #[inline]
    pub fn headers(&self) -> &crate::HeaderMap {
        self.0.headers()
    }
}
