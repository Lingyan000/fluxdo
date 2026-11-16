//! HTTP fingerprint implementations (JA4H, Akamai HTTP/2).

mod akamai;
#[doc(inline)]
pub use akamai::{AkamaiH2, AkamaiH2ComputeError};

mod ja4;
#[doc(inline)]
pub use ja4::{Ja4H, Ja4HComputeError};

mod http_utils {
    use private::HttpRequestProviderPriv;

    use crate::{HeaderMap, Method, Version};

    #[derive(Debug, Clone)]
    /// Minimal input data structure which can be used
    /// by ja4h computation functions instead of a reference
    /// to a [`crate::Request`].
    pub struct HttpRequestInput {
        pub header_map: HeaderMap,
        pub http_method: Method,
        pub version: Version,
    }

    /// Sealed trait used by the ja4h computation functions,
    /// to allow you to immediately compute from borrowed [`crate::HttpRequestParts`]
    /// or a [`HttpRequestInput`] data structure.
    pub trait HttpRequestProvider: HttpRequestProviderPriv {}
    impl<P: HttpRequestProviderPriv> HttpRequestProvider for P {}

    mod private {
        use super::*;
        use crate::HttpRequestParts;

        pub trait HttpRequestProviderPriv {
            fn http_request_input(&self) -> (&HeaderMap, &Method, Version);
        }

        impl<P> HttpRequestProviderPriv for &P
        where
            P: HttpRequestParts + ?Sized,
        {
            fn http_request_input(&self) -> (&HeaderMap, &Method, Version) {
                (self.headers(), self.method(), self.version())
            }
        }

        impl HttpRequestProviderPriv for HttpRequestInput {
            #[inline(always)]
            fn http_request_input(&self) -> (&HeaderMap, &Method, Version) {
                (&self.header_map, &self.http_method, self.version)
            }
        }
    }
}

#[doc(inline)]
pub use http_utils::{HttpRequestInput, HttpRequestProvider};
