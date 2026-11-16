//! 将平台已验证的叶子与签发者传给本地验签器；JNI 与本地校验均失败关闭。

use jni::{Env, jni_sig, jni_str, objects::JObject};

pub(super) fn verify_staple(
    env: &mut Env<'_>,
    leaf: &JObject<'_>,
    issuer: &JObject<'_>,
    response: &[u8],
    now: i64,
) -> jni::errors::Result<Result<(), super::native_ocsp::Error>> {
    let mut encoded = Vec::with_capacity(2);
    for cert in [leaf, issuer] {
        let bytes = env
            .call_method(cert, jni_str!("getEncoded"), jni_sig!("()[B"), &[])?
            .l()?;
        let bytes = env.cast_local::<jni::objects::JByteArray<'_>>(bytes)?;
        encoded.push(env.convert_byte_array(&bytes)?);
    }
    Ok(super::native_ocsp::verify_staple(
        response,
        &encoded[0],
        &encoded[1],
        now,
    ))
}
