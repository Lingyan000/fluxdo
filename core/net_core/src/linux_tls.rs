//! Linux WPE 的原生 TLS 后端。系统库缺失或能力不匹配时不参与选择；ECH 保留原有路径。
//! C 回调只访问有界内存缓冲，所有 socket IO 仍由 Tokio 与既有出口负责。
use crate::{BoxStream, NetError};
use bytes::{Buf, BytesMut};
use libloading::Library;
use parking_lot::Mutex;
use rama::tls::client::{ClientHello, parse_client_hello_handshake};
use std::{
    collections::VecDeque,
    ffi::{CStr, CString, c_char, c_int, c_uint, c_void},
    future::poll_fn,
    io,
    pin::Pin,
    ptr,
    sync::{Arc, OnceLock},
    task::{Context, Poll, ready},
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

const AGAIN: c_int = -28;
const INTERRUPTED: c_int = -52;
const CERTIFICATE_ERROR: c_int = -348;
const MAX_BUFFER: usize = 256 * 1024;
const MAX_TICKET: usize = 16 * 1024;
type Handle = *mut c_void;
#[repr(C)]
struct Datum {
    data: *mut u8,
    size: c_uint,
}
type Pull = unsafe extern "C" fn(Handle, *mut c_void, usize) -> isize;
type Push = unsafe extern "C" fn(Handle, *const c_void, usize) -> isize;
type Errno = unsafe extern "C" fn(Handle) -> c_int;
type PullTimeout = unsafe extern "C" fn(Handle, c_uint) -> c_int;

// 签名来自 GnuTLS 的稳定 C ABI；库句柄与所有函数指针共同保存在进程级 OnceLock。
macro_rules! api {
    ($($field:ident : $ty:ty),* $(,)?) => {
        struct Api { _library: Library, $($field: $ty,)* }
        impl Api {
            unsafe fn load() -> Result<Self, libloading::Error> {
                // SAFETY: 只加载 Linux 系统 GnuTLS SONAME，所有符号按官方 C ABI 声明。
                let library = unsafe { Library::new("libgnutls.so.30")? };
                $(let $field = unsafe { *library.get::<$ty>(concat!("gnutls_", stringify!($field), "\0").as_bytes())? };)*
                Ok(Self { _library: library, $($field,)* })
            }
        }
    }
}
api! {
    global_init: unsafe extern "C" fn() -> c_int,
    check_version: unsafe extern "C" fn(*const c_char) -> *const c_char,
    init: unsafe extern "C" fn(*mut Handle, c_uint) -> c_int,
    deinit: unsafe extern "C" fn(Handle),
    certificate_allocate_credentials: unsafe extern "C" fn(*mut Handle) -> c_int,
    certificate_free_credentials: unsafe extern "C" fn(Handle),
    certificate_set_x509_system_trust: unsafe extern "C" fn(Handle) -> c_int,
    certificate_set_x509_trust_file: unsafe extern "C" fn(Handle, *const c_char, c_int) -> c_int,
    credentials_set: unsafe extern "C" fn(Handle, c_uint, Handle) -> c_int,
    priority_set_direct: unsafe extern "C" fn(Handle, *const c_char, *mut *const c_char) -> c_int,
    server_name_set: unsafe extern "C" fn(Handle, c_uint, *const c_void, usize) -> c_int,
    alpn_set_protocols: unsafe extern "C" fn(Handle, *const Datum, c_uint, c_uint) -> c_int,
    alpn_get_selected_protocol: unsafe extern "C" fn(Handle, *mut Datum) -> c_int,
    session_set_verify_cert: unsafe extern "C" fn(Handle, *const c_char, c_uint),
    session_is_resumed: unsafe extern "C" fn(Handle) -> c_int,
    session_set_data: unsafe extern "C" fn(Handle, *const c_void, usize) -> c_int,
    session_get_data: unsafe extern "C" fn(Handle, *mut c_void, *mut usize) -> c_int,
    db_check_entry_expire_time: unsafe extern "C" fn(*mut Datum) -> std::ffi::c_long,
    transport_set_ptr: unsafe extern "C" fn(Handle, Handle),
    transport_set_pull_function: unsafe extern "C" fn(Handle, Pull),
    transport_set_push_function: unsafe extern "C" fn(Handle, Push),
    transport_set_errno_function: unsafe extern "C" fn(Handle, Errno),
    transport_set_pull_timeout_function: unsafe extern "C" fn(Handle, PullTimeout),
    handshake: unsafe extern "C" fn(Handle) -> c_int,
    record_recv: unsafe extern "C" fn(Handle, *mut c_void, usize) -> isize,
    record_send: unsafe extern "C" fn(Handle, *const c_void, usize) -> isize,
    bye: unsafe extern "C" fn(Handle, c_int) -> c_int,
    strerror: unsafe extern "C" fn(c_int) -> *const c_char,
}
fn api() -> Option<&'static Api> {
    static API: OnceLock<Option<Api>> = OnceLock::new();
    API.get_or_init(|| {
        // SAFETY: OnceLock 串行初始化；此后不卸载库或执行 global_deinit。
        let value = unsafe { Api::load().ok()? };
        unsafe {
            if (value.check_version)(c"3.6.5".as_ptr()).is_null() || (value.global_init)() < 0 {
                return None;
            }
        }
        Some(value)
    })
    .as_ref()
}
fn priority() -> CString {
    // 与 glib-networking 的运行时覆盖保持一致，不改用户环境。
    CString::new(std::env::var("G_TLS_GNUTLS_PRIORITY").unwrap_or_else(|_| "NORMAL:%COMPAT".into()))
        .unwrap_or_else(|_| c"NORMAL:%COMPAT".to_owned())
}
fn error(api: &Api, code: c_int) -> NetError {
    // SAFETY: strerror 返回静态的 NUL 终止诊断字符串，不含握手密钥。
    let message = unsafe { CStr::from_ptr((api.strerror)(code)) }
        .to_string_lossy()
        .into_owned();
    if code == CERTIFICATE_ERROR {
        NetError::Certificate(message)
    } else {
        NetError::Proxy(format!("GnuTLS: {message}"))
    }
}
fn check(api: &Api, code: c_int) -> Result<(), NetError> {
    if code < 0 {
        Err(error(api, code))
    } else {
        Ok(())
    }
}

#[derive(Default)]
struct Buffers {
    input: BytesMut,
    output: BytesMut,
    eof: bool,
    errno: c_int,
}
unsafe extern "C" fn pull(pointer: Handle, data: *mut c_void, len: usize) -> isize {
    // SAFETY: 该指针是 Session 持有的固定 Box，回调只在同一可变借用内同步执行。
    let buffers = unsafe { &mut *pointer.cast::<Buffers>() };
    let count = len.min(buffers.input.len());
    if count == 0 {
        if buffers.eof {
            return 0;
        }
        buffers.errno = 11;
        return -1;
    }
    unsafe {
        ptr::copy_nonoverlapping(buffers.input.as_ptr(), data.cast(), count);
    }
    buffers.input.advance(count);
    count as isize
}
unsafe extern "C" fn push(pointer: Handle, data: *const c_void, len: usize) -> isize {
    if len == 0 {
        return 0;
    }
    let buffers = unsafe { &mut *pointer.cast::<Buffers>() };
    if len > MAX_BUFFER.saturating_sub(buffers.output.len()) {
        buffers.errno = 90;
        return -1;
    }
    // SAFETY: GnuTLS 提供有效 len 字节，复制后不保留外部指针。
    buffers
        .output
        .extend_from_slice(unsafe { std::slice::from_raw_parts(data.cast(), len) });
    len as isize
}
unsafe extern "C" fn last_errno(pointer: Handle) -> c_int {
    unsafe { (*pointer.cast::<Buffers>()).errno }
}
unsafe extern "C" fn pull_timeout(pointer: Handle, _timeout: c_uint) -> c_int {
    let buffers = unsafe { &*pointer.cast::<Buffers>() };
    c_int::from(!buffers.input.is_empty() || buffers.eof)
}

struct Session {
    api: &'static Api,
    handle: Handle,
    credentials: Handle,
    buffers: Box<Buffers>,
    _hostname: CString,
    authenticated: bool,
}
// SAFETY: session/credentials 独占拥有；回调只访问同一个 Box，不跨线程并发调用 C 会话。
unsafe impl Send for Session {}
impl Drop for Session {
    fn drop(&mut self) {
        unsafe {
            (self.api.deinit)(self.handle);
            (self.api.certificate_free_credentials)(self.credentials);
        }
    }
}
impl Session {
    fn new(
        host: &str,
        trust: bool,
        extra_ca: Option<&str>,
        reference: Option<&ClientHello>,
    ) -> Result<Self, NetError> {
        let api = api().ok_or_else(|| NetError::Proxy("GnuTLS unavailable".into()))?;
        let hostname =
            CString::new(host).map_err(|_| NetError::InvalidUrl("NUL in server name".into()))?;
        let mut handle = ptr::null_mut();
        let mut credentials = ptr::null_mut();
        // SAFETY: 所有返回值都检查，任一失败时释放此前成功分配的对象。
        unsafe {
            check(api, (api.init)(&mut handle, 2 | 8))?;
            if let Err(e) = check(
                api,
                (api.certificate_allocate_credentials)(&mut credentials),
            ) {
                (api.deinit)(handle);
                return Err(e);
            }
        }
        let mut session = Self {
            api,
            handle,
            credentials,
            buffers: Box::default(),
            _hostname: hostname,
            authenticated: false,
        };
        unsafe {
            check(api, (api.credentials_set)(handle, 1, credentials))?;
            check(
                api,
                (api.priority_set_direct)(handle, priority().as_ptr(), ptr::null_mut()),
            )?;
            // IP 目标仍做 SAN 校验，但不能把 IP 地址作为 DNS SNI 发送。
            if host.parse::<std::net::IpAddr>().is_err() {
                check(
                    api,
                    (api.server_name_set)(handle, 1, session._hostname.as_ptr().cast(), host.len()),
                )?;
            }
            let defaults = [
                rama::net::tls::ApplicationProtocol::HTTP_2,
                rama::net::tls::ApplicationProtocol::HTTP_11,
            ];
            let alpn = reference
                .map(|h| h.ext_alpn().unwrap_or_default())
                .unwrap_or(&defaults);
            let protocols: Vec<_> = alpn
                .iter()
                .map(|p| Datum {
                    data: p.as_bytes().as_ptr().cast_mut(),
                    size: p.as_bytes().len() as c_uint,
                })
                .collect();
            if !protocols.is_empty() {
                check(
                    api,
                    (api.alpn_set_protocols)(
                        handle,
                        protocols.as_ptr(),
                        protocols.len() as c_uint,
                        0,
                    ),
                )?;
            }
            if trust {
                let roots = (api.certificate_set_x509_system_trust)(credentials);
                check(api, roots)?;
                if let Some(path) = extra_ca {
                    let path = CString::new(path)
                        .map_err(|_| NetError::Certificate("invalid CA path".into()))?;
                    check(
                        api,
                        (api.certificate_set_x509_trust_file)(credentials, path.as_ptr(), 1),
                    )?;
                }
            }
            // 即使 HelloSink 没有信任根也始终安装主机名与证书校验；生产不提供跳过校验开关。
            (api.session_set_verify_cert)(handle, session._hostname.as_ptr(), 0);
            (api.transport_set_ptr)(handle, (&mut *session.buffers as *mut Buffers).cast());
            (api.transport_set_pull_function)(handle, pull);
            (api.transport_set_push_function)(handle, push);
            (api.transport_set_errno_function)(handle, last_errno);
            (api.transport_set_pull_timeout_function)(handle, pull_timeout);
        }
        Ok(session)
    }
    fn alpn(&self) -> Option<Vec<u8>> {
        let mut datum = Datum {
            data: ptr::null_mut(),
            size: 0,
        };
        unsafe {
            ((self.api.alpn_get_selected_protocol)(self.handle, &mut datum) == 0
                && !datum.data.is_null()
                && datum.size > 0)
                .then(|| std::slice::from_raw_parts(datum.data, datum.size as usize).to_vec())
        }
    }
    fn ticket(&self) -> Option<(Vec<u8>, u64)> {
        if !self.authenticated {
            return None;
        }
        let mut len = 0;
        unsafe {
            (self.api.session_get_data)(self.handle, ptr::null_mut(), &mut len);
        }
        if len == 0 || len > MAX_TICKET {
            return None;
        }
        let mut data = vec![0; len];
        unsafe {
            if (self.api.session_get_data)(self.handle, data.as_mut_ptr().cast(), &mut len) < 0 {
                return None;
            }
            data.truncate(len);
            let mut datum = Datum {
                data: data.as_mut_ptr(),
                size: len as c_uint,
            };
            let expires = (self.api.db_check_entry_expire_time)(&mut datum);
            (expires > 0).then_some((data, expires as u64))
        }
    }
}

/// 只生成公开 ClientHello，不连接服务器，也不初始化进程的系统信任状态。
pub fn emit_client_hello() -> Result<ClientHello, NetError> {
    emit_for(None)
}

pub fn emit_for(reference: Option<&ClientHello>) -> Result<ClientHello, NetError> {
    let session = Session::new("localhost", false, None, reference)?;
    let code = unsafe { (session.api.handshake)(session.handle) };
    if code != AGAIN {
        return Err(error(session.api, code));
    }
    parse_client_hello_handshake(&session.buffers.output)
        .map_err(|e| NetError::Parse(e.to_string()))
}
/// 实际原生能力必须匹配；不靠 UA/品牌/平台版本的硬编码表选择 TLS 后端。
pub fn matches(reference: &ClientHello, permutes: bool) -> bool {
    static PROFILES: OnceLock<Mutex<Vec<(Vec<u8>, ClientHello, bool)>>> = OnceLock::new();
    let key =
        serde_json::to_vec(&(priority().as_bytes(), reference.ext_alpn())).unwrap_or_default();
    let mut cache = PROFILES.get_or_init(Default::default).lock();
    let (actual, actual_permutes) =
        if let Some((_, hello, order)) = cache.iter().find(|(p, _, _)| p == &key) {
            (hello.clone(), *order)
        } else {
            let Ok(hello) = emit_for(Some(reference)) else {
                return false;
            };
            let Ok(second) = emit_for(Some(reference)) else {
                return false;
            };
            if crate::mirror::profile_hash(&hello) != crate::mirror::profile_hash(&second) {
                return false;
            }
            let order =
                crate::mirror::extension_order(&hello) != crate::mirror::extension_order(&second);
            if cache.len() >= 4 {
                cache.remove(0);
            }
            cache.push((key, hello.clone(), order));
            (hello, order)
        };
    actual_permutes == permutes
        && crate::mirror::profile_hash(reference) == crate::mirror::profile_hash(&actual)
        && (permutes
            || crate::mirror::extension_order(reference) == crate::mirror::extension_order(&actual))
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
#[derive(Default)]
pub(crate) struct Sessions {
    memory: Mutex<VecDeque<(String, Vec<u8>, u64)>>,
    persistent: Option<(Arc<crate::session_cache::TicketStore>, String)>,
}
impl Sessions {
    pub(crate) fn persistent(
        store: Arc<crate::session_cache::TicketStore>,
        namespace: String,
    ) -> Self {
        Self {
            persistent: Some((store, namespace)),
            ..Self::default()
        }
    }
    fn key(&self, host: &str, port: u16, hello: &ClientHello) -> String {
        let version = api()
            .map(|api| {
                unsafe { CStr::from_ptr((api.check_version)(ptr::null())) }.to_string_lossy()
            })
            .unwrap_or_default();
        let namespace = self
            .persistent
            .as_ref()
            .map(|(_, s)| s.as_str())
            .unwrap_or_default();
        crate::session_cache::scope(
            &format!("GnuTLS:{version}:{namespace}:{:?}", priority()),
            host,
            port,
            Some(hello),
            None,
        )
    }
    fn take(&self, key: &str) -> Option<Vec<u8>> {
        if let Some((store, _)) = &self.persistent {
            return store.take_bytes(key);
        }
        let mut entries = self.memory.lock();
        entries.retain(|(_, _, expires)| *expires > now());
        let index = entries.iter().position(|(scope, _, _)| scope == key)?;
        entries.remove(index).map(|(_, bytes, _)| bytes)
    }
    fn put(&self, key: &str, data: Vec<u8>, expires: u64) {
        let expires = expires.min(now() + 86400);
        if expires <= now() || data.len() > MAX_TICKET {
            return;
        }
        if let Some((store, _)) = &self.persistent {
            store.put_bytes(key, data, expires);
            return;
        }
        let mut entries = self.memory.lock();
        entries.retain(|(scope, _, until)| scope != key && *until > now());
        entries.push_back((key.into(), data, expires));
        while entries.len() > 128
            || entries.iter().map(|(_, b, _)| b.len()).sum::<usize>() > 96 * 1024
        {
            entries.pop_front();
        }
    }
}

pub struct NativeTlsStream {
    io: BoxStream,
    session: Session,
    tickets: Option<(Arc<Sessions>, String)>,
    last_ticket: Vec<u8>,
    shutdown: bool,
    handshake_complete: bool,
}
impl NativeTlsStream {
    pub(crate) async fn connect(
        io: BoxStream,
        host: &str,
        port: u16,
        hello: &ClientHello,
        sessions: Arc<Sessions>,
    ) -> Result<Self, NetError> {
        let ca = std::env::var("SSL_CERT_FILE").ok();
        Self::connect_with_ca(io, host, port, hello, sessions, ca.as_deref()).await
    }
    async fn connect_with_ca(
        io: BoxStream,
        host: &str,
        port: u16,
        hello: &ClientHello,
        sessions: Arc<Sessions>,
        ca: Option<&str>,
    ) -> Result<Self, NetError> {
        let mut session = Session::new(host, true, ca, Some(hello))?;
        let key = sessions.key(host, port, hello);
        if let Some(data) = sessions.take(&key) {
            // 缓存加载失败只丢弃票据；证书校验和完整握手仍然保留。
            if unsafe {
                (session.api.session_set_data)(session.handle, data.as_ptr().cast(), data.len())
            } < 0
            {
                session = Session::new(host, true, ca, Some(hello))?;
            }
        }
        let mut stream = Self {
            io,
            session,
            tickets: Some((sessions, key)),
            last_ticket: Vec::new(),
            shutdown: false,
            handshake_complete: false,
        };
        poll_fn(|cx| stream.poll_handshake(cx)).await?;
        stream.session.authenticated = true;
        stream.save_ticket();
        Ok(stream)
    }
    pub fn alpn(&self) -> Option<Vec<u8>> {
        self.session.alpn()
    }
    pub fn resumed(&self) -> bool {
        unsafe { (self.session.api.session_is_resumed)(self.session.handle) != 0 }
    }
    fn save_ticket(&mut self) {
        if let Some((data, expires)) = self.session.ticket() {
            if data != self.last_ticket {
                if let Some((sessions, key)) = &self.tickets {
                    sessions.put(key, data.clone(), expires);
                }
                self.last_ticket = data;
            }
        }
    }
    fn flush_ciphertext(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        while !self.session.buffers.output.is_empty() {
            let n = ready!(Pin::new(&mut *self.io).poll_write(cx, &self.session.buffers.output))?;
            if n == 0 {
                return Poll::Ready(Err(io::ErrorKind::WriteZero.into()));
            }
            self.session.buffers.output.advance(n);
        }
        Pin::new(&mut *self.io).poll_flush(cx)
    }
    fn receive_ciphertext(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        if self.session.buffers.eof {
            return Poll::Ready(Err(io::ErrorKind::UnexpectedEof.into()));
        }
        let mut bytes = [0u8; 16 * 1024];
        let mut buffer = ReadBuf::new(&mut bytes);
        ready!(Pin::new(&mut *self.io).poll_read(cx, &mut buffer))?;
        if buffer.filled().is_empty() {
            self.session.buffers.eof = true;
        }
        if self.session.buffers.input.len() + buffer.filled().len() > MAX_BUFFER {
            return Poll::Ready(Err(io::Error::other("GnuTLS receive budget exceeded")));
        }
        self.session
            .buffers
            .input
            .extend_from_slice(buffer.filled());
        Poll::Ready(Ok(()))
    }
    fn poll_handshake(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), NetError>> {
        for _ in 0..32 {
            ready!(self.flush_ciphertext(cx)).map_err(NetError::Io)?;
            if self.handshake_complete {
                return Poll::Ready(Ok(()));
            }
            let code = unsafe { (self.session.api.handshake)(self.session.handle) };
            if code == 0 {
                self.handshake_complete = true;
                continue;
            }
            if code == INTERRUPTED {
                continue;
            }
            if code != AGAIN {
                return Poll::Ready(Err(error(self.session.api, code)));
            }
            ready!(self.flush_ciphertext(cx)).map_err(NetError::Io)?;
            if !self.session.buffers.input.is_empty() {
                continue;
            }
            ready!(self.receive_ciphertext(cx)).map_err(NetError::Io)?;
        }
        cx.waker().wake_by_ref();
        Poll::Pending
    }
}
impl AsyncRead for NativeTlsStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        output: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if output.remaining() == 0 {
            return Poll::Ready(Ok(()));
        }
        for _ in 0..32 {
            ready!(self.flush_ciphertext(cx))?;
            let target = output.initialize_unfilled();
            let code = unsafe {
                (self.session.api.record_recv)(
                    self.session.handle,
                    target.as_mut_ptr().cast(),
                    target.len(),
                )
            };
            if code >= 0 {
                output.advance(code as usize);
                self.save_ticket();
                return Poll::Ready(Ok(()));
            }
            if code == INTERRUPTED as isize {
                continue;
            }
            if code != AGAIN as isize {
                return Poll::Ready(Err(io::Error::other(error(
                    self.session.api,
                    code as c_int,
                ))));
            }
            ready!(self.flush_ciphertext(cx))?;
            // 处理 TLS 1.3 票据后也可能返回 AGAIN；先消费已经读入的后续记录，
            // 否则票据与应用数据合并到一个 TCP 包时会等待不会到来的新数据。
            if !self.session.buffers.input.is_empty() {
                continue;
            }
            ready!(self.receive_ciphertext(cx))?;
        }
        cx.waker().wake_by_ref();
        Poll::Pending
    }
}
impl AsyncWrite for NativeTlsStream {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        if self.shutdown {
            return Poll::Ready(Err(io::ErrorKind::BrokenPipe.into()));
        }
        ready!(self.flush_ciphertext(cx))?;
        if bytes.is_empty() {
            return Poll::Ready(Ok(0));
        }
        // 每次至多一个 TLS 记录；push 回调只写有界内存，返回 Ready 后密文归本对象持有。
        let count = bytes.len().min(16 * 1024);
        let code = unsafe {
            (self.session.api.record_send)(self.session.handle, bytes.as_ptr().cast(), count)
        };
        if code < 0 {
            return Poll::Ready(Err(io::Error::other(error(
                self.session.api,
                code as c_int,
            ))));
        }
        Poll::Ready(Ok(code as usize))
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.flush_ciphertext(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        ready!(self.flush_ciphertext(cx))?;
        if !self.shutdown {
            let code = unsafe { (self.session.api.bye)(self.session.handle, 1) };
            if code < 0 {
                return Poll::Ready(Err(io::Error::other(error(self.session.api, code))));
            }
            self.shutdown = true;
        }
        ready!(self.flush_ciphertext(cx))?;
        Pin::new(&mut *self.io).poll_shutdown(cx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rama::tls::boring::core::{
        pkey::PKey,
        ssl::{SslAcceptor, SslMethod},
        tokio::accept,
        x509::X509,
    };
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    struct Fixture {
        root: std::path::PathBuf,
        ca: String,
        acceptor: Arc<SslAcceptor>,
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
    fn fixture() -> Fixture {
        fixture_with_version(None)
    }
    fn fixture_with_version(version: Option<rama::tls::boring::core::ssl::SslVersion>) -> Fixture {
        fixture_for("native.test", version)
    }
    fn fixture_for(
        host: &'static str,
        version: Option<rama::tls::boring::core::ssl::SslVersion>,
    ) -> Fixture {
        let (chain, key) = rama_crypto::cert::generate_server_auth(
            rama_crypto::cert::GeneratedServerAuthConfig::generated_ca_for(
                rama::net::address::Domain::from_static(host),
            ),
        )
        .unwrap();
        let mut acceptor = SslAcceptor::mozilla_intermediate_v5(SslMethod::tls()).unwrap();
        acceptor.set_max_proto_version(version).unwrap();
        acceptor
            .set_certificate(&X509::from_der(chain[0].as_ref()).unwrap())
            .unwrap();
        acceptor
            .set_private_key(&PKey::private_key_from_der(key.secret_der()).unwrap())
            .unwrap();
        let root = std::env::temp_dir().join(format!(
            "fluxdo-native-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let ca = root.join("ca.pem");
        std::fs::write(
            &ca,
            X509::from_der(chain.last().unwrap().as_ref())
                .unwrap()
                .to_pem()
                .unwrap(),
        )
        .unwrap();
        Fixture {
            root,
            ca: ca.to_str().unwrap().into(),
            acceptor: Arc::new(acceptor.build()),
        }
    }
    async fn roundtrip(f: &Fixture, sessions: Arc<Sessions>) -> bool {
        // 小于单个 TLS 记录，强制握手和应用数据经历多次 Pending / 部分写入。
        let (client, server) = tokio::io::duplex(73);
        let acceptor = f.acceptor.clone();
        let job = tokio::spawn(async move {
            let mut tls = accept(&acceptor, server).await.unwrap();
            let mut input = vec![0; 70000];
            tls.read_exact(&mut input).await.unwrap();
            assert!(input.iter().all(|v| *v == 0xa5));
            tls.write_all(b"verified").await.unwrap();
            tls.flush().await.unwrap();
            let mut eof = [0];
            assert_eq!(tls.read(&mut eof).await.unwrap(), 0);
        });
        let template: crate::mirror::FingerprintTemplate = serde_json::from_str(include_str!(
            "../tests/fixtures/linux_wpe_webkit_probe.json"
        ))
        .unwrap();
        let hello = template.hello;
        let mut tls = NativeTlsStream::connect_with_ca(
            Box::new(client),
            "native.test",
            443,
            &hello,
            sessions,
            Some(&f.ca),
        )
        .await
        .unwrap();
        let resumed = tls.resumed();
        tls.write_all(&vec![0xa5; 70000]).await.unwrap();
        tls.flush().await.unwrap();
        let mut response = [0; 8];
        tls.read_exact(&mut response).await.unwrap();
        assert_eq!(&response, b"verified");
        tls.shutdown().await.unwrap();
        job.await.unwrap();
        resumed
    }

    #[tokio::test]
    async fn native_partial_io_and_encrypted_ticket_reload() {
        use base64::{Engine as _, engine::general_purpose::STANDARD};
        let f = fixture();
        let key = STANDARD.encode([23; 32]);
        let store =
            crate::session_cache::TicketStore::open(f.root.join("first.bin"), &key).unwrap();
        let sessions = Arc::new(Sessions::persistent(store.clone(), "native-test".into()));
        tokio::time::timeout(std::time::Duration::from_secs(15), async {
            assert!(!roundtrip(&f, sessions).await);
            store.flush().unwrap();
            let encrypted = std::fs::read(f.root.join("first.bin")).unwrap();
            assert!(!String::from_utf8_lossy(&encrypted).contains("native.test"));
            std::fs::write(f.root.join("restored.bin"), encrypted).unwrap();
            let restored =
                crate::session_cache::TicketStore::open(f.root.join("restored.bin"), &key).unwrap();
            assert!(
                roundtrip(
                    &f,
                    Arc::new(Sessions::persistent(restored, "native-test".into()))
                )
                .await
            );
        })
        .await
        .expect("native TLS stalled under backpressure");
    }

    #[tokio::test]
    async fn native_tls12_full_and_resumed_handshake() {
        let f = fixture_with_version(Some(rama::tls::boring::core::ssl::SslVersion::TLS1_2));
        let sessions = Arc::new(Sessions::default());
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            assert!(!roundtrip(&f, sessions.clone()).await);
            assert!(roundtrip(&f, sessions).await);
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn native_rejects_untrusted_certificate_and_wrong_hostname() {
        let f = fixture();
        for (host, ca) in [("native.test", None), ("wrong.test", Some(f.ca.as_str()))] {
            let (client, server) = tokio::io::duplex(4096);
            let acceptor = f.acceptor.clone();
            let job = tokio::spawn(async move {
                let _ = accept(&acceptor, server).await;
            });
            let sessions = Arc::new(Sessions::default());
            let result = tokio::time::timeout(
                std::time::Duration::from_secs(5),
                NativeTlsStream::connect_with_ca(
                    Box::new(client),
                    host,
                    443,
                    &emit_client_hello().unwrap(),
                    sessions.clone(),
                    ca,
                ),
            )
            .await
            .unwrap();
            assert!(matches!(result, Err(NetError::Certificate(_))));
            assert!(sessions.memory.lock().is_empty());
            job.abort();
        }
    }

    #[tokio::test]
    async fn native_timeout_and_truncated_peer_release_transport() {
        let f = fixture();
        let (client, mut server) = tokio::io::duplex(4096);
        let hello = emit_client_hello().unwrap();
        let result = tokio::time::timeout(
            std::time::Duration::from_millis(30),
            NativeTlsStream::connect_with_ca(
                Box::new(client),
                "native.test",
                443,
                &hello,
                Arc::new(Sessions::default()),
                Some(&f.ca),
            ),
        )
        .await;
        assert!(result.is_err());
        let mut received = Vec::new();
        tokio::time::timeout(
            std::time::Duration::from_secs(1),
            server.read_to_end(&mut received),
        )
        .await
        .unwrap()
        .unwrap();
        assert!(!received.is_empty());
        let (client, server) = tokio::io::duplex(4096);
        drop(server);
        assert!(
            NativeTlsStream::connect_with_ca(
                Box::new(client),
                "native.test",
                443,
                &hello,
                Arc::new(Sessions::default()),
                Some(&f.ca)
            )
            .await
            .is_err()
        );
    }

    #[test]
    fn native_ticket_scope_separates_backends_hosts_ports_and_policy() {
        let hello = emit_client_hello().unwrap();
        let sessions = Sessions::default();
        let a = sessions.key("native.test", 443, &hello);
        assert_ne!(a, sessions.key("native.test", 8443, &hello));
        assert_ne!(a, sessions.key("other.test", 443, &hello));
        assert_ne!(
            a,
            crate::session_cache::scope("", "native.test", 443, Some(&hello), None)
        );
        sessions.put(&a, vec![42], now() + 60);
        assert!(
            sessions
                .take(&sessions.key("other.test", 443, &hello))
                .is_none()
        );
        assert_eq!(sessions.take(&a), Some(vec![42]));
        assert!(sessions.take(&a).is_none());
    }

    #[test]
    fn native_capability_check_preserves_sampled_alpn_and_rejects_other_profiles() {
        let template: crate::mirror::FingerprintTemplate = serde_json::from_str(include_str!(
            "../tests/fixtures/linux_wpe_webkit_probe.json"
        ))
        .unwrap();
        let emitted = emit_for(Some(&template.hello)).unwrap();
        assert_eq!(emitted.ext_alpn(), template.hello.ext_alpn());
        // 系统库可以随发行版变化；只在完整能力匹配时允许采用该后端。
        if crate::mirror::profile_hash(&emitted) == crate::mirror::profile_hash(&template.hello) {
            assert!(matches(
                &template.hello,
                template.tls_permute_extensions.unwrap()
            ));
            let audit = crate::browser_tls::selected_capability_audit(&template.hello, true);
            assert_eq!(audit["backend"], "GnuTLS");
            assert_eq!(audit["ech_fallback"]["backend"], "BoringSSL");
        }
        let chrome: ClientHello = serde_json::from_str(include_str!(
            "../tests/fixtures/chrome156_linux_do_hello.json"
        ))
        .unwrap();
        assert!(!matches(&chrome, true));
    }

    #[tokio::test]
    async fn native_corrupt_ticket_uses_fresh_authenticated_handshake() {
        let f = fixture();
        let template: crate::mirror::FingerprintTemplate = serde_json::from_str(include_str!(
            "../tests/fixtures/linux_wpe_webkit_probe.json"
        ))
        .unwrap();
        let sessions = Arc::new(Sessions::default());
        let key = sessions.key("native.test", 443, &template.hello);
        sessions.put(&key, vec![0xff; 19], now() + 60);
        assert!(
            !tokio::time::timeout(std::time::Duration::from_secs(5), roundtrip(&f, sessions))
                .await
                .unwrap()
        );
    }
    #[tokio::test]
    async fn native_webview_tunnel_preserves_origin_certificate_and_does_not_resample() {
        tokio::time::timeout(std::time::Duration::from_secs(10), async {
            let f = fixture_for("localhost", None);
            let mut template: crate::mirror::FingerprintTemplate = serde_json::from_str(include_str!(
                "../tests/fixtures/linux_wpe_webkit_probe.json")).unwrap();
            // 此用例验证当前原生后端的透明转发，不要求 runner 的 GnuTLS
            // 与归档 WPE 环境完全相同；固定旧握手会错误走入另一条 MITM 路径。
            let first = emit_for(Some(&template.hello)).unwrap();
            let second = emit_for(Some(&template.hello)).unwrap();
            template.tls_permute_extensions = Some(
                crate::mirror::extension_order(&first) != crate::mirror::extension_order(&second));
            template.hello = first;
            assert!(matches(&template.hello, template.tls_permute_extensions.unwrap()));
            template.cache_revision = Some(crate::mirror::cache_revision());
            let cache = f.root.join("template.json");
            std::fs::write(&cache, serde_json::to_vec(&template).unwrap()).unwrap();
            let templates = Arc::new(crate::mirror::FingerprintTemplates::new(Some(cache)));
            assert_eq!(serde_json::from_str::<serde_json::Value>(&templates.status_json()).unwrap()["ready"], true);
            let (app_ca, app_key) = crate::cert::generate_ca_pem().unwrap();
            let mirror = Arc::new(crate::mirror::MirrorRelay::new(&app_ca, &app_key, templates.clone()).unwrap());
            let egress = Arc::new(crate::egress::EgressConnector::new(None, None, None,
                Some("127.0.0.1"), std::time::Duration::from_secs(3)));
            let listener = Arc::new(tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap());
            let port = listener.local_addr().unwrap().port();
            let sessions = Arc::new(Sessions::default());
            for (index, trust_origin) in [true, true, false].into_iter().enumerate() {
                let listener = listener.clone();
                let acceptor = f.acceptor.clone();
                let server = tokio::spawn(async move {
                    let (socket, _) = listener.accept().await.unwrap();
                    if let Ok(mut tls) = accept(&acceptor, socket).await {
                        tls.write_all(b"origin").await.unwrap();
                        tls.flush().await.unwrap();
                        let mut byte = [0];
                        let _ = tls.read(&mut byte).await;
                    }
                });
                let (client, incoming) = tokio::io::duplex(1024);
                let task = mirror.serve(incoming, egress.clone(), "localhost".into(), port);
                let relay = tokio::spawn(task);
                // 只信任源站 CA，不信任应用的镜像 CA，确保不是另一条 MITM 握手。
                let result = NativeTlsStream::connect_with_ca(Box::new(client), "localhost", port,
                    &template.hello, if trust_origin { sessions.clone() } else { Arc::new(Sessions::default()) }, trust_origin.then_some(f.ca.as_str())).await;
                if trust_origin {
                    let mut tls = match result {
                        Ok(tls) => tls,
                        Err(error) => panic!("native client: {error}; relay: {:?}", relay.await),
                    };
                    assert_eq!(tls.resumed(), index == 1);
                    let mut body = [0; 6];
                    tls.read_exact(&mut body).await.unwrap();
                    assert_eq!(&body, b"origin");
                    tls.shutdown().await.unwrap();
                } else {
                    assert!(matches!(result, Err(NetError::Certificate(_))));
                }
                server.await.unwrap();
                let _ = relay.await.unwrap();
            }
            let state: serde_json::Value = serde_json::from_str(&templates.status_json()).unwrap();
            assert_eq!(state["tls_observations"], 0, "透明连接不能伪造已认证的探针采样");
        }).await.unwrap();
    }
}
