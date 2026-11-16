//! RFC 9110 §5.6.2 tokens.

use rama_utils::byte_set::{set_ascii_alphanum, set_each};

const TCHAR: [bool; 256] = set_each(set_ascii_alphanum([false; 256]), b"!#$%&'*+-.^_`|~");

/// Whether `bytes` is a non-empty HTTP token (`1*tchar`).
pub(crate) const fn is_token(bytes: &[u8]) -> bool {
    if bytes.is_empty() {
        return false;
    }
    let mut i = 0;
    while i < bytes.len() {
        if !TCHAR[bytes[i] as usize] {
            return false;
        }
        i += 1;
    }
    true
}
