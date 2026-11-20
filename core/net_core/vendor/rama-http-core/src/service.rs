use rama_core::bytes::Bytes;
use rama_core::extensions::{Extensions, ExtensionsRef as _, Ingress};
use rama_core::telemetry::tracing::{Instrument, trace_root_span};
use rama_core::{Service, error::BoxError};
use rama_http::StreamingBody;
use rama_http::opentelemetry::version_as_protocol_version;
use rama_http::service::web::response::IntoResponse;
use rama_http_types::{Body, BodyLimit, Request, Response, body::util::Limited};
use std::{convert::Infallible, fmt};

#[derive(Clone, fmt::Debug)]
pub struct RamaHttpService<S> {
    svc: S,
}

impl<S> RamaHttpService<S> {
    pub fn new(svc: S) -> Self {
        Self { svc }
    }
}

impl<S, ReqBody, R> Service<Request<ReqBody>> for RamaHttpService<S>
where
    S: Service<Request, Output = R, Error = Infallible>,
    ReqBody: StreamingBody<Data = Bytes, Error: Into<BoxError>> + Send + Sync + 'static,
    R: IntoResponse + Send + 'static,
{
    type Output = Response;
    type Error = Infallible;

    async fn serve(&self, req: Request<ReqBody>) -> Result<Response, Infallible> {
        let body_limit = req
            .extensions()
            .get_ref::<Ingress<Extensions>>()
            .and_then(|ingress| ingress.get_ref::<BodyLimit>())
            .copied();
        let req = req.map(|body| match body_limit.and_then(|limit| limit.request()) {
            Some(limit) => Body::new(Limited::new(body, limit)),
            None => Body::new(body),
        });

        let span = trace_root_span!(
            "http::serve",
            otel.kind = "server",
            http.request.method = %req.method().as_str(),
            url.full = %req.request_uri(),
            url.path = %req.uri().path_or_root().as_ref(),
            url.query = %req.uri().query_or_empty().as_ref(),
            url.scheme = %req.uri().scheme_str().unwrap_or_default(),
            network.protocol.name = "http",
            network.protocol.version = version_as_protocol_version(req.version()),
        );

        let serve = |req| async move {
            let response = self.svc.serve(req).instrument(span).await?.into_response();
            Ok(match body_limit.and_then(|limit| limit.response()) {
                Some(limit) => response.map(|body| Body::new(Limited::new(body, limit))),
                None => response,
            })
        };
        #[cfg(feature = "dial9")]
        {
            rama_http::layer::dial9::observe_request("http.server", req, serve).await
        }
        #[cfg(not(feature = "dial9"))]
        serve(req).await
    }
}

#[derive(Debug, Default)]
#[cfg(test)]
pub(crate) struct VoidHttpService;

#[cfg(test)]
impl<ReqBody> Service<Request<ReqBody>> for VoidHttpService
where
    ReqBody: StreamingBody<Data = Bytes, Error: Into<BoxError>> + Send + Sync + 'static,
{
    type Output = Response;
    type Error = Infallible;

    #[expect(clippy::manual_async_fn)]
    fn serve(
        &self,
        _req: Request<ReqBody>,
    ) -> impl Future<Output = Result<Response, Infallible>> + Send + '_ {
        async move { Ok(Response::new(rama_http_types::Body::empty())) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rama_core::{
        Layer as _, ServiceInput, extensions::Extensions, futures::stream, rt::Executor,
        service::service_fn,
    };
    use rama_http::layer::body_limit::BodyLimitLayer as ApplicationBodyLimitLayer;
    use rama_http_types::{
        BodyLimitLayer, Method, StatusCode,
        body::util::{BodyExt as _, CollectErrorKind, LengthLimitError},
        request,
    };
    use std::assert_matches;
    use tokio::io::DuplexStream;

    fn streaming_body() -> Body {
        Body::from_stream(stream::iter([
            Ok::<_, Infallible>(Bytes::from_static(b"1234")),
            Ok(Bytes::from_static(b"5678")),
        ]))
    }

    fn request_with_limit(body: Body, limit: BodyLimit) -> Request {
        let ingress = Extensions::new();
        ingress.insert(limit);
        Request::builder()
            .extension(Ingress(ingress))
            .body(body)
            .unwrap()
    }

    async fn assert_stream_is_limited(mut body: Body) {
        let first = body
            .frame()
            .await
            .expect("first body frame")
            .expect("first body frame succeeds")
            .into_data()
            .expect("first frame contains data");
        assert_eq!(first, Bytes::from_static(b"1234"));

        let error = body
            .frame()
            .await
            .expect("over-limit body frame")
            .expect_err("over-limit body frame fails");
        assert!(error.downcast_ref::<LengthLimitError>().is_some());
        assert!(body.frame().await.is_none());
    }

    #[tokio::test]
    async fn request_limit_forwards_fitting_frames_then_errors() {
        let service = RamaHttpService::new(service_fn(|request: Request| async move {
            Ok::<_, Infallible>(Response::new(request.into_body()))
        }));

        let response = service
            .serve(request_with_limit(
                streaming_body(),
                BodyLimit::request_only(5),
            ))
            .await
            .unwrap();

        assert_stream_is_limited(response.into_body()).await;
    }

    #[tokio::test]
    async fn response_limit_forwards_fitting_frames_then_errors() {
        let service = RamaHttpService::new(service_fn(|_request: Request| async move {
            Ok::<_, Infallible>(Response::new(streaming_body()))
        }));

        let response = service
            .serve(request_with_limit(
                Body::empty(),
                BodyLimit::response_only(5),
            ))
            .await
            .unwrap();

        assert_stream_is_limited(response.into_body()).await;
    }

    #[tokio::test]
    async fn zero_limit_leaves_request_and_response_unlimited() {
        let service = RamaHttpService::new(service_fn(|request: Request| async move {
            Ok::<_, Infallible>(Response::new(request.into_body()))
        }));

        let response = service
            .serve(request_with_limit(
                streaming_body(),
                BodyLimit::symmetric(0),
            ))
            .await
            .unwrap();
        let body = response.into_body().collect().await.unwrap().to_bytes();

        assert_eq!(body, Bytes::from_static(b"12345678"));
    }

    #[tokio::test]
    async fn transport_and_application_request_limits_compose_to_the_smaller_value() {
        for (transport_limit, application_limit) in [(5, 8), (8, 5)] {
            let application = ApplicationBodyLimitLayer::new(application_limit).into_layer(
                service_fn(|request: Request| async move {
                    Ok::<_, Infallible>(Response::new(request.into_body()))
                }),
            );
            let service = RamaHttpService::new(application);
            let response = service
                .serve(request_with_limit(
                    streaming_body(),
                    BodyLimit::request_only(transport_limit),
                ))
                .await
                .unwrap();

            assert_stream_is_limited(response.into_body()).await;
        }
    }

    #[derive(Clone, Copy)]
    enum TestProtocol {
        Http1,
        Http2,
    }

    async fn oversized_request_status(protocol: TestProtocol) -> StatusCode {
        let (client_io, server_io) = tokio::io::duplex(4096);
        let http_service = RamaHttpService::new(service_fn(|request: Request| async move {
            let status = match request.into_body().collect().await {
                Ok(_) => StatusCode::OK,
                Err(error) => {
                    assert_matches!(
                        error.kind(),
                        CollectErrorKind::Stream(error)
                            if error.downcast_ref::<LengthLimitError>().is_some(),
                    );
                    StatusCode::PAYLOAD_TOO_LARGE
                }
            };
            Ok::<_, Infallible>(
                Response::builder()
                    .status(status)
                    .body(Body::empty())
                    .unwrap(),
            )
        }));
        let server_io = ServiceInput::new(server_io);
        let server_task = match protocol {
            TestProtocol::Http1 => {
                let connection_service = service_fn(move |io: ServiceInput<DuplexStream>| {
                    let http_service = http_service.clone();
                    async move {
                        crate::server::conn::http1::Builder::new()
                            .serve_connection(io, http_service)
                            .await
                    }
                });
                let connection_service =
                    BodyLimitLayer::request_only(5).into_layer(connection_service);
                tokio::spawn(async move { connection_service.serve(server_io).await })
            }
            TestProtocol::Http2 => {
                let connection_service = service_fn(move |io: ServiceInput<DuplexStream>| {
                    let http_service = http_service.clone();
                    async move {
                        crate::server::conn::http2::Builder::new(Executor::new())
                            .serve_connection(io, http_service)
                            .await
                    }
                });
                let connection_service =
                    BodyLimitLayer::request_only(5).into_layer(connection_service);
                tokio::spawn(async move { connection_service.serve(server_io).await })
            }
        };

        let request = Request::builder()
            .method(Method::POST)
            .uri("/")
            .body(streaming_body())
            .unwrap();
        let (response, client_task) = match protocol {
            TestProtocol::Http1 => {
                let (mut sender, connection) =
                    crate::client::conn::http1::handshake::<_, Body>(ServiceInput::new(client_io))
                        .await
                        .unwrap();
                let client_task = tokio::spawn(connection);
                (sender.send_request(request).await.unwrap(), client_task)
            }
            TestProtocol::Http2 => {
                let (mut sender, connection) = crate::client::conn::http2::handshake::<_, Body>(
                    Executor::new(),
                    ServiceInput::new(client_io),
                )
                .await
                .unwrap();
                let client_task = tokio::spawn(connection);
                (sender.send_request(request).await.unwrap(), client_task)
            }
        };
        let status = response.status();
        client_task.abort();
        server_task.abort();
        status
    }

    #[tokio::test]
    async fn transport_body_limit_reaches_http1_and_http2_requests() {
        for protocol in [TestProtocol::Http1, TestProtocol::Http2] {
            assert_eq!(
                oversized_request_status(protocol).await,
                StatusCode::PAYLOAD_TOO_LARGE
            );
        }
    }

    #[test]
    fn body_limit_is_read_from_ingress_connection_extensions() {
        let ingress = Extensions::new();
        ingress.insert(BodyLimit::asymmetric(3, 7));
        let request = request::Builder::new()
            .extension(Ingress(ingress))
            .body(Body::empty())
            .unwrap();
        let limit = request
            .extensions()
            .get_ref::<Ingress<Extensions>>()
            .and_then(|ingress| ingress.get_ref::<BodyLimit>())
            .copied()
            .unwrap();

        assert_eq!(limit.request(), Some(3));
        assert_eq!(limit.response(), Some(7));
    }
}
