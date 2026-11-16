mod connection;
mod error;
mod go_away;
mod peer;
mod peer_settings;
mod ping_pong;
mod settings;
mod streams;

pub(crate) use self::connection::{Config, Connection, DataFrameBudget};
pub use self::error::{Error, Initiator};
pub(crate) use self::peer::{Dyn as DynPeer, Peer};
pub(crate) use self::peer_settings::PeerSettingsState;
pub(crate) use self::ping_pong::UserPings;
pub(crate) use self::settings::with_local_caps;
pub(crate) use self::streams::{DynStreams, OpaqueStreamRef, StreamRef, Streams};
pub(crate) use self::streams::{LocalStreams, Open, PollReset, Prioritized};

use crate::h2::codec::Codec;

use self::go_away::GoAway;
use self::ping_pong::PingPong;
use self::settings::Settings;

use rama_http_types::proto::h2::frame::{self, Frame};

use rama_core::bytes::Buf;

use tokio::io::AsyncWrite;

pub type PingPayload = [u8; 8];

pub type WindowSize = u32;

// Constants
pub const MAX_WINDOW_SIZE: WindowSize = (1 << 31) - 1; // i32::MAX as u32
pub const DEFAULT_REMOTE_RESET_STREAM_MAX: usize = 20;
pub const DEFAULT_LOCAL_RESET_COUNT_MAX: usize = 1024;
// Approximately the memory occupied by one buffered DATA event. Payloads
// smaller than this consume more internal bookkeeping than useful data.
pub const DEFAULT_DATA_FRAME_OVERHEAD_THRESHOLD: usize = 256;
pub const DEFAULT_DATA_FRAME_BUDGET: usize = DEFAULT_DATA_FRAME_OVERHEAD_THRESHOLD * 100;
// Empty DATA frames without END_STREAM a peer may send over a connection's whole
// life: they carry nothing, so more is taken as abuse (ENHANCE_YOUR_CALM).
pub const MAX_RECV_EMPTY_DATA_FRAMES: usize = 100;
// RFC 9113 suggests allowing at minimum 100 streams, it seems reasonable to
// by default allow a portion of that to be remembered as reset for some time.
pub const DEFAULT_RESET_STREAM_MAX: usize = 50;
// RFC 9113#5.4.2 suggests ~1 RTT. We don't track that closely, but use a
// reasonable guess of the average here.
pub const DEFAULT_RESET_STREAM_SECS: u64 = 1;
pub const DEFAULT_MAX_SEND_BUFFER_SIZE: u32 = 1024 * 400;
