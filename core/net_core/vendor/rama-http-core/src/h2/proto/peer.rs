use crate::h2::error::Reason;
use crate::h2::proto::{Error, Open};

use rama_core::extensions::Extensions;
use rama_http_types::proto::h2::frame::{Pseudo, StreamId};
use rama_http_types::{HeaderMap, Request, Response};

use std::fmt;

/// Either a Client or a Server
pub(crate) trait Peer {
    /// Message type polled from the transport
    type Poll: fmt::Debug;
    const NAME: &'static str;

    fn r#dyn() -> Dyn;

    //fn is_server() -> bool;

    fn convert_poll_message(
        pseudo: Pseudo,
        fields: HeaderMap,
        header_size: usize,
        stream_id: StreamId,
        extensions: Extensions,
    ) -> Result<Self::Poll, Error>;

    /*
    fn is_local_init(id: StreamId) -> bool {
        assert!(!id.is_zero());
        Self::is_server() == id.is_server_initiated()
    }
    */
}

/// A dynamic representation of `Peer`.
///
/// This is used internally to avoid incurring a generic on all internal types.
#[derive(Debug, Copy, Clone, Eq, PartialEq)]
pub(crate) enum Dyn {
    Client,
    Server,
}

#[derive(Debug)]
pub(crate) enum PollMessage {
    Client(Response<()>),
    Server(Request<()>),
}

// ===== impl Dyn =====

impl Dyn {
    pub(crate) fn is_server(self) -> bool {
        self == Self::Server
    }

    pub(crate) fn is_local_init(self, id: StreamId) -> bool {
        assert!(!id.is_zero());
        self.is_server() == id.is_server_initiated()
    }

    pub(crate) fn convert_poll_message(
        self,
        pseudo: Pseudo,
        fields: HeaderMap,
        header_size: usize,
        stream_id: StreamId,
        extensions: Extensions,
    ) -> Result<PollMessage, Error> {
        if self.is_server() {
            crate::h2::server::Peer::convert_poll_message(
                pseudo,
                fields,
                header_size,
                stream_id,
                extensions,
            )
            .map(PollMessage::Server)
        } else {
            crate::h2::client::Peer::convert_poll_message(
                pseudo,
                fields,
                header_size,
                stream_id,
                extensions,
            )
            .map(PollMessage::Client)
        }
    }

    /// Returns true if the remote peer can initiate a stream with the given ID.
    pub(crate) fn ensure_can_open(self, id: StreamId, mode: Open) -> Result<(), Error> {
        if self.is_server() {
            // Ensure that the ID is a valid client initiated ID
            if mode.is_push_promise() || !id.is_client_initiated() {
                proto_err!(conn: "cannot open stream {:?} - not client initiated", id);
                return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
            }

            Ok(())
        } else {
            // Ensure that the ID is a valid server initiated ID
            if !mode.is_push_promise() || !id.is_server_initiated() {
                proto_err!(conn: "cannot open stream {:?} - not server initiated", id);
                return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
            }

            Ok(())
        }
    }
}
