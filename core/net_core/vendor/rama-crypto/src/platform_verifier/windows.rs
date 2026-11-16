//! Verification through CryptoAPI's certificate chain engine.

use std::{
    ffi::c_void,
    mem,
    ptr::{self, NonNull},
    slice,
    time::{SystemTime, UNIX_EPOCH},
};

use rama_core::error::BoxError;
use windows_sys::Win32::{
    Foundation::{
        CERT_E_CN_NO_MATCH, CERT_E_EXPIRED, CERT_E_INVALID_NAME, CERT_E_UNTRUSTEDROOT,
        CERT_E_WRONG_USAGE, CRYPT_E_REVOKED, FILETIME, TRUE,
    },
    Security::Cryptography::{
        AUTHTYPE_SERVER, CERT_CHAIN_CACHE_END_CERT, CERT_CHAIN_CONTEXT, CERT_CHAIN_ENGINE_CONFIG,
        CERT_CHAIN_PARA, CERT_CHAIN_POLICY_IGNORE_ALL_REV_UNKNOWN_FLAGS, CERT_CHAIN_POLICY_PARA,
        CERT_CHAIN_POLICY_SSL, CERT_CHAIN_POLICY_STATUS,
        CERT_CHAIN_REVOCATION_ACCUMULATIVE_TIMEOUT, CERT_CHAIN_REVOCATION_CHECK_END_CERT,
        CERT_CONTEXT, CERT_OCSP_RESPONSE_PROP_ID, CERT_SET_PROPERTY_IGNORE_PERSIST_ERROR_FLAG,
        CERT_STORE_ADD_ALWAYS, CERT_STORE_DEFER_CLOSE_UNTIL_LAST_FREE_FLAG, CERT_STORE_PROV_MEMORY,
        CERT_TRUST_IS_PARTIAL_CHAIN, CERT_TRUST_IS_UNTRUSTED_ROOT, CERT_USAGE_MATCH,
        CRYPT_INTEGER_BLOB, CTL_USAGE, CertAddEncodedCertificateToStore, CertCloseStore,
        CertCreateCertificateChainEngine, CertFreeCertificateChain, CertFreeCertificateChainEngine,
        CertFreeCertificateContext, CertGetCertificateChain, CertOpenStore,
        CertSetCertificateContextProperty, CertVerifyCertificateChainPolicy, HCERTCHAINENGINE,
        HTTPSPolicyCallbackData, HTTPSPolicyCallbackData_0, USAGE_MATCH_TYPE_AND,
        X509_ASN_ENCODING, szOID_PKIX_KP_SERVER_AUTH,
    },
};

use super::{PlatformVerifyError, PlatformVerifyErrorKind};
use crate::pki_types::CertificateDer;

/// Extended key usages of which the leaf must carry at least one.
const ALLOWED_EKUS: &[windows_sys::core::PCSTR] = &[szOID_PKIX_KP_SERVER_AUTH];

/// Seconds between 1601-01-01 (the `FILETIME` epoch) and the Unix epoch.
const FILETIME_UNIX_OFFSET_SECS: u64 = 11_644_473_600;

// The engine reads `cbSize` to interpret `CERT_CHAIN_PARA` and
// `CERT_CHAIN_ENGINE_CONFIG`, so the Windows 8+ layouts that `windows-sys`
// declares also work on older releases.

/// `size_of::<T>()` as the DWORD a `cbSize` field takes.
const fn dword_size_of<T>() -> u32 {
    let size = mem::size_of::<T>();
    assert!(
        size <= u32::MAX as usize,
        "structure is larger than a DWORD"
    );
    size as u32
}

fn last_os_error(kind: PlatformVerifyErrorKind) -> PlatformVerifyError {
    PlatformVerifyError::with_source(kind, std::io::Error::last_os_error())
}

/// An owned chain context.
struct CertChain(
    // Safety invariant: a chain context returned by `CertGetCertificateChain`,
    // owned by `self` and freed only by `Drop`.
    NonNull<CERT_CHAIN_CONTEXT>,
);

impl CertChain {
    /// The chain context, borrowed for `self`.
    fn context(&self) -> &CERT_CHAIN_CONTEXT {
        // SAFETY: `as_ref` needs an aligned pointer to an initialized
        // `CERT_CHAIN_CONTEXT` that is not mutated while the borrow lives. By
        // the field invariant it is a context `CertGetCertificateChain`
        // returned (an initialized C structure), alive until `Drop` frees it,
        // which the `&self` borrow excludes. CryptoAPI hands it out as
        // `PCCERT_CHAIN_CONTEXT` (const) and does not mutate it.
        unsafe { self.0.as_ref() }
    }

    fn trust_error_status(&self) -> u32 {
        self.context().TrustStatus.dwErrorStatus
    }

    fn verify_ssl_policy(
        &self,
        server_name: &str,
    ) -> Result<CERT_CHAIN_POLICY_STATUS, PlatformVerifyError> {
        let mut server_name: Vec<u16> = server_name.encode_utf16().chain(Some(0)).collect();

        let mut extra = HTTPSPolicyCallbackData {
            Anonymous: HTTPSPolicyCallbackData_0 {
                cbSize: dword_size_of::<HTTPSPolicyCallbackData>(),
            },
            dwAuthType: AUTHTYPE_SERVER,
            pwszServerName: server_name.as_mut_ptr(),
            ..Default::default()
        };

        let params = CERT_CHAIN_POLICY_PARA {
            cbSize: dword_size_of::<CERT_CHAIN_POLICY_PARA>(),
            // Missing revocation information is not an error, as with other
            // platform verifiers.
            dwFlags: CERT_CHAIN_POLICY_IGNORE_ALL_REV_UNKNOWN_FLAGS,
            pvExtraPolicyPara: NonNull::from(&mut extra).cast::<c_void>().as_ptr(),
        };

        // An input/output structure: the caller sets its size.
        let mut status = CERT_CHAIN_POLICY_STATUS {
            cbSize: dword_size_of::<CERT_CHAIN_POLICY_STATUS>(),
            ..Default::default()
        };
        // SAFETY: per the CertVerifyCertificateChainPolicy docs the call reads
        // the chain, `params` and (for `CERT_CHAIN_POLICY_SSL`) the
        // `HTTPSPolicyCallbackData` it points to, with its NUL-terminated
        // server name, and writes `*status`; it returns synchronously. The
        // chain is live (field invariant); `params`, `extra` and
        // `server_name` are live locals with sizes set; `status` is a live,
        // writable local.
        let res = unsafe {
            CertVerifyCertificateChainPolicy(
                CERT_CHAIN_POLICY_SSL,
                self.0.as_ptr(),
                &raw const params,
                &raw mut status,
            )
        };
        if res != TRUE {
            return Err(PlatformVerifyError::new(
                PlatformVerifyErrorKind::Unavailable,
            ));
        }
        Ok(status)
    }

    /// The built path of the first simple chain, leaf first.
    ///
    /// The structures reached here belong to the chain context: per the
    /// `CERT_CHAIN_CONTEXT`, `CERT_SIMPLE_CHAIN`, `CERT_CHAIN_ELEMENT` and
    /// `CERT_CONTEXT` docs, `rgpChain` is an array of `cChain` simple-chain
    /// pointers, `rgpElement` an array of `cElement` element pointers, and
    /// `pbCertEncoded` holds `cbCertEncoded` bytes, all initialized C data
    /// that lives, unmodified, as long as the context (borrowed for `self`).
    fn certificates(&self) -> Vec<CertificateDer<'static>> {
        let context = self.context();
        if context.cChain == 0 || context.rgpChain.is_null() {
            return Vec::new();
        }
        // SAFETY: a place read needs `rgpChain` aligned, readable and
        // initialized for one pointer: it is non-null and holds `cChain > 0`
        // entries (chain context data, see above).
        let first = unsafe { *context.rgpChain };
        // SAFETY: `as_ref` needs null or an aligned pointer to an initialized,
        // unmutated `CERT_SIMPLE_CHAIN` for the borrow: chain context data.
        let Some(simple) = (unsafe { first.as_ref() }) else {
            return Vec::new();
        };
        if simple.rgpElement.is_null() {
            return Vec::new();
        }
        // SAFETY: `from_raw_parts` needs a non-null, aligned pointer to
        // `cElement` initialized pointers in one allocation, unmutated for the
        // borrow, within `isize::MAX` bytes: chain context data, non-null
        // checked above, and the array is one live allocation.
        let elements =
            unsafe { slice::from_raw_parts(simple.rgpElement, simple.cElement as usize) };
        elements
            .iter()
            // SAFETY: as for `first`, for a `CERT_CHAIN_ELEMENT`.
            .filter_map(|element| unsafe { element.as_ref() })
            // SAFETY: as for `first`, for a `CERT_CONTEXT`.
            .filter_map(|element| unsafe { element.pCertContext.as_ref() })
            .filter(|certificate| !certificate.pbCertEncoded.is_null())
            .map(|certificate| {
                // SAFETY: as for `elements`, for the `cbCertEncoded` bytes at
                // the non-null `pbCertEncoded`; the slice is copied at once.
                let der = unsafe {
                    slice::from_raw_parts(
                        certificate.pbCertEncoded,
                        certificate.cbCertEncoded as usize,
                    )
                };
                CertificateDer::from(der.to_vec())
            })
            .collect()
    }
}

impl Drop for CertChain {
    fn drop(&mut self) {
        // SAFETY: `CertFreeCertificateChain` frees a chain context once; by
        // the field invariant `self` owns it and `drop` runs once, after the
        // last borrow from `context()`.
        unsafe { CertFreeCertificateChain(self.0.as_ptr()) }
    }
}

/// A certificate context inside a [`CertificateStore`].
struct Certificate(
    // Safety invariant: a certificate context returned by
    // `CertAddEncodedCertificateToStore`, owning one reference that `Drop`
    // releases.
    NonNull<CERT_CONTEXT>,
);

impl Certificate {
    fn set_ocsp_response(&mut self, response: &[u8]) -> Result<(), PlatformVerifyError> {
        let blob = CRYPT_INTEGER_BLOB {
            cbData: response.len().try_into().map_err(|err| {
                PlatformVerifyError::with_source(PlatformVerifyErrorKind::BadEncoding, err)
            })?,
            pbData: response.as_ptr().cast_mut(),
        };
        // SAFETY: per the CertSetCertificateContextProperty docs, for
        // `CERT_OCSP_RESPONSE_PROP_ID` `pvData` points to a
        // `CRYPT_DATA_BLOB` (an alias of `CRYPT_INTEGER_BLOB`) whose bytes the
        // call copies before returning. The context is live (field
        // invariant); `blob` is a live local naming `response`, readable for
        // `cbData` bytes, and the call does not write through it.
        let res = unsafe {
            CertSetCertificateContextProperty(
                self.0.as_ptr(),
                CERT_OCSP_RESPONSE_PROP_ID,
                CERT_SET_PROPERTY_IGNORE_PERSIST_ERROR_FLAG,
                NonNull::from(&blob).cast::<c_void>().as_ptr(),
            )
        };
        if res == TRUE {
            Ok(())
        } else {
            Err(last_os_error(PlatformVerifyErrorKind::Other))
        }
    }
}

impl Drop for Certificate {
    fn drop(&mut self) {
        // SAFETY: `CertFreeCertificateContext` releases one reference; by the
        // field invariant `self` owns one and `drop` runs once.
        unsafe { CertFreeCertificateContext(self.0.as_ptr()) };
    }
}

/// An in-memory certificate store.
///
/// Opened with `CERT_STORE_DEFER_CLOSE_UNTIL_LAST_FREE_FLAG`, so certificate
/// contexts created from it may outlive it.
struct CertificateStore(
    // Safety invariant: a store handle returned by `CertOpenStore`, owned by
    // `self` and closed only by `Drop`.
    NonNull<c_void>,
);

impl CertificateStore {
    fn new() -> Result<Self, PlatformVerifyError> {
        // SAFETY: per the CertOpenStore docs `CERT_STORE_PROV_MEMORY` takes no
        // encoding type, crypt provider or `pvPara` (null), so the call reads
        // no caller memory; it returns a new handle or null, checked below.
        let store = unsafe {
            CertOpenStore(
                CERT_STORE_PROV_MEMORY,
                0,
                0,
                CERT_STORE_DEFER_CLOSE_UNTIL_LAST_FREE_FLAG,
                ptr::null(),
            )
        };
        NonNull::new(store)
            .map(Self)
            .ok_or_else(|| last_os_error(PlatformVerifyErrorKind::Other))
    }

    fn add_cert(&mut self, der: &[u8]) -> Result<Certificate, PlatformVerifyError> {
        let mut context: *mut CERT_CONTEXT = ptr::null_mut();
        let len = der.len().try_into().map_err(|err| {
            PlatformVerifyError::with_source(PlatformVerifyErrorKind::BadEncoding, err)
        })?;
        // SAFETY: per the CertAddEncodedCertificateToStore docs the call reads
        // `cbCertEncoded` bytes at `pbCertEncoded` and writes a new context
        // (one reference owned by the caller) to `*ppCertContext`. The store
        // is live (field invariant); `der` is readable for `len` bytes (`len`
        // is its length); `context` is a live, writable local.
        let res = unsafe {
            CertAddEncodedCertificateToStore(
                self.0.as_ptr(),
                X509_ASN_ENCODING,
                der.as_ptr(),
                len,
                CERT_STORE_ADD_ALWAYS,
                &raw mut context,
            )
        };
        match (res, NonNull::new(context)) {
            // Upholds the `Certificate` invariant: a context from a successful call.
            (TRUE, Some(context)) => Ok(Certificate(context)),
            _ => Err(PlatformVerifyError::new(
                PlatformVerifyErrorKind::BadEncoding,
            )),
        }
    }

    fn build_chain(
        &self,
        leaf: &Certificate,
        now: SystemTime,
        engine: Option<&CertEngine>,
    ) -> Result<CertChain, PlatformVerifyError> {
        let parameters = CERT_CHAIN_PARA {
            cbSize: dword_size_of::<CERT_CHAIN_PARA>(),
            RequestedUsage: CERT_USAGE_MATCH {
                dwType: USAGE_MATCH_TYPE_AND,
                Usage: CTL_USAGE {
                    cUsageIdentifier: ALLOWED_EKUS.len() as u32,
                    rgpszUsageIdentifier: ALLOWED_EKUS.as_ptr().cast_mut().cast(),
                },
            },
            // Below the 15s default: fetches are for revocation and intermediates.
            dwUrlRetrievalTimeout: 10_000,
            ..Default::default()
        };

        // Revocation is checked for the leaf only, network time is bounded
        // across all fetches, and repeated connections reuse the cached leaf.
        const FLAGS: u32 = CERT_CHAIN_REVOCATION_CHECK_END_CERT
            | CERT_CHAIN_REVOCATION_ACCUMULATIVE_TIMEOUT
            | CERT_CHAIN_CACHE_END_CERT;

        let time = filetime(now)?;
        let mut chain = ptr::null_mut();
        // SAFETY: per the CertGetCertificateChain docs the call reads the
        // engine (null: the default engine), the leaf context, `*pTime`, the
        // additional store and `*pChainPara` (with the usage OIDs it names),
        // and writes a new chain context to `*ppChainContext`, returning
        // synchronously. The engine, leaf and store are live (their field
        // invariants, borrowed for the call); `time`, `parameters` and `chain`
        // are live locals; `ALLOWED_EKUS` is a static array of NUL-terminated
        // OID strings that the call only reads.
        let res = unsafe {
            CertGetCertificateChain(
                engine.map_or(ptr::null_mut(), |engine| engine.engine.as_ptr()),
                leaf.0.as_ptr(),
                &raw const time,
                self.0.as_ptr(),
                &raw const parameters,
                FLAGS,
                ptr::null_mut(),
                &raw mut chain,
            )
        };
        match NonNull::new(chain) {
            // Upholds the `CertChain` invariant: a context from a successful call.
            Some(chain) if res == TRUE => Ok(CertChain(chain)),
            _ => Err(last_os_error(PlatformVerifyErrorKind::Other)),
        }
    }
}

impl Drop for CertificateStore {
    fn drop(&mut self) {
        // SAFETY: `CertCloseStore` closes a handle once; by the field
        // invariant `self` owns it and `drop` runs once. With
        // `CERT_STORE_DEFER_CLOSE_UNTIL_LAST_FREE_FLAG` contexts and engines
        // still using the store keep it open.
        unsafe { CertCloseStore(self.0.as_ptr(), 0) };
    }
}

/// A chain engine that trusts additional roots.
///
/// Neither `Send` nor `Sync`: CryptoAPI documents no thread-safety for chain
/// engines, so each one stays on the thread that creates it.
struct CertEngine {
    // Safety invariant: an engine returned by
    // `CertCreateCertificateChainEngine`, owned by `self` and freed only by
    // `Drop`; its `hExclusiveRoot` is `_roots`.
    engine: NonNull<c_void>,
    // Safety invariant: open at least until `engine` is freed. `Drop` frees
    // the engine before fields drop, so this store closes after it.
    _roots: CertificateStore,
}

impl CertEngine {
    fn try_with_extra_roots(
        roots: &[CertificateDer<'static>],
    ) -> Result<Self, PlatformVerifyError> {
        let mut roots_store = CertificateStore::new()?;
        for root in roots {
            roots_store.add_cert(root)?;
        }

        // `dwExclusiveFlags` stays 0: only self-signed certificates anchor, as Windows trust does.
        let config = CERT_CHAIN_ENGINE_CONFIG {
            cbSize: dword_size_of::<CERT_CHAIN_ENGINE_CONFIG>(),
            hExclusiveRoot: roots_store.0.as_ptr(),
            ..Default::default()
        };

        let mut engine: HCERTCHAINENGINE = ptr::null_mut();
        // SAFETY: per the CertCreateCertificateChainEngine docs the call reads
        // `*pConfig` (its `cbSize` gives the layout) and writes a new engine
        // to `*phChainEngine`. `config` is a live local whose only handle,
        // `hExclusiveRoot`, is the live `roots_store`; `engine` is a live,
        // writable local.
        let res = unsafe { CertCreateCertificateChainEngine(&raw const config, &raw mut engine) };
        match NonNull::new(engine) {
            // Upholds both field invariants: a new engine using `roots_store`,
            // which moves into the same value.
            Some(engine) if res == TRUE => Ok(Self {
                engine,
                _roots: roots_store,
            }),
            _ => Err(last_os_error(PlatformVerifyErrorKind::Other)),
        }
    }
}

impl Drop for CertEngine {
    fn drop(&mut self) {
        // SAFETY: `CertFreeCertificateChainEngine` frees an engine once; by
        // the field invariant `self` owns it and `drop` runs once. `_roots`
        // is still open here.
        unsafe { CertFreeCertificateChainEngine(self.engine.as_ptr()) };
    }
}

pub(super) struct Verifier {
    /// Roots for a per-verification [`CertEngine`]; never empty.
    extra_roots: Option<Box<[CertificateDer<'static>]>>,
}

impl Verifier {
    pub(super) fn new() -> Self {
        Self { extra_roots: None }
    }

    pub(super) fn try_with_extra_roots(
        roots: &[CertificateDer<'static>],
    ) -> Result<Self, BoxError> {
        // Reject unusable roots now rather than at every verification.
        drop(CertEngine::try_with_extra_roots(roots)?);
        Ok(Self {
            extra_roots: Some(roots.into()),
        })
    }

    pub(super) fn verify_server_chain(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        server_name: &str,
        ocsp_response: Option<&[u8]>,
        now: SystemTime,
    ) -> Result<Vec<CertificateDer<'static>>, PlatformVerifyError> {
        let mut store = CertificateStore::new()?;
        let mut leaf = store.add_cert(end_entity)?;
        for intermediate in intermediates {
            store.add_cert(intermediate)?;
        }
        if let Some(response) = ocsp_response {
            leaf.set_ocsp_response(response)?;
        }

        // Declared before `chain` so it is dropped after the chain built
        // with it.
        let engine;
        let mut chain = store.build_chain(&leaf, now, None)?;
        // The system roots come first; additional roots only rescue a chain
        // the system could not complete.
        if let Some(roots) = &self.extra_roots
            && chain.trust_error_status()
                & (CERT_TRUST_IS_PARTIAL_CHAIN | CERT_TRUST_IS_UNTRUSTED_ROOT)
                != 0
        {
            engine = CertEngine::try_with_extra_roots(roots)?;
            chain = store.build_chain(&leaf, now, Some(&engine))?;
        }

        let status = chain.verify_ssl_policy(server_name)?;
        if status.dwError == 0 {
            return Ok(chain.certificates());
        }

        let kind = match status.dwError as i32 {
            CERT_E_CN_NO_MATCH | CERT_E_INVALID_NAME => PlatformVerifyErrorKind::NotValidForName,
            CRYPT_E_REVOKED => PlatformVerifyErrorKind::Revoked,
            CERT_E_EXPIRED => PlatformVerifyErrorKind::Expired,
            CERT_E_UNTRUSTEDROOT => PlatformVerifyErrorKind::UnknownIssuer,
            CERT_E_WRONG_USAGE => PlatformVerifyErrorKind::InvalidPurpose,
            _ => PlatformVerifyErrorKind::Other,
        };
        Err(PlatformVerifyError::with_source(
            kind,
            std::io::Error::from_raw_os_error(status.dwError as i32),
        ))
    }
}

fn filetime(now: SystemTime) -> Result<FILETIME, PlatformVerifyError> {
    let since_unix = now
        .duration_since(UNIX_EPOCH)
        .map_err(|err| PlatformVerifyError::with_source(PlatformVerifyErrorKind::Other, err))?;
    // `FILETIME` counts 100ns intervals.
    let intervals = since_unix
        .as_secs()
        .checked_add(FILETIME_UNIX_OFFSET_SECS)
        .and_then(|secs| secs.checked_mul(10_000_000))
        .and_then(|ticks| ticks.checked_add(u64::from(since_unix.subsec_nanos() / 100)))
        .ok_or_else(|| PlatformVerifyError::new(PlatformVerifyErrorKind::Other))?;
    Ok(FILETIME {
        dwLowDateTime: intervals as u32,
        dwHighDateTime: (intervals >> 32) as u32,
    })
}
