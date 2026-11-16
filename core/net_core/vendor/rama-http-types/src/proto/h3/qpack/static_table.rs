//! The QPACK static table (RFC 9204 Appendix A, Table 4): 99 entries, indexed `0..=98`.
//!
//! Values are copied verbatim from the RFC as published — including the uppercase
//! `access-control-allow-credentials` values `FALSE`/`TRUE` (indices 73/74), which erratum 7277 is
//! *Held for Document Update* and every interoperable implementation keeps, because the static
//! table is a fixed wire contract.

/// The number of entries in the QPACK static table.
pub const STATIC_TABLE_SIZE: usize = 99;

/// The QPACK static table as `(name, value)` byte pairs, indexed by absolute static index.
pub static STATIC_TABLE: [(&[u8], &[u8]); STATIC_TABLE_SIZE] = [
    (b":authority", b""),
    (b":path", b"/"),
    (b"age", b"0"),
    (b"content-disposition", b""),
    (b"content-length", b"0"),
    (b"cookie", b""),
    (b"date", b""),
    (b"etag", b""),
    (b"if-modified-since", b""),
    (b"if-none-match", b""),
    (b"last-modified", b""),
    (b"link", b""),
    (b"location", b""),
    (b"referer", b""),
    (b"set-cookie", b""),
    (b":method", b"CONNECT"),
    (b":method", b"DELETE"),
    (b":method", b"GET"),
    (b":method", b"HEAD"),
    (b":method", b"OPTIONS"),
    (b":method", b"POST"),
    (b":method", b"PUT"),
    (b":scheme", b"http"),
    (b":scheme", b"https"),
    (b":status", b"103"),
    (b":status", b"200"),
    (b":status", b"304"),
    (b":status", b"404"),
    (b":status", b"503"),
    (b"accept", b"*/*"),
    (b"accept", b"application/dns-message"),
    (b"accept-encoding", b"gzip, deflate, br"),
    (b"accept-ranges", b"bytes"),
    (b"access-control-allow-headers", b"cache-control"),
    (b"access-control-allow-headers", b"content-type"),
    (b"access-control-allow-origin", b"*"),
    (b"cache-control", b"max-age=0"),
    (b"cache-control", b"max-age=2592000"),
    (b"cache-control", b"max-age=604800"),
    (b"cache-control", b"no-cache"),
    (b"cache-control", b"no-store"),
    (b"cache-control", b"public, max-age=31536000"),
    (b"content-encoding", b"br"),
    (b"content-encoding", b"gzip"),
    (b"content-type", b"application/dns-message"),
    (b"content-type", b"application/javascript"),
    (b"content-type", b"application/json"),
    (b"content-type", b"application/x-www-form-urlencoded"),
    (b"content-type", b"image/gif"),
    (b"content-type", b"image/jpeg"),
    (b"content-type", b"image/png"),
    (b"content-type", b"text/css"),
    (b"content-type", b"text/html; charset=utf-8"),
    (b"content-type", b"text/plain"),
    (b"content-type", b"text/plain;charset=utf-8"),
    (b"range", b"bytes=0-"),
    (b"strict-transport-security", b"max-age=31536000"),
    (
        b"strict-transport-security",
        b"max-age=31536000; includesubdomains",
    ),
    (
        b"strict-transport-security",
        b"max-age=31536000; includesubdomains; preload",
    ),
    (b"vary", b"accept-encoding"),
    (b"vary", b"origin"),
    (b"x-content-type-options", b"nosniff"),
    (b"x-xss-protection", b"1; mode=block"),
    (b":status", b"100"),
    (b":status", b"204"),
    (b":status", b"206"),
    (b":status", b"302"),
    (b":status", b"400"),
    (b":status", b"403"),
    (b":status", b"421"),
    (b":status", b"425"),
    (b":status", b"500"),
    (b"accept-language", b""),
    (b"access-control-allow-credentials", b"FALSE"),
    (b"access-control-allow-credentials", b"TRUE"),
    (b"access-control-allow-headers", b"*"),
    (b"access-control-allow-methods", b"get"),
    (b"access-control-allow-methods", b"get, post, options"),
    (b"access-control-allow-methods", b"options"),
    (b"access-control-expose-headers", b"content-length"),
    (b"access-control-request-headers", b"content-type"),
    (b"access-control-request-method", b"get"),
    (b"access-control-request-method", b"post"),
    (b"alt-svc", b"clear"),
    (b"authorization", b""),
    (
        b"content-security-policy",
        b"script-src 'none'; object-src 'none'; base-uri 'none'",
    ),
    (b"early-data", b"1"),
    (b"expect-ct", b""),
    (b"forwarded", b""),
    (b"if-range", b""),
    (b"origin", b""),
    (b"purpose", b"prefetch"),
    (b"server", b""),
    (b"timing-allow-origin", b"*"),
    (b"upgrade-insecure-requests", b"1"),
    (b"user-agent", b""),
    (b"x-forwarded-for", b""),
    (b"x-frame-options", b"deny"),
    (b"x-frame-options", b"sameorigin"),
];

/// Look up a static-table entry by index (RFC 9204 §3.1).
#[must_use]
pub fn get(index: usize) -> Option<(&'static [u8], &'static [u8])> {
    STATIC_TABLE.get(index).copied()
}

/// Find the index of a static entry whose name and value both match exactly, if any.
#[must_use]
pub fn find(name: &[u8], value: &[u8]) -> Option<usize> {
    name_indices(name)
        .iter()
        .copied()
        .find(|&index| STATIC_TABLE[index].1 == value)
}

/// Find the lowest index of a static entry whose name matches, if any (name-only match).
#[must_use]
pub fn find_name(name: &[u8]) -> Option<usize> {
    name_indices(name).first().copied()
}

// Dispatch once on the name, then compare only candidate values. Some names occur
// in multiple disjoint ranges of the RFC table (notably :status).
fn name_indices(name: &[u8]) -> &'static [usize] {
    match name {
        b":authority" => &[0],
        b":path" => &[1],
        b"age" => &[2],
        b"content-disposition" => &[3],
        b"content-length" => &[4],
        b"cookie" => &[5],
        b"date" => &[6],
        b"etag" => &[7],
        b"if-modified-since" => &[8],
        b"if-none-match" => &[9],
        b"last-modified" => &[10],
        b"link" => &[11],
        b"location" => &[12],
        b"referer" => &[13],
        b"set-cookie" => &[14],
        b":method" => &[15, 16, 17, 18, 19, 20, 21],
        b":scheme" => &[22, 23],
        b":status" => &[24, 25, 26, 27, 28, 63, 64, 65, 66, 67, 68, 69, 70, 71],
        b"accept" => &[29, 30],
        b"accept-encoding" => &[31],
        b"accept-ranges" => &[32],
        b"access-control-allow-headers" => &[33, 34, 75],
        b"access-control-allow-origin" => &[35],
        b"cache-control" => &[36, 37, 38, 39, 40, 41],
        b"content-encoding" => &[42, 43],
        b"content-type" => &[44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54],
        b"range" => &[55],
        b"strict-transport-security" => &[56, 57, 58],
        b"vary" => &[59, 60],
        b"x-content-type-options" => &[61],
        b"x-xss-protection" => &[62],
        b"accept-language" => &[72],
        b"access-control-allow-credentials" => &[73, 74],
        b"access-control-allow-methods" => &[76, 77, 78],
        b"access-control-expose-headers" => &[79],
        b"access-control-request-headers" => &[80],
        b"access-control-request-method" => &[81, 82],
        b"alt-svc" => &[83],
        b"authorization" => &[84],
        b"content-security-policy" => &[85],
        b"early-data" => &[86],
        b"expect-ct" => &[87],
        b"forwarded" => &[88],
        b"if-range" => &[89],
        b"origin" => &[90],
        b"purpose" => &[91],
        b"server" => &[92],
        b"timing-allow-origin" => &[93],
        b"upgrade-insecure-requests" => &[94],
        b"user-agent" => &[95],
        b"x-forwarded-for" => &[96],
        b"x-frame-options" => &[97, 98],
        _ => &[],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn complete_rfc_static_table_fixture() {
        let fixture = include_str!("fixtures/rfc9204-static-table.tsv");
        let mut count = 0;
        for row in fixture.lines().filter(|line| !line.starts_with('#')) {
            let mut fields = row.split('\t');
            let index: usize = fields.next().unwrap().parse().unwrap();
            let name = fields.next().unwrap().as_bytes();
            let value = fields.next().unwrap().as_bytes();
            assert_eq!(get(index), Some((name, value)), "RFC static index {index}");
            assert_eq!(find(name, value), Some(index));
            assert_eq!(
                find_name(name),
                STATIC_TABLE.iter().position(|(n, _)| *n == name)
            );
            count += 1;
        }
        assert_eq!(count, STATIC_TABLE_SIZE);
    }

    #[test]
    fn size_and_spot_checks() {
        assert_eq!(STATIC_TABLE.len(), 99);
        assert_eq!(get(0), Some((&b":authority"[..], &b""[..])));
        assert_eq!(get(1), Some((&b":path"[..], &b"/"[..])));
        assert_eq!(get(17), Some((&b":method"[..], &b"GET"[..])));
        assert_eq!(get(98), Some((&b"x-frame-options"[..], &b"sameorigin"[..])));
        assert_eq!(get(99), None);
    }

    #[test]
    fn exact_find() {
        assert_eq!(find(b":method", b"GET"), Some(17));
        assert_eq!(find(b":status", b"200"), Some(25));
        assert_eq!(find(b":method", b"TRACE"), None);
    }

    #[test]
    fn name_find_returns_lowest() {
        assert_eq!(find_name(b":method"), Some(15));
        assert_eq!(find_name(b":status"), Some(24));
        assert_eq!(find_name(b"content-type"), Some(44));
        assert_eq!(find_name(b"x-frame-options"), Some(97));
        assert_eq!(find_name(b"not-a-header"), None);
    }

    #[test]
    fn credentials_kept_uppercase_per_rfc() {
        assert_eq!(
            get(73),
            Some((&b"access-control-allow-credentials"[..], &b"FALSE"[..]))
        );
        assert_eq!(
            get(74),
            Some((&b"access-control-allow-credentials"[..], &b"TRUE"[..]))
        );
    }
}
