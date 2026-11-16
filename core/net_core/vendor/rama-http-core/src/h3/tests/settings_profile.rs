use super::{LIMIT, Pair};
use crate::h3::{
    client,
    connection::Config,
    observation::{H3Observer, SettingsObservation},
    server,
};
use rama_core::{
    extensions::ExtensionsRef as _,
    rt::{Executor, spawn},
};
use rama_http_types::{
    Body, Request, Response,
    proto::h3::{SettingId, Settings},
};
use std::{sync::Arc, time::Duration};
use tokio::time::Instant;

#[tokio::test(start_paused = true)]
async fn settings_profile_reaches_peer_in_literal_order() {
    for connect_protocol in [None, Some(0), Some(1)] {
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::in_memory(None, None).await;
            let mut config = Config::default();
            let mut settings = Settings::new();
            let mut entries = vec![
                (SettingId::FIRST_RESERVED, 17),
                (
                    SettingId::QPACK_BLOCKED_STREAMS,
                    config.decoder.max_blocked_streams,
                ),
                (SettingId::new(0xface), 29),
                (SettingId::H3_DATAGRAM, 1),
                (
                    SettingId::QPACK_MAX_TABLE_CAPACITY,
                    config.decoder.max_table_capacity,
                ),
            ];
            if let Some(value) = connect_protocol {
                entries.insert(1, (SettingId::ENABLE_CONNECT_PROTOCOL, value));
            }
            for (id, value) in entries {
                settings.set(id, value).unwrap();
            }
            let expected: Vec<_> = settings
                .entries()
                .iter()
                .map(|entry| (entry.id.value(), entry.value))
                .collect();
            config = config.try_with_client_settings(Arc::new(settings)).unwrap();
            let (mut server, driver) = server::handshake(
                pair.server.clone(),
                Config {
                    observation: Some(Default::default()),
                    ..Config::default()
                },
            )
            .unwrap();
            spawn(driver.run());
            let (mut client, driver) =
                client::handshake::<Body, _>(pair.client.clone(), config, Executor::new()).unwrap();
            spawn(driver.run());

            let serve = spawn(async move {
                let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
                let observer = request
                    .extensions()
                    .get_ref::<H3Observer>()
                    .unwrap()
                    .clone();
                let SettingsObservation::Received(observed) = observer
                    .settings(Instant::now() + Duration::from_secs(1))
                    .await
                else {
                    panic!("profile SETTINGS were not received");
                };
                let actual: Vec<_> = observed
                    .settings
                    .as_ref()
                    .unwrap()
                    .iter()
                    .map(|entry| (entry.id, entry.value))
                    .collect();
                assert_eq!(actual, expected);
                response
                    .send_response(Response::new(Body::empty()))
                    .await
                    .unwrap();
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
            serve.await.unwrap();
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

#[tokio::test(start_paused = true)]
async fn settings_profile_omitting_an_available_capability_does_not_advertise_it() {
    let pair = Pair::in_memory(None, None).await;
    let mut settings = Settings::new();
    let mut config = Config::default();
    settings
        .set(
            SettingId::QPACK_MAX_TABLE_CAPACITY,
            config.decoder.max_table_capacity,
        )
        .unwrap();
    settings
        .set(
            SettingId::QPACK_BLOCKED_STREAMS,
            config.decoder.max_blocked_streams,
        )
        .unwrap();
    // QUIC DATAGRAM is available and enabled locally, but the profile omits it.
    config.settings_profile = Some(Arc::new(settings));
    let (sender, driver) =
        client::handshake::<Body, _>(pair.client.clone(), config, Executor::new()).unwrap();
    drop((sender, driver));
    pair.close().await;
}

#[test]
fn captured_settings_raise_qpack_limits_up_to_the_ceiling() {
    let captured = |table, blocked, section| {
        let mut settings = Settings::new();
        settings
            .set(SettingId::QPACK_MAX_TABLE_CAPACITY, table)
            .unwrap();
        settings
            .set(SettingId::QPACK_BLOCKED_STREAMS, blocked)
            .unwrap();
        settings
            .set(SettingId::MAX_FIELD_SECTION_SIZE, section)
            .unwrap();
        Arc::new(settings)
    };

    // Browser values above the defaults are advertised as captured.
    let browser = captured(65_536, 100, 262_144);
    let config = Config::default()
        .try_with_captured_client_settings(browser.clone())
        .unwrap();
    assert_eq!(config.decoder.max_table_capacity, 65_536);
    assert_eq!(config.decoder.max_blocked_streams, 100);
    assert_eq!(config.decoder.max_field_section_size, 262_144);
    assert_eq!(config.settings().unwrap().entries(), browser.entries());

    // Values beyond the ceiling are lowered to it.
    let ceiling = Config::CAPTURED_QPACK_CEILING;
    let config = Config::default()
        .try_with_captured_client_settings(captured(u32::MAX.into(), 1 << 20, 1 << 40))
        .unwrap();
    assert_eq!(
        config.decoder.max_table_capacity,
        ceiling.max_table_capacity
    );
    assert_eq!(
        config.decoder.max_blocked_streams,
        ceiling.max_blocked_streams
    );
    assert_eq!(
        config.decoder.max_field_section_size,
        ceiling.max_field_section_size
    );

    // Literal client SETTINGS keep fitting under the configured limits.
    let config = Config::default()
        .try_with_client_settings(captured(65_536, 100, 262_144))
        .unwrap();
    let defaults = Config::default().decoder;
    assert_eq!(
        config.decoder.max_table_capacity,
        defaults.max_table_capacity
    );
    assert_eq!(
        config.decoder.max_blocked_streams,
        defaults.max_blocked_streams
    );
}
