#![expect(
    clippy::unreachable,
    reason = "vendored fuzz harness: panic-on-bad-state is the standard quickcheck pattern"
)]

use crate::proto::h2::hpack::{Decoder, Encoder, Header};

use crate::{HeaderName, HeaderValue};

use quickcheck::{Arbitrary, Gen, QuickCheck, TestResult};
use rama_core::bytes::BytesMut;
use rama_utils::octets::kib;
use rand::distr::slice::Choose;
use rand::rngs::StdRng;
use rand::{RngExt as _, SeedableRng, rng};

use std::io::Cursor;
use std::ops::ControlFlow;

const MAX_CHUNK: usize = kib(2);

#[test]
fn hpack_fuzz() {
    fn prop(fuzz: FuzzHpack) -> TestResult {
        fuzz.run();
        TestResult::from_bool(true)
    }

    QuickCheck::new()
        .tests(100)
        .quickcheck(prop as fn(FuzzHpack) -> TestResult)
}

/*
// If wanting to test with a specific feed, uncomment and fill in the seed.
#[test]
fn hpack_fuzz_seeded() {
    _ = env_logger::try_init();
    let seed = [/* fill me in*/];
    FuzzHpack::new(seed).run();
}
*/

#[derive(Debug, Clone)]
struct FuzzHpack {
    // The set of headers to encode / decode
    frames: Vec<HeaderFrame>,
}

#[derive(Debug, Clone)]
struct HeaderFrame {
    resizes: Vec<usize>,
    headers: Vec<Header<Option<HeaderName>>>,
}

impl FuzzHpack {
    fn new(seed: [u8; 32]) -> Self {
        // Seed the RNG
        let mut rng = StdRng::from_seed(seed);

        // Generates a bunch of source headers
        let mut source: Vec<Header<Option<HeaderName>>> = vec![];

        for _ in 0..2000 {
            source.push(gen_header(&mut rng));
        }

        // Actual test run headers
        let num: usize = rng.random_range(40..500);

        let mut frames: Vec<HeaderFrame> = vec![];
        let mut added = 0;

        let skew: i32 = rng.random_range(1..5);

        // Rough number of headers to add
        while added < num {
            let mut frame = HeaderFrame {
                resizes: vec![],
                headers: vec![],
            };

            match rng.random_range(0..20) {
                0 => {
                    // Two resizes
                    let high = rng.random_range(128..MAX_CHUNK * 2);
                    let low = rng.random_range(0..high);

                    frame.resizes.extend([low, high]);
                }
                1..=3 => {
                    frame.resizes.push(rng.random_range(128..MAX_CHUNK * 2));
                }
                _ => {}
            }

            let mut is_name_required = true;

            for _ in 0..rng.random_range(1..(num - added) + 1) {
                let x: f64 = rng.random_range(0.0..1.0);
                let x = x.powi(skew);

                let i = (x * source.len() as f64) as usize;

                let header = &source[i];
                match header {
                    Header::Field { name: None, .. } => {
                        if is_name_required {
                            continue;
                        }
                    }
                    Header::Field { .. } => {
                        is_name_required = false;
                    }
                    _ => {
                        // pseudos can't be followed by a header with no name
                        is_name_required = true;
                    }
                }

                frame.headers.push(header.clone());

                added += 1;
            }

            frames.push(frame);
        }

        Self { frames }
    }

    fn run(self) {
        let frames = self.frames;
        let mut expect = vec![];

        let mut encoder = Encoder::default();
        let mut decoder = Decoder::default();

        for frame in frames {
            // build "expected" frames, such that decoding headers always
            // includes a name
            let mut prev_name = None;
            for header in &frame.headers {
                match header.clone().reify() {
                    Ok(h) => {
                        prev_name = match h {
                            Header::Field { ref name, .. } => Some(name.clone()),
                            _ => None,
                        };
                        expect.push(h);
                    }
                    Err(value) => {
                        expect.push(Header::Field {
                            name: prev_name.as_ref().cloned().expect("previous header name"),
                            value,
                        });
                    }
                }
            }

            let mut buf = BytesMut::new();

            if let Some(max) = frame.resizes.iter().max() {
                decoder.queue_size_update(*max);
            }

            // Apply resizes
            for resize in &frame.resizes {
                encoder.update_max_size(*resize);
            }

            encoder.encode(frame.headers, &mut buf);

            // Decode the chunk!
            decoder
                .decode(&mut Cursor::new(&mut buf), |h| {
                    let e = expect.remove(0);
                    assert_eq!(h, e);
                    ControlFlow::Continue(())
                })
                .expect("full decode");
        }

        assert_eq!(0, expect.len());
    }
}

impl Arbitrary for FuzzHpack {
    fn arbitrary(_: &mut Gen) -> Self {
        Self::new(rng().random())
    }
}

fn gen_header(g: &mut StdRng) -> Header<Option<HeaderName>> {
    use crate::{Method, StatusCode};

    if g.random_ratio(1, 10) {
        match g.random_range(0u32..5) {
            0 => {
                let value = gen_string(g, 4, 20);
                Header::Authority(to_shared(&value))
            }
            1 => {
                let method = match g.random_range(0u32..6) {
                    0 => Method::GET,
                    1 => Method::POST,
                    2 => Method::PUT,
                    3 => Method::PATCH,
                    4 => Method::DELETE,
                    5 => {
                        let n: usize = g.random_range(3..7);
                        let bytes: Vec<u8> = (0..n)
                            .map(|_| *g.sample(Choose::new(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ").unwrap()))
                            .collect();

                        Method::from_bytes(&bytes).unwrap()
                    }
                    _ => unreachable!(),
                };

                Header::Method(method)
            }
            2 => {
                let value = match g.random_range(0u32..2) {
                    0 => "http",
                    1 => "https",
                    _ => unreachable!(),
                };

                Header::Scheme(to_shared(value))
            }
            3 => {
                let value = match g.random_range(0u32..100) {
                    0 => "/".to_owned(),
                    1 => "/index.html".to_owned(),
                    _ => gen_string(g, 2, 20),
                };

                Header::Path(to_shared(&value))
            }
            4 => {
                let status = (g.random::<u16>() % 500) + 100;

                Header::Status(StatusCode::from_u16(status).unwrap())
            }
            _ => unreachable!(),
        }
    } else {
        let name = if g.random_ratio(1, 10) {
            None
        } else {
            Some(gen_header_name(g))
        };
        let mut value = gen_header_value(g);

        if g.random_ratio(1, 30) {
            value.set_sensitive(true);
        }

        Header::Field { name, value }
    }
}

fn gen_header_name(g: &mut StdRng) -> HeaderName {
    use crate::header;

    if g.random_ratio(1, 2) {
        g.sample(
            Choose::new(&[
                header::ACCEPT,
                header::ACCEPT_CHARSET,
                header::ACCEPT_ENCODING,
                header::ACCEPT_LANGUAGE,
                header::ACCEPT_RANGES,
                header::ACCESS_CONTROL_ALLOW_CREDENTIALS,
                header::ACCESS_CONTROL_ALLOW_HEADERS,
                header::ACCESS_CONTROL_ALLOW_METHODS,
                header::ACCESS_CONTROL_ALLOW_ORIGIN,
                header::ACCESS_CONTROL_EXPOSE_HEADERS,
                header::ACCESS_CONTROL_MAX_AGE,
                header::ACCESS_CONTROL_REQUEST_HEADERS,
                header::ACCESS_CONTROL_REQUEST_METHOD,
                header::AGE,
                header::ALLOW,
                header::ALT_SVC,
                header::AUTHORIZATION,
                header::CACHE_CONTROL,
                header::CONNECTION,
                header::CONTENT_DISPOSITION,
                header::CONTENT_ENCODING,
                header::CONTENT_LANGUAGE,
                header::CONTENT_LENGTH,
                header::CONTENT_LOCATION,
                header::CONTENT_RANGE,
                header::CONTENT_SECURITY_POLICY,
                header::CONTENT_SECURITY_POLICY_REPORT_ONLY,
                header::CONTENT_TYPE,
                header::COOKIE,
                header::DNT,
                header::DATE,
                header::ETAG,
                header::EXPECT,
                header::EXPIRES,
                header::FORWARDED,
                header::FROM,
                header::HOST,
                header::IF_MATCH,
                header::IF_MODIFIED_SINCE,
                header::IF_NONE_MATCH,
                header::IF_RANGE,
                header::IF_UNMODIFIED_SINCE,
                header::LAST_MODIFIED,
                header::LINK,
                header::LOCATION,
                header::MAX_FORWARDS,
                header::ORIGIN,
                header::PRAGMA,
                header::PROXY_AUTHENTICATE,
                header::PROXY_AUTHORIZATION,
                header::PUBLIC_KEY_PINS,
                header::PUBLIC_KEY_PINS_REPORT_ONLY,
                header::RANGE,
                header::REFERER,
                header::REFERRER_POLICY,
                header::REFRESH,
                header::RETRY_AFTER,
                header::SERVER,
                header::SET_COOKIE,
                header::STRICT_TRANSPORT_SECURITY,
                header::TE,
                header::TRAILER,
                header::TRANSFER_ENCODING,
                header::USER_AGENT,
                header::UPGRADE,
                header::UPGRADE_INSECURE_REQUESTS,
                header::VARY,
                header::VIA,
                header::WARNING,
                header::WWW_AUTHENTICATE,
                header::X_CONTENT_TYPE_OPTIONS,
                header::X_DNS_PREFETCH_CONTROL,
                header::X_FRAME_OPTIONS,
                header::X_XSS_PROTECTION,
            ])
            .unwrap(),
        )
        .clone()
    } else {
        let value = gen_string(g, 1, 25);
        HeaderName::from_bytes(value.as_bytes()).unwrap()
    }
}

fn gen_header_value(g: &mut StdRng) -> HeaderValue {
    let value = gen_string(g, 0, 70);
    HeaderValue::from_bytes(value.as_bytes()).unwrap()
}

fn gen_string(g: &mut StdRng, min: usize, max: usize) -> String {
    let bytes: Vec<_> = (min..max)
        .map(|_| {
            // Chars to pick from
            *g.sample(Choose::new(b"ABCDEFGHIJKLMNOPQRSTUVabcdefghilpqrstuvwxyz----").unwrap())
        })
        .collect();

    String::from_utf8(bytes).unwrap()
}

fn to_shared(src: &str) -> crate::proto::h2::hpack::BytesStr {
    crate::proto::h2::hpack::BytesStr::from(src)
}
