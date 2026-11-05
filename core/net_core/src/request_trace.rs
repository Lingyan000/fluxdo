//! CSRF 请求在核心整理头部后的快照。只保留短哈希；并非服务端 wire 抓包。
use std::collections::BTreeMap;

use rama::http::{HeaderMap, Request};
use rama::tls::boring::core::sha::sha256;
use serde::Serialize;

#[derive(Clone, Debug, Serialize)]
pub struct PreparedRequestTrace {
    pub stage: &'static str,
    pub header_hashes: BTreeMap<String, Vec<String>>,
}

impl rama::extensions::Extension for PreparedRequestTrace {}

impl PreparedRequestTrace {
    pub fn capture<B>(request: &Request<B>) -> Option<Self> {
        if !request
            .uri()
            .path()
            .is_some_and(|path| path == "/session/csrf")
            && (request.method() == rama::http::Method::GET
                || !request.headers().contains_key("x-csrf-token"))
        {
            return None;
        }
        Some(Self {
            stage: "core-prepared-headers",
            header_hashes: header_hashes(request.headers()),
        })
    }
}

fn header_hashes(headers: &HeaderMap) -> BTreeMap<String, Vec<String>> {
    [
        "cookie",
        "x-csrf-token",
        "origin",
        "referer",
        "user-agent",
        "content-type",
        "content-length",
    ]
    .into_iter()
    .filter_map(|name| {
        let hashes: Vec<_> = headers
            .get_all(name)
            .iter()
            .map(|value| {
                sha256(value.as_bytes())[..8]
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect::<String>()
            })
            .collect();
        (!hashes.is_empty()).then(|| (name.to_owned(), hashes))
    })
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_preserves_duplicate_counts_without_leaking_values() {
        let request = Request::builder()
            .method("POST")
            .uri("https://linux.do/topics/timings")
            .header("x-csrf-token", "secret-token")
            .header("x-csrf-token", "second-token")
            .header("cookie", "_forum_session=secret-cookie")
            .body(())
            .unwrap();
        let trace = PreparedRequestTrace::capture(&request).unwrap();
        assert_eq!(trace.header_hashes["x-csrf-token"].len(), 2);
        assert_eq!(trace.header_hashes["cookie"].len(), 1);
        assert_eq!(trace.header_hashes["x-csrf-token"][0], "930bbdc51b6aed5c");
        let serialized = serde_json::to_string(&trace).unwrap();
        assert!(!serialized.contains("secret-token"));
        assert!(!serialized.contains("secret-cookie"));
    }

    #[test]
    fn csrf_refresh_is_traced_but_images_are_not() {
        let csrf = Request::builder()
            .uri("https://linux.do/session/csrf")
            .body(())
            .unwrap();
        let image = Request::builder()
            .uri("https://cdn.ldstatic.com/image.png")
            .header("x-csrf-token", "cached-token-on-get")
            .body(())
            .unwrap();
        assert!(PreparedRequestTrace::capture(&csrf).is_some());
        assert!(PreparedRequestTrace::capture(&image).is_none());
    }
}
