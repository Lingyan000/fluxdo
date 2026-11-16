use std::fmt;

use rama_core::extensions::{Extension, Extensions, ExtensionsMut, ExtensionsRef};
use rama_net::ClientIp;
use rama_utils::macros::generate_set_and_with;

use crate::{HeaderMap, HeaderName, HeaderValue, Method, Result, Uri, Version, body::Body};

/// Represents an HTTP request.
///
/// An HTTP request consists of a head and a potentially optional body. The body
/// component is generic, enabling arbitrary types to represent the HTTP body.
/// For example, the body could be `Vec<u8>`, a `Stream` of byte chunks, or a
/// value that has been deserialized.
///
/// The Serde representation contains `method`, `uri`, `version`, `headers`,
/// and `body`. Typed [`Extensions`] are process-local values and are
/// intentionally omitted. Deserializing therefore creates empty extensions.
///
/// # Examples
///
/// Creating a `Request` to send
///
/// ```no_run
/// use rama_http_types::{Request, Response};
///
/// let mut request = Request::builder()
///     .uri("https://www.rust-lang.org/")
///     .header("User-Agent", "my-awesome-agent/1.0");
///
/// if needs_awesome_header() {
///     request = request.header("Awesome", "yes");
/// }
///
/// let response = send(request.body(()).unwrap());
///
/// # fn needs_awesome_header() -> bool {
/// #     true
/// # }
/// #
/// fn send(req: Request<()>) -> Response<()> {
///     // ...
/// # panic!()
/// }
/// ```
///
/// Inspecting a request to see what was sent.
///
/// ```
/// use rama_http_types::{Request, Response, Result, StatusCode};
///
/// fn respond_to(req: Request<()>) -> Result<Response<()>> {
///     if req.uri().as_str() != "/awesome-url" {
///         return Response::builder()
///             .status(StatusCode::NOT_FOUND)
///             .body(())
///     }
///
///     let has_awesome_header = req.headers().contains_key("Awesome");
///     let body = req.body();
///
///     // ...
/// # panic!()
/// }
/// ```
///
/// Deserialize a request of bytes via json:
///
/// ```
/// use rama_http_types::Request;
/// use serde::de;
///
/// fn deserialize<T>(req: Request<Vec<u8>>) -> serde_json::Result<Request<T>>
///     where for<'de> T: de::Deserialize<'de>,
/// {
///     let (parts, body) = req.into_parts();
///     let body = serde_json::from_slice(&body)?;
///     Ok(Request::from_parts(parts, body))
/// }
/// #
/// # fn main() {}
/// ```
///
/// Or alternatively, serialize the body of a request to json
///
/// ```
/// use rama_http_types::Request;
/// use serde::ser;
///
/// fn serialize<T>(req: Request<T>) -> serde_json::Result<Request<Vec<u8>>>
///     where T: ser::Serialize,
/// {
///     let (parts, body) = req.into_parts();
///     let body = serde_json::to_vec(&body)?;
///     Ok(Request::from_parts(parts, body))
/// }
/// #
/// # fn main() {}
/// ```
#[derive(Clone)]
pub struct Request<T = Body> {
    head: Parts,
    // Safety invariant: pinning is structural for `body`. `Request` has no `Drop`
    // impl, no manual `Unpin` impl, is not `repr(packed)`, and no method takes
    // `Pin<&mut Self>` and moves `body` out.
    body: T,
}

#[non_exhaustive]
#[derive(Clone)]
pub struct Parts {
    /// The request's method
    pub method: Method,

    /// The request's URI
    pub uri: Uri,

    /// The request's version
    pub version: Version,

    /// The request's headers
    pub headers: HeaderMap<HeaderValue>,

    /// The request's extensions
    pub extensions: Extensions,
}

#[derive(serde::Deserialize)]
#[serde(rename = "RequestParts")]
struct RequestPartsSerde {
    method: Method,
    uri: String,
    version: Version,
    headers: HeaderMap<HeaderValue>,
}

impl serde::Serialize for Parts {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        use serde::ser::SerializeStruct as _;

        let mut state = serializer.serialize_struct("RequestParts", 4)?;
        state.serialize_field("method", &self.method)?;
        state.serialize_field("uri", &self.uri)?;
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
        let repr = RequestPartsSerde::deserialize(deserializer)?;
        let uri =
            deserialize_request_uri(&repr.method, &repr.uri).map_err(serde::de::Error::custom)?;
        Ok(Self {
            method: repr.method,
            uri,
            version: repr.version,
            headers: repr.headers,
            extensions: Extensions::new(),
        })
    }
}

impl<T: serde::Serialize> serde::Serialize for Request<T> {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        use serde::ser::SerializeStruct as _;

        let mut state = serializer.serialize_struct("Request", 5)?;
        state.serialize_field("method", &self.head.method)?;
        state.serialize_field("uri", &self.head.uri)?;
        state.serialize_field("version", &self.head.version)?;
        state.serialize_field("headers", &self.head.headers)?;
        state.serialize_field("body", &self.body)?;
        state.end()
    }
}

#[derive(serde::Deserialize)]
#[serde(rename = "Request")]
struct RequestSerde<T> {
    method: Method,
    uri: String,
    version: Version,
    headers: HeaderMap<HeaderValue>,
    body: T,
}

impl<'de, T: serde::Deserialize<'de>> serde::Deserialize<'de> for Request<T> {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let repr = RequestSerde::deserialize(deserializer)?;
        let uri =
            deserialize_request_uri(&repr.method, &repr.uri).map_err(serde::de::Error::custom)?;
        Ok(Self {
            head: Parts {
                method: repr.method,
                uri,
                version: repr.version,
                headers: repr.headers,
                extensions: Extensions::new(),
            },
            body: repr.body,
        })
    }
}

fn deserialize_request_uri(method: &Method, value: &str) -> Result<Uri> {
    if method == Method::CONNECT {
        Uri::parse_authority_form(value).or_else(|_| Uri::parse_reference(value))
    } else {
        Uri::parse_reference(value)
    }
    .map_err(Into::into)
}

impl ExtensionsRef for Parts {
    fn extensions(&self) -> &Extensions {
        &self.extensions
    }
}

impl ExtensionsMut for Parts {
    fn extensions_mut(&mut self) -> &mut Extensions {
        &mut self.extensions
    }
}

impl ClientIp for Parts {
    fn client_ip(&self) -> Option<std::net::IpAddr> {
        rama_net::client_ip::client_ip(self)
    }
}

/// An HTTP request builder
///
/// This type can be used to construct an instance of `Request`
/// through a builder-like pattern.
#[derive(Debug)]
#[must_use]
pub struct Builder {
    inner: Result<Parts>,
}

impl Request<()> {
    /// Creates a new builder-style object to manufacture a `Request`
    ///
    /// This method returns an instance of `Builder` which can be used to
    /// create a `Request`.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let request = Request::builder()
    ///     .method("GET")
    ///     .uri("https://www.rust-lang.org/")
    ///     .header("X-Custom-Foo", "Bar")
    ///     .body(())
    ///     .unwrap();
    /// ```
    #[inline]
    pub fn builder() -> Builder {
        Builder::new()
    }

    #[inline]
    /// Same as [`Request::builder`] but with the given [`Extensions`] to start from.
    pub fn builder_with_extensions(ext: Extensions) -> Builder {
        Builder::new_with_extensions(ext)
    }

    /// Creates a new `Builder` initialized with a GET method and the given URI.
    ///
    /// This method returns an instance of `Builder` which can be used to
    /// create a `Request`.
    ///
    /// # Example
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let request = Request::get("https://www.rust-lang.org/")
    ///     .body(())
    ///     .unwrap();
    /// ```
    pub fn get<T>(uri: T) -> Builder
    where
        T: TryInto<Uri>,
        <T as TryInto<Uri>>::Error: Into<crate::Error>,
    {
        Builder::new().method(Method::GET).uri(uri)
    }

    /// Creates a new `Builder` initialized with a PUT method and the given URI.
    ///
    /// This method returns an instance of `Builder` which can be used to
    /// create a `Request`.
    ///
    /// # Example
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let request = Request::put("https://www.rust-lang.org/")
    ///     .body(())
    ///     .unwrap();
    /// ```
    pub fn put<T>(uri: T) -> Builder
    where
        T: TryInto<Uri>,
        <T as TryInto<Uri>>::Error: Into<crate::Error>,
    {
        Builder::new().method(Method::PUT).uri(uri)
    }

    /// Creates a new `Builder` initialized with a POST method and the given URI.
    ///
    /// This method returns an instance of `Builder` which can be used to
    /// create a `Request`.
    ///
    /// # Example
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let request = Request::post("https://www.rust-lang.org/")
    ///     .body(())
    ///     .unwrap();
    /// ```
    pub fn post<T>(uri: T) -> Builder
    where
        T: TryInto<Uri>,
        <T as TryInto<Uri>>::Error: Into<crate::Error>,
    {
        Builder::new().method(Method::POST).uri(uri)
    }

    /// Creates a new `Builder` initialized with a DELETE method and the given URI.
    ///
    /// This method returns an instance of `Builder` which can be used to
    /// create a `Request`.
    ///
    /// # Example
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let request = Request::delete("https://www.rust-lang.org/")
    ///     .body(())
    ///     .unwrap();
    /// ```
    pub fn delete<T>(uri: T) -> Builder
    where
        T: TryInto<Uri>,
        <T as TryInto<Uri>>::Error: Into<crate::Error>,
    {
        Builder::new().method(Method::DELETE).uri(uri)
    }

    /// Creates a new `Builder` initialized with an OPTIONS method and the given URI.
    ///
    /// This method returns an instance of `Builder` which can be used to
    /// create a `Request`.
    ///
    /// # Example
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let request = Request::options("https://www.rust-lang.org/")
    ///     .body(())
    ///     .unwrap();
    /// # assert_eq!(*request.method(), Method::OPTIONS);
    /// ```
    pub fn options<T>(uri: T) -> Builder
    where
        T: TryInto<Uri>,
        <T as TryInto<Uri>>::Error: Into<crate::Error>,
    {
        Builder::new().method(Method::OPTIONS).uri(uri)
    }

    /// Creates a new `Builder` initialized with a HEAD method and the given URI.
    ///
    /// This method returns an instance of `Builder` which can be used to
    /// create a `Request`.
    ///
    /// # Example
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let request = Request::head("https://www.rust-lang.org/")
    ///     .body(())
    ///     .unwrap();
    /// ```
    pub fn head<T>(uri: T) -> Builder
    where
        T: TryInto<Uri>,
        <T as TryInto<Uri>>::Error: Into<crate::Error>,
    {
        Builder::new().method(Method::HEAD).uri(uri)
    }

    /// Creates a new `Builder` initialized with a CONNECT method and the given URI.
    ///
    /// This method returns an instance of `Builder` which can be used to
    /// create a `Request`.
    ///
    /// # Example
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let request = Request::connect("https://www.rust-lang.org/")
    ///     .body(())
    ///     .unwrap();
    /// ```
    pub fn connect<T>(uri: T) -> Builder
    where
        T: TryInto<Uri>,
        <T as TryInto<Uri>>::Error: Into<crate::Error>,
    {
        Builder::new().method(Method::CONNECT).uri(uri)
    }

    /// Creates a new `Builder` initialized with a PATCH method and the given URI.
    ///
    /// This method returns an instance of `Builder` which can be used to
    /// create a `Request`.
    ///
    /// # Example
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let request = Request::patch("https://www.rust-lang.org/")
    ///     .body(())
    ///     .unwrap();
    /// ```
    pub fn patch<T>(uri: T) -> Builder
    where
        T: TryInto<Uri>,
        <T as TryInto<Uri>>::Error: Into<crate::Error>,
    {
        Builder::new().method(Method::PATCH).uri(uri)
    }

    /// Creates a new `Builder` initialized with a TRACE method and the given URI.
    ///
    /// This method returns an instance of `Builder` which can be used to
    /// create a `Request`.
    ///
    /// # Example
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let request = Request::trace("https://www.rust-lang.org/")
    ///     .body(())
    ///     .unwrap();
    /// ```
    pub fn trace<T>(uri: T) -> Builder
    where
        T: TryInto<Uri>,
        <T as TryInto<Uri>>::Error: Into<crate::Error>,
    {
        Builder::new().method(Method::TRACE).uri(uri)
    }

    /// Creates a new `Builder` initialized with a QUERY method and the given URI.
    ///
    /// QUERY ([RFC 10008](https://www.rfc-editor.org/rfc/rfc10008)) is a safe,
    /// idempotent method whose request content defines the query; remember to
    /// set a `Content-Type` for the body.
    ///
    /// This method returns an instance of `Builder` which can be used to
    /// create a `Request`.
    ///
    /// # Example
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let request = Request::query("https://www.rust-lang.org/")
    ///     .body(())
    ///     .unwrap();
    /// ```
    pub fn query<T>(uri: T) -> Builder
    where
        T: TryInto<Uri>,
        <T as TryInto<Uri>>::Error: Into<crate::Error>,
    {
        Builder::new().method(Method::QUERY).uri(uri)
    }
}

impl<T> Request<T> {
    /// Creates a new blank `Request` with the body
    ///
    /// The component parts of this request will be set to their default, e.g.
    /// the GET method, no headers, etc.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let request = Request::new("hello world");
    ///
    /// assert_eq!(*request.method(), Method::GET);
    /// assert_eq!(*request.body(), "hello world");
    /// ```
    #[inline]
    pub fn new(body: T) -> Self {
        Self {
            head: Parts::new(),
            body,
        }
    }

    /// Creates a new `Request` with the given components parts and body.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let request = Request::new("hello world");
    /// let (mut parts, body) = request.into_parts();
    /// parts.method = Method::POST;
    ///
    /// let request = Request::from_parts(parts, body);
    /// ```
    #[inline]
    pub fn from_parts(parts: Parts, body: T) -> Self {
        Self { head: parts, body }
    }

    /// Returns a reference to the associated HTTP method.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let request: Request<()> = Request::default();
    /// assert_eq!(*request.method(), Method::GET);
    /// ```
    #[inline]
    pub fn method(&self) -> &Method {
        &self.head.method
    }

    /// Returns a mutable reference to the associated HTTP method.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let mut request: Request<()> = Request::default();
    /// *request.method_mut() = Method::PUT;
    /// assert_eq!(*request.method(), Method::PUT);
    /// ```
    #[inline]
    pub fn method_mut(&mut self) -> &mut Method {
        &mut self.head.method
    }

    /// Returns a reference to the associated URI.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let request: Request<()> = Request::default();
    /// assert_eq!(request.uri().as_str(), "/");
    /// ```
    #[inline]
    pub fn uri(&self) -> &Uri {
        &self.head.uri
    }

    /// Get the URI as complete as possible for this request.
    ///
    /// Where [`uri`](Self::uri) returns the URI exactly as received (often
    /// origin-form `/path` for HTTP/1.1), this fills in the scheme and
    /// authority from the request's contextual protocol and authority (`Forwarded` →
    /// URI → `Host` header → TLS SNI) — a derivation callers can treat as a technical
    /// detail.
    #[must_use]
    pub fn request_uri(&self) -> Uri {
        use rama_net::{AuthorityInputExt as _, ProtocolInputExt as _};

        let mut uri = self.uri().clone();
        if let Some(authority) = self.authority() {
            let protocol = self.protocol().unwrap_or(&rama_net::Protocol::HTTP);
            let rama_net::address::HostWithOptPort { host, port } =
                authority.without_default_port_for(Some(protocol));
            uri.set_scheme(protocol.clone())
                .set_host(host)
                .set_port(port);
        }
        uri
    }

    /// Returns a mutable reference to the associated URI.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let mut request: Request<()> = Request::default();
    /// *request.uri_mut() = "/hello".parse().unwrap();
    /// assert_eq!(request.uri().as_str(), "/hello");
    /// ```
    #[inline]
    pub fn uri_mut(&mut self) -> &mut Uri {
        &mut self.head.uri
    }

    /// Returns the associated version.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let request: Request<()> = Request::default();
    /// assert_eq!(request.version(), Version::HTTP_11);
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
    /// let mut request: Request<()> = Request::default();
    /// *request.version_mut() = Version::HTTP_2;
    /// assert_eq!(request.version(), Version::HTTP_2);
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
    /// let request: Request<()> = Request::default();
    /// assert!(request.headers().is_empty());
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
    /// let mut request: Request<()> = Request::default();
    /// request.headers_mut().insert(HOST, HeaderValue::from_static("world"));
    /// assert!(!request.headers().is_empty());
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
    /// let request: Request<String> = Request::default();
    /// assert!(request.body().is_empty());
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
    /// let mut request: Request<String> = Request::default();
    /// request.body_mut().push_str("hello world");
    /// assert!(!request.body().is_empty());
    /// ```
    ///
    /// # Safety-usable invariant
    ///
    /// Returns a reference to the `body` field of `self` and moves nothing.
    #[inline]
    pub fn body_mut(&mut self) -> &mut T {
        &mut self.body
    }

    /// Consumes the request, returning just the body.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::Request;
    /// let request = Request::new(10);
    /// let body = request.into_body();
    /// assert_eq!(body, 10);
    /// ```
    #[inline]
    pub fn into_body(self) -> T {
        self.body
    }

    /// Consumes the request returning the head and body parts.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let request = Request::new(());
    /// let (parts, body) = request.into_parts();
    /// assert_eq!(parts.method, Method::GET);
    /// ```
    #[inline]
    pub fn into_parts(self) -> (Parts, T) {
        (self.head, self.body)
    }

    /// Consumes the request returning a new request with body mapped to the
    /// return type of the passed in function.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    /// let request = Request::builder().body("some string").unwrap();
    /// let mapped_request: Request<&[u8]> = request.map(|b| {
    ///   assert_eq!(b, "some string");
    ///   b.as_bytes()
    /// });
    /// assert_eq!(mapped_request.body(), &"some string".as_bytes());
    /// ```
    #[inline]
    pub fn map<F, U>(self, f: F) -> Request<U>
    where
        F: FnOnce(T) -> U,
    {
        Request {
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

    /// Replace this request's [`Extensions`] with a [`fork`][Extensions::fork] of them, returning
    /// the original store.
    ///
    /// Use this to give one attempt of a multi-attempt operation — a redirect hop, a retry — its
    /// own child store: the attempt reads everything the caller inserted, its own inserts land in
    /// the child, and the returned parent stays untouched so the next attempt can fork from it
    /// again.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::Request;
    /// # use rama_core::extensions::{Extension, ExtensionsRef as _};
    /// #[derive(Debug, Extension)]
    /// struct Caller;
    /// #[derive(Debug, Extension)]
    /// struct Attempt;
    ///
    /// let mut req = Request::new(());
    /// req.extensions().insert(Caller);
    ///
    /// let parent = req.fork_extensions_in_place();
    /// req.extensions().insert(Attempt);
    ///
    /// assert!(req.extensions().contains::<Caller>());
    /// assert!(!parent.contains::<Attempt>());
    /// ```
    #[must_use]
    pub fn fork_extensions_in_place(&mut self) -> Extensions {
        let child = self.head.extensions.fork();
        core::mem::replace(&mut self.head.extensions, child)
    }
}

impl<T: Default> Default for Request<T> {
    fn default() -> Self {
        Self::new(T::default())
    }
}

impl<T: fmt::Debug> fmt::Debug for Request<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Request")
            .field("method", self.method())
            .field("uri", self.uri())
            .field("version", &self.version())
            .field("headers", self.headers())
            // omits Extensions because not useful
            .field("body", self.body())
            .finish()
    }
}

impl<B> ExtensionsRef for Request<B> {
    fn extensions(&self) -> &Extensions {
        &self.head.extensions
    }
}

impl<B> ExtensionsMut for Request<B> {
    fn extensions_mut(&mut self) -> &mut Extensions {
        &mut self.head.extensions
    }
}

impl<B> ClientIp for Request<B> {
    fn client_ip(&self) -> Option<std::net::IpAddr> {
        rama_net::client_ip::client_ip(self)
    }
}

impl Default for Parts {
    fn default() -> Self {
        Self::new()
    }
}

impl Parts {
    /// Creates a new default instance of `Parts`
    fn new() -> Self {
        Self {
            method: Method::default(),
            uri: Uri::from_static("/"),
            version: Version::default(),
            headers: HeaderMap::default(),
            extensions: Extensions::default(),
        }
    }
}

impl fmt::Debug for Parts {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Parts")
            .field("method", &self.method)
            .field("uri", &self.uri)
            .field("version", &self.version)
            .field("headers", &self.headers)
            // omits Extensions because not useful
            // omits _priv because not useful
            .finish()
    }
}

impl Builder {
    /// Creates a new default instance of `Builder` to construct a `Request`.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let req = request::Builder::new()
    ///     .method("POST")
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
                method: Method::default(),
                uri: Uri::from_static("/"),
                version: Version::default(),
                headers: HeaderMap::default(),
                extensions: ext,
            }),
        }
    }

    /// Set the HTTP method for this request.
    ///
    /// By default this is `GET`.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let req = Request::builder()
    ///     .method("POST")
    ///     .body(())
    ///     .unwrap();
    /// ```
    pub fn method<T>(self, method: T) -> Self
    where
        T: TryInto<Method>,
        <T as TryInto<Method>>::Error: Into<crate::Error>,
    {
        self.and_then(move |mut head| {
            let method = method.try_into().map_err(Into::into)?;
            head.method = method;
            Ok(head)
        })
    }

    /// Get the HTTP Method for this request.
    ///
    /// By default this is `GET`. If builder has error, returns None.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let mut req = Request::builder();
    /// assert_eq!(req.method_ref(),Some(&Method::GET));
    ///
    /// req = req.method("POST");
    /// assert_eq!(req.method_ref(),Some(&Method::POST));
    /// ```
    pub fn method_ref(&self) -> Option<&Method> {
        self.inner.as_ref().ok().map(|h| &h.method)
    }

    /// Set the URI for this request.
    ///
    /// By default this is `/`.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let req = Request::builder()
    ///     .uri("https://www.rust-lang.org/")
    ///     .body(())
    ///     .unwrap();
    /// ```
    pub fn uri<T>(self, uri: T) -> Self
    where
        T: TryInto<Uri>,
        <T as TryInto<Uri>>::Error: Into<crate::Error>,
    {
        self.and_then(move |mut head| {
            head.uri = uri.try_into().map_err(Into::into)?;
            Ok(head)
        })
    }

    /// Get the URI for this request
    ///
    /// By default this is `/`.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let mut req = Request::builder();
    /// assert_eq!(req.uri_ref().unwrap().as_str(), "/");
    ///
    /// req = req.uri("https://www.rust-lang.org/");
    /// assert_eq!(req.uri_ref().unwrap().as_str(), "https://www.rust-lang.org/");
    /// ```
    pub fn uri_ref(&self) -> Option<&Uri> {
        self.inner.as_ref().ok().map(|h| &h.uri)
    }

    /// Set the HTTP version for this request.
    ///
    /// By default this is HTTP/1.1
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let req = Request::builder()
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

    /// Get the HTTP version for this request
    ///
    /// By default this is HTTP/1.1.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::*;
    ///
    /// let mut req = Request::builder();
    /// assert_eq!(req.version_ref().unwrap(), &Version::HTTP_11 );
    ///
    /// req = req.version(Version::HTTP_2);
    /// assert_eq!(req.version_ref().unwrap(), &Version::HTTP_2 );
    /// ```
    pub fn version_ref(&self) -> Option<&Version> {
        self.inner.as_ref().ok().map(|h| &h.version)
    }

    /// Appends a header to this request builder.
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
    /// let req = Request::builder()
    ///     .header("Accept", "text/html")
    ///     .header("X-Custom-Foo", "bar")
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

    /// Get header on this request builder.
    /// when builder has error returns None
    ///
    /// # Example
    ///
    /// ```
    /// # use rama_http_types::Request;
    /// let req = Request::builder()
    ///     .header("Accept", "text/html")
    ///     .header("X-Custom-Foo", "bar");
    /// let headers = req.headers_ref().unwrap();
    /// assert_eq!( headers["Accept"], "text/html" );
    /// assert_eq!( headers["X-Custom-Foo"], "bar" );
    /// ```
    pub fn headers_ref(&self) -> Option<&HeaderMap<HeaderValue>> {
        self.inner.as_ref().ok().map(|h| &h.headers)
    }

    /// Get headers on this request builder.
    ///
    /// When builder has error returns None.
    ///
    /// # Example
    ///
    /// ```
    /// # use rama_http_types::{header::HeaderValue, Request};
    /// let mut req = Request::builder();
    /// {
    ///   let headers = req.headers_mut().unwrap();
    ///   headers.insert("Accept", HeaderValue::from_static("text/html"));
    ///   headers.insert("X-Custom-Foo", HeaderValue::from_static("bar"));
    /// }
    /// let headers = req.headers_ref().unwrap();
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
    /// # use rama_http_types::Request;
    /// # use rama_core::extensions::{Extension, ExtensionsRef as _};
    ///
    /// #[derive(Debug, Clone, PartialEq)]
    /// struct MyExtension(&'static str);
    /// impl Extension for MyExtension {}
    ///
    /// let req = Request::builder()
    ///     .extension(MyExtension("My Extension"))
    ///     .body(())
    ///     .unwrap();
    ///
    /// assert_eq!(req.extensions().get_ref::<MyExtension>(),
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

    /// Get a reference to the extensions for this request builder.
    ///
    /// If the builder has an error, this returns `None`.
    ///
    /// # Example
    ///
    /// ```
    /// # use rama_http_types::Request;
    /// # use rama_core::extensions::Extension;
    /// #[derive(Debug, Clone, PartialEq)]
    /// struct MyExtension(&'static str);
    /// impl Extension for MyExtension {}
    ///
    /// #[derive(Debug, Clone, PartialEq)]
    /// struct MyCount(u32);
    /// impl Extension for MyCount {}
    ///
    /// let req = Request::builder().extension(MyExtension("My Extension")).extension(MyCount(5));
    /// let extensions = req.extensions().unwrap();
    /// assert_eq!(extensions.get_ref::<MyExtension>(), Some(&MyExtension("My Extension")));
    /// assert_eq!(extensions.get_ref::<MyCount>(), Some(&MyCount(5)));
    /// ```
    pub fn extensions(&self) -> Option<&Extensions> {
        self.inner.as_ref().ok().map(|h| &h.extensions)
    }

    /// "Consumes" this builder, using the provided `body` to return a
    /// constructed `Request`.
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
    /// let request = Request::builder()
    ///     .body(())
    ///     .unwrap();
    /// ```
    pub fn body<T>(self, body: T) -> Result<Request<T>> {
        self.inner.map(move |head| Request { head, body })
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

/// [`HttpRequestParts`] is used in places where we don't need the [`ReqBody`] of the [`HttpRequest`]
///
/// In those places we need to support using [`HttpRequest`] and [`Parts`]. By using
/// this trait we can support both types behind a single generic that implements this trait.
///
/// [`ReqBody`]: crate::body::StreamingBody
/// [`HttpRequest`]: crate::Request
pub trait HttpRequestParts: ExtensionsRef {
    fn method(&self) -> &Method;

    fn uri(&self) -> &Uri;

    fn version(&self) -> Version;

    fn headers(&self) -> &HeaderMap<HeaderValue>;
}

impl<T: HttpRequestParts> HttpRequestParts for &T {
    #[inline(always)]
    fn method(&self) -> &Method {
        (*self).method()
    }

    #[inline(always)]
    fn uri(&self) -> &Uri {
        (*self).uri()
    }

    #[inline(always)]
    fn version(&self) -> Version {
        (*self).version()
    }

    #[inline(always)]
    fn headers(&self) -> &HeaderMap<HeaderValue> {
        (*self).headers()
    }
}

impl<T: HttpRequestParts> HttpRequestParts for &mut T {
    #[inline(always)]
    fn method(&self) -> &Method {
        (**self).method()
    }

    fn uri(&self) -> &Uri {
        (**self).uri()
    }

    fn version(&self) -> Version {
        (**self).version()
    }

    fn headers(&self) -> &HeaderMap<HeaderValue> {
        (**self).headers()
    }
}

impl<Body> HttpRequestParts for Request<Body> {
    fn method(&self) -> &Method {
        self.method()
    }

    fn uri(&self) -> &Uri {
        self.uri()
    }

    fn version(&self) -> Version {
        self.version()
    }

    fn headers(&self) -> &HeaderMap<HeaderValue> {
        self.headers()
    }
}

impl HttpRequestParts for Parts {
    fn method(&self) -> &Method {
        &self.method
    }

    fn uri(&self) -> &Uri {
        &self.uri
    }

    fn version(&self) -> Version {
        self.version
    }

    fn headers(&self) -> &HeaderMap<HeaderValue> {
        &self.headers
    }
}

/// Same as [`HttpRequestParts`] but also adding mutable access
pub trait HttpRequestPartsMut: HttpRequestParts + ExtensionsRef {
    fn method_mut(&mut self) -> &mut Method;

    fn uri_mut(&mut self) -> &mut Uri;

    fn version_mut(&mut self) -> &mut Version;

    fn headers_mut(&mut self) -> &mut HeaderMap<HeaderValue>;
}

impl<T: HttpRequestPartsMut> HttpRequestPartsMut for &mut T {
    fn method_mut(&mut self) -> &mut Method {
        (*self).method_mut()
    }

    fn uri_mut(&mut self) -> &mut Uri {
        (*self).uri_mut()
    }

    fn version_mut(&mut self) -> &mut Version {
        (*self).version_mut()
    }

    fn headers_mut(&mut self) -> &mut HeaderMap<HeaderValue> {
        (*self).headers_mut()
    }
}

impl<Body> HttpRequestPartsMut for Request<Body> {
    fn method_mut(&mut self) -> &mut Method {
        self.method_mut()
    }

    fn uri_mut(&mut self) -> &mut Uri {
        self.uri_mut()
    }

    fn version_mut(&mut self) -> &mut Version {
        self.version_mut()
    }

    fn headers_mut(&mut self) -> &mut HeaderMap<HeaderValue> {
        self.headers_mut()
    }
}

impl HttpRequestPartsMut for Parts {
    fn method_mut(&mut self) -> &mut Method {
        &mut self.method
    }

    fn uri_mut(&mut self) -> &mut Uri {
        &mut self.uri
    }

    fn version_mut(&mut self) -> &mut Version {
        &mut self.version
    }

    fn headers_mut(&mut self) -> &mut HeaderMap<HeaderValue> {
        &mut self.headers
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_can_map_a_body_from_one_type_to_another() {
        let request = Request::builder().body("some string").unwrap();
        let mapped_request = request.map(|s| {
            assert_eq!(s, "some string");
            123u32
        });
        assert_eq!(mapped_request.body(), &123u32);
    }

    #[test]
    fn fork_extensions_in_place_isolates_attempts_from_the_parent() {
        #[derive(Debug, Extension)]
        struct Caller;
        #[derive(Debug, Extension)]
        struct AttemptOne;
        #[derive(Debug, Extension)]
        struct AttemptTwo;

        let mut request = Request::new(());
        request.extensions().insert(Caller);

        let parent = request.fork_extensions_in_place();
        assert!(parent.self_contains::<Caller>());

        // an attempt reads the caller's extensions but keeps its own inserts to itself
        assert!(request.extensions().contains::<Caller>());
        request.extensions().insert(AttemptOne);
        assert!(!parent.contains::<AttemptOne>());

        // ... so the next attempt forks from an untouched parent
        request.set_extensions(parent.fork());
        assert!(request.extensions().contains::<Caller>());
        assert!(!request.extensions().contains::<AttemptOne>());

        request.extensions().insert(AttemptTwo);
        assert!(!parent.contains::<AttemptTwo>());
    }

    #[test]
    fn test_request_uri() {
        use rama_net::{
            address::Domain,
            forwarded::{Forwarded, ForwardedElement},
        };

        use crate::header::HOST;

        for (request, expected_uri_str) in [
            (Request::builder().uri("/foo").body(()).unwrap(), "/foo"),
            (
                Request::builder()
                    .uri("/foo")
                    .header(HOST, "example.com")
                    .body(())
                    .unwrap(),
                "http://example.com/foo",
            ),
            (
                Request::builder()
                    .uri("/foo")
                    .extension(Forwarded::new(ForwardedElement::new_forwarded_host(
                        Domain::from_static("example.com"),
                    )))
                    .body(())
                    .unwrap(),
                "http://example.com/foo",
            ),
            (
                Request::builder()
                    .uri("http://example.com/foo")
                    .body(())
                    .unwrap(),
                "http://example.com/foo",
            ),
            (
                Request::builder()
                    .uri("https://example.com/foo")
                    .body(())
                    .unwrap(),
                "https://example.com/foo",
            ),
            (
                Request::builder()
                    .uri(Uri::parse_authority_form("WwW.ExamplE.COM").unwrap())
                    .body(())
                    .unwrap(),
                // native Uri preserves the empty path (no forced trailing `/`)
                "http://WwW.ExamplE.COM",
            ),
        ] {
            let s = request.request_uri().to_string();
            assert_eq!(s, expected_uri_str, "request: {request:?}");
        }
    }
}
