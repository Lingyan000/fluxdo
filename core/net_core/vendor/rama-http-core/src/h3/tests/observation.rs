use super::{LIMIT, Pair};
use crate::h3::{
    client,
    connection::{Config, initial_control},
    control::Role,
    observation::{H3Observer, SettingsObservation},
    qpack::{Encoder, EncoderConfig},
    quic::Writer,
    server,
};
use rama_core::{
    extensions::{ExtensionsRef as _, Ingress},
    rt::{Executor, spawn},
};
use rama_http_types::{
    Body, Request, Response,
    body::util::BodyExt as _,
    proto::h3::{
        FrameType,
        observation::{H3RequestObservation, ObservationLimits},
    },
};
use rama_quic_proto::capture::QuicObservation;
use rama_tls::SecureTransport;
use std::{future::poll_fn, num::NonZeroUsize, time::Duration};
use tokio::time::Instant;

#[tokio::test(start_paused = true)]
async fn observation_delivers_requests_before_settings_and_wakes_on_late_settings() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::build(None, None, Some(NonZeroUsize::MIN), true).await;
        let (mut server, driver) = server::handshake(
            pair.server.clone(),
            Config {
                observation: Some(Default::default()),
                ..Config::default()
            },
        )
        .unwrap();
        spawn(driver.run());
        // No H3 client driver: send a legal request before opening any control stream.
        let (send, _recv) = pair.client.open_bi().await.unwrap();
        let mut encoder = Encoder::before_peer_settings(EncoderConfig::default());
        let section = encoder
            .encode(
                u64::from(send.id()),
                [
                    (":method", "GET"),
                    (":scheme", "https"),
                    (":authority", "localhost"),
                    (":path", "/"),
                    ("priority", "u=1"),
                ],
            )
            .unwrap();
        let mut writer = Writer::new(send);
        writer.queue(FrameType::HEADERS, section).unwrap();
        poll_fn(|cx| writer.poll_finish(cx)).await.unwrap();
        let (request, _response) = server.accept().await.unwrap().resolve().await.unwrap();
        // Match the HTTP backend's connection-to-request ingress attachment.
        request
            .extensions()
            .insert(Ingress(pair.server.extensions().clone()));
        let quic = request.extensions().get_ref::<QuicObservation>().unwrap();
        assert!(quic.completeness.is_complete());
        assert!(
            request
                .extensions()
                .get_ref::<SecureTransport>()
                .unwrap()
                .client_hello()
                .is_some()
        );
        let captured = request
            .extensions()
            .get_ref::<H3RequestObservation>()
            .unwrap();
        assert!(captured.connection.settings.is_none());
        assert_eq!(captured.fields.len(), 5);
        assert_eq!(captured.priority.as_deref(), Some(b"u=1".as_slice()));
        let observer = request
            .extensions()
            .get_ref::<H3Observer>()
            .unwrap()
            .clone();
        let old = captured.connection.clone();
        let second = observer.clone();
        let second_waiting = spawn(async move {
            second
                .settings(Instant::now() + Duration::from_secs(1))
                .await
        });
        let waiting = spawn(async move {
            observer
                .settings(Instant::now() + Duration::from_secs(1))
                .await
        });
        let mut control = pair.client.open_uni().await.unwrap();
        control
            .write_all(&initial_control(&Config::default(), Role::Client, false).unwrap())
            .await
            .unwrap();
        let SettingsObservation::Received(snapshot) = waiting.await.unwrap() else {
            panic!("late SETTINGS were not observed")
        };
        assert!(matches!(
            second_waiting.await.unwrap(),
            SettingsObservation::Received(_)
        ));
        assert!(snapshot.settings.is_some());
        assert!(snapshot.completeness.settings);
        assert!(old.settings.is_none());
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn observation_waiter_wakes_when_peer_closes_before_settings() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut server, driver) = server::handshake(
            pair.server.clone(),
            Config {
                observation: Some(Default::default()),
                ..Config::default()
            },
        )
        .unwrap();
        spawn(driver.run());
        let (send, _recv) = pair.client.open_bi().await.unwrap();
        let mut encoder = Encoder::before_peer_settings(EncoderConfig::default());
        let section = encoder
            .encode(
                u64::from(send.id()),
                [
                    (":method", "GET"),
                    (":scheme", "https"),
                    (":authority", "localhost"),
                    (":path", "/"),
                ],
            )
            .unwrap();
        let mut writer = Writer::new(send);
        writer.queue(FrameType::HEADERS, section).unwrap();
        poll_fn(|cx| writer.poll_finish(cx)).await.unwrap();
        let (request, _response) = server.accept().await.unwrap().resolve().await.unwrap();
        let observer = request
            .extensions()
            .get_ref::<H3Observer>()
            .unwrap()
            .clone();
        let waiting = spawn(async move {
            observer
                .settings(Instant::now() + Duration::from_secs(10))
                .await
        });
        pair.client.close(0u32, b"closed before settings");
        assert!(matches!(
            waiting.await.unwrap(),
            SettingsObservation::Closed { .. }
        ));
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn observation_trailers_cannot_exhaust_later_request_field_capture() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let limits = ObservationLimits {
            pending_fields: 2,
            retained_snapshots: 2,
            ..ObservationLimits::default()
        };
        let (mut server, driver) = server::handshake(
            pair.server.clone(),
            Config {
                observation: Some(Box::new(limits)),
                ..Config::default()
            },
        )
        .unwrap();
        spawn(driver.run());
        let mut encoder = Encoder::before_peer_settings(EncoderConfig::default());
        for index in 0..12 {
            let (send, _recv) = pair.client.open_bi().await.unwrap();
            let id = u64::from(send.id());
            let head = encoder
                .encode(
                    id,
                    [
                        (":method", "GET"),
                        (":scheme", "https"),
                        (":authority", "localhost"),
                        (":path", "/"),
                    ],
                )
                .unwrap();
            let mut writer = Writer::new(send);
            writer.queue(FrameType::HEADERS, head).unwrap();
            poll_fn(|cx| writer.poll_flush(cx)).await.unwrap();
            if index < 11 {
                let trailers = encoder.encode(id, [("x-trailer", "done")]).unwrap();
                writer.queue(FrameType::HEADERS, trailers).unwrap();
            }
            poll_fn(|cx| writer.poll_finish(cx)).await.unwrap();
            let (request, _response) = server.accept().await.unwrap().resolve().await.unwrap();
            let captured = request
                .extensions()
                .get_ref::<H3RequestObservation>()
                .unwrap();
            assert!(captured.fields_complete, "request {index}: {captured:?}");
            assert_eq!(captured.fields.len(), 4);
            request.into_body().collect().await.unwrap();
        }
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn observation_disabled_leaves_connection_and_request_extensions_empty() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut server, driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        spawn(driver.run());
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        spawn(driver.run());
        let serve = spawn(async move {
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            request
                .extensions()
                .insert(Ingress(pair.server.extensions().clone()));
            assert!(!request.extensions().contains::<H3RequestObservation>());
            assert!(!request.extensions().contains::<H3Observer>());
            assert!(!request.extensions().contains::<QuicObservation>());
            assert!(!request.extensions().contains::<SecureTransport>());
            response
                .send_response(Response::new(Body::empty()))
                .await
                .unwrap();
            pair
        });
        client
            .send_request(
                Request::builder()
                    .uri("https://localhost/")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let pair = serve.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}
