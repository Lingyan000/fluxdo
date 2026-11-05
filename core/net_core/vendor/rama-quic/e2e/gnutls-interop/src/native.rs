//! The C bridge owns its callbacks and buffers; Rust copies output before releasing the lock.
use std::{
    ffi::{CStr, CString, c_char, c_int, c_uint, c_void},
    ptr::NonNull,
    sync::OnceLock,
};
use zeroize::Zeroizing;

#[derive(Debug, Clone)]
pub struct GnuTlsError {
    pub code: i32,
    pub description: String,
    pub certificate_status: u32,
}

impl std::fmt::Display for GnuTlsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "GnuTLS {}: {} (certificate status {})",
            self.code, self.description, self.certificate_status
        )
    }
}

impl std::error::Error for GnuTlsError {}

pub type Result<T> = std::result::Result<T, GnuTlsError>;

fn check(code: i32) -> Result<()> {
    if code >= 0 {
        return Ok(());
    }
    // SAFETY: `qg_error` calls `gnutls_strerror`, which accepts any code and takes no pointers.
    let description = unsafe { qg_error(code) };
    // SAFETY: `CStr::from_ptr` needs a non-null, NUL-terminated string that is not written
    // while borrowed: `gnutls_strerror` returns a static description, also for unknown codes.
    let description = unsafe { CStr::from_ptr(description) }
        .to_string_lossy()
        .into_owned();
    Err(GnuTlsError {
        code,
        description,
        certificate_status: 0,
    })
}

pub fn init() -> Result<()> {
    static INIT: OnceLock<Result<()>> = OnceLock::new();
    // SAFETY: global initialization is performed once; it remains initialized for process lifetime.
    INIT.get_or_init(|| check(unsafe { qg_init() })).clone()
}

pub fn version() -> String {
    // SAFETY: `qg_version` calls `gnutls_check_version(NULL)`, which takes no pointers.
    let version = unsafe { qg_version() };
    // SAFETY: `CStr::from_ptr` needs a non-null, NUL-terminated string that is not written
    // while borrowed: with NULL, `gnutls_check_version` returns the static version string.
    unsafe { CStr::from_ptr(version) }
        .to_string_lossy()
        .into_owned()
}

#[repr(C)]
#[derive(Default)]
pub struct EventInfo {
    pub kind: c_int,
    pub level: c_int,
    pub read_size: usize,
    pub write_size: usize,
    pub size: usize,
}

pub struct Event {
    pub info: EventInfo,
    pub data: Zeroizing<Vec<u8>>,
}

pub struct Options<'a> {
    pub server: bool,
    pub ca: &'a str,
    pub certificate: &'a str,
    pub key: &'a str,
    pub name: &'a str,
    pub alpn: &'a [u8],
    pub parameters: &'a [u8],
}

pub struct NativeSession(NonNull<c_void>);

// SAFETY: a session has one owner, no thread affinity, and all access is serialized by Session's Mutex.
unsafe impl Send for NativeSession {}

impl Drop for NativeSession {
    fn drop(&mut self) {
        // SAFETY: this pointer was allocated by qg_new and is freed exactly once.
        unsafe { qg_free(self.0.as_ptr()) }
    }
}

impl NativeSession {
    pub fn new(options: Options<'_>) -> Result<Self> {
        init()?;
        let string = |s: &str| {
            CString::new(s).map_err(|_| GnuTlsError {
                code: -50,
                description: "embedded NUL in configuration".into(),
                certificate_status: 0,
            })
        };
        let ca = string(options.ca)?;
        let certificate = string(options.certificate)?;
        let key = string(options.key)?;
        let name = string(options.name)?;
        let mut output = std::ptr::null_mut();
        // SAFETY: strings and slices are valid for the call; C loads/copies them and owns the returned session.
        check(unsafe {
            qg_new(
                &raw mut output,
                options.server.into(),
                ca.as_ptr(),
                certificate.as_ptr(),
                key.as_ptr(),
                name.as_ptr(),
                options.alpn.as_ptr(),
                options.alpn.len(),
                options.parameters.as_ptr(),
                options.parameters.len(),
            )
        })?;
        Ok(Self(
            NonNull::new(output).expect("successful qg_new returns a session"),
        ))
    }

    pub fn step(&mut self, level: i32, data: &[u8]) -> Result<bool> {
        // SAFETY: exclusive session access, valid input slice; C does not retain its pointer.
        let code = unsafe { qg_step(self.0.as_ptr(), level, data.as_ptr(), data.len()) };
        check(code).map_err(|mut error| {
            // SAFETY: session is live and exclusively borrowed.
            error.certificate_status = unsafe { qg_verify_status(self.0.as_ptr()) };
            error
        })?;
        Ok(code == 0)
    }

    pub fn alert(&self, code: i32) -> u8 {
        // SAFETY: live session and an error code returned by the same library.
        u8::try_from(unsafe { qg_alert(self.0.as_ptr(), code) }).unwrap_or(80)
    }

    pub fn event(&mut self) -> Result<Option<Event>> {
        let mut info = EventInfo::default();
        // SAFETY: info is writable, the session is live, no pointer is retained.
        if unsafe { qg_peek(self.0.as_ptr(), &raw mut info) } == 0 {
            return Ok(None);
        }
        let mut data = Zeroizing::new(vec![0; info.size]);
        // SAFETY: output has precisely the size reported for this event under exclusive access.
        check(unsafe { qg_take(self.0.as_ptr(), data.as_mut_ptr(), data.len()) })?;
        Ok(Some(Event { info, data }))
    }

    pub fn parameters(&self) -> Option<Vec<u8>> {
        let mut data = std::ptr::null();
        let mut size = 0;
        // SAFETY: outputs are writable and copied while the session stays borrowed.
        if unsafe { qg_peer_params(self.0.as_ptr(), &raw mut data, &raw mut size) } == 0 {
            return None;
        }
        Some(copy_bytes(data, size))
    }

    pub fn alpn(&self) -> Option<Vec<u8>> {
        let mut data = std::ptr::null();
        let mut size = 0;
        // SAFETY: outputs are writable and copied while the session stays borrowed.
        check(unsafe { qg_alpn(self.0.as_ptr(), &raw mut data, &raw mut size) }).ok()?;
        Some(copy_bytes(data, size))
    }

    pub fn certificates(&self) -> Vec<Vec<u8>> {
        let mut certificates = Vec::new();
        for index in 0.. {
            let mut data = std::ptr::null();
            let mut size = 0;
            // SAFETY: outputs are writable and copied while the session stays borrowed.
            if unsafe { qg_peer_cert(self.0.as_ptr(), index, &raw mut data, &raw mut size) } == 0 {
                break;
            }
            certificates.push(copy_bytes(data, size));
        }
        certificates
    }

    pub fn export(&self, label: &[u8], context: &[u8], out: &mut [u8]) -> Result<()> {
        // SAFETY: disjoint slices remain valid for this synchronous call.
        check(unsafe {
            qg_export(
                self.0.as_ptr(),
                label.as_ptr(),
                label.len(),
                context.as_ptr(),
                context.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        })
    }
}

fn copy_bytes(data: *const u8, size: usize) -> Vec<u8> {
    if size == 0 {
        return Vec::new();
    }
    // SAFETY: callers pass a GnuTLS-owned buffer and its reported length, while holding the session lock.
    unsafe { std::slice::from_raw_parts(data, size) }.to_vec()
}

pub fn random(out: &mut [u8]) -> Result<()> {
    init()?;
    // SAFETY: output is writable for the supplied length.
    check(unsafe { qg_random(out.as_mut_ptr(), out.len()) })
}

pub fn extract(salt: &[u8], key: &[u8]) -> Result<Zeroizing<[u8; 32]>> {
    init()?;
    let mut out = Zeroizing::new([0; 32]);
    // SAFETY: inputs are readable and output is the SHA256 digest size.
    check(unsafe {
        qg_extract(
            salt.as_ptr(),
            salt.len(),
            key.as_ptr(),
            key.len(),
            out.as_mut_ptr(),
        )
    })?;
    Ok(out)
}

pub fn expand(key: &[u8; 32], info: &[u8], out: &mut [u8]) -> Result<()> {
    // SAFETY: key has the bridge's fixed size; all buffers match supplied lengths.
    check(unsafe {
        qg_expand(
            key.as_ptr(),
            info.as_ptr(),
            info.len(),
            out.as_mut_ptr(),
            out.len(),
        )
    })
}

pub fn aead(
    decrypt: bool,
    key: &[u8; 16],
    nonce: &[u8; 12],
    aad: &[u8],
    input: &[u8],
) -> Result<Vec<u8>> {
    let mut out = vec![0; input.len() + 16];
    let mut size = out.len();
    // SAFETY: keys/nonces have fixed sizes, slices match lengths, output accommodates the tag.
    check(unsafe {
        qg_aead(
            decrypt.into(),
            key.as_ptr(),
            nonce.as_ptr(),
            aad.as_ptr(),
            aad.len(),
            input.as_ptr(),
            input.len(),
            out.as_mut_ptr(),
            &raw mut size,
        )
    })?;
    out.truncate(size);
    Ok(out)
}

pub fn mask(key: &[u8; 16], sample: &[u8; 16]) -> Result<[u8; 16]> {
    let mut out = [0; 16];
    // SAFETY: all buffers are exactly one AES block.
    check(unsafe { qg_mask(key.as_ptr(), sample.as_ptr(), out.as_mut_ptr()) })?;
    Ok(out)
}

unsafe extern "C" {

    fn qg_init() -> c_int;

    fn qg_version() -> *const c_char;

    fn qg_error(code: c_int) -> *const c_char;

    fn qg_new(
        out: *mut *mut c_void,
        server: c_int,
        ca: *const c_char,
        certificate: *const c_char,
        key: *const c_char,
        name: *const c_char,
        alpn: *const u8,
        alpn_size: usize,
        params: *const u8,
        params_size: usize,
    ) -> c_int;

    fn qg_free(session: *mut c_void);

    fn qg_step(session: *mut c_void, level: c_int, data: *const u8, size: usize) -> c_int;

    fn qg_peek(session: *mut c_void, info: *mut EventInfo) -> c_int;

    fn qg_take(session: *mut c_void, data: *mut u8, size: usize) -> c_int;

    fn qg_peer_params(session: *mut c_void, data: *mut *const u8, size: *mut usize) -> c_int;

    fn qg_alpn(session: *mut c_void, data: *mut *const u8, size: *mut usize) -> c_int;

    fn qg_peer_cert(
        session: *mut c_void,
        index: c_uint,
        data: *mut *const u8,
        size: *mut usize,
    ) -> c_int;

    fn qg_verify_status(session: *mut c_void) -> c_uint;

    fn qg_alert(session: *mut c_void, error: c_int) -> c_int;

    fn qg_export(
        session: *mut c_void,
        label: *const u8,
        label_size: usize,
        context: *const u8,
        context_size: usize,
        out: *mut u8,
        size: usize,
    ) -> c_int;

    fn qg_random(out: *mut u8, size: usize) -> c_int;

    fn qg_extract(
        salt: *const u8,
        salt_size: usize,
        key: *const u8,
        key_size: usize,
        out: *mut u8,
    ) -> c_int;

    fn qg_expand(
        key: *const u8,
        info: *const u8,
        info_size: usize,
        out: *mut u8,
        size: usize,
    ) -> c_int;

    fn qg_aead(
        decrypt: c_int,
        key: *const u8,
        nonce: *const u8,
        aad: *const u8,
        aad_size: usize,
        input: *const u8,
        input_size: usize,
        out: *mut u8,
        out_size: *mut usize,
    ) -> c_int;

    fn qg_mask(key: *const u8, sample: *const u8, out: *mut u8) -> c_int;
}
