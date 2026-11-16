//! Load the platform's native certificate store (system trust chain) in a
//! tls-implementation agnostic way, as [`pki_types`] certificates.
//!
//! The certificates returned here can be fed into any tls backend (e.g.
//! `rustls` or `boring`), which is why this lives in `rama-crypto` rather than
//! in one of the tls backend crates.
//!
//! The main entry points are:
//!
//! - [`shared_native_trust_anchors`]: the cached, process-wide default trust
//!   anchors used by rama tls clients. Loads the native store once; if nothing
//!   is found it warns and falls back to the bundled webpki roots.
//! - [`load_native_certs`]: a one-shot (uncached) read of the platform store,
//!   for callers that want to manage caching/merging themselves.
//! - [`bundled_root_certs`]: the bundled Mozilla (CCADB) root certificates used
//!   as the fallback.
//!
//! # Attribution
//!
//! The platform readers and `SSL_CERT_FILE`/`SSL_CERT_DIR` handling are an
//! adapted fork of [`rustls-native-certs`] (Apache-2.0 OR ISC OR MIT), with the
//! pending [permission-skip fix][pr228] folded in and the public surface
//! reshaped around rama's [`pki_types`] re-export, error and tracing
//! conventions.
//!
//! [`pki_types`]: crate::pki_types
//! [`rustls-native-certs`]: https://github.com/rustls/rustls-native-certs
//! [pr228]: https://github.com/rustls/rustls-native-certs/pull/228

use std::error::Error as StdError;
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock};
use std::{env, fmt, fs, io};

use rama_core::telemetry::tracing::{debug, warn};

use crate::pki_types::CertificateDer;
use crate::pki_types::pem::{self, PemObject};

#[cfg(all(unix, not(target_os = "macos")))]
mod unix;
#[cfg(all(unix, not(target_os = "macos")))]
use unix as platform;

#[cfg(windows)]
mod windows;
#[cfg(windows)]
use windows as platform;

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
use macos as platform;

/// Returns the cached, process-wide default trust anchors used by rama tls
/// clients (both the `rustls` and `boring` backends consume these).
///
/// On first call this loads the platform's native certificate store via
/// [`load_native_certs`] (honoring `SSL_CERT_FILE`/`SSL_CERT_DIR`). If the
/// native store yields no certificates, a warning is logged and the bundled
/// webpki roots ([`bundled_root_certs`]) are used instead so that clients on
/// minimal systems (e.g. distroless containers) still have a sane default.
///
/// The [`shared_extra_trust_anchors`] are always added.
///
/// The result is cached for the lifetime of the process: the (potentially
/// expensive) native read happens at most once.
pub fn shared_native_trust_anchors() -> Arc<[CertificateDer<'static>]> {
    static ANCHORS: LazyLock<Arc<[CertificateDer<'static>]>> = LazyLock::new(|| {
        let paths = CertPaths::from_env();
        let result = load_native_certs_with_paths(&paths);
        for err in &result.errors {
            debug!(%err, "rama native-certs: error while loading native root certificate");
        }

        let base: &[CertificateDer<'static>] = if result.certs.is_empty() && !paths.has_overrides()
        {
            warn!(
                native_cert_errors = result.errors.len(),
                "rama native-certs: no native system root certificates found; \
                 falling back to the bundled webpki (Mozilla CCADB) root certificates"
            );
            bundled_root_certs()
        } else {
            debug!(
                native_cert_count = result.certs.len(),
                "rama native-certs: loaded native system root certificates"
            );
            &result.certs
        };
        base.iter()
            .chain(shared_extra_trust_anchors().iter())
            .cloned()
            .collect()
    });
    ANCHORS.clone()
}

/// Returns the cached, process-wide extra trust anchors, loaded from
/// `SSL_CERT_EXTRA_FILE` (a PEM file) and `SSL_CERT_EXTRA_DIR` (directories,
/// split like `SSL_CERT_DIR`).
///
/// Unlike `SSL_CERT_FILE` and `SSL_CERT_DIR`, which replace the native store,
/// these are trusted in addition to it, and also by the platform verifier.
/// Empty when neither variable is set.
pub fn shared_extra_trust_anchors() -> Arc<[CertificateDer<'static>]> {
    static ANCHORS: LazyLock<Arc<[CertificateDer<'static>]>> = LazyLock::new(|| {
        let paths = CertPaths::from_env_vars(ENV_EXTRA_CERT_FILE, ENV_EXTRA_CERT_DIR);
        if !paths.has_overrides() {
            return Arc::default();
        }
        let result = paths.load();
        for err in &result.errors {
            warn!(%err, "rama native-certs: error while loading extra root certificate");
        }
        debug!(
            extra_cert_count = result.certs.len(),
            "rama native-certs: loaded extra root certificates"
        );
        result.certs.into()
    });
    ANCHORS.clone()
}

/// The bundled Mozilla (CCADB) root certificates, used as the fallback by
/// [`shared_native_trust_anchors`] and available for explicit use.
///
/// This is a re-export of the data shipped by the [`webpki-root-certs`] crate.
///
/// [`webpki-root-certs`]: https://docs.rs/webpki-root-certs
pub fn bundled_root_certs() -> &'static [CertificateDer<'static>] {
    webpki_root_certs::TLS_SERVER_ROOT_CERTS
}

/// Load root certificates found in the platform's native certificate store.
///
/// ## Environment Variables
///
/// | Env. Var.     | Description                                                       |
/// |---------------|-------------------------------------------------------------------|
/// | SSL_CERT_FILE | File containing an arbitrary number of certificates in PEM format.|
/// | SSL_CERT_DIR  | `:`/`;` separated list of directories containing certificate files.|
///
/// If **either** (or **both**) are set, certificates are only loaded from the
/// locations specified via environment variables and not the platform-native
/// certificate store. `SSL_CERT_EXTRA_FILE` and `SSL_CERT_EXTRA_DIR` add to
/// the store instead, see [`shared_extra_trust_anchors`].
///
/// ## Caveats
///
/// This function can be expensive: on some platforms it involves loading and
/// parsing a ~300KB disk file, or querying the OS keychain. Prefer
/// [`shared_native_trust_anchors`] which caches the result.
pub fn load_native_certs() -> CertificateResult {
    load_native_certs_with_paths(&CertPaths::from_env())
}

fn load_native_certs_with_paths(paths: &CertPaths) -> CertificateResult {
    match paths.has_overrides() {
        true => paths.load(),
        _ => platform::load_native_certs(),
    }
}

/// Results from trying to load certificates from the platform's native store.
#[non_exhaustive]
#[derive(Debug, Default)]
pub struct CertificateResult {
    /// Any certificates that were successfully loaded.
    pub certs: Vec<CertificateDer<'static>>,
    /// Any errors encountered while loading certificates.
    pub errors: Vec<Error>,
}

impl CertificateResult {
    fn pem_error(&mut self, err: pem::Error, path: &Path) {
        self.errors.push(Error {
            context: "failed to read PEM from file",
            kind: match err {
                pem::Error::Io(err) => ErrorKind::Io {
                    inner: err,
                    path: path.to_owned(),
                },
                _ => ErrorKind::Pem(err),
            },
        });
    }

    fn io_error(&mut self, err: io::Error, path: &Path, context: &'static str) {
        self.errors.push(Error {
            context,
            kind: ErrorKind::Io {
                inner: err,
                path: path.to_owned(),
            },
        });
    }

    #[cfg(any(windows, target_os = "macos"))]
    fn os_error(&mut self, err: Box<dyn StdError + Send + Sync + 'static>, context: &'static str) {
        self.errors.push(Error {
            context,
            kind: ErrorKind::Os(err),
        });
    }
}

/// Certificate paths from a file and/or directory environment variable pair.
struct CertPaths {
    file: Option<PathBuf>,
    dirs: Vec<PathBuf>,
}

impl CertPaths {
    fn from_env() -> Self {
        Self::from_env_vars(ENV_CERT_FILE, ENV_CERT_DIR)
    }

    fn from_env_vars(file_var: &str, dir_var: &str) -> Self {
        Self {
            file: env::var_os(file_var).map(PathBuf::from),
            // Read `SSL_CERT_DIR`, split it on the platform delimiter (`:` on
            // unix, `;` on windows), ignoring empty entries.
            //
            // See <https://docs.openssl.org/3.5/man1/openssl-rehash/#options>
            dirs: match env::var_os(dir_var) {
                Some(dirs) => env::split_paths(&dirs)
                    .filter(|p| !p.as_os_str().is_empty())
                    .collect(),
                None => Vec::new(),
            },
        }
    }

    fn load(&self) -> CertificateResult {
        load_certs_from_paths_internal(self.file.as_deref(), &self.dirs)
    }

    fn has_overrides(&self) -> bool {
        self.file.is_some() || !self.dirs.is_empty()
    }
}

/// Load certificates from the given paths.
///
/// If both are `None`, returns an empty [`CertificateResult`].
///
/// If `file` is `Some`, it must be a path to an existing, accessible file from
/// which certificates can be loaded. The PEM parser ignores parts of the file
/// which are not considered part of a certificate; malformed certificates may
/// be silently skipped.
///
/// If `dir` is defined, a directory must exist at this path. The directory is
/// not scanned recursively and may be empty; entries that are not readable
/// (e.g. root-only files) are skipped.
pub fn load_certs_from_paths(file: Option<&Path>, dir: Option<&Path>) -> CertificateResult {
    let dir = match dir {
        Some(d) => vec![d],
        None => Vec::new(),
    };

    load_certs_from_paths_internal(file, dir.as_ref())
}

fn load_certs_from_paths_internal(
    file: Option<&Path>,
    dir: &[impl AsRef<Path>],
) -> CertificateResult {
    let mut out = CertificateResult::default();
    if file.is_none() && dir.is_empty() {
        return out;
    }

    if let Some(cert_file) = file {
        // An explicit file is expected to exist and be readable: surface errors.
        load_pem_certs(cert_file, &mut out, false);
    }

    for cert_dir in dir.iter() {
        load_pem_certs_from_dir(cert_dir.as_ref(), &mut out);
    }

    out.certs.sort_unstable_by(|a, b| a.cmp(b));
    out.certs.dedup();
    out
}

/// Load certificates from a certificate directory (what OpenSSL calls CAdir).
fn load_pem_certs_from_dir(dir: &Path, out: &mut CertificateResult) {
    let dir_reader = match fs::read_dir(dir) {
        Ok(reader) => reader,
        Err(err) => {
            out.io_error(err, dir, "opening directory");
            return;
        }
    };

    for entry in dir_reader {
        let entry = match entry {
            Ok(entry) => entry,
            Err(err) => {
                out.io_error(err, dir, "reading directory entries");
                continue;
            }
        };

        let path = entry.path();

        // `openssl rehash` used to create this directory uses symlinks, so
        // resolve them.
        let metadata = match fs::metadata(&path) {
            Ok(metadata) => metadata,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                // Dangling symlink
                continue;
            }
            Err(e) => {
                out.io_error(e, &path, "failed to open file");
                continue;
            }
        };

        if metadata.is_file() {
            // When scanning a directory, skip over files that are not readable
            // (usually `chown root` or `chmod -r`), rather than failing the
            // whole load. See <https://github.com/rustls/rustls-native-certs/pull/228>.
            load_pem_certs(&path, out, true);
        }
    }
}

fn load_pem_certs(path: &Path, out: &mut CertificateResult, skip_eperm: bool) {
    let iter = match CertificateDer::pem_file_iter(path) {
        Ok(iter) => iter,
        Err(err) => {
            if skip_eperm
                && let pem::Error::Io(io_error) = &err
                && io_error.kind() == io::ErrorKind::PermissionDenied
            {
                return;
            }
            out.pem_error(err, path);
            return;
        }
    };

    for result in iter {
        match result {
            Ok(cert) => out.certs.push(cert),
            Err(err) => out.pem_error(err, path),
        }
    }
}

/// An error encountered while loading certificates from the platform store.
#[derive(Debug)]
pub struct Error {
    /// Human-readable context describing what was being attempted.
    pub context: &'static str,
    /// The underlying error kind.
    pub kind: ErrorKind,
}

impl StdError for Error {
    fn source(&self) -> Option<&(dyn StdError + 'static)> {
        Some(match &self.kind {
            ErrorKind::Io { inner, .. } => inner,
            ErrorKind::Os(err) => &**err,
            ErrorKind::Pem(err) => err,
        })
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.context)?;
        f.write_str(": ")?;
        match &self.kind {
            ErrorKind::Io { inner, path } => write!(f, "{inner} at '{}'", path.display()),
            ErrorKind::Os(err) => err.fmt(f),
            ErrorKind::Pem(err) => err.fmt(f),
        }
    }
}

/// The kinds of errors that can occur while loading native certificates.
#[non_exhaustive]
#[derive(Debug)]
pub enum ErrorKind {
    /// An I/O error while reading a certificate file or directory.
    Io {
        /// The underlying I/O error.
        inner: io::Error,
        /// The path being read.
        path: PathBuf,
    },
    /// A platform (OS keychain / cert store) error.
    Os(Box<dyn StdError + Send + Sync + 'static>),
    /// A PEM parsing error.
    Pem(pem::Error),
}

const ENV_CERT_FILE: &str = "SSL_CERT_FILE";
const ENV_CERT_DIR: &str = "SSL_CERT_DIR";
const ENV_EXTRA_CERT_FILE: &str = "SSL_CERT_EXTRA_FILE";
const ENV_EXTRA_CERT_DIR: &str = "SSL_CERT_EXTRA_DIR";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_root_certs_non_empty() {
        assert!(
            !bundled_root_certs().is_empty(),
            "bundled webpki root certificates should not be empty"
        );
    }

    #[test]
    fn from_env_missing_file() {
        let mut result = CertificateResult::default();
        load_pem_certs(Path::new("no/such/file"), &mut result, false);
        match &result.errors.first().unwrap().kind {
            ErrorKind::Io { inner, .. } => assert_eq!(inner.kind(), io::ErrorKind::NotFound),
            other => panic!("unexpected error {other:?}"),
        }
    }

    #[test]
    fn from_env_missing_dir() {
        let mut result = CertificateResult::default();
        load_pem_certs_from_dir(Path::new("no/such/directory"), &mut result);
        match &result.errors.first().unwrap().kind {
            ErrorKind::Io { inner, .. } => assert_eq!(inner.kind(), io::ErrorKind::NotFound),
            other => panic!("unexpected error {other:?}"),
        }
    }

    #[test]
    fn cert_paths_detects_env_overrides() {
        assert!(
            !CertPaths {
                file: None,
                dirs: Vec::new()
            }
            .has_overrides()
        );
        assert!(
            CertPaths {
                file: Some(PathBuf::from("ca.pem")),
                dirs: Vec::new()
            }
            .has_overrides()
        );
        assert!(
            CertPaths {
                file: None,
                dirs: vec![PathBuf::from("certs")]
            }
            .has_overrides()
        );
    }

    #[test]
    #[cfg(unix)]
    fn from_env_with_non_regular_and_empty_file() {
        let mut result = CertificateResult::default();
        load_pem_certs(Path::new("/dev/null"), &mut result, false);
        assert_eq!(result.certs.len(), 0);
        assert!(result.errors.is_empty());
    }
}
