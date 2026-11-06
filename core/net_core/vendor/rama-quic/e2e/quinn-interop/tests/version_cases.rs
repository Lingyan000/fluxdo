//! The shared QUIC version cases (RFC 9368, RFC 9369) are recorded as unsupported here: the
//! pinned quinn speaks version 1 only, so it can neither start in nor be moved to version 2.

use interop_common::{Unsupported, version_cases};

const PEER: &str = "quinn";

#[test]
fn version_cases_are_unsupported() {
    for case in version_cases() {
        // Visible with `cargo test -- --nocapture`.
        println!(
            "{}",
            Unsupported {
                case: case.name,
                peer: PEER,
                reason: "the pinned quinn speaks QUIC v1 only",
            }
        );
    }
}
