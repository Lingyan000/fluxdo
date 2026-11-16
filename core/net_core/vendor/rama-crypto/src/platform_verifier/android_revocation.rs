//! Android 的 API 等级不保证证书提供者实现了可选的撤销检查接口。

use jni::{Env, jni_sig, jni_str, objects::JObject};

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
