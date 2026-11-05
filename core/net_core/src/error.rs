//! 网络核心的错误类型。
//!
//! [`NetError::kind`] 给出稳定的分类名，经 FFI 回传给宿主，由 Dart 侧映射成
//! 对应的 DioException 类型（超时、连接失败、取消等），不靠解析错误文本。

use thiserror::Error;

#[derive(Error, Debug)]
pub enum NetError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("DNS error: {0}")]
    Dns(String),

    #[error("Invalid URL: {0}")]
    InvalidUrl(String),

    #[error("Connection timeout")]
    Timeout,

    /// 等响应（头或下一个数据块）超时；与建连超时分开，宿主映射成不同的异常类型
    #[error("Receive timeout")]
    ReceiveTimeout,

    #[error("Send timeout")]
    SendTimeout,

    #[error("Cancelled")]
    Cancelled,

    #[error("Proxy error: {0}")]
    Proxy(String),

    #[error("Parse error: {0}")]
    Parse(String),

    #[error("Certificate error: {0}")]
    Certificate(String),
}

impl NetError {
    /// 稳定的错误分类名，供宿主映射异常类型（新增分类时 Dart 侧按未知处理）。
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Io(_) => "io",
            Self::Dns(_) => "dns",
            Self::InvalidUrl(_) => "invalid_url",
            Self::Timeout => "timeout",
            Self::ReceiveTimeout => "receive_timeout",
            Self::SendTimeout => "send_timeout",
            Self::Cancelled => "cancelled",
            Self::Proxy(_) => "proxy",
            Self::Parse(_) => "parse",
            Self::Certificate(_) => "certificate",
        }
    }
}

impl NetError {
    /// 复制一份同分类的错误（`io::Error` 不可克隆，按种类与文本重建）。
    pub fn replicate(&self) -> Self {
        match self {
            Self::Io(e) => Self::Io(std::io::Error::new(e.kind(), e.to_string())),
            Self::Dns(m) => Self::Dns(m.clone()),
            Self::InvalidUrl(m) => Self::InvalidUrl(m.clone()),
            Self::Timeout => Self::Timeout,
            Self::ReceiveTimeout => Self::ReceiveTimeout,
            Self::SendTimeout => Self::SendTimeout,
            Self::Cancelled => Self::Cancelled,
            Self::Proxy(m) => Self::Proxy(m.clone()),
            Self::Parse(m) => Self::Parse(m.clone()),
            Self::Certificate(m) => Self::Certificate(m.clone()),
        }
    }

    /// 给错误文本加上下文，分类不变。
    pub fn with_context(self, context: &str) -> Self {
        match self {
            Self::Io(e) => Self::Io(std::io::Error::new(e.kind(), format!("{context}: {e}"))),
            Self::Dns(m) => Self::Dns(format!("{context}: {m}")),
            Self::InvalidUrl(m) => Self::InvalidUrl(format!("{context}: {m}")),
            Self::Proxy(m) => Self::Proxy(format!("{context}: {m}")),
            Self::Parse(m) => Self::Parse(format!("{context}: {m}")),
            Self::Certificate(m) => Self::Certificate(format!("{context}: {m}")),
            other
            @ (Self::Timeout | Self::ReceiveTimeout | Self::SendTimeout | Self::Cancelled) => other,
        }
    }
}

pub type Result<T> = std::result::Result<T, NetError>;
