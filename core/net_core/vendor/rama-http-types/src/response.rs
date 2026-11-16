use std::{
    borrow::Cow,
    convert::TryInto,
    fmt::{self, Display},
};

use rama_core::extensions::{Extension, Extensions, ExtensionsRef};
use rama_utils::macros::generate_set_and_with;

use crate::{
    Body, Result,
    header::{HeaderMap, HeaderName, HeaderValue},
    proto::h1::ext::ReasonPhrase,
    status::StatusCode,
    version::Version,
};

/// Represents an HTTP response
///
/// An HTTP response consists of a head and a potentially optional body. The body
/// component is generic, enabling arbitrary types to represent the HTTP body.
/// For example, the body could be `Vec<u8>`, a `Stream` of byte chunks, or a
/// value that has been deserialized.
///
/// The Serde representation contains `status`, `version`, `headers`, and
/// `body`. Typed [`Extensions`] are process-local values and are intentionally
/// omitted. Deserializing therefore creates empty extensions.
///
/// Typically you'll work with responses on the client side as the result of
/// sending a `Request` and on the server you'll be generating a `Response` to
/// send back to the client.
///
/// # Examples
///
/// Creating a `Response` to return
///
/// ```
/// use rama_http_types::{Request, Response, StatusCode};
///
/// fn respond_to(req: Request<()>) -> rama_http_types::Result<Response<()>> {
///     let mut builder = Response::builder()
///         .header("Foo", "Bar")
///         .status(StatusCode::OK);
///
///     if req.headers().contains_key("Another-Header") {
///         builder = builder.header("Another-Header", "Ack");
///     }
///
///     builder.body(())
/// }
/// ```
///
/// A simple 404 handler
///
/// ```
/// use rama_http_types::{Request, Response, StatusCode};
///
/// fn not_found(_req: Request<()>) -> rama_http_types::Result<Response<()>> {
///     Response::builder()
///         .status(StatusCode::NOT_FOUND)
///         .body(())
/// }
/// ```
///
/// Or otherwise inspecting the result of a request:
///
/// ```no_run
/// use rama_http_types::{Request, Response};
///
/// fn get(url: &str) -> rama_http_types::Result<Response<()>> {
///     // ...
/// # panic!()
/// }
///
/// let response = get("https://www.rust-lang.org/").unwrap();
///
/// if !response.status().is_success() {
///     panic!("failed to get a successful response status!");
/// }
///
/// if let Some(date) = response.headers().get("Date") {
///     // we've got a `Date` header!
/// }
///
/// let body = response.body();
/// // ...
/// ```
///
/// Deserialize a response of bytes via json:
///
/// ```
/// use rama_http_types::Response;
/// use serde::de;
///
/// fn deserialize<T>(res: Response<Vec<u8>>) -> serde_json::Result<Response<T>>
///     where for<'de> T: de::Deserialize<'de>,
/// {
///     let (parts, body) = res.into_parts();
///     let body = serde_json::from_slice(&body)?;
///     Ok(Response::from_parts(parts, body))
/// }
/// #
/// # fn main() {}
/// ```
///
/// Or alternatively, serialize the body of a response to json
///
/// ```
/// use rama_http_types::Response;
/// use serde::ser;
///
/// fn serialize<T>(res: Response<T>) -> serde_json::Result<Response<Vec<u8>>>
///     where T: ser::Serialize,
/// {
///     let (parts, body) = res.into_parts();
///     let body = serde_json::to_vec(&body)?;
///     Ok(Response::from_parts(parts, body))
/// }
/// #
/// # fn main() {}
/// ```
#[derive(Clone)]
pub struct Response<T = Body> {
    head: Parts,
    // Safety invariant: pinning is structural for `body`. `Response` has no `Drop`
    // impl, no manual `Unpin` impl, is not `repr(packed)`, and no method takes
    // `Pin<&mut Self>` and moves `body` out.
    body: T,
}

/// Component parts of an HTTP `Response`
///
/// The HTTP response head consists of a status, version, and a set of
/// header fields.
#[non_exhaustive]
#[derive(Clone)]
pub struct Parts {
    /// The response's status
    pub status: StatusCode,

    /// The response's version
    pub version: Version,

    /// The response's headers
    pub headers: HeaderMap<HeaderValue>,

    /// The response's extensions
    pub extensions: Extensions,
}

#[derive(serde::Deserialize)]
#[serde(rename = "ResponseParts")]
struct ResponsePartsSerde {
    status: StatusCode,
    version: Version,
    headers: HeaderMap<HeaderValue>,
}

impl serde::Serialize for Parts {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        use serde::ser::SerializeStruct as _;

        let mut state = serializer.serialize_struct("ResponseParts", 3)?;
        state.serialize_field("status", &self.status)?;
        state.serialize_field("version", &self.version)?;
        state.serialize_field("headers", &self.headers)?;
        state.end()
    }
}

impl<'de> serde::Deserialize<'de> for Parts {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let repr = ResponsePartsSerde::deserialize(deserializer)?;
        Ok(Self {
            status: repr.status,
            version: repr.version,
            headers: repr.headers,
            extensions: Extensions::new(),
        })
    }
}

impl<T: serde::Serialize> serde::Serialize for Response<T> {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        use serde::ser::SerializeStruct as _;

        let mut state = serializer.serialize_struct("Response", 4)?;
        state.serialize_field("status", &self.head.status)?;
        state.serialize_field("version", &self.head.version)?;
        state.serialize_field("headers", &self.head.headers)?;
        state.serialize_field("body", &self.body)?;
        state.end()
    }
}

#[derive(serde::Deserialize)]
#[serde(rename = "Response")]
struct ResponseSerde<T> {
    status: StatusCode,
    version: Version,
    headers: HeaderMap<HeaderValue>,
    body: T,
}

impl<'de, T: serde::Deserialize<'de>> serde::Deserialize<'de> for Response<T> {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let repr = ResponseSerde::deserialize(deserializer)?;
        Ok(Self {
            head: Parts {
                status: repr.status,
                version: repr.version,
                headers: repr.headers,
                extensions: Extensions::new(),
            },
            body: repr.body,
        })
    }
}

impl ExtensionsRef for Parts {
    fn extensions(&self) -> &Extensions {
        &self.extensions
    }
}

/// An HTTP response builder
///
/// This type can be used to construct an instance of `Response` through a
/// builder-like pattern.
#[derive(Debug)]
#[must_use]
pub struct Builder {
    inner: Result<Parts>,
}

impl Response<()> {
    /// Creates a new builder-style object to manufacture a `Response`
    ///
    /// This method returns an instance of `Builder` which can be used to
    /// create a `Response`.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let response = Response::builder()
    ///     .status(200)
    ///     .header("X-Custom-Foo", "Bar")
    ///     .body(())
    ///     .unwrap();
    /// ```
    #[inline]
    pub fn builder() -> Builder {
        Builder::new()
    }

    #[inline]
    /// Same as [`Response::builder`] but with the given [`Extensions`] to start from.
    pub fn builder_with_extensions(ext: Extensions) -> Builder {
        Builder::new_with_extensions(ext)
    }
}

impl<T> Response<T> {
    /// Creates a new blank `Response` with the body
    ///
    /// The component parts of this response will be set to their default, e.g.
    /// the ok status, no headers, etc.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let response = Response::new("hello world");
    ///
    /// assert_eq!(response.status(), StatusCode::OK);
    /// assert_eq!(*response.body(), "hello world");
    /// ```
    #[inline]
    pub fn new(body: T) -> Self {
        Self {
            head: Parts::new(),
            body,
        }
    }

    /// Creates a new `Response` with the given head and body
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let response = Response::new("hello world");
    /// let (mut parts, body) = response.into_parts();
    ///
    /// parts.status = StatusCode::BAD_REQUEST;
    /// let response = Response::from_parts(parts, body);
    ///
    /// assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    /// assert_eq!(*response.body(), "hello world");
    /// ```
    #[inline]
    pub fn from_parts(parts: Parts, body: T) -> Self {
        Self { head: parts, body }
    }

    /// Returns the `StatusCode`.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let response: Response<()> = Response::default();
    /// assert_eq!(response.status(), StatusCode::OK);
    /// ```
    #[inline]
    pub fn status(&self) -> StatusCode {
        self.head.status
    }

    /// Returns a mutable reference to the associated `StatusCode`.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let mut response: Response<()> = Response::default();
    /// *response.status_mut() = StatusCode::CREATED;
    /// assert_eq!(response.status(), StatusCode::CREATED);
    /// ```
    #[inline]
    pub fn status_mut(&mut self) -> &mut StatusCode {
        &mut self.head.status
    }

    /// Turn a response into an error if the server returned an error.
    ///
    /// # Example
    ///
    /// ```
    /// # use rama_http_types::Response;
    /// fn on_response(res: Response) {
    ///     match res.error_for_status() {
    ///         Ok(_res) => (),
    ///         Err(err) => {
    ///             // asserting a 400 as an example
    ///             // it could be any status between 400...599
    ///             assert_eq!(
    ///                 err.status(),
    ///                 rama_http_types::StatusCode::BAD_REQUEST,
    ///             );
    ///         }
    ///     }
    /// }
    /// # fn main() {}
    /// ```
    pub fn error_for_status(self) -> std::result::Result<Self, StatusCodeError> {
        let status = self.status();

        if status.is_client_error() || status.is_server_error() {
            Err(StatusCodeError {
                status,
                reason: match self.extensions().get_ref::<ReasonPhrase>() {
                    Some(reason) => Some(
                        String::from_utf8_lossy(reason.as_bytes())
                            .into_owned()
                            .into(),
                    ),
                    None => status.canonical_reason().map(Into::into),
                },
            })
        } else {
            Ok(self)
        }
    }

    /// Turn a reference to a response into an error if the server returned an error.
    ///
    /// # Example
    ///
    /// ```
    /// # use rama_http_types::Response;
    /// fn on_response(res: &Response) {
    ///     match res.error_for_status_ref() {
    ///         Ok(_res) => (),
    ///         Err(err) => {
    ///             // asserting a 400 as an example
    ///             // it could be any status between 400...599
    ///             assert_eq!(
    ///                 err.status(),
    ///                 rama_http_types::StatusCode::BAD_REQUEST
    ///             );
    ///         }
    ///     }
    /// }
    /// # fn main() {}
    /// ```
    pub fn error_for_status_ref(&self) -> std::result::Result<&Self, StatusCodeError> {
        let status = self.status();

        if status.is_client_error() || status.is_server_error() {
            Err(StatusCodeError {
                status,
                reason: match self.extensions().get_ref::<ReasonPhrase>() {
                    Some(reason) => Some(
                        String::from_utf8_lossy(reason.as_bytes())
                            .into_owned()
                            .into(),
                    ),
                    None => status.canonical_reason().map(Into::into),
                },
            })
        } else {
            Ok(self)
        }
    }

    /// Returns a reference to the associated version.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let response: Response<()> = Response::default();
    /// assert_eq!(response.version(), Version::HTTP_11);
    /// ```
    #[inline]
    pub fn version(&self) -> Version {
        self.head.version
    }

    /// Returns a mutable reference to the associated version.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let mut response: Response<()> = Response::default();
    /// *response.version_mut() = Version::HTTP_2;
    /// assert_eq!(response.version(), Version::HTTP_2);
    /// ```
    #[inline]
    pub fn version_mut(&mut self) -> &mut Version {
        &mut self.head.version
    }

    /// Returns a reference to the associated header field map.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let response: Response<()> = Response::default();
    /// assert!(response.headers().is_empty());
    /// ```
    #[inline]
    pub fn headers(&self) -> &HeaderMap<HeaderValue> {
        &self.head.headers
    }

    /// Returns a mutable reference to the associated header field map.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// # use rama_http_types::header::*;
    /// let mut response: Response<()> = Response::default();
    /// response.headers_mut().insert(HOST, HeaderValue::from_static("world"));
    /// assert!(!response.headers().is_empty());
    /// ```
    #[inline]
    pub fn headers_mut(&mut self) -> &mut HeaderMap<HeaderValue> {
        &mut self.head.headers
    }

    /// Returned a cloned of the associated HTTP header.
    #[inline]
    pub fn clone_parts(&self) -> Parts {
        self.head.clone()
    }

    /// Returns a reference to the associated HTTP body.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let response: Response<String> = Response::default();
    /// assert!(response.body().is_empty());
    /// ```
    #[inline]
    pub fn body(&self) -> &T {
        &self.body
    }

    /// Returns a mutable reference to the associated HTTP body.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let mut response: Response<String> = Response::default();
    /// response.body_mut().push_str("hello world");
    /// assert!(!response.body().is_empty());
    /// ```
    ///
    /// # Safety-usable invariant
    ///
    /// Returns a reference to the `body` field of `self` and moves nothing.
    #[inline]
    pub fn body_mut(&mut self) -> &mut T {
        &mut self.body
    }

    /// Consumes the response, returning just the body.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::Response;
    /// let response = Response::new(10);
    /// let body = response.into_body();
    /// assert_eq!(body, 10);
    /// ```
    #[inline]
    pub fn into_body(self) -> T {
        self.body
    }

    /// Consumes the response returning the head and body parts.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let response: Response<()> = Response::default();
    /// let (parts, body) = response.into_parts();
    /// assert_eq!(parts.status, StatusCode::OK);
    /// ```
    #[inline]
    pub fn into_parts(self) -> (Parts, T) {
        (self.head, self.body)
    }

    /// Consumes the response returning a new response with body mapped to the
    /// return type of the passed in function.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let response = Response::builder().body("some string").unwrap();
    /// let mapped_response: Response<&[u8]> = response.map(|b| {
    ///   assert_eq!(b, "some string");
    ///   b.as_bytes()
    /// });
    /// assert_eq!(mapped_response.body(), &"some string".as_bytes());
    /// ```
    #[inline]
    pub fn map<F, U>(self, f: F) -> Response<U>
    where
        F: FnOnce(T) -> U,
    {
        Response {
            body: f(self.body),
            head: self.head,
        }
    }

    generate_set_and_with! {
        pub fn extensions(mut self, extensions: Extensions) -> Self {
            self.head.extensions = extensions;
            self
        }
    }

    /// Replace this response's [`Extensions`] with a [`fork`][Extensions::fork] of them, returning
    /// the original store.
    ///
    /// See [`Request::fork_extensions_in_place`](crate::Request::fork_extensions_in_place).
    #[must_use]
    pub fn fork_extensions_in_place(&mut self) -> Extensions {
        let child = self.head.extensions.fork();
        core::mem::replace(&mut self.head.extensions, child)
    }
}

impl<T: Default> Default for Response<T> {
    #[inline]
    fn default() -> Self {
        Self::new(T::default())
    }
}

impl<T: fmt::Debug> fmt::Debug for Response<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Response")
            .field("status", &self.status())
            .field("version", &self.version())
            .field("headers", self.headers())
            // omits Extensions because not useful
            .field("body", self.body())
            .finish()
    }
}

impl<T> ExtensionsRef for Response<T> {
    fn extensions(&self) -> &Extensions {
        &self.head.extensions
    }
}

#[derive(Debug)]
/// Error generated by a client or server status code.
pub struct StatusCodeError {
    status: StatusCode,
    reason: Option<Cow<'static, str>>,
}

impl StatusCodeError {
    pub fn status(&self) -> StatusCode {
        self.status
    }

    pub fn reason(&self) -> Option<&str> {
        self.reason.as_deref()
    }
}

impl Display for StatusCodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.status.is_client_error() {
            write!(
                f,
                "http client error: status={}; reason: '{}'",
                self.status,
                self.reason.as_deref().unwrap_or_default(),
            )
        } else if self.status.is_server_error() {
            write!(
                f,
                "http server error: status={}; reason: '{}'",
                self.status,
                self.reason.as_deref().unwrap_or_default(),
            )
        } else {
            write!(
                f,
                "http error: status={}; reason: '{}'",
                self.status,
                self.reason.as_deref().unwrap_or_default(),
            )
        }
    }
}

impl std::error::Error for StatusCodeError {}

impl Default for Parts {
    fn default() -> Self {
        Self::new()
    }
}

impl Parts {
    /// Creates a new default instance of `Parts`
    fn new() -> Self {
        Self {
            status: StatusCode::default(),
            version: Version::default(),
            headers: HeaderMap::default(),
            extensions: Extensions::default(),
        }
    }
}

impl fmt::Debug for Parts {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Parts")
            .field("status", &self.status)
            .field("version", &self.version)
            .field("headers", &self.headers)
            // omits Extensions because not useful
            // omits _priv because not useful
            .finish()
    }
}

impl Builder {
    /// Creates a new default instance of `Builder` to construct either a
    /// `Head` or a `Response`.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let response = response::Builder::new()
    ///     .status(200)
    ///     .body(())
    ///     .unwrap();
    /// ```
    #[inline]
    pub fn new() -> Self {
        Self::default()
    }

    #[inline]
    /// Same as [`Self::new`] but with the given [`Extensions`] to start from.
    pub fn new_with_extensions(ext: Extensions) -> Self {
        Self {
            inner: Ok(Parts {
                status: StatusCode::default(),
                version: Version::default(),
                headers: HeaderMap::default(),
                extensions: ext,
            }),
        }
    }

    /// Set the HTTP status for this response.
    ///
    /// By default this is `200`.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let response = Response::builder()
    ///     .status(200)
    ///     .body(())
    ///     .unwrap();
    /// ```
    pub fn status<T>(self, status: T) -> Self
    where
        T: TryInto<StatusCode>,
        <T as TryInto<StatusCode>>::Error: Into<crate::Error>,
    {
        self.and_then(move |mut head| {
            head.status = status.try_into().map_err(Into::into)?;
            Ok(head)
        })
    }

    /// Set the HTTP version for this response.
    ///
    /// By default this is HTTP/1.1
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let response = Response::builder()
    ///     .version(Version::HTTP_2)
    ///     .body(())
    ///     .unwrap();
    /// ```
    pub fn version(self, version: Version) -> Self {
        self.and_then(move |mut head| {
            head.version = version;
            Ok(head)
        })
    }

    /// Appends a header to this response builder.
    ///
    /// This function will append the provided key/value as a header to the
    /// internal `HeaderMap` being constructed. Essentially this is equivalent
    /// to calling `HeaderMap::append`.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// # use rama_http_types::header::HeaderValue;
    ///
    /// let response = Response::builder()
    ///     .header("Content-Type", "text/html")
    ///     .header("X-Custom-Foo", "bar")
    ///     .header("content-length", 0)
    ///     .body(())
    ///     .unwrap();
    /// ```
    pub fn header<K, V>(self, key: K, value: V) -> Self
    where
        K: TryInto<HeaderName>,
        <K as TryInto<HeaderName>>::Error: Into<crate::Error>,
        V: TryInto<HeaderValue>,
        <V as TryInto<HeaderValue>>::Error: Into<crate::Error>,
    {
        self.and_then(move |mut head| {
            let name = key.try_into().map_err(Into::into)?;
            let value = value.try_into().map_err(Into::into)?;
            head.headers.try_append(name, value)?;
            Ok(head)
        })
    }

    /// Get header on this response builder.
    ///
    /// When builder has error returns None.
    ///
    /// # Example
    ///
    /// ```
    /// # use rama_http_types::Response;
    /// # use rama_http_types::header::HeaderValue;
    /// let res = Response::builder()
    ///     .header("Accept", "text/html")
    ///     .header("X-Custom-Foo", "bar");
    /// let headers = res.headers_ref().unwrap();
    /// assert_eq!( headers["Accept"], "text/html" );
    /// assert_eq!( headers["X-Custom-Foo"], "bar" );
    /// ```
    #[must_use]
    pub fn headers_ref(&self) -> Option<&HeaderMap<HeaderValue>> {
        self.inner.as_ref().ok().map(|h| &h.headers)
    }

    /// Get header on this response builder.
    /// when builder has error returns None
    ///
    /// # Example
    ///
    /// ```
    /// # use rama_http_types::*;
    /// # use rama_http_types::header::HeaderValue;
    /// # use rama_http_types::response::Builder;
    /// let mut res = Response::builder();
    /// {
    ///   let headers = res.headers_mut().unwrap();
    ///   headers.insert("Accept", HeaderValue::from_static("text/html"));
    ///   headers.insert("X-Custom-Foo", HeaderValue::from_static("bar"));
    /// }
    /// let headers = res.headers_ref().unwrap();
    /// assert_eq!( headers["Accept"], "text/html" );
    /// assert_eq!( headers["X-Custom-Foo"], "bar" );
    /// ```
    pub fn headers_mut(&mut self) -> Option<&mut HeaderMap<HeaderValue>> {
        self.inner.as_mut().ok().map(|h| &mut h.headers)
    }

    /// Adds an extension to this builder
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::Response;
    /// # use rama_core::extensions::{Extension, ExtensionsRef as _};
    ///
    /// #[derive(Debug, Clone, PartialEq)]
    /// struct MyExtension(&'static str);
    /// impl Extension for MyExtension {}
    ///
    /// let response = Response::builder()
    ///     .extension(MyExtension("My Extension"))
    ///     .body(())
    ///     .unwrap();
    ///
    /// assert_eq!(response.extensions().get_ref::<MyExtension>(),
    ///            Some(&MyExtension("My Extension")));
    /// ```
    pub fn extension<T>(self, extension: T) -> Self
    where
        T: Extension,
    {
        self.and_then(move |head| {
            head.extensions.insert(extension);
            Ok(head)
        })
    }

    /// Get a reference to the extensions for this response builder.
    ///
    /// If the builder has an error, this returns `None`.
    ///
    /// # Example
    ///
    /// ```
    /// # use rama_http_types::Response;
    /// # use rama_core::extensions::Extension;
    /// #[derive(Debug, Clone, PartialEq)]
    /// struct MyExtension(&'static str);
    /// impl Extension for MyExtension {}
    ///
    /// #[derive(Debug, Clone, PartialEq)]
    /// struct MyCount(u32);
    /// impl Extension for MyCount {}
    ///
    /// let res = Response::builder().extension(MyExtension("My Extension")).extension(MyCount(5));
    /// let extensions = res.extensions().unwrap();
    /// assert_eq!(extensions.get_ref::<MyExtension>(), Some(&MyExtension("My Extension")));
    /// assert_eq!(extensions.get_ref::<MyCount>(), Some(&MyCount(5)));
    /// ```
    #[must_use]
    pub fn extensions(&self) -> Option<&Extensions> {
        self.inner.as_ref().ok().map(|h| &h.extensions)
    }

    /// "Consumes" this builder, using the provided `body` to return a
    /// constructed `Response`.
    ///
    /// # Errors
    ///
    /// This function may return an error if any previously configured argument
    /// failed to parse or get converted to the internal representation. For
    /// example if an invalid `head` was specified via `header("Foo",
    /// "Bar\r\n")` the error will be returned when this function is called
    /// rather than when `header` was called.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let response = Response::builder()
    ///     .body(())
    ///     .unwrap();
    /// ```
    pub fn body<T>(self, body: T) -> Result<Response<T>> {
        self.inner.map(move |head| Response { head, body })
    }

    // private

    fn and_then<F>(self, func: F) -> Self
    where
        F: FnOnce(Parts) -> Result<Parts>,
    {
        Self {
            inner: self.inner.and_then(func),
        }
    }
}

impl Default for Builder {
    #[inline]
    fn default() -> Self {
        Self {
            inner: Ok(Parts::new()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_can_map_a_body_from_one_type_to_another() {
        let response = Response::builder().body("some string").unwrap();
        let mapped_response = response.map(|s| {
            assert_eq!(s, "some string");
            123u32
        });
        assert_eq!(mapped_response.body(), &123u32);
    }

    #[test]
    fn fork_extensions_in_place_isolates_the_child_from_the_parent() {
        #[derive(Debug, Extension)]
        struct Source;
        #[derive(Debug, Extension)]
        struct Child;

        let mut response = Response::new(());
        response.extensions().insert(Source);

        let parent = response.fork_extensions_in_place();
        response.extensions().insert(Child);

        assert!(response.extensions().contains::<Source>());
        assert!(!parent.contains::<Child>());

        // ... so a second child forks from an untouched parent
        response.set_extensions(parent.fork());
        assert!(response.extensions().contains::<Source>());
        assert!(!response.extensions().contains::<Child>());
    }
}
