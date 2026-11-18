//! Verification through the platform `X509TrustManager`, with direct JNI
//! calls so embedders do not ship an Android component.

use std::{
    ptr::NonNull,
    sync::OnceLock,
    time::{SystemTime, UNIX_EPOCH},
};

use jni::{
    Env, JavaVM, jni_sig, jni_str,
    objects::{Global, JByteArray, JObject, JThrowable, JValue},
};
use rama_core::error::{BoxError, BoxErrorExt as _};

use super::{PlatformVerifyError, PlatformVerifyErrorKind, name};
use crate::pki_types::CertificateDer;

#[path = "android_revocation.rs"]
mod revocation;
use revocation::{RevocationChecker, allow_unsupported_revocation, revocation_checker};

#[cfg(feature = "boring")]
use crate::ocsp::verify as native_ocsp;
#[cfg(feature = "boring")]
#[path = "android_ocsp.rs"]
mod native_bridge;

/// `id-kp-serverAuth`: a leaf that restricts its extended key usages must
/// allow server authentication.
const SERVER_AUTH_EKU: &str = "1.3.6.1.5.5.7.3.1";

/// Android's trust manager only uses the auth type for client certificates.
const AUTH_TYPE: &str = "RSA";

/// Android N: first release with `PKIXRevocationChecker`.
const REVOCATION_CHECKER_SDK: i32 = 24;

/// A trust manager and its root store (the Android store is for classification only).
struct TrustManager {
    extensions: Global<JObject<'static>>,
    key_store: Global<JObject<'static>>,
}

pub(super) struct Verifier {
    extra_roots: Vec<CertificateDer<'static>>,
    system: OnceLock<TrustManager>,
    extra: OnceLock<TrustManager>,
}

impl Verifier {
    pub(super) fn new() -> Self {
        Self {
            extra_roots: Vec::new(),
            system: OnceLock::new(),
            extra: OnceLock::new(),
        }
    }

    pub(super) fn try_with_extra_roots(
        roots: &[CertificateDer<'static>],
    ) -> Result<Self, BoxError> {
        Ok(Self {
            extra_roots: roots.to_vec(),
            ..Self::new()
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
        // Android's trust manager does not check names: that is done here.
        match name::leaf_matches(end_entity, server_name) {
            Some(true) => {}
            Some(false) => {
                return Err(PlatformVerifyError::new(
                    PlatformVerifyErrorKind::NotValidForName,
                ));
            }
            None => {
                return Err(PlatformVerifyError::new(
                    PlatformVerifyErrorKind::BadEncoding,
                ));
            }
        }

        let now_millis: i64 = now
            .duration_since(UNIX_EPOCH)
            .ok()
            .and_then(|since| since.as_millis().try_into().ok())
            .ok_or_else(|| PlatformVerifyError::new(PlatformVerifyErrorKind::Other))?;

        with_env(|env| {
            let factory = certificate_factory(env)?;
            let certificates = std::iter::once(end_entity)
                .chain(intermediates)
                .map(|der| generate_certificate(env, &factory, der))
                .collect::<Result<Vec<_>, _>>()?;
            let leaf = &certificates[0];

            check_validity(env, leaf, now_millis)?;
            check_server_auth_usage(env, leaf)?;

            let presented = certificate_array(env, &certificates)?;
            let system = cached_trust_manager(env, &self.system, None)?;
            let valid_chain = match check_server_trusted(env, system, &presented, server_name) {
                Ok(chain) => chain,
                Err(err)
                    if self.extra_roots.is_empty()
                        || err.kind() != PlatformVerifyErrorKind::UnknownIssuer =>
                {
                    return Err(err);
                }
                Err(_) => {
                    // Broken extra roots are a configuration error worth reporting.
                    let extra = cached_trust_manager(env, &self.extra, Some(&self.extra_roots))?;
                    // Never override an explicit platform rejection, including
                    // application Network Security Config pins or blocklists.
                    check_server_trusted(env, extra, &presented, server_name)?
                }
            };

            check_revocation(
                env,
                &factory,
                system,
                leaf,
                &valid_chain,
                ocsp_response,
                now_millis,
            ).map_err(|err| {
                rama_core::telemetry::tracing::warn!(
                    event = "tls_revocation_rejected",
                    stage = "supplementary_revocation",
                    stapled = ocsp_response.is_some(),
                    "Platform trust verification passed but supplementary revocation verification failed"
                );
                err
            })?;
            encoded_chain(env, &valid_chain)
        })
    }
}

/// The trust manager in `slot`, created on first success: a failure is retried
/// by the next verification instead of disabling the verifier for good.
fn cached_trust_manager<'slot>(
    env: &mut Env<'_>,
    slot: &'slot OnceLock<TrustManager>,
    roots: Option<&[CertificateDer<'static>]>,
) -> Result<&'slot TrustManager, PlatformVerifyError> {
    if let Some(trust) = slot.get() {
        return Ok(trust);
    }
    let trust = trust_manager(env, roots)?;
    Ok(slot.get_or_init(|| trust))
}

/// Run `f` on a thread attached to the process `JavaVM` from `ndk-context`.
fn with_env<T>(
    f: impl FnOnce(&mut Env<'_>) -> Result<T, PlatformVerifyError>,
) -> Result<T, PlatformVerifyError> {
    let context = std::panic::catch_unwind(ndk_context::android_context).map_err(|panic| {
        drop(panic);
        PlatformVerifyError::with_source(
            PlatformVerifyErrorKind::Unavailable,
            BoxError::from_static_str("Android context is not initialized"),
        )
    })?;
    let vm_ptr = NonNull::new(context.vm()).ok_or_else(|| {
        PlatformVerifyError::with_source(
            PlatformVerifyErrorKind::Unavailable,
            BoxError::from_static_str("Android context has a null JavaVM"),
        )
    })?;
    // SAFETY: `JavaVM::from_raw` needs a valid, non-null `JavaVM` pointer
    // supporting JNI >= 1.4. Non-null is checked above. The pointer was handed
    // to `ndk_context::initialize_android_context`, whose `# Safety` makes its
    // caller guarantee valid pointers; Android VMs support JNI 1.6 and are
    // never destroyed while the process runs. The wrapper does not own the VM.
    let vm = unsafe { JavaVM::from_raw(vm_ptr.as_ptr().cast()) };
    vm.attach_current_thread(f)
}

impl From<jni::errors::Error> for PlatformVerifyError {
    fn from(err: jni::errors::Error) -> Self {
        Self::with_source(PlatformVerifyErrorKind::Other, err)
    }
}

/// Turn a thrown Java exception into a cleared, inspectable throwable.
fn caught<'local, T>(
    env: &mut Env<'local>,
    result: jni::errors::Result<T>,
) -> Result<Result<T, JThrowable<'local>>, PlatformVerifyError> {
    match result {
        Ok(value) => Ok(Ok(value)),
        Err(jni::errors::Error::JavaException) => {
            let throwable = env.exception_occurred();
            env.exception_clear();
            throwable
                .map(Err)
                .ok_or_else(|| PlatformVerifyError::new(PlatformVerifyErrorKind::Other))
        }
        Err(err) => Err(err.into()),
    }
}

fn describe(env: &mut Env<'_>, throwable: &JThrowable<'_>) -> BoxError {
    let message = env
        .call_method(
            throwable,
            jni_str!("toString"),
            jni_sig!("()Ljava/lang/String;"),
            &[],
        )
        .and_then(|value| value.l())
        .and_then(|value| env.cast_local::<jni::objects::JString<'_>>(value))
        .and_then(|value| value.try_to_string(env));
    env.exception_clear();
    match message {
        Ok(message) => BoxError::from(message),
        Err(_) => BoxError::from_static_str("java exception"),
    }
}

/// The innermost cause of a throwable chain.
fn root_cause<'local>(
    env: &mut Env<'local>,
    throwable: JThrowable<'local>,
) -> Result<JThrowable<'local>, PlatformVerifyError> {
    let mut current = throwable;
    // Bounded: a malformed cause cycle must not hang the handshake.
    for _ in 0..16 {
        let cause = env
            .call_method(
                &current,
                jni_str!("getCause"),
                jni_sig!("()Ljava/lang/Throwable;"),
                &[],
            )?
            .l()?;
        if cause.is_null() || env.is_same_object(&cause, &current)? {
            break;
        }
        current = env.cast_local::<JThrowable<'_>>(cause)?;
    }
    Ok(current)
}

fn is_expiry(env: &mut Env<'_>, throwable: &JThrowable<'_>) -> Result<bool, PlatformVerifyError> {
    Ok(env.is_instance_of(
        throwable,
        jni_str!("java/security/cert/CertificateExpiredException"),
    )? || env.is_instance_of(
        throwable,
        jni_str!("java/security/cert/CertificateNotYetValidException"),
    )?)
}

fn new_string<'local>(
    env: &mut Env<'local>,
    value: &str,
) -> Result<JObject<'local>, PlatformVerifyError> {
    Ok(env.new_string(value)?.into())
}

fn certificate_factory<'local>(
    env: &mut Env<'local>,
) -> Result<JObject<'local>, PlatformVerifyError> {
    let kind = new_string(env, "X.509")?;
    Ok(env
        .call_static_method(
            jni_str!("java/security/cert/CertificateFactory"),
            jni_str!("getInstance"),
            jni_sig!("(Ljava/lang/String;)Ljava/security/cert/CertificateFactory;"),
            &[JValue::Object(&kind)],
        )?
        .l()?)
}

fn generate_certificate<'local>(
    env: &mut Env<'local>,
    factory: &JObject<'_>,
    der: &[u8],
) -> Result<JObject<'local>, PlatformVerifyError> {
    let bytes = env.byte_array_from_slice(der)?;
    let input = env.new_object(
        jni_str!("java/io/ByteArrayInputStream"),
        jni_sig!("([B)V"),
        &[JValue::Object(&bytes)],
    )?;
    let generated = env
        .call_method(
            factory,
            jni_str!("generateCertificate"),
            jni_sig!("(Ljava/io/InputStream;)Ljava/security/cert/Certificate;"),
            &[JValue::Object(&input)],
        )
        .and_then(|value| value.l());
    match caught(env, generated)? {
        Ok(certificate) if !certificate.is_null() => Ok(certificate),
        Ok(_) => Err(PlatformVerifyError::new(
            PlatformVerifyErrorKind::BadEncoding,
        )),
        Err(throwable) => Err(PlatformVerifyError::with_source(
            PlatformVerifyErrorKind::BadEncoding,
            describe(env, &throwable),
        )),
    }
}

fn check_validity(
    env: &mut Env<'_>,
    leaf: &JObject<'_>,
    now_millis: i64,
) -> Result<(), PlatformVerifyError> {
    let date = env.new_object(
        jni_str!("java/util/Date"),
        jni_sig!("(J)V"),
        &[JValue::Long(now_millis)],
    )?;
    let checked = env
        .call_method(
            leaf,
            jni_str!("checkValidity"),
            jni_sig!("(Ljava/util/Date;)V"),
            &[JValue::Object(&date)],
        )
        .and_then(|value| value.v());
    match caught(env, checked)? {
        Ok(()) => Ok(()),
        Err(throwable) => Err(PlatformVerifyError::with_source(
            PlatformVerifyErrorKind::Expired,
            describe(env, &throwable),
        )),
    }
}

fn check_server_auth_usage(
    env: &mut Env<'_>,
    leaf: &JObject<'_>,
) -> Result<(), PlatformVerifyError> {
    let usages = env
        .call_method(
            leaf,
            jni_str!("getExtendedKeyUsage"),
            jni_sig!("()Ljava/util/List;"),
            &[],
        )
        .and_then(|value| value.l());
    let usages = match caught(env, usages)? {
        // No extended key usage extension: any usage is allowed.
        Ok(usages) if usages.is_null() => return Ok(()),
        Ok(usages) => usages,
        Err(throwable) => {
            return Err(PlatformVerifyError::with_source(
                PlatformVerifyErrorKind::InvalidPurpose,
                describe(env, &throwable),
            ));
        }
    };
    let server_auth = new_string(env, SERVER_AUTH_EKU)?;
    let allowed = env
        .call_method(
            &usages,
            jni_str!("contains"),
            jni_sig!("(Ljava/lang/Object;)Z"),
            &[JValue::Object(&server_auth)],
        )?
        .z()?;
    if allowed {
        Ok(())
    } else {
        Err(PlatformVerifyError::new(
            PlatformVerifyErrorKind::InvalidPurpose,
        ))
    }
}

/// An `X509Certificate[]`, as required by `checkServerTrusted`.
fn certificate_array<'local>(
    env: &mut Env<'local>,
    certificates: &[JObject<'_>],
) -> Result<JObject<'local>, PlatformVerifyError> {
    let class = env.find_class(jni_str!("java/security/cert/X509Certificate"))?;
    let length = i32::try_from(certificates.len()).map_err(|err| {
        PlatformVerifyError::with_source(PlatformVerifyErrorKind::BadEncoding, err)
    })?;
    let array = env
        .call_static_method(
            jni_str!("java/lang/reflect/Array"),
            jni_str!("newInstance"),
            jni_sig!("(Ljava/lang/Class;I)Ljava/lang/Object;"),
            &[JValue::Object(&class), JValue::Int(length)],
        )?
        .l()?;
    for (index, certificate) in (0..length).zip(certificates) {
        env.call_static_method(
            jni_str!("java/lang/reflect/Array"),
            jni_str!("set"),
            jni_sig!("(Ljava/lang/Object;ILjava/lang/Object;)V"),
            &[
                JValue::Object(&array),
                JValue::Int(index),
                JValue::Object(certificate),
            ],
        )?
        .v()?;
    }
    Ok(array)
}

/// Create a trust manager for the system store, or for `roots` only.
fn trust_manager(
    env: &mut Env<'_>,
    roots: Option<&[CertificateDer<'static>]>,
) -> Result<TrustManager, PlatformVerifyError> {
    let key_store_type = match roots {
        None => new_string(env, "AndroidCAStore")?,
        Some(_) => env
            .call_static_method(
                jni_str!("java/security/KeyStore"),
                jni_str!("getDefaultType"),
                jni_sig!("()Ljava/lang/String;"),
                &[],
            )?
            .l()?,
    };
    let key_store = env
        .call_static_method(
            jni_str!("java/security/KeyStore"),
            jni_str!("getInstance"),
            jni_sig!("(Ljava/lang/String;)Ljava/security/KeyStore;"),
            &[JValue::Object(&key_store_type)],
        )
        .and_then(|value| value.l());
    let key_store = match caught(env, key_store)? {
        Ok(key_store) => key_store,
        Err(throwable) => {
            return Err(PlatformVerifyError::with_source(
                PlatformVerifyErrorKind::Unavailable,
                describe(env, &throwable),
            ));
        }
    };
    env.call_method(
        &key_store,
        jni_str!("load"),
        jni_sig!("(Ljava/security/KeyStore$LoadStoreParameter;)V"),
        &[JValue::Object(&JObject::null())],
    )?
    .v()?;

    if let Some(roots) = roots {
        let factory = certificate_factory(env)?;
        for (index, root) in roots.iter().enumerate() {
            let certificate = generate_certificate(env, &factory, root)?;
            let alias = new_string(env, &format!("rama_{index}"))?;
            env.call_method(
                &key_store,
                jni_str!("setCertificateEntry"),
                jni_sig!("(Ljava/lang/String;Ljava/security/cert/Certificate;)V"),
                &[JValue::Object(&alias), JValue::Object(&certificate)],
            )?
            .v()?;
        }
    }

    let algorithm = env
        .call_static_method(
            jni_str!("javax/net/ssl/TrustManagerFactory"),
            jni_str!("getDefaultAlgorithm"),
            jni_sig!("()Ljava/lang/String;"),
            &[],
        )?
        .l()?;
    let factory = env
        .call_static_method(
            jni_str!("javax/net/ssl/TrustManagerFactory"),
            jni_str!("getInstance"),
            jni_sig!("(Ljava/lang/String;)Ljavax/net/ssl/TrustManagerFactory;"),
            &[JValue::Object(&algorithm)],
        )?
        .l()?;
    // Null selects Android's application-aware default trust manager. Passing
    // AndroidCAStore here would replace Network Security Config with raw roots,
    // including user CAs that the application did not opt into trusting.
    let default_store = JObject::null();
    let manager_store = if roots.is_some() {
        &key_store
    } else {
        &default_store
    };
    env.call_method(
        &factory,
        jni_str!("init"),
        jni_sig!("(Ljava/security/KeyStore;)V"),
        &[JValue::Object(manager_store)],
    )?
    .v()?;
    let managers = env
        .call_method(
            &factory,
            jni_str!("getTrustManagers"),
            jni_sig!("()[Ljavax/net/ssl/TrustManager;"),
            &[],
        )?
        .l()?;
    let managers = env.cast_local::<jni::objects::JObjectArray<'_>>(managers)?;

    for index in 0..managers.len(env)? {
        let manager = managers.get_element(env, index)?;
        if manager.is_null()
            || !env.is_instance_of(&manager, jni_str!("javax/net/ssl/X509TrustManager"))?
        {
            continue;
        }
        let extensions = env.new_object(
            jni_str!("android/net/http/X509TrustManagerExtensions"),
            jni_sig!("(Ljavax/net/ssl/X509TrustManager;)V"),
            &[JValue::Object(&manager)],
        )?;
        return Ok(TrustManager {
            extensions: env.new_global_ref(&extensions)?,
            key_store: env.new_global_ref(&key_store)?,
        });
    }
    Err(PlatformVerifyError::new(
        PlatformVerifyErrorKind::Unavailable,
    ))
}

/// The chain the trust manager built for `presented`, as a `List`.
fn check_server_trusted<'local>(
    env: &mut Env<'local>,
    trust: &TrustManager,
    presented: &JObject<'_>,
    server_name: &str,
) -> Result<JObject<'local>, PlatformVerifyError> {
    let auth_type = new_string(env, AUTH_TYPE)?;
    let host = new_string(env, server_name)?;
    let chain = env
        .call_method(
            &trust.extensions,
            jni_str!("checkServerTrusted"),
            jni_sig!(
                "([Ljava/security/cert/X509Certificate;Ljava/lang/String;Ljava/lang/String;)Ljava/util/List;"
            ),
            &[
                JValue::Object(presented),
                JValue::Object(&auth_type),
                JValue::Object(&host),
            ],
        )
        .and_then(|value| value.l());
    match caught(env, chain)? {
        Ok(chain) if !chain.is_null() => Ok(chain),
        Ok(_) => Err(PlatformVerifyError::new(PlatformVerifyErrorKind::Other)),
        Err(throwable) => {
            let cause = root_cause(env, throwable)?;
            let kind = if is_expiry(env, &cause)? {
                PlatformVerifyErrorKind::Expired
            } else if is_missing_anchor(env, &cause)? {
                PlatformVerifyErrorKind::UnknownIssuer
            } else {
                PlatformVerifyErrorKind::Other
            };
            Err(PlatformVerifyError::with_source(
                kind,
                describe(env, &cause),
            ))
        }
    }
}

/// Conscrypt reports a missing trust anchor with this exact exception message.
/// Do not infer it from arbitrary CertificateExceptions: that could turn an
/// application pin rejection into permission to use the additional roots.
/// `CertPathValidatorException.getReason`/`PKIXReason` require API 24, while
/// this verifier also supports API 23.
fn is_missing_anchor(
    env: &mut Env<'_>,
    throwable: &JThrowable<'_>,
) -> Result<bool, PlatformVerifyError> {
    if !env.is_instance_of(
        throwable,
        jni_str!("java/security/cert/CertPathValidatorException"),
    )? {
        return Ok(false);
    }
    let message = env
        .call_method(
            throwable,
            jni_str!("getMessage"),
            jni_sig!("()Ljava/lang/String;"),
            &[],
        )?
        .l()?;
    if message.is_null() {
        return Ok(false);
    }
    let message = env
        .cast_local::<jni::objects::JString<'_>>(message)?
        .try_to_string(env)?;
    Ok(message == "Trust anchor for certification path not found.")
}

/// Ask the active Android store, which includes Conscrypt APEX updates and
/// excludes removed system roots. Reissued additional anchors are additional
/// roots unless their certificate is also present in the system store.
fn is_system_root(
    env: &mut Env<'_>,
    system: &TrustManager,
    root: &JObject<'_>,
) -> Result<bool, PlatformVerifyError> {
    let alias = env
        .call_method(
            &system.key_store,
            jni_str!("getCertificateAlias"),
            jni_sig!("(Ljava/security/cert/Certificate;)Ljava/lang/String;"),
            &[JValue::Object(root)],
        )?
        .l()?;
    if alias.is_null() {
        return Ok(false);
    }
    let alias = env
        .cast_local::<jni::objects::JString<'_>>(alias)?
        .try_to_string(env)?;
    Ok(alias.starts_with("system:"))
}

fn list_get<'local>(
    env: &mut Env<'local>,
    list: &JObject<'_>,
    index: i32,
) -> Result<JObject<'local>, PlatformVerifyError> {
    Ok(env
        .call_method(
            list,
            jni_str!("get"),
            jni_sig!("(I)Ljava/lang/Object;"),
            &[JValue::Int(index)],
        )?
        .l()?)
}

fn list_len(env: &mut Env<'_>, list: &JObject<'_>) -> Result<i32, PlatformVerifyError> {
    Ok(env
        .call_method(list, jni_str!("size"), jni_sig!("()I"), &[])?
        .i()?)
}

/// Check the leaf for revocation, soft-failing when no information is available.
///
/// Revocation is only fetched for chains ending at a system root: user-added
/// and additional roots usually belong to private PKIs without public
/// revocation endpoints. A stapled response is always checked.
fn check_revocation(
    env: &mut Env<'_>,
    factory: &JObject<'_>,
    system: &TrustManager,
    leaf: &JObject<'_>,
    valid_chain: &JObject<'_>,
    ocsp_response: Option<&[u8]>,
    now_millis: i64,
) -> Result<(), PlatformVerifyError> {
    let sdk = env
        .get_static_field(
            jni_str!("android/os/Build$VERSION"),
            jni_str!("SDK_INT"),
            jni_sig!("I"),
        )?
        .i()?;
    if sdk < REVOCATION_CHECKER_SDK {
        return Ok(());
    }

    let length = list_len(env, valid_chain)?;
    if length == 0 {
        return Err(PlatformVerifyError::new(
            PlatformVerifyErrorKind::UnknownIssuer,
        ));
    }
    // A single-certificate path has no authenticated issuer for this pass.
    if length == 1 {
        return Ok(());
    }
    let root = list_get(env, valid_chain, length - 1)?;
    if ocsp_response.is_none() && !is_system_root(env, system, &root)? {
        return Ok(());
    }

    let algorithm = new_string(env, "PKIX")?;
    let validator = env
        .call_static_method(
            jni_str!("java/security/cert/CertPathValidator"),
            jni_str!("getInstance"),
            jni_sig!("(Ljava/lang/String;)Ljava/security/cert/CertPathValidator;"),
            &[JValue::Object(&algorithm)],
        )?
        .l()?;
    let result = revocation_checker(env, &validator);
    let checker = match caught(env, result)? {
        Ok(RevocationChecker::Available(checker)) => checker,
        Ok(RevocationChecker::Unsupported)
            if allow_unsupported_revocation(ocsp_response.is_some()) =>
        {
            // TrustManager、名称、有效期和用途已校验成功；这里只跳过平台未实现的补充检查。
            rama_core::telemetry::tracing::warn!(
                event = "tls_revocation_check_unsupported",
                "Android certificate provider has no supplementary revocation checker; platform trust verification passed"
            );
            return Ok(());
        }
        Ok(RevocationChecker::Unsupported) => {
            #[cfg(feature = "boring")]
            {
                // 只接受平台已经构建的链中的签发者，响应附带证书不能充当信任锚点。
                let issuer = list_get(env, valid_chain, 1)?;
                let response = ocsp_response.expect("未携带 staple 的分支已提前处理");
                let result = native_bridge::verify_staple(env, leaf, &issuer, response, now_millis / 1000)?;
                if result.is_ok() {
                    rama_core::telemetry::tracing::debug!(
                        event = "tls_ocsp_native_verified",
                        "Android supplementary checker unavailable; OCSP staple verified locally"
                    );
                }
                return result.map_err(|err| PlatformVerifyError::with_source(
                    if err == native_ocsp::Error::Revoked { PlatformVerifyErrorKind::Revoked }
                    else { PlatformVerifyErrorKind::Other }, err,
                ));
            }
            #[cfg(not(feature = "boring"))]
            return Err(PlatformVerifyError::with_source(
                PlatformVerifyErrorKind::Other,
                BoxError::from_static_str("Android certificate provider cannot validate the supplied OCSP staple"),
            ));
        }
        Err(thrown) => {
            return Err(PlatformVerifyError::with_source(
                PlatformVerifyErrorKind::Other,
                describe(env, &thrown),
            ));
        }
    };

    let leaf_der = env.call_method(leaf, jni_str!("getEncoded"), jni_sig!("()[B"), &[])?.l()?;
    let leaf_der = env.cast_local::<JByteArray<'_>>(leaf_der)?;
    let has_ocsp_responder = crate::ocsp::certificate_has_ocsp_responder(
        &env.convert_byte_array(&leaf_der)?,
    ).map_err(|err| PlatformVerifyError::with_source(PlatformVerifyErrorKind::BadEncoding, err))?;
    revocation::configure_revocation_checker(env, &checker, ocsp_response.is_some(), has_ocsp_responder)?;
    if ocsp_response.is_none() && !has_ocsp_responder {
        rama_core::telemetry::tracing::info!(
            event = "tls_revocation_crl_only",
            "Platform trust verification passed; no OCSP responder advertised, checking CRLs with soft-fail for unavailable status"
        );
    }

    if let Some(response) = ocsp_response {
        let response: JByteArray<'_> = env.byte_array_from_slice(response)?;
        let responses = env.new_object(jni_str!("java/util/HashMap"), jni_sig!("()V"), &[])?;
        env.call_method(
            &responses,
            jni_str!("put"),
            jni_sig!("(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;"),
            &[JValue::Object(leaf), JValue::Object(&response)],
        )?
        .l()?;
        env.call_method(
            &checker,
            jni_str!("setOcspResponses"),
            jni_sig!("(Ljava/util/Map;)V"),
            &[JValue::Object(&responses)],
        )?
        .v()?;
    }

    // TrustManager already authenticated the entire chain. This supplementary
    // pass checks only leaf revocation, using its authenticated issuer as the
    // anchor. Conscrypt may append further trusted certificates after its first
    // anchor; revalidating that suffix would reject valid intermediate anchors.
    let issuer = list_get(env, valid_chain, 1)?;
    let anchor = env.new_object(
        jni_str!("java/security/cert/TrustAnchor"),
        jni_sig!("(Ljava/security/cert/X509Certificate;[B)V"),
        &[JValue::Object(&issuer), JValue::Object(&JObject::null())],
    )?;
    let anchors = env
        .call_static_method(
            jni_str!("java/util/Collections"),
            jni_str!("singleton"),
            jni_sig!("(Ljava/lang/Object;)Ljava/util/Set;"),
            &[JValue::Object(&anchor)],
        )?
        .l()?;
    let parameters = env.new_object(
        jni_str!("java/security/cert/PKIXParameters"),
        jni_sig!("(Ljava/util/Set;)V"),
        &[JValue::Object(&anchors)],
    )?;
    let date = env.new_object(
        jni_str!("java/util/Date"),
        jni_sig!("(J)V"),
        &[JValue::Long(now_millis)],
    )?;
    env.call_method(
        &parameters,
        jni_str!("setDate"),
        jni_sig!("(Ljava/util/Date;)V"),
        &[JValue::Object(&date)],
    )?
    .v()?;
    let checkers = env
        .call_static_method(
            jni_str!("java/util/Collections"),
            jni_str!("singletonList"),
            jni_sig!("(Ljava/lang/Object;)Ljava/util/List;"),
            &[JValue::Object(&checker)],
        )?
        .l()?;
    env.call_method(
        &parameters,
        jni_str!("setCertPathCheckers"),
        jni_sig!("(Ljava/util/List;)V"),
        &[JValue::Object(&checkers)],
    )?
    .v()?;
    // Only the configured checker runs, not the default revocation checks.
    env.call_method(
        &parameters,
        jni_str!("setRevocationEnabled"),
        jni_sig!("(Z)V"),
        &[JValue::Bool(false)],
    )?
    .v()?;

    let leaf_path = env
        .call_static_method(
            jni_str!("java/util/Collections"),
            jni_str!("singletonList"),
            jni_sig!("(Ljava/lang/Object;)Ljava/util/List;"),
            &[JValue::Object(leaf)],
        )?
        .l()?;
    let path = env
        .call_method(
            factory,
            jni_str!("generateCertPath"),
            jni_sig!("(Ljava/util/List;)Ljava/security/cert/CertPath;"),
            &[JValue::Object(&leaf_path)],
        )?
        .l()?;
    let validated = env
        .call_method(
            &validator,
            jni_str!("validate"),
            jni_sig!(
                "(Ljava/security/cert/CertPath;Ljava/security/cert/CertPathParameters;)Ljava/security/cert/CertPathValidatorResult;"
            ),
            &[JValue::Object(&path), JValue::Object(&parameters)],
        )
        .and_then(|value| value.l());
    match caught(env, validated)? {
        Ok(_) => Ok(()),
        Err(throwable) => {
            let mut kind = PlatformVerifyErrorKind::Other;
            if env.is_instance_of(
                &throwable,
                jni_str!("java/security/cert/CertPathValidatorException"),
            )? {
                let reason = env
                    .call_method(
                        &throwable,
                        jni_str!("getReason"),
                        jni_sig!("()Ljava/security/cert/CertPathValidatorException$Reason;"),
                        &[],
                    )?
                    .l()?;
                let revoked = env
                    .get_static_field(
                        jni_str!("java/security/cert/CertPathValidatorException$BasicReason"),
                        jni_str!("REVOKED"),
                        jni_sig!("Ljava/security/cert/CertPathValidatorException$BasicReason;"),
                    )?
                    .l()?;
                if env.is_same_object(&reason, &revoked)? {
                    kind = PlatformVerifyErrorKind::Revoked;
                }
            }
            let cause = root_cause(env, throwable)?;
            if env.is_instance_of(
                &cause,
                jni_str!("java/security/cert/CertificateRevokedException"),
            )? {
                kind = PlatformVerifyErrorKind::Revoked;
            } else if is_expiry(env, &cause)? {
                kind = PlatformVerifyErrorKind::Expired;
            }
            Err(PlatformVerifyError::with_source(
                kind,
                describe(env, &cause),
            ))
        }
    }
}

fn encoded_chain(
    env: &mut Env<'_>,
    chain: &JObject<'_>,
) -> Result<Vec<CertificateDer<'static>>, PlatformVerifyError> {
    let length = list_len(env, chain)?;
    let mut encoded = Vec::with_capacity(usize::try_from(length).unwrap_or_default());
    for index in 0..length {
        let certificate = list_get(env, chain, index)?;
        let der = env
            .call_method(&certificate, jni_str!("getEncoded"), jni_sig!("()[B"), &[])?
            .l()?;
        let der = env.cast_local::<JByteArray<'_>>(der)?;
        encoded.push(CertificateDer::from(env.convert_byte_array(&der)?));
    }
    Ok(encoded)
}
