use std::{
    borrow::Cow,
    net::{Ipv4Addr, Ipv6Addr},
};

use super::*;
use lifecycle::{ConnectionClosedView, ReasonView, TransportErrorName};
use negotiation::{AlpnIdentifierView, HexView, Version, VersionInformationView, VersionListView};

fn alpn(bytes: &[u8]) -> EventFieldsView<'_> {
    NegotiationEventView::AlpnInformation {
        chosen_alpn: AlpnIdentifierView {
            byte_value: HexView(Cow::Borrowed(bytes)),
        },
    }
    .into()
}

#[test]
fn borrowed_alpn_preserves_pointer_and_ownership_is_explicit() {
    let owned;
    {
        let source = vec![0, 0xff, b'h', b'3'];
        let view = alpn(&source);
        assert_eq!(view.heap_size(), 0);
        assert_eq!(view.owned_heap_size(), source.len());
        let EventView::Negotiation(NegotiationEventView::AlpnInformation { chosen_alpn }) =
            &view.event
        else {
            panic!("ALPN fixture")
        };
        assert_eq!(chosen_alpn.byte_value.0.as_ptr(), source.as_ptr());
        owned = view.to_owned();
        let EventView::Negotiation(NegotiationEventView::AlpnInformation { chosen_alpn }) =
            &owned.event
        else {
            panic!("ALPN fixture")
        };
        assert_ne!(chosen_alpn.byte_value.0.as_ptr(), source.as_ptr());
        assert_eq!(
            serde_json::to_value(&view).unwrap(),
            serde_json::to_value(&owned).unwrap()
        );
    }

    fn assert_owned_send<T: Send + 'static>() {}
    assert_owned_send::<EventFields>();
    let value = std::thread::spawn(move || serde_json::to_value(owned).unwrap())
        .join()
        .unwrap();
    assert_eq!(
        value,
        serde_json::json!({
            "name": "quic:alpn_information", "data": {"chosen_alpn": {"byte_value": "00ff6833"}}
        })
    );
}

#[test]
fn consuming_an_owned_event_preserves_its_allocation() {
    let mut bytes = Vec::with_capacity(57);
    bytes.extend_from_slice(b"alpn");
    let pointer = bytes.as_ptr();
    let capacity = bytes.capacity();
    let fields: EventFields = NegotiationEventView::AlpnInformation {
        chosen_alpn: AlpnIdentifierView {
            byte_value: HexView(Cow::Owned(bytes)),
        },
    }
    .into();
    assert_eq!(fields.heap_size(), capacity);
    assert_eq!(fields.owned_heap_size(), capacity);
    let fields = fields.into_owned();
    let EventView::Negotiation(NegotiationEventView::AlpnInformation { chosen_alpn }) =
        fields.event
    else {
        panic!("ALPN fixture")
    };
    assert_eq!(chosen_alpn.byte_value.0.as_ptr(), pointer);
    assert_eq!(chosen_alpn.byte_value.0.len(), 4);
}

#[test]
fn version_lists_borrow_either_representation_and_serialize_identically() {
    let native = [rama_quic_proto::Version::V1, rama_quic_proto::Version::V2];
    let network = [[0, 0, 0, 1], [0x6b, 0x33, 0x43, 0xcf]];
    let fields: EventFieldsView<'_> =
        NegotiationEventView::VersionInformation(VersionInformationView {
            client_versions: Some(VersionListView::Host(Cow::Borrowed(&native))),
            server_versions: Some(VersionListView::Network(Cow::Borrowed(&network))),
            chosen_version: Some(Version([0, 0, 0, 1])),
        })
        .into();
    assert_eq!(fields.heap_size(), 0);
    assert_eq!(fields.owned_heap_size(), 16);
    let owned = fields.to_owned();
    assert_eq!(owned.heap_size(), 16);
    assert_eq!(
        serde_json::to_value(&fields).unwrap(),
        serde_json::to_value(&owned).unwrap()
    );
    let value = serde_json::to_value(fields).unwrap();
    assert_eq!(
        value["data"]["client_versions"],
        serde_json::json!(["00000001", "6b3343cf"])
    );
    assert_eq!(
        value["data"]["server_versions"],
        value["data"]["client_versions"]
    );
    assert_eq!(value["data"]["chosen_version"], "00000001");
}

#[test]
fn owned_version_lists_count_spare_capacity_and_move_it() {
    let mut native = Vec::with_capacity(13);
    native.push(rama_quic_proto::Version::V1);
    let mut network = Vec::with_capacity(17);
    network.push([0, 0, 0, 1]);
    let expected = (native.capacity() + network.capacity()) * 4;
    let native_pointer = native.as_ptr();
    let fields: EventFields = NegotiationEventView::VersionInformation(VersionInformationView {
        client_versions: Some(VersionListView::Host(Cow::Owned(native))),
        server_versions: Some(VersionListView::Network(Cow::Owned(network))),
        chosen_version: None,
    })
    .into();
    assert_eq!(fields.heap_size(), expected);
    assert_eq!(fields.owned_heap_size(), expected);
    let owned = fields.into_owned();
    assert_eq!(owned.heap_size(), expected);
    let EventView::Negotiation(NegotiationEventView::VersionInformation(info)) = owned.event else {
        panic!("version fixture")
    };
    let Some(VersionListView::Host(versions)) = info.client_versions else {
        panic!("native version fixture")
    };
    assert_eq!(versions.as_ptr(), native_pointer);
    let absent: EventFields = NegotiationEventView::VersionInformation(VersionInformationView {
        client_versions: None,
        server_versions: None,
        chosen_version: None,
    })
    .into();
    assert_eq!(absent.heap_size(), 0);
    assert_eq!(absent.owned_heap_size(), 0);
}

#[test]
fn reason_storage_is_borrowed_until_retained_and_preserves_raw_bytes() {
    let text = String::from("local reason");
    let wire = vec![b'r', 0xff, 0, b'"'];
    for reason in [
        ReasonView::Text(&text),
        ReasonView::Bytes(Cow::Borrowed(&wire)),
    ] {
        let expected_size = match &reason {
            ReasonView::Text(text) => text.len(),
            ReasonView::Bytes(bytes) => bytes.len(),
            _ => panic!("borrowed reason fixture"),
        };
        let fields: EventFieldsView<'_> = LifecycleEventView::Closed(ConnectionClosedView {
            reason: Some(reason),
            ..Default::default()
        })
        .into();
        assert_eq!(fields.heap_size(), 0);
        assert_eq!(fields.owned_heap_size(), expected_size);
        let owned = fields.to_owned();
        assert_eq!(owned.heap_size(), expected_size);
        assert_eq!(
            serde_json::to_value(&fields).unwrap(),
            serde_json::to_value(&owned).unwrap()
        );
        let EventView::Lifecycle(LifecycleEventView::Closed(closed)) = owned.event else {
            panic!("close fixture")
        };
        match closed.reason.unwrap() {
            ReasonView::Owned(value) => assert_eq!(&*value, text),
            ReasonView::Bytes(Cow::Owned(value)) => assert_eq!(value, wire),
            _ => panic!("expected independent owned reason"),
        }
    }
    let static_reason = ReasonView::Static("timeout").into_owned();
    assert_eq!(static_reason.heap_size(), 0);
    assert_eq!(static_reason.owned_heap_size(), 0);
    let owned: Box<str> = "already owned".into();
    let pointer = owned.as_ptr();
    let reason = ReasonView::Owned(owned).into_owned();
    let ReasonView::Owned(value) = reason else {
        panic!("owned reason fixture")
    };
    assert_eq!(value.as_ptr(), pointer);
}

#[test]
fn owned_wire_reason_counts_spare_byte_capacity() {
    let mut bytes = Vec::with_capacity(83);
    bytes.extend_from_slice(b"reason");
    let expected = bytes.capacity();
    let reason = ReasonView::Bytes(Cow::Owned(bytes));
    assert_eq!(reason.heap_size(), expected);
    assert_eq!(reason.owned_heap_size(), expected);
    assert_eq!(reason.into_owned().heap_size(), expected);
}

#[test]
fn streaming_lossy_reason_matches_standard_utf8_rendering() {
    let all_bytes: Vec<u8> = (0..=255).collect();
    let cases: &[&[u8]] = &[
        b"",
        b"ordinary UTF-8",
        "\u{1f600}".as_bytes(),
        b"\xff",
        b"\xc0\xaf",
        b"\xe2\x82",
        b"\xe2\x82x",
        b"\xf0\x90\x80",
        b"\xed\xa0\x80",
        b"\xf4\x90\x80\x80",
        b"before\xff\xffafter\0\n\"\\",
        &all_bytes,
    ];
    for bytes in cases {
        let reason = ReasonView::Bytes(Cow::Borrowed(bytes));
        assert_eq!(reason.heap_size(), 0);
        assert_eq!(
            serde_json::to_string(&reason).unwrap(),
            serde_json::to_string(&String::from_utf8_lossy(bytes)).unwrap()
        );
        assert_eq!(
            serde_json::to_string(&reason.into_owned()).unwrap(),
            serde_json::to_string(&String::from_utf8_lossy(bytes)).unwrap()
        );
    }
}

#[test]
fn compact_path_and_connection_values_need_no_heap() {
    let cid = ConnectionId::new(&[0xab, 0xcd]);
    let event = LifecycleEventView::Started {
        local: lifecycle::TupleEndpointInfo {
            ip_v4: Some(Ipv4Addr::LOCALHOST),
            port_v4: Some(443),
            ip_v6: None,
            port_v6: None,
            connection_ids: [cid],
        },
        remote: lifecycle::TupleEndpointInfo {
            ip_v4: None,
            port_v4: None,
            ip_v6: Some(Ipv6Addr::LOCALHOST),
            port_v6: Some(80),
            connection_ids: [ConnectionId::new(&[])],
        },
    };
    let fields: EventFields = event.into();
    assert_eq!(fields.heap_size(), 0);
    assert_eq!(fields.owned_heap_size(), 0);
    let value = serde_json::to_value(fields).unwrap();
    assert_eq!(value["data"]["local"]["ip_v4"], "127.0.0.1");
    assert_eq!(
        value["data"]["local"]["connection_ids"],
        serde_json::json!(["abcd"])
    );
    assert_eq!(value["data"]["remote"]["ip_v6"], "::1");
    assert_eq!(
        value["data"]["remote"]["connection_ids"],
        serde_json::json!([""])
    );
    for (id, text) in [
        (TupleId::Default, ""),
        (TupleId::Generation(7), "7"),
        (TupleId::Probe(2), "probe-2"),
    ] {
        let fields = EventFieldsView {
            tuple: Some(id),
            event: PathEvent::TupleAssigned(path::TupleAssigned {
                tuple_id: id,
                tuple_remote: Some(path::TupleEndpointInfo::V4 {
                    ip_v4: Ipv4Addr::LOCALHOST,
                    port_v4: 443,
                }),
                tuple_local: None,
            })
            .into(),
        };
        assert_eq!(fields.heap_size(), 0);
        assert_eq!(fields.to_owned().heap_size(), 0);
        let value = serde_json::to_value(fields).unwrap();
        assert_eq!(value["tuple"], text);
        assert_eq!(value["data"]["tuple_id"], text);
    }
}

#[test]
fn wrapper_preserves_tagged_packet_drop_schema() {
    let fields = EventFields::from(PacketDropped {
        header: Some(drops::DropHeader {
            packet_type: drops::DropPacketType::OneRtt,
            packet_number: Some(42),
        }),
        raw: Some(packet::RawInfo { length: 1200 }),
        trigger: drops::DropReason::Duplicate,
    });
    assert_eq!(fields.heap_size(), 0);
    assert_eq!(fields.to_owned().heap_size(), 0);
    assert_eq!(
        serde_json::to_value(fields).unwrap(),
        serde_json::json!({
            "name": "quic:packet_dropped",
            "data": {"header": {"packet_type": "1RTT", "packet_number": 42}, "raw": {"length": 1200}, "trigger": "duplicate"}
        })
    );
}

#[test]
fn transport_parameter_cids_are_inline_and_hex_only_at_serialization() {
    let params = negotiation::ParametersSet {
        initiator: Initiator::Local,
        parameters: negotiation::RestoredParameters {
            disable_active_migration: false,
            max_idle_timeout: 0,
            max_udp_payload_size: 1200,
            active_connection_id_limit: 2,
            initial_max_data: 0,
            initial_max_stream_data_bidi_local: 0,
            initial_max_stream_data_bidi_remote: 0,
            initial_max_stream_data_uni: 0,
            initial_max_streams_bidi: 0,
            initial_max_streams_uni: 0,
            max_datagram_frame_size: None,
            grease_quic_bit: false,
        },
        ack_delay_exponent: 3,
        max_ack_delay: 25,
        original_destination_connection_id: Some(ConnectionId::new(&[0x00, 0xff])),
        initial_source_connection_id: Some(ConnectionId::new(&[0xab, 0xcd])),
        retry_source_connection_id: None,
    };
    let fields: EventFields = NegotiationEventView::ParametersSet(params).into();
    assert_eq!(fields.heap_size(), 0);
    assert_eq!(fields.owned_heap_size(), 0);
    let value = serde_json::to_value(fields).unwrap();
    assert_eq!(value["data"]["original_destination_connection_id"], "00ff");
    assert_eq!(value["data"]["initial_source_connection_id"], "abcd");
    assert!(value["data"].get("retry_source_connection_id").is_none());
}

#[test]
fn all_crypto_alert_names_format_without_owned_text() {
    for alert in 0..=255 {
        let fields: EventFields = LifecycleEventView::Closed(ConnectionClosedView {
            connection_error: Some(TransportErrorName::Crypto(alert)),
            ..Default::default()
        })
        .into();
        assert_eq!(fields.heap_size(), 0);
        assert_eq!(fields.owned_heap_size(), 0);
        let value = serde_json::to_value(fields).unwrap();
        assert_eq!(
            value["data"]["connection_error"],
            format!("crypto_error_0x{:03x}", 0x100 + u16::from(alert))
        );
    }
}

#[test]
fn unspecified_closure_omits_unknown_classifications() {
    let value =
        serde_json::to_value(LifecycleEventView::Closed(ConnectionClosedView::default())).unwrap();
    assert_eq!(
        value,
        serde_json::json!({"name": "quic:connection_closed", "data": {}})
    );
}

#[test]
fn recovery_parameters_omit_non_finite_optional_measurements() {
    for value in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
        let event = PathEvent::RecoveryParametersSet {
            reordering_threshold: None,
            time_threshold: value,
            timer_granularity: 1,
            initial_rtt: value,
            max_datagram_size: 1200,
            initial_congestion_window: 12000,
            persistent_congestion_threshold: None,
        };
        let data = serde_json::to_value(event).unwrap();
        assert!(data["data"].get("time_threshold").is_none());
        assert!(data["data"].get("initial_rtt").is_none());
        assert_eq!(data["data"]["timer_granularity"], 1);
    }
}
