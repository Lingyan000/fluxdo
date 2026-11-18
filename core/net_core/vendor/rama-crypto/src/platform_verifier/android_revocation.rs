//! Android 的 API 等级不保证证书提供者实现了可选的撤销检查接口。

use jni::{Env, jni_sig, jni_str, objects::{JObject, JValue}};

/// 无 OCSP 入口时只检查 CRL，避免提供者把“没有响应地址”当成硬失败。
/// CRL 的撤销结果仍会拒绝；缺少/无法获取 CRL 才由平台 SOFT_FAIL 处理。
/// 携带 staple 时必须严格校验它，不能回退到 CRL 或软失败。
pub(super) fn configure_revocation_checker(
    env: &mut Env<'_>,
    checker: &JObject<'_>,
    has_staple: bool,
    has_ocsp_responder: bool,
) -> jni::errors::Result<()> {
    let class = jni_str!("java/security/cert/PKIXRevocationChecker$Option");
    let options = env.new_object(jni_str!("java/util/HashSet"), jni_sig!("()V"), &[])?;
    for (name, enabled) in [
        (jni_str!("ONLY_END_ENTITY"), true),
        (jni_str!("SOFT_FAIL"), !has_staple),
        (jni_str!("NO_FALLBACK"), has_staple || !has_ocsp_responder),
        (jni_str!("PREFER_CRLS"), !has_staple && !has_ocsp_responder),
    ] {
        if !enabled {
            continue;
        }
        let option = env
            .get_static_field(
                class,
                name,
                jni_sig!("Ljava/security/cert/PKIXRevocationChecker$Option;"),
            )?
            .l()?;
        env.call_method(
            &options,
            jni_str!("add"),
            jni_sig!("(Ljava/lang/Object;)Z"),
            &[JValue::Object(&option)],
        )?
        .z()?;
    }
    env.call_method(
        checker,
        jni_str!("setOptions"),
        jni_sig!("(Ljava/util/Set;)V"),
        &[JValue::Object(&options)],
    )?
    .v()?;
    Ok(())
}

pub(super) enum RevocationChecker<'local> {
    Available(JObject<'local>),
    Unsupported,
}

pub(super) fn revocation_checker<'local>(
    env: &mut Env<'local>,
    validator: &JObject<'_>,
) -> jni::errors::Result<RevocationChecker<'local>> {
    let result = env.call_method(
        validator,
        jni_str!("getRevocationChecker"),
        jni_sig!("()Ljava/security/cert/CertPathChecker;"),
        &[],
    ).and_then(|value| value.l());
    match result {
        Ok(checker) => Ok(RevocationChecker::Available(checker)),
        Err(jni::errors::Error::JavaException) => {
            let thrown = env.exception_occurred().ok_or(jni::errors::Error::JavaException)?;
            env.exception_clear();
            if env.is_instance_of(&thrown, jni_str!("java/lang/UnsupportedOperationException"))? {
                Ok(RevocationChecker::Unsupported)
            } else {
                // 其他提供者异常必须保留给调用方，不能当成“不支持”忽略。
                env.throw(&thrown)?;
                Err(jni::errors::Error::JavaException)
            }
        }
        Err(err) => Err(err),
    }
}

/// 已通过系统校验的连接，只有未携带 staple 时才允许跳过不支持的补充检查。
pub(super) fn allow_unsupported_revocation(has_staple: bool) -> bool {
    !has_staple
}
