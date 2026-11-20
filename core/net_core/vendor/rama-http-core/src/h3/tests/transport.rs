use std::{
    task::{Context, Poll},
    time::Duration,
};

use rama_core::{
    bytes::Bytes,
    extensions::{Extensions, ExtensionsRef},
    rt::{Executor, spawn},
};
use rama_http_types::{Body, Request, Response, body::util::BodyExt};
use rama_net::{stream::SocketInfo, tls::ApplicationProtocol};
use rama_quic::NegotiatedTlsParameters;
use rama_quic_proto::{ConnectionError, Dir, Side, StreamId, VarInt};

use super::{LIMIT, Pair};
use crate::h3::{
    client,
    connection::Config,
    server,
    transport::{self, BoxedConnection, ClosedStream, ReadError, StoppedError, WriteError},
};

#[derive(Clone, Debug)]
struct Wrapped(rama_quic::Connection);

struct WrappedSend(rama_quic::SendStream);

struct WrappedRecv(rama_quic::RecvStream);

fn wrap_bi(
    (send, recv): (rama_quic::SendStream, rama_quic::RecvStream),
) -> (WrappedSend, WrappedRecv) {
    (WrappedSend(send), WrappedRecv(recv))
}

#[tokio::test]
async fn request_round_trip_over_custom_transport() {
    round_trip(Wrapped).await;
}

#[tokio::test]
async fn request_round_trip_over_boxed_transport() {
    round_trip(BoxedConnection::new).await;
}

async fn round_trip<C: transport::Connection>(wrap: impl Fn(rama_quic::Connection) -> C) {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (mut client, client_driver) = client::handshake::<Body, _>(
            wrap(pair.client.clone()),
            Config::default(),
            Executor::new(),
        )
        .unwrap();
        let (mut server, server_driver) =
            server::handshake(wrap(pair.server.clone()), Config::default()).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let serve = spawn(async move {
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            let body = request.into_body().collect().await.unwrap().to_bytes();
            response
                .send_response(Response::new(Body::from(body)))
                .await
                .unwrap();
        });
        let response = client
            .send_request(
                Request::builder()
                    .method("POST")
                    .uri("https://localhost/echo")
                    .body(Body::from("over a custom transport"))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            response.into_body().collect().await.unwrap().to_bytes(),
            "over a custom transport"
        );
        serve.await.unwrap();
        for connection in [&pair.client, &pair.server] {
            let extensions = connection.extensions();
            assert_eq!(
                extensions
                    .get_ref::<SocketInfo>()
                    .unwrap()
                    .peer_addr()
                    .to_string(),
                connection.remote_address().to_string(),
            );
            assert_eq!(
                extensions
                    .get_ref::<NegotiatedTlsParameters>()
                    .unwrap()
                    .application_layer_protocol,
                Some(ApplicationProtocol::HTTP_3),
            );
        }
        drop(client);
        _ = client_driver.await.unwrap();
        _ = server_driver.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

impl ExtensionsRef for Wrapped {
    fn extensions(&self) -> &Extensions {
        self.0.extensions()
    }
}

impl transport::Connection for Wrapped {
    type SendStream = WrappedSend;
    type RecvStream = WrappedRecv;
    type CloseLease = rama_quic::CloseLease;

    async fn open_bi(&self) -> Result<(WrappedSend, WrappedRecv), ConnectionError> {
        self.0.open_bi().await.map(wrap_bi)
    }

    async fn open_uni(&self) -> Result<WrappedSend, ConnectionError> {
        self.0.open_uni().await.map(WrappedSend)
    }

    async fn accept_bi(&self) -> Result<(WrappedSend, WrappedRecv), ConnectionError> {
        self.0.accept_bi().await.map(wrap_bi)
    }

    async fn accept_uni(&self) -> Result<WrappedRecv, ConnectionError> {
        self.0.accept_uni().await.map(WrappedRecv)
    }

    fn side(&self) -> Side {
        self.0.side()
    }

    async fn handshake_confirmed(&self) -> Result<(), ConnectionError> {
        self.0.handshake_confirmed().await
    }

    fn is_handshake_confirmed(&self) -> bool {
        self.0.is_handshake_confirmed()
    }

    fn close(&self, error_code: VarInt, reason: &[u8]) {
        self.0.close(error_code, reason);
    }

    async fn closed(&self) -> ConnectionError {
        self.0.closed().await
    }

    fn close_reason(&self) -> Option<ConnectionError> {
        self.0.close_reason()
    }

    fn available_streams(&self, dir: Dir) -> u64 {
        self.0.available_streams(dir)
    }

    fn max_concurrent_streams(&self, dir: Dir) -> u64 {
        self.0.max_concurrent_streams(dir)
    }

    fn remote_stream_limit(&self, dir: Dir) -> u64 {
        self.0.remote_stream_limit(dir)
    }

    fn local_stream_limit(&self, dir: Dir) -> u64 {
        self.0.local_stream_limit(dir)
    }

    fn early_data(&self) -> transport::EarlyData {
        transport::Connection::early_data(&self.0)
    }

    fn qlog_control(&self) -> Option<rama_quic::qlog::ConnectionQlogControl> {
        self.0.qlog_control()
    }

    fn received_datagrams(&self) -> usize {
        self.0.received_datagrams()
    }

    fn datagram_send_ready(&self) -> impl Future<Output = ()> + Send + 'static + use<> {
        self.0.datagram_send_ready()
    }

    fn close_lease(&self) -> rama_quic::CloseLease {
        self.0.close_lease()
    }

    async fn read_datagram(&self) -> Result<Bytes, ConnectionError> {
        self.0.read_datagram().await
    }

    fn max_datagram_size(&self) -> Option<usize> {
        self.0.max_datagram_size()
    }

    fn datagram_receive_enabled(&self) -> bool {
        self.0.datagram_receive_enabled()
    }

    fn rtt(&self) -> Duration {
        self.0.rtt()
    }
}

impl transport::SendStream for WrappedSend {
    type Handle = rama_quic::StreamHandle;

    fn id(&self) -> StreamId {
        self.0.id()
    }

    fn poll_write_chunks(
        &mut self,
        cx: &mut Context<'_>,
        chunks: &mut [Bytes],
        reserve: u64,
    ) -> Poll<Result<(), WriteError>> {
        transport::SendStream::poll_write_chunks(&mut self.0, cx, chunks, reserve)
    }

    fn try_write_generated(
        &mut self,
        reserve: u64,
        generate: impl FnOnce(usize) -> Bytes,
    ) -> Result<(), WriteError> {
        transport::SendStream::try_write_generated(&mut self.0, reserve, generate)
    }

    fn finish(&mut self) -> Result<(), ClosedStream> {
        transport::SendStream::finish(&mut self.0)
    }

    fn reset(&mut self, error_code: VarInt) -> Result<(), ClosedStream> {
        transport::SendStream::reset(&mut self.0, error_code)
    }

    fn set_priority(&self, priority: i32) -> Result<(), ClosedStream> {
        transport::SendStream::set_priority(&self.0, priority)
    }

    fn stopped(
        &self,
    ) -> impl Future<Output = Result<Option<VarInt>, StoppedError>> + Send + Sync + 'static + use<>
    {
        transport::SendStream::stopped(&self.0)
    }

    fn handle(&self) -> rama_quic::StreamHandle {
        self.0.handle()
    }
}

impl transport::RecvStream for WrappedRecv {
    fn id(&self) -> StreamId {
        self.0.id()
    }

    fn poll_read_chunk(
        &mut self,
        cx: &mut Context<'_>,
        max_length: usize,
    ) -> Poll<Result<Option<Bytes>, ReadError>> {
        transport::RecvStream::poll_read_chunk(&mut self.0, cx, max_length)
    }

    fn stop(&mut self, error_code: VarInt) -> Result<(), ClosedStream> {
        transport::RecvStream::stop(&mut self.0, error_code)
    }

    fn is_0rtt(&self) -> bool {
        self.0.is_0rtt()
    }
}
