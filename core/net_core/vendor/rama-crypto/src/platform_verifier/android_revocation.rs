//! Android 的 API 等级不保证证书提供者实现了可选的撤销检查接口。

use jni::{Env, jni_sig, jni_str, objects::{JObject, JValue}};

/// 只校验叶子证书的装订响应：不软失败，也不回退到联网取 CRL。
pub(super) fn configure_revocation_checker(
    env: &mut Env<'_>,
    checker: &JObject<'_>,
) -> jni::errors::Result<()> {
    let class = jni_str!("java/security/cert/PKIXRevocationChecker$Option");
    let options = env.new_object(jni_str!("java/util/HashSet"), jni_sig!("()V"), &[])?;
    for name in [jni_str!("ONLY_END_ENTITY"), jni_str!("NO_FALLBACK")] {
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
