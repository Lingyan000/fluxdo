//! Control-stream validation, independent of transport scheduling.

use super::{Error, frame::FrameEvent};
use rama_http_types::proto::h3::{Code, FrameType, Settings, StreamType};

/// Local HTTP endpoint role.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Role {
    Client,
    Server,
}

/// Connection-wide state for peer critical streams and control frames.
#[derive(Debug)]
pub(crate) struct Control {
    role: Role,
    critical: [bool; 3],
    settings: Option<Settings>,
    goaway: Option<u64>,
    max_push_id: Option<u64>,
}

impl Control {
    pub(crate) fn new(role: Role) -> Self {
        Self {
            role,
            critical: [false; 3],
            settings: None,
            goaway: None,
            max_push_id: None,
        }
    }

    /// Called only once a complete stream type has been received.
    pub(crate) fn register(&mut self, ty: StreamType) -> Result<(), Error> {
        let slot = match ty {
            StreamType::CONTROL => 0,
            StreamType::QPACK_ENCODER => 1,
            StreamType::QPACK_DECODER => 2,
            StreamType::PUSH if self.role == Role::Server => {
                return Err(Error::connection(
                    Code::H3_STREAM_CREATION_ERROR,
                    "client opened a push stream",
                ));
            }
            _ => return Ok(()),
        };
        if std::mem::replace(&mut self.critical[slot], true) {
            return Err(Error::connection(
                Code::H3_STREAM_CREATION_ERROR,
                "duplicate critical stream",
            ));
        }
        Ok(())
    }

    /// Validate placement before buffering any advertised payload.
    pub(crate) fn header(&self, ty: FrameType) -> Result<(), Error> {
        if self.settings.is_none() && ty != FrameType::SETTINGS {
            return Err(Error::connection(
                Code::H3_MISSING_SETTINGS,
                "control stream must begin with SETTINGS",
            ));
        }
        if ty.is_h2_reserved()
            || matches!(
                ty,
                FrameType::DATA | FrameType::HEADERS | FrameType::PUSH_PROMISE
            )
            || (ty == FrameType::SETTINGS && self.settings.is_some())
            || (self.role == Role::Client
                && matches!(
                    ty,
                    FrameType::MAX_PUSH_ID
                        | FrameType::PRIORITY_UPDATE_REQUEST
                        | FrameType::PRIORITY_UPDATE_PUSH
                ))
        {
            return Err(Error::connection(
                Code::H3_FRAME_UNEXPECTED,
                "frame forbidden on peer control stream",
            ));
        }
        Ok(())
    }

    pub(crate) fn receive(&mut self, event: &FrameEvent) -> Result<(), Error> {
        match event {
            FrameEvent::Header(header) => self.header(header.ty)?,
            FrameEvent::Settings(settings) => {
                self.header(FrameType::SETTINGS)?;
                self.settings = Some(settings.clone());
            }
            FrameEvent::GoAway(id) => {
                if self.role == Role::Client && id % 4 != 0 {
                    return Err(Error::connection(
                        Code::H3_ID_ERROR,
                        "server GOAWAY is not a client bidirectional stream ID",
                    ));
                }
                if self.goaway.is_some_and(|previous| *id > previous) {
                    return Err(Error::connection(
                        Code::H3_ID_ERROR,
                        "GOAWAY identifier increased",
                    ));
                }
                self.goaway = Some(*id);
            }
            FrameEvent::MaxPushId(id) => {
                if self.max_push_id.is_some_and(|previous| *id < previous) {
                    return Err(Error::connection(
                        Code::H3_ID_ERROR,
                        "MAX_PUSH_ID decreased",
                    ));
                }
                self.max_push_id = Some(*id);
            }
            _ => (),
        }
        Ok(())
    }

    pub(crate) fn goaway(&self) -> Option<u64> {
        self.goaway
    }

    /// The peer's SETTINGS, once received.
    pub(crate) fn settings(&self) -> Option<&Settings> {
        self.settings.as_ref()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::h3::frame::FrameDecoder;
    use rama_core::bytes::BytesMut;
    use rama_http_types::proto::h3::FrameHeader;

    #[test]
    fn critical_streams_are_unique_and_role_checked() {
        for role in [Role::Client, Role::Server] {
            for ty in [
                StreamType::CONTROL,
                StreamType::QPACK_ENCODER,
                StreamType::QPACK_DECODER,
            ] {
                let mut control = Control::new(role);
                control.register(ty).unwrap();
                assert_eq!(
                    control.register(ty).unwrap_err().code(),
                    Code::H3_STREAM_CREATION_ERROR
                );
            }
        }
        Control::new(Role::Client)
            .register(StreamType::PUSH)
            .unwrap();
        assert!(
            Control::new(Role::Server)
                .register(StreamType::PUSH)
                .is_err()
        );
    }

    #[test]
    fn control_header_rejected_before_payload_arrives() {
        let control = Control::new(Role::Server);
        let mut encoded = BytesMut::new();
        FrameHeader::new(
            FrameType::HEADERS,
            rama_http_types::proto::h3::VarInt::MAX.into_inner(),
        )
        .encode(&mut encoded)
        .unwrap();
        let mut decoder = FrameDecoder::new(16).with_header_events();
        decoder.feed_bytes(&mut encoded.freeze()).unwrap();
        let Some(FrameEvent::Header(header)) = decoder.poll().unwrap() else {
            panic!("missing header")
        };
        assert_eq!(
            control.header(header.ty).unwrap_err().code(),
            Code::H3_MISSING_SETTINGS
        );
    }

    #[test]
    fn goaway_is_monotonic_and_role_specific() {
        for role in [Role::Client, Role::Server] {
            let mut control = Control::new(role);
            control
                .receive(&FrameEvent::Settings(Settings::new()))
                .unwrap();
            control.receive(&FrameEvent::GoAway(8)).unwrap();
            control.receive(&FrameEvent::GoAway(4)).unwrap();
            assert_eq!(
                control.receive(&FrameEvent::GoAway(8)).unwrap_err().code(),
                Code::H3_ID_ERROR
            );
            assert_eq!(control.goaway(), Some(4));
        }
        let mut client = Control::new(Role::Client);
        assert!(client.receive(&FrameEvent::GoAway(1)).is_err());
        // Client GOAWAY carries a push ID, not a QUIC stream ID.
        let mut server = Control::new(Role::Server);
        server.receive(&FrameEvent::GoAway(1)).unwrap();
    }

    #[test]
    fn settings_and_control_placement() {
        for role in [Role::Client, Role::Server] {
            let mut control = Control::new(role);
            assert_eq!(
                control.header(FrameType::new(0x21)).unwrap_err().code(),
                Code::H3_MISSING_SETTINGS
            );
            control
                .receive(&FrameEvent::Settings(Settings::new()))
                .unwrap();
            control.header(FrameType::new(0x21)).unwrap();
            for ty in [
                FrameType::SETTINGS,
                FrameType::DATA,
                FrameType::HEADERS,
                FrameType::PUSH_PROMISE,
            ] {
                assert_eq!(
                    control.header(ty).unwrap_err().code(),
                    Code::H3_FRAME_UNEXPECTED
                );
            }
            assert_eq!(
                control.header(FrameType::MAX_PUSH_ID).is_ok(),
                role == Role::Server
            );
        }
    }
}
