use crate::h2::codec::UserError;
use crate::h2::error::Reason;
use crate::h2::proto::*;

use rama_core::telemetry::tracing;
use std::{
    task::{Context, Poll},
    time::Duration,
};
use tokio::time::Instant;

/// `literal` as the hop enforces it: receive caps the frame omits keep their `local` value.
pub(crate) fn with_local_caps(
    mut literal: frame::Settings,
    local: &frame::SettingsConfig,
) -> frame::Settings {
    let cfg = &mut literal.config;
    if cfg.max_concurrent_streams.is_none() && local.max_concurrent_streams.is_some() {
        tracing::debug!(
            max = ?local.max_concurrent_streams,
            "h2: initial SETTINGS omit MAX_CONCURRENT_STREAMS; local cap enforced unadvertised"
        );
        cfg.max_concurrent_streams = local.max_concurrent_streams;
    }
    if cfg.max_header_list_size.is_none() && local.max_header_list_size.is_some() {
        tracing::debug!(
            max = ?local.max_header_list_size,
            "h2: initial SETTINGS omit MAX_HEADER_LIST_SIZE; local cap enforced unadvertised"
        );
        cfg.max_header_list_size = local.max_header_list_size;
    }
    literal
}

#[derive(Debug)]
pub(crate) struct Settings {
    /// Our local SETTINGS sync state with the remote.
    local: Local,
    /// Received SETTINGS frame pending processing. The ACK must be written to
    /// the socket first then the settings applied **before** receiving any
    /// further frames.
    remote: Option<frame::Settings>,
    /// Whether the connection has received the initial SETTINGS frame from the
    /// remote peer.
    has_received_remote_initial_settings: bool,
    /// When the initial local SETTINGS left, until their ACK arrives.
    initial_sent_at: Option<Instant>,
    /// The round trip of the initial local SETTINGS, until taken.
    rtt: Option<Duration>,
}

#[derive(Debug)]
enum Local {
    /// We want to send these SETTINGS to the remote when the socket is ready.
    ToSend(frame::Settings),
    /// We have sent these SETTINGS and are waiting for the remote to ACK
    /// before we apply them.
    WaitingAck(frame::Settings),
    /// Our local settings are in sync with the remote.
    Synced,
}

impl Settings {
    pub(crate) fn new(local: frame::Settings, initial_sent_at: Option<Instant>) -> Self {
        Self {
            // We assume the initial local SETTINGS were flushed during
            // the handshake process.
            local: Local::WaitingAck(local),
            remote: None,
            has_received_remote_initial_settings: false,
            initial_sent_at,
            rtt: None,
        }
    }

    /// The round trip of the initial local SETTINGS, once they were acknowledged.
    pub(crate) fn take_rtt(&mut self) -> Option<Duration> {
        self.rtt.take()
    }

    pub(crate) fn recv_settings<T, B, C, P>(
        &mut self,
        frame: frame::Settings,
        codec: &mut Codec<T, B>,
        streams: &mut Streams<C, P>,
    ) -> Result<(), Error>
    where
        T: AsyncWrite + Unpin,
        B: Buf,
        C: Buf,
        P: Peer,
    {
        if frame.flags.is_ack() {
            match &self.local {
                Local::WaitingAck(local) => {
                    tracing::debug!("received settings ACK; applying {:?}", local);

                    if let Some(max) = local.config.max_frame_size {
                        codec.set_max_recv_frame_size(max as usize);
                    }

                    if let Some(max) = local.config.max_header_list_size {
                        codec.set_max_recv_header_list_size(max as usize);
                    }

                    if let Some(val) = local.config.header_table_size {
                        codec.set_recv_header_table_size(val as usize);
                    }

                    streams.apply_local_settings(local, &frame)?;
                    self.local = Local::Synced;
                    if let Some(sent) = self.initial_sent_at.take() {
                        self.rtt = Some(Instant::now().saturating_duration_since(sent));
                    }
                    Ok(())
                }
                Local::ToSend(..) | Local::Synced => {
                    // We haven't sent any SETTINGS frames to be ACKed, so
                    // this is very bizarre! Remote is either buggy or malicious.
                    proto_err!(conn: "received unexpected settings ack");
                    Err(Error::library_go_away(Reason::PROTOCOL_ERROR))
                }
            }
        } else {
            // We always ACK before reading more frames, so `remote` should
            // always be none!
            assert!(self.remote.is_none());
            streams.record_remote_settings(&frame);
            self.remote = Some(frame);
            Ok(())
        }
    }

    pub(crate) fn send_settings(&mut self, frame: frame::Settings) -> Result<(), UserError> {
        assert!(!frame.flags.is_ack());
        match &self.local {
            Local::ToSend(..) => {
                tracing::debug!("SendSettingsWhilePending (send local, no early)");
                Err(UserError::SendSettingsWhilePending)
            }
            Local::WaitingAck(..) => {
                tracing::debug!("SendSettingsWhilePending (send local, waiting ack)");
                Err(UserError::SendSettingsWhilePending)
            }
            Local::Synced => {
                tracing::trace!("queue to send local settings: {frame:?}");
                self.local = Local::ToSend(frame);
                Ok(())
            }
        }
    }

    /// Returns whether no local SETTINGS are queued or awaiting acknowledgment.
    pub(crate) fn is_synced(&self) -> bool {
        matches!(self.local, Local::Synced)
    }

    /// Sets `true` to `self.has_received_remote_initial_settings`.
    /// Returns `true` if this method is called for the first time.
    /// (i.e. it is the initial SETTINGS frame from the remote peer)
    fn mark_remote_initial_settings_as_received(&mut self) -> bool {
        let has_received = self.has_received_remote_initial_settings;
        self.has_received_remote_initial_settings = true;
        !has_received
    }

    pub(crate) fn poll_send<T, B, C, P>(
        &mut self,
        cx: &mut Context,
        dst: &mut Codec<T, B>,
        streams: &mut Streams<C, P>,
    ) -> Poll<Result<(), Error>>
    where
        T: AsyncWrite + Unpin,
        B: Buf,
        C: Buf,
        P: Peer,
    {
        if let Some(settings) = self.remote.clone() {
            if !dst.poll_ready(cx)?.is_ready() {
                return Poll::Pending;
            }

            // Create an ACK settings frame
            let frame = frame::Settings::ack();

            // Buffer the settings frame
            dst.buffer(frame.into())?;

            tracing::trace!("ACK sent; applying settings");

            let is_initial = self.mark_remote_initial_settings_as_received();
            streams.apply_remote_settings(&settings, is_initial)?;

            if let Some(val) = settings.config.header_table_size {
                dst.set_send_header_table_size(val as usize);
            }

            if let Some(val) = settings.config.max_frame_size {
                dst.set_max_send_frame_size(val as usize);
            }
        }
        self.remote = None;

        match &self.local {
            Local::ToSend(settings) => {
                if !dst.poll_ready(cx)?.is_ready() {
                    return Poll::Pending;
                }

                // Buffer the settings frame
                dst.buffer(settings.clone().into())?;
                tracing::trace!("local settings sent; waiting for ack: {:?}", settings);

                self.local = Local::WaitingAck(settings.clone());
            }
            Local::WaitingAck(..) | Local::Synced => {}
        }

        Poll::Ready(Ok(()))
    }
}
