//! Current-field insertion preferences work through ordinary request/response extensions.

use super::*;
use crate::h3::{
    connection::{Shared, initial_control},
    control::Role,
    headers,
    qpack::{Encoder, EncoderConfig},
    quic::Writer,
};
use rama_core::extensions::Extensions;
use rama_http_types::proto::h3::{
    FrameType,
    qpack::{
        FieldSectionBase,
        encoding::{FieldPreferences, HeaderPreferences, InsertionPreferences, Representation},
    },
};
use std::future::poll_fn;

#[tokio::test(start_paused = true)]
async fn insertion_preferences_round_trip_on_fresh_connections_in_both_directions() {
    tokio::time::timeout(LIMIT, async {
        for (startup, representation) in [Startup::Immediate, Startup::OnDemand]
            .into_iter()
            .flat_map(|startup| {
                [
                    Representation::LiteralName,
                    Representation::DynamicIndexBeforeBase,
                    Representation::DynamicIndexAfterBase,
                    Representation::LiteralDynamicNameBeforeBase,
                    Representation::LiteralDynamicNameAfterBase,
                ]
                .map(|representation| (startup, representation))
            })
        {
            let pair = Pair::in_memory(None, None).await;
            let mut config = Config::default();
            config.encoder.defer_dynamic_first_section = !representation.names_base_position();
            config.critical_streams.encoder = startup;
            let (mut server, driver) =
                server::handshake(pair.server.clone(), config.clone()).unwrap();
            spawn(driver.run());
            let (mut client, driver) =
                client::handshake::<Body, _>(pair.client.clone(), config, Executor::new()).unwrap();
            spawn(driver.run());
            let mut preferences = HeaderPreferences::default();
            preferences.headers.append(
                "x-current",
                FieldPreferences {
                    representation,
                    insertion: (!representation.names_base_position())
                        .then(InsertionPreferences::default),
                    ..FieldPreferences::default()
                },
            );
            let response_preferences = preferences.clone();
            let serving = spawn(async move {
                let (request, respond) = server.accept().await.unwrap().resolve().await.unwrap();
                assert_eq!(request.headers()["x-current"], "request-owned");
                let response = Response::builder()
                    .header("x-current", "response-owned")
                    .body(Body::empty())
                    .unwrap();
                response.extensions().insert(response_preferences);
                response
                    .extensions()
                    .insert(FieldSectionBase::FromFieldPreferences);
                respond.send_response(response).await.unwrap();
            });
            let request = Request::get("https://localhost/")
                .header("x-current", "request-owned")
                .body(Body::empty())
                .unwrap();
            request.extensions().insert(preferences);
            request
                .extensions()
                .insert(FieldSectionBase::FromFieldPreferences);
            let response = client.send_request(request).await.unwrap();
            assert_eq!(response.headers()["x-current"], "response-owned");
            response.into_body().collect().await.unwrap();
            serving.await.unwrap();
            pair.close().await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn required_response_insertions_wait_for_late_peer_settings() {
    tokio::time::timeout(LIMIT, async {
        for (informational, representation) in [false, true].into_iter().flat_map(|informational| {
            [
                Representation::LiteralName,
                Representation::DynamicIndexBeforeBase,
                Representation::DynamicIndexAfterBase,
                Representation::LiteralDynamicNameBeforeBase,
                Representation::LiteralDynamicNameAfterBase,
            ]
            .map(|representation| (informational, representation))
        }) {
            let pair = Pair::in_memory(None, None).await;
            let mut config = Config::default();
            config.encoder.defer_dynamic_first_section = !representation.names_base_position();
            let (mut server, driver) = server::handshake(pair.server.clone(), config).unwrap();
            spawn(driver.run());
            let (send, mut receive) = pair.client.open_bi().await.unwrap();
            let mut encoder = Encoder::before_peer_settings(EncoderConfig::default());
            let fields = encoder
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
            writer.queue(FrameType::HEADERS, fields).unwrap();
            poll_fn(|cx| writer.poll_finish(cx)).await.unwrap();
            let (_, mut respond) = server.accept().await.unwrap().resolve().await.unwrap();
            let mut preferences = HeaderPreferences::default();
            preferences.headers.append(
                "x-current",
                FieldPreferences {
                    representation,
                    insertion: (!representation.names_base_position())
                        .then(InsertionPreferences::default),
                    ..FieldPreferences::default()
                },
            );
            let sending = async move {
                if informational {
                    let response = Response::builder()
                        .status(103)
                        .header("x-current", "response-owned")
                        .body(())
                        .unwrap();
                    response.extensions().insert(preferences);
                    response
                        .extensions()
                        .insert(FieldSectionBase::FromFieldPreferences);
                    respond.send_informational(response).await?;
                    respond.send_response(Response::new(Body::empty())).await
                } else {
                    let response = Response::builder()
                        .header("x-current", "response-owned")
                        .body(Body::empty())
                        .unwrap();
                    response.extensions().insert(preferences);
                    response
                        .extensions()
                        .insert(FieldSectionBase::FromFieldPreferences);
                    respond.send_response(response).await
                }
            };
            tokio::pin!(sending);
            // The client deliberately has not opened its control stream. Neither
            // informational nor final required insertions may assume capacity0.
            tokio::time::timeout(Duration::from_secs(1), sending.as_mut())
                .await
                .unwrap_err();
            let mut control = pair.client.open_uni().await.unwrap();
            control
                .write_all(&initial_control(&Config::default(), Role::Client, false).unwrap())
                .await
                .unwrap();
            let (sent, bytes) = tokio::join!(sending, receive.read_to_end(4096));
            sent.unwrap();
            assert!(!bytes.unwrap().is_empty());
            pair.close().await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn ordinary_header_preferences_do_not_wait_for_peer_settings() {
    let shared = Shared::new(Config::default(), Role::Client, Extensions::new()).unwrap();
    let extensions = Extensions::new();
    tokio::time::timeout(
        Duration::ZERO,
        headers::wait_for_header_admission(&shared, &extensions),
    )
    .await
    .unwrap()
    .unwrap();
    for representation in [
        Representation::Automatic,
        Representation::LiteralName,
        Representation::DynamicIndex,
        Representation::LiteralDynamicName,
    ] {
        let mut preferences = HeaderPreferences::default();
        preferences.headers.append(
            "x-current",
            FieldPreferences {
                representation,
                ..FieldPreferences::default()
            },
        );
        extensions.insert(preferences);
        tokio::time::timeout(
            Duration::ZERO,
            headers::wait_for_header_admission(&shared, &extensions),
        )
        .await
        .unwrap()
        .unwrap();
    }
}

#[tokio::test(start_paused = true)]
async fn insertion_without_encoder_credit_still_sends_the_request() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut server, driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        spawn(driver.run());
        let serving = spawn(async move {
            for expected in ["prefetch", "ordinary"] {
                let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
                assert_eq!(request.headers()["x-current"], expected);
                response
                    .send_response(Response::new(Body::empty()))
                    .await
                    .unwrap();
            }
        });
        let mut config = Config::default();
        config.encoder.defer_dynamic_first_section = true;
        config.encoder.max_encoder_stream_bytes = 0;
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), config, Executor::new()).unwrap();
        spawn(driver.run());
        let mut preferences = HeaderPreferences::default();
        preferences.headers.append(
            "x-current",
            FieldPreferences {
                representation: Representation::LiteralName,
                insertion: Some(InsertionPreferences::default()),
                ..FieldPreferences::default()
            },
        );
        for value in ["prefetch", "ordinary"] {
            let request = Request::get("https://localhost/")
                .header("x-current", value)
                .body(Body::empty())
                .unwrap();
            if value == "prefetch" {
                request.extensions().insert(preferences.clone());
            }
            client.ready().await.unwrap();
            let response = client.send_request(request).await.unwrap();
            response.into_body().collect().await.unwrap();
        }
        serving.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn required_request_insertions_wait_for_late_peer_settings() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let mut config = Config::default();
        config.encoder.defer_dynamic_first_section = true;
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), config, Executor::new()).unwrap();
        spawn(driver.run());
        let mut preferences = HeaderPreferences::default();
        preferences.headers.append(
            "x-current",
            FieldPreferences {
                representation: Representation::LiteralName,
                insertion: Some(InsertionPreferences::default()),
                ..FieldPreferences::default()
            },
        );
        let request = Request::get("https://localhost/")
            .header("x-current", "request-owned")
            .body(Body::empty())
            .unwrap();
        request.extensions().insert(preferences);
        let sending = client.send_request(request);
        tokio::pin!(sending);
        tokio::time::timeout(Duration::from_secs(1), sending.as_mut())
            .await
            .unwrap_err();
        // The raw server has deliberately sent no HTTP/3 control data yet.
        let mut control = pair.server.open_uni().await.unwrap();
        control
            .write_all(&initial_control(&Config::default(), Role::Server, false).unwrap())
            .await
            .unwrap();
        let answering = async {
            let (send, mut receive) = pair.server.accept_bi().await.unwrap();
            assert!(!receive.read_to_end(4096).await.unwrap().is_empty());
            let mut encoder = Encoder::before_peer_settings(EncoderConfig::default());
            let section = encoder
                .encode(u64::from(send.id()), [(":status", "200")])
                .unwrap();
            let mut writer = Writer::new(send);
            writer.queue(FrameType::HEADERS, section).unwrap();
            poll_fn(|cx| writer.poll_finish(cx)).await.unwrap();
            writer
        };
        let (response, mut writer) = tokio::join!(sending, answering);
        response.unwrap().into_body().collect().await.unwrap();
        writer.acknowledged().await.unwrap();
        writer.mark_acknowledged();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn required_dynamic_requests_wait_for_settings_and_cancel_before_stream_admission() {
    tokio::time::timeout(LIMIT, async {
        for (startup, representation) in [Startup::Immediate, Startup::OnDemand]
            .into_iter()
            .flat_map(|startup| {
                [
                    Representation::DynamicIndexBeforeBase,
                    Representation::DynamicIndexAfterBase,
                    Representation::LiteralDynamicNameBeforeBase,
                    Representation::LiteralDynamicNameAfterBase,
                ]
                .map(|representation| (startup, representation))
            })
        {
            let pair = Pair::in_memory(None, None).await;
            let mut config = Config::default();
            config.critical_streams.encoder = startup;
            let (mut client, driver) =
                client::handshake::<Body, _>(pair.client.clone(), config, Executor::new()).unwrap();
            spawn(driver.run());
            let request = || {
                let mut preferences = HeaderPreferences::default();
                preferences.headers.append(
                    "x-current",
                    FieldPreferences {
                        representation,
                        ..FieldPreferences::default()
                    },
                );
                let request = Request::get("https://localhost/")
                    .header("x-current", "current-owned")
                    .body(Body::empty())
                    .unwrap();
                request.extensions().insert(preferences);
                request
                    .extensions()
                    .insert(FieldSectionBase::FromFieldPreferences);
                request
            };
            {
                let sending = client.send_request(request());
                tokio::pin!(sending);
                tokio::time::timeout(Duration::from_secs(1), sending.as_mut())
                    .await
                    .unwrap_err();
                tokio::time::timeout(Duration::ZERO, pair.server.accept_bi())
                    .await
                    .unwrap_err();
                // Drop the waiting operation before it can allocate a request stream.
            }
            let mut control = pair.server.open_uni().await.unwrap();
            control
                .write_all(&initial_control(&Config::default(), Role::Server, false).unwrap())
                .await
                .unwrap();
            let answering = async {
                let (send, mut receive) = pair.server.accept_bi().await.unwrap();
                assert_eq!(
                    u64::from(send.id()),
                    0,
                    "cancelled request consumed stream credit"
                );
                assert!(!receive.read_to_end(4096).await.unwrap().is_empty());
                let mut encoder = Encoder::before_peer_settings(EncoderConfig::default());
                let section = encoder.encode(0, [(":status", "200")]).unwrap();
                let mut writer = Writer::new(send);
                writer.queue(FrameType::HEADERS, section).unwrap();
                poll_fn(|cx| writer.poll_finish(cx)).await.unwrap();
                writer
            };
            let (response, mut writer) = tokio::join!(client.send_request(request()), answering);
            response.unwrap().into_body().collect().await.unwrap();
            writer.acknowledged().await.unwrap();
            writer.mark_acknowledged();
            pair.close().await;
        }
    })
    .await
    .unwrap();
}
