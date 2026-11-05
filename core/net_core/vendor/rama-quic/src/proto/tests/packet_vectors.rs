//! Packet header encoding against a known Initial vector, exercising the engine's crypto backend
//! together with the `rama-quic-proto` packet codec.

use rama_core::bytes::Bytes;
use rama_quic_proto::{
    ConnectionId, Side, Version,
    packet::{FixedLengthConnectionIdParser, Header, InitialHeader, PacketNumber, PartialDecode},
    transport_parameters::TransportParameters,
};

use crate::proto::DEFAULT_SUPPORTED_VERSIONS;

#[test]
#[expect(clippy::print_stdout, reason = "debug output of a test")]
fn header_encoding() {
    let dcid = ConnectionId::new(&[0x06, 0xb8, 0x58, 0xec, 0x6f, 0x80, 0x45, 0x2b]);
    let config = crate::test_helpers::client(&crate::test_helpers::identity());
    let session = config
        .crypto
        .start_session(
            Version::V1,
            "localhost",
            &TransportParameters {
                initial_src_cid: Some(dcid),
                ..TransportParameters::default()
            },
        )
        .unwrap();
    let client = session
        .initial_keys(Version::V1, &dcid, Side::Client)
        .unwrap();
    let mut buf = Vec::new();
    let header = Header::Initial(InitialHeader {
        number: PacketNumber::U8(0),
        src_cid: ConnectionId::new(&[]),
        dst_cid: dcid,
        token: Bytes::new(),
        version: DEFAULT_SUPPORTED_VERSIONS[0].to_wire().unwrap(),
    });
    let encode = header.encode(&mut buf);
    let header_len = buf.len();
    buf.resize(header_len + 16 + client.local.packet.tag_len(), 0);
    encode
        .finish(
            &mut buf,
            &*client.local.header,
            Some((0, &*client.local.packet)),
        )
        .unwrap();

    println!("{}", rama_utils::fmt::hex(&buf));
    let expected: [u8; 51] = rama_utils::hex::decode(concat!(
        "c8000000", "010806b8", "58ec6f80", "452b0000", "4021be3e", "f50807b8", "4191a196",
        "f760a6da", "d1e9d1c4", "30c48952", "cba01482", "50c21c0a", "6a70e1",
    ))
    .expect("valid initial packet test vector");
    assert_eq!(buf[..], expected[..]);

    let server = session
        .initial_keys(Version::V1, &dcid, Side::Server)
        .unwrap();
    let supported_versions = DEFAULT_SUPPORTED_VERSIONS.to_vec();
    let decode = PartialDecode::new(
        buf.as_slice().into(),
        &FixedLengthConnectionIdParser::new(0),
        &supported_versions,
        false,
    )
    .unwrap()
    .0;
    let mut packet = decode
        .finish_protected(&*server.remote.as_ref().unwrap().header)
        .unwrap();
    assert_eq!(
        packet.header_data[..],
        [
            0xc0, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0xb8, 0x58, 0xec, 0x6f, 0x80, 0x45, 0x2b,
            0x00, 0x00, 0x40, 0x21, 0x00
        ][..]
    );
    server
        .remote
        .as_ref()
        .unwrap()
        .packet
        .decrypt(0, &packet.header_data, &mut packet.payload)
        .unwrap();
    assert_eq!(packet.payload[..], [0; 16]);
    match packet.header {
        Header::Initial(InitialHeader {
            number: PacketNumber::U8(0),
            ..
        }) => {}
        _ => {
            panic!("unexpected header {:?}", packet.header);
        }
    }
}
