//! HTTP connection utilities.

mod http_service;
pub use http_service::{
    EstablishedHttpService, HttpOrigin, HttpServiceCandidate, HttpServiceCandidates,
    HttpServiceSelection, HttpServiceSource, SelectedHttpService,
};

use std::{sync::Arc, time::Duration};

use rama_utils::octets::{kib_u32, mib_u32};

use crate::proto::h2::{
    PseudoHeaderOrder,
    frame::{
        self, DEFAULT_MAX_FRAME_SIZE, DEFAULT_SETTINGS_HEADER_TABLE_SIZE, EarlyFrame,
        EarlyFrameCapture, MAX_MAX_FRAME_SIZE, Settings,
    },
};
use rama_core::extensions::Extension;

#[derive(Debug, Clone, Default, Extension)]
#[extension(tags(http))]
/// Optional parameters that can be set in the [`Extensions`] of a (h1) request
/// to customise the connection of the h1 connection.
///
/// Can be used by Http connector services, especially in the context of proxies,
/// where there might not be one static config that is to be applied to all client connections.
///
/// [`Extensions`]: rama_core::extensions::Extensions
pub struct Http1ClientContextParams {
    /// Set whether HTTP/1 connections will write header names as title case at
    /// the socket level.
    ///
    /// Default is `false`.
    pub title_header_case: bool,
}

#[derive(Debug, Clone, Default, Extension)]
#[extension(tags(http))]
/// Optional parameters that can be set in the [`Extensions`] of a (h2) request
/// to customise the connection of the h2 connection.
///
/// Can be used by Http connector services, especially in the context of proxies,
/// where there might not be one static config that is to be applied to all client connections.
///
/// [`Extensions`]: rama_core::extensions::Extensions
pub struct H2ClientContextParams {
    /// Replace the complete initial SETTINGS frame, including order and omissions.
    /// Semantic codec/stream limits use this same frame; a stream or header-list cap it
    /// omits keeps the local value, enforced unadvertised. Other connection options
    /// remain independent; this takes precedence over replayed initial SETTINGS.
    pub initial_settings: Option<Arc<Settings>>,

    /// Pseudo order of the headers stream
    pub headers_pseudo_order: Option<PseudoHeaderOrder>,

    /// Early frames to be applied first
    pub early_frames: Option<EarlyFrameCapture>,

    /// Exact ordered early frames prepared for replay on this connection.
    /// These take precedence over [`Self::early_frames`].
    pub replay_early_frames: Option<Arc<[EarlyFrame]>>,

    /// The `SETTINGS_INITIAL_WINDOW_SIZE` option for HTTP2
    /// stream-level flow control.
    pub init_stream_window_size: Option<u32>,

    /// The max connection-level flow control for HTTP2.
    pub init_connection_window_size: Option<u32>,

    /// An interval for HTTP2 Ping frames should be sent to keep a
    /// connection alive.
    pub keep_alive_interval: Option<Duration>,

    /// A timeout for receiving an acknowledgement of the keep-alive ping.
    pub keep_alive_timeout: Option<Duration>,

    /// Whether HTTP2 keep-alive should apply while the connection is idle.
    pub keep_alive_while_idle: Option<bool>,

    /// The max size of received header frames.
    pub max_header_list_size: Option<u32>,

    /// The `SETTINGS_MAX_FRAME_SIZE` option for HTTP2.
    pub max_frame_size: Option<u32>,

    /// The `SETTINGS_HEADER_TABLE_SIZE` option for HTTP2, the header
    /// compression table size the remote peer may use to encode header
    /// blocks sent to us.
    pub header_table_size: Option<u32>,

    /// The `SETTINGS_MAX_CONCURRENT_STREAMS` option for HTTP2,
    /// limiting the number of concurrent streams the remote peer
    /// may initiate.
    pub max_concurrent_streams: Option<u32>,

    /// Whether to use an adaptive flow control.
    pub adaptive_window: Option<bool>,

    /// The initial maximum of locally initiated (send) streams.
    ///
    /// This value is overwritten by the value included in the initial
    /// `SETTINGS` frame received from the peer.
    pub initial_max_send_streams: Option<usize>,

    /// Reset every PUSH_PROMISE with REFUSED_STREAM, whatever ENABLE_PUSH advertises.
    pub refuse_push_promises: Option<bool>,

    /// The maximum write buffer size for each HTTP2 stream.
    pub max_send_buf_size: Option<u32>,

    /// The maximum number of HTTP2 concurrent locally reset streams.
    pub max_concurrent_reset_streams: Option<usize>,

    /// The maximum number of pending reset streams allowed before a
    /// `GOAWAY` will be sent.
    pub max_pending_accept_reset_streams: Option<usize>,

    /// The maximum number of local resets due to protocol errors made
    /// by the remote peer.
    pub max_local_error_reset_streams: Option<usize>,

    /// The duration to remember locally reset streams.
    pub reset_stream_duration: Option<Duration>,
}

pub use rama_net::http::{FallbackHttpVersion, TargetHttpVersion};

#[derive(Debug, Clone, Default, Extension)]
#[extension(tags(http))]
/// Per-conn override for the h2 server's initial SETTINGS frame, set on
/// the IO's [`Extensions`]. Any field left `None` retains the builder
/// default. `Some(value)` overrides one-to-one; this type can't express
/// "explicitly unset" — set the builder directly if you need that.
///
/// Used by arbitrary connection layers, including MITM relays. A complete
/// `initial_settings` frame takes precedence over scalar SETTINGS overrides;
/// connection-window and adaptive-flow options remain independent.
///
/// [`Extensions`]: rama_core::extensions::Extensions
pub struct H2ServerContextParams {
    /// Replace the complete initial SETTINGS frame, including order and omissions.
    /// Semantic codec/stream limits use this same frame; a stream or header-list cap it
    /// omits keeps the builder's value, enforced unadvertised. Absent keeps builder
    /// defaults. A server frame must not contain SETTINGS_ENABLE_PUSH.
    pub initial_settings: Option<Arc<Settings>>,

    /// Whether to advertise the [extended CONNECT protocol][1] in the
    /// initial SETTINGS frame.
    ///
    /// [1]: https://datatracker.ietf.org/doc/html/rfc8441#section-4
    pub enable_connect_protocol: Option<bool>,

    /// `SETTINGS_MAX_CONCURRENT_STREAMS`.
    pub max_concurrent_streams: Option<u32>,

    /// `SETTINGS_HEADER_TABLE_SIZE`.
    pub header_table_size: Option<u32>,

    /// `SETTINGS_MAX_FRAME_SIZE`.
    pub max_frame_size: Option<u32>,

    /// `SETTINGS_MAX_HEADER_LIST_SIZE`.
    pub max_header_list_size: Option<u32>,

    /// `SETTINGS_INITIAL_WINDOW_SIZE` (stream-level flow control).
    pub initial_stream_window_size: Option<u32>,

    /// Connection-level flow-control window.
    pub initial_connection_window_size: Option<u32>,

    /// Whether to use adaptive flow control. If `Some(true)`, the
    /// stream/connection window-size overrides above are reset to the
    /// spec default before adaptive control takes over.
    pub adaptive_window: Option<bool>,
}

/// Resource ceilings for an explicit initial SETTINGS frame or native relay mirror.
/// Install on a connection IO to narrow or expand its supported byte budgets.
/// Literal wire observation itself retains at most 256 setting occurrences.
/// An explicit frame exceeding a ceiling is an error; a relay mirror lowers to it.
/// Ceilings below a protocol minimum count as that minimum.
#[derive(Debug, Clone, Copy, Extension)]
#[extension(tags(http))]
#[non_exhaustive]
pub struct H2SettingsLimits {
    /// Maximum retained ordered setting occurrences, including duplicates/unknowns.
    pub entries: usize,
    /// Maximum advertised HPACK decoder table size in bytes.
    pub header_table_size: u32,
    /// Maximum advertised frame payload size in bytes.
    pub frame_size: u32,
    /// Maximum explicitly advertised decoded header-list size in bytes.
    /// Also the MITM relay's receive budget when no header-list cap is mirrored.
    pub header_list_size: u32,
    /// Maximum explicitly advertised concurrent streams the peer may open.
    pub max_concurrent_streams: u32,
}

impl Default for H2SettingsLimits {
    fn default() -> Self {
        Self {
            // Matches the native bounded SETTINGS observation capacity.
            entries: 256,
            header_table_size: kib_u32(64),
            frame_size: mib_u32(1),
            // Admit what browsers and common origins advertise. The MITM relay also
            // uses this header budget for omissions; native stream caps remain unchanged.
            header_list_size: kib_u32(256),
            max_concurrent_streams: 1000,
        }
    }
}

impl H2SettingsLimits {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Advertised HPACK table ceiling; never below the protocol default an omission implies.
    #[must_use]
    pub fn header_table_ceiling(&self) -> u32 {
        self.header_table_size
            .max(DEFAULT_SETTINGS_HEADER_TABLE_SIZE as u32)
    }

    /// Advertised frame size ceiling, within the protocol's valid range.
    #[must_use]
    pub fn frame_size_ceiling(&self) -> u32 {
        self.frame_size
            .clamp(DEFAULT_MAX_FRAME_SIZE, MAX_MAX_FRAME_SIZE)
    }

    /// Check a validated literal frame before advertising its receive budgets.
    /// Omitted fields keep their protocol meanings, not builder advertisements.
    pub fn validate(&self, settings: &Settings) -> Result<(), frame::Error> {
        let count = settings
            .observation
            .as_ref()
            .map_or(0, |wire| wire.entries.len());
        let cfg = &settings.config;
        if count > self.entries
            || cfg
                .header_table_size
                .unwrap_or(DEFAULT_SETTINGS_HEADER_TABLE_SIZE as u32)
                > self.header_table_ceiling()
            || cfg.max_frame_size.unwrap_or(DEFAULT_MAX_FRAME_SIZE) > self.frame_size_ceiling()
            || cfg
                .max_header_list_size
                .is_some_and(|value| value > self.header_list_size)
            || cfg
                .max_concurrent_streams
                .is_some_and(|value| value > self.max_concurrent_streams)
        {
            return Err(frame::Error::InvalidSettingValue);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Extension)]
#[extension(tags(http))]
/// The peer's initial (first non-ACK) h2 [`Settings`] frame, set as an
/// extension on every h2 client response. Captured once per connection;
/// subsequent SETTINGS updates are not reflected. Stored once in
/// `Arc<PeerH2Settings>` and shared per-response via
/// [`rama_core::extensions::Extensions::insert_arc`].
pub struct PeerH2Settings(pub Settings);
