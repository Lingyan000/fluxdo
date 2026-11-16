use rama_core::{
    bytes::Bytes,
    extensions::ExtensionsRef as _,
    rt::{Executor, spawn},
};
use rama_http::{
    datagram::{DatagramTransport, HttpDatagramSession, SessionEvent},
    headers::{HeaderMapExt as _, Priority},
    io::upgrade::{Upgraded, handle_upgrade},
};
use rama_http_types::{
    Body, Method, Request, Response, StatusCode, Version,
    body::util::BodyExt,
    proto::ext::{HttpDatagrams, Protocol},
};
use rama_quic::TransportConfig;
use rama_quic_proto::Side;
use std::{sync::Arc, time::Duration};
use tokio::sync::oneshot;

use super::{LIMIT, Pair, qlog::Sink};
use crate::h3::{
    client,
    connection::Config,
    server,
    transport::{BoxedConnection, Connection as _, Reversed},
};

type Quic = Reversed<rama_quic::Connection>;

/// The QUIC client serves HTTP/3, the QUIC server sends the requests.
async fn start(
    pair: &Pair,
    client: Config,
    server: Config,
) -> (client::SendRequest<Body, Quic>, server::Connection<Quic>) {
    let (client, driver) =
        client::handshake::<Body, _>(Reversed::new(pair.server.clone()), client, Executor::new())
            .unwrap();
    spawn(driver.run());
    let (server, driver) = server::handshake(Reversed::new(pair.client.clone()), server).unwrap();
    spawn(driver.run());
    (client, server)
}

fn get(path: &str) -> Request<Body> {
    Request::builder()
        .uri(format!("https://localhost{path}"))
        .version(Version::HTTP_3)
        .body(Body::empty())
        .unwrap()
}

#[tokio::test]
async fn the_quic_client_serves_requests_sent_by_the_quic_server() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let served_by_quic_client = Reversed::new(pair.client.clone());
        let sent_by_quic_server = Reversed::new(pair.server.clone());
        assert_eq!(served_by_quic_client.side(), Side::Server);
        assert_eq!(sent_by_quic_server.side(), Side::Client);

        let (mut server, server_driver) =
            server::handshake(served_by_quic_client, Config::default()).unwrap();
        let (mut client, client_driver) =
            client::handshake::<Body, _>(sent_by_quic_server, Config::default(), Executor::new())
                .unwrap();
        let server_driver = spawn(server_driver.run());
        let client_driver = spawn(client_driver.run());
        let serve = spawn(async move {
            for _ in 0..2 {
                let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
                let path = request.uri().request_target().to_string();
                let body = request.into_body().collect().await.unwrap().to_bytes();
                let mut reply = path.into_bytes();
                reply.extend_from_slice(&body);
                response
                    .send_response(Response::new(Body::from(reply)))
                    .await
                    .unwrap();
            }
        });
        for path in ["/first", "/second"] {
            let response = client
                .send_request(
                    Request::builder()
                        .method("POST")
                        .uri(format!("https://localhost{path}"))
                        .body(Body::from(" from the quic server"))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(
                response.into_body().collect().await.unwrap().to_bytes(),
                format!("{path} from the quic server")
            );
        }
        serve.await.unwrap();
        drop(client);
        _ = client_driver.await.unwrap();
        _ = server_driver.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn reversed_nests_with_boxed_connection_either_way() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let served = BoxedConnection::new(Reversed::new(pair.client.clone()));
        let sending = Reversed::new(BoxedConnection::new(pair.server.clone()));
        assert_eq!(served.side(), Side::Server);
        assert_eq!(sending.side(), Side::Client);

        let (mut server, driver) = server::handshake(served, Config::default()).unwrap();
        spawn(driver.run());
        let (mut client, driver) =
            client::handshake::<Body, _>(sending, Config::default(), Executor::new()).unwrap();
        spawn(driver.run());
        let serve = spawn(async move {
            let (_, response) = server.accept().await.unwrap().resolve().await.unwrap();
            response
                .send_response(Response::new(Body::from("nested")))
                .await
                .unwrap();
        });
        let response = client.send_request(get("/")).await.unwrap();
        assert_eq!(
            response.into_body().collect().await.unwrap().to_bytes(),
            "nested"
        );
        serve.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

/// Open an Extended CONNECT tunnel that declares HTTP datagrams on both sides.
async fn datagram_tunnel(
    client: &mut client::SendRequest<Body, Quic>,
    server: &mut server::Connection<Quic>,
) -> (HttpDatagramSession, HttpDatagramSession) {
    let accept = async {
        let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
        let upgrade = handle_upgrade(&request);
        let accepted = Response::new(Body::empty());
        accepted.extensions().insert(HttpDatagrams);
        response.send_response(accepted).await.unwrap();
        upgrade.await.unwrap()
    };
    let request = Request::builder()
        .method(Method::CONNECT)
        .uri("https://localhost/datagrams")
        .body(Body::empty())
        .unwrap();
    request
        .extensions()
        .insert(Protocol::from_static("x-reversed-datagrams"));
    request.extensions().insert(HttpDatagrams);
    let (response, server_io): (_, Upgraded) = tokio::join!(client.send_request(request), accept);
    let response = response.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let client_io = handle_upgrade(&response).await.unwrap();
    (
        HttpDatagramSession::new(client_io),
        HttpDatagramSession::new(server_io),
    )
}

async fn native_ready(session: &HttpDatagramSession) {
    while session
        .native()
        .and_then(|native| native.channel().max_payload_size())
        .is_none()
    {
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
}

fn native(payload: &[u8]) -> Option<SessionEvent> {
    Some(SessionEvent::Datagram {
        payload: Bytes::copy_from_slice(payload),
        transport: DatagramTransport::Native,
    })
}

#[tokio::test]
async fn extended_connect_sessions_get_their_own_datagrams() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let server_config = Config {
            extended_connect: true,
            datagrams: Some(Default::default()),
            ..Config::default()
        };
        let (mut client, mut server) = start(&pair, Config::default(), server_config).await;
        // Two sessions, so their datagram prefixes carry different stream IDs.
        let mut sessions = Vec::new();
        for _ in 0..2 {
            sessions.push(datagram_tunnel(&mut client, &mut server).await);
        }
        for (client_session, server_session) in &sessions {
            native_ready(client_session).await;
            native_ready(server_session).await;
        }
        for (index, (client_session, server_session)) in sessions.iter_mut().enumerate() {
            let request = [b'q', index as u8];
            client_session
                .send_datagram(Bytes::copy_from_slice(&request))
                .await
                .unwrap();
            assert_eq!(server_session.recv().await.unwrap(), native(&request));
            let reply = [b'r', index as u8];
            server_session
                .send_datagram(Bytes::copy_from_slice(&reply))
                .await
                .unwrap();
            assert_eq!(client_session.recv().await.unwrap(), native(&reply));
        }
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn goaway_rejects_new_requests_and_finishes_the_one_in_flight() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, mut server) = start(&pair, Config::default(), Config::default()).await;
        let in_flight = spawn({
            let mut client = client.clone();
            async move { client.send_request(get("/in-flight")).await }
        });
        let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
        server.shutdown().unwrap();
        // The GOAWAY carries a stream ID: the client must see it as covering the in-flight one.
        let draining = client.closed_or_draining().await;
        assert!(draining.is_rejected(), "{draining:?}");
        let refused = client.send_request(get("/late")).await.unwrap_err();
        assert!(refused.is_rejected(), "{refused:?}");
        drop(request);
        response
            .send_response(Response::new(Body::from("finished")))
            .await
            .unwrap();
        let finished = in_flight.await.unwrap().unwrap();
        assert_eq!(
            finished.into_body().collect().await.unwrap().to_bytes(),
            "finished"
        );
        server.drained().await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn priority_updates_reach_the_request_they_name() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, mut server) = start(&pair, Config::default(), Config::default()).await;
        let (tx, rx) = oneshot::channel();
        let mut request = get("/");
        let initial = Priority::new(5, false).unwrap();
        request.headers_mut().typed_insert(initial);
        let result = spawn(async move {
            client
                .send_request_with_priority(request, move |handle| {
                    tx.send(handle).unwrap();
                })
                .await
        });
        let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
        let mut observed = response.peer_priority();
        assert_eq!(observed.changed().await.unwrap(), initial);
        let handle = rx.await.unwrap();
        // PRIORITY_UPDATE names its request by stream ID, in the flipped numbering on both ends.
        let updated = Priority::new(0, true).unwrap();
        handle.update(updated).unwrap();
        assert_eq!(observed.changed().await.unwrap(), updated);
        drop(request);
        response
            .send_response(Response::new(Body::empty()))
            .await
            .unwrap();
        drop(result.await.unwrap().unwrap());
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn h3_qlog_events_carry_the_flipped_stream_ids() {
    tokio::time::timeout(LIMIT, async {
        let log = Sink::new(true);
        // The HTTP/3 client runs on the QUIC server, so its log is the server's.
        let pair = Pair::in_memory(
            None,
            Some(TransportConfig::default().with_qlog_sink(Arc::new(log.clone()))),
        )
        .await;
        let (mut client, mut server) = start(&pair, Config::default(), Config::default()).await;
        let serve = spawn(async move {
            let (_request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            response
                .send_response(Response::new(Body::empty()))
                .await
                .unwrap();
        });
        client.send_request(get("/")).await.unwrap();
        serve.await.unwrap();
        // The QUIC server's first bidirectional stream is 1 on the wire; h3 sees and logs it as
        // the first client-initiated one.
        let request_streams: Vec<_> = log
            .events
            .lock()
            .iter()
            .filter(|(name, data)| {
                *name == "http3:stream_type_set" && data["stream_type"] == "request"
            })
            .map(|(_, data)| data["stream_id"].as_u64().unwrap())
            .collect();
        assert_eq!(request_streams, [0]);
        pair.close().await;
    })
    .await
    .unwrap();
}
