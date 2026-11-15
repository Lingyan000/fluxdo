//! Per-connection QPACK stream allocation and first-write preferences.

use rama_core::extensions::Extension;

/// When a QPACK stream's type prefix is sent.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Startup {
    /// Advertise the stream as soon as the HTTP/3 driver starts.
    #[default]
    Immediate,
    /// Wait until instructions are available before advertising the stream.
    OnDemand,
}

/// QPACK stream allocation after the control stream reserves the first ID.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Order {
    #[default]
    EncoderFirst,
    DecoderFirst,
}

/// Independent allocation and first-write choices; defaults retain eager startup.
///
/// This controls stream IDs and whether idle QPACK prefixes are emitted. It does
/// not prescribe instruction contents. Independent scheduling is the default.
/// As a connection extension it overrides a client connector's fixed startup
/// preferences; absent extensions retain the connector's configuration.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Extension)]
pub struct Preferences {
    /// Which QPACK stream reserves the lower ID after the control stream.
    pub order: Order,
    /// Send the encoder type immediately or with its first instructions.
    pub encoder: Startup,
    /// Send the decoder type immediately or with its first feedback.
    pub decoder: Startup,
    /// Queue initial CONTROL bytes, then Immediate QPACK type prefixes in allocated
    /// ID order before starting their independent tasks. OnDemand stays deferred.
    ///
    /// This orders local send-buffer writes, not peer delivery, acknowledgements,
    /// complete frames across packet boundaries, or receiver callback scheduling.
    /// HEADERS admission waits for these local writes. This does not wait for
    /// future OnDemand instructions or require peer SETTINGS for literal fields.
    pub ordered_startup: bool,
}
