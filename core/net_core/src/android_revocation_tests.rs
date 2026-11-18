//! 在真实 JVM 上执行生产 JNI 分支，避免只模拟一个布尔能力标记。

use rama_crypto::ocsp::verify as native_ocsp;

#[path = "../vendor/rama-crypto/src/platform_verifier/android_revocation.rs"]
mod production;
#[path = "../vendor/rama-crypto/src/platform_verifier/android_ocsp.rs"]
mod native_bridge;

#[test]
fn optional_revocation_checker_distinguishes_unsupported_from_rejection() {
    use jni::{InitArgsBuilder, JavaVM, jni_sig, jni_str, objects::JValue};
    use production::{RevocationChecker, allow_unsupported_revocation, revocation_checker};

    let dir = std::env::temp_dir().join(format!("fluxdo-revocation-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let source = dir.join("RevocationFixture.java");
    std::fs::write(&source, include_str!("../tests/RevocationFixture.java")).unwrap();
    let status = std::process::Command::new("java").arg("com.sun.tools.javac.Main")
        .arg("-d").arg(&dir).arg(&source)
        .status().expect("JNI 回归需要包含编译器的 Java 运行时");
    assert!(status.success());
    let android_jar = std::env::var_os("FLUXDO_ANDROID_ALL");
    let classpath = std::env::join_paths(std::iter::once(dir.clone()).chain(android_jar.clone().map(std::path::PathBuf::from))).unwrap();
    let args = InitArgsBuilder::new()
        .option(format!("-Djava.class.path={}", classpath.to_string_lossy()))
        .build().unwrap();
    let vm = JavaVM::new(args).unwrap();
    vm.attach_current_thread(|env| -> jni::errors::Result<()> {
        for mode in [0, 1, 2].into_iter().chain(android_jar.is_some().then_some(3)) {
            let validator = env.call_static_method(
                jni_str!("RevocationFixture"), jni_str!("validator"),
                jni_sig!("(I)Ljava/security/cert/CertPathValidator;"), &[JValue::Int(mode)],
            )?.l()?;
            let result = revocation_checker(env, &validator);
            match mode {
                0 | 3 => {
                    assert!(matches!(result, Ok(RevocationChecker::Unsupported)));
                    assert!(!env.exception_check());
                    assert!(allow_unsupported_revocation(false));
                    assert!(!allow_unsupported_revocation(true), "携带 staple 必须验证，不能跳过");
                    let f = crate::ocsp_tests::fixtures();
                    let leaf_bytes = env.byte_array_from_slice(&f.leaf)?;
                    let issuer_bytes = env.byte_array_from_slice(&f.issuer)?;
                    let leaf = env.call_static_method(
                        jni_str!("RevocationFixture"), jni_str!("certificate"),
                        jni_sig!("([B)Ljava/security/cert/X509Certificate;"), &[JValue::Object(&leaf_bytes)],
                    )?.l()?;
                    let issuer = env.call_static_method(
                        jni_str!("RevocationFixture"), jni_str!("certificate"),
                        jni_sig!("([B)Ljava/security/cert/X509Certificate;"), &[JValue::Object(&issuer_bytes)],
                    )?.l()?;
                    for (name, response) in &f.responses {
                        let result = native_bridge::verify_staple(env, &leaf, &issuer, response, f.now)?;
                        assert_eq!(result, crate::ocsp_tests::expected(name), "真实 JNI 回退: {name}");
                        assert!(!env.exception_check());
                    }
                    eprintln!("JNI OCSP 验证完成: provider_mode={mode}, cases={}", f.responses.len());
                }
                1 => {
                    assert!(matches!(result, Err(jni::errors::Error::JavaException)));
                    let thrown = env.exception_occurred().unwrap();
                    env.exception_clear();
                    assert!(env.is_instance_of(&thrown, jni_str!("java/lang/SecurityException"))?);
                }
                _ => {
                    let Ok(RevocationChecker::Available(checker)) = result else {
                        panic!("支持的提供者必须继续使用其校验器");
                    };
                    assert!(!checker.is_null());
                    assert!(!env.exception_check());
                    check_available_provider_policy(env)?;
                }
            }
        }
        Ok(())
    }).unwrap();
    std::fs::remove_dir_all(dir).unwrap();
}

fn check_available_provider_policy(env: &mut jni::Env<'_>) -> jni::errors::Result<()> {
    use jni::{
        jni_sig, jni_str,
        objects::{JObject, JString, JValue},
    };
    use production::{RevocationChecker, configure_revocation_checker, revocation_checker};
    let f = crate::ocsp_tests::fixtures();
    // 第一项复现旧选项的同名异常，其余项执行修复后的生产 JNI 配置。
    for (name, has_ocsp, staple, crl, age, expected) in [
        (
            "旧策略复现",
            true,
            None,
            None,
            0,
            "UNSPECIFIED: Certificate does not specify OCSP responder",
        ),
        ("无撤销入口", false, None, None, 0, "OK"),
        ("有效 CRL", false, None, Some("valid"), 0, "OK"),
        ("CRL 已吊销", false, None, Some("revoked"), 0, "REVOKED:"),
        ("有效 staple", false, Some("good"), None, 0, "OK"),
        (
            "staple 已吊销",
            false,
            Some("revoked"),
            Some("valid"),
            0,
            "REVOKED:",
        ),
        (
            "staple 签名错误",
            false,
            Some("bad_signature"),
            Some("valid"),
            0,
            "!OK",
        ),
        (
            "staple 状态未知",
            false,
            Some("unknown"),
            Some("valid"),
            0,
            "!OK",
        ),
        (
            "staple 编码损坏",
            false,
            Some("truncated"),
            Some("valid"),
            0,
            "!OK",
        ),
        ("过期证书", false, None, None, 40 * 86400, "EXPIRED:"),
    ] {
        let validator = env
            .call_static_method(
                jni_str!("RevocationFixture"),
                jni_str!("validator"),
                jni_sig!("(I)Ljava/security/cert/CertPathValidator;"),
                &[JValue::Int(2)],
            )?
            .l()?;
        let RevocationChecker::Available(checker) = revocation_checker(env, &validator)? else {
            panic!("需要真实可用校验器");
        };
        configure_revocation_checker(env, &checker, staple.is_some(), has_ocsp)?;
        let leaf = env.byte_array_from_slice(&f.leaf)?;
        let issuer = env.byte_array_from_slice(&f.issuer)?;
        let response: JObject = match staple {
            Some(key) => env.byte_array_from_slice(&f.responses[key])?.into(),
            None => JObject::null(),
        };
        let crl: JObject = match crl {
            Some(key) => env.byte_array_from_slice(&f.crls[key])?.into(),
            None => JObject::null(),
        };
        let result = env
            .call_static_method(
                jni_str!("RevocationFixture"),
                jni_str!("validate"),
                jni_sig!("([B[BLjava/security/cert/PKIXRevocationChecker;[B[BJ)Ljava/lang/String;"),
                &[
                    JValue::Object(&leaf),
                    JValue::Object(&issuer),
                    JValue::Object(&checker),
                    JValue::Object(&response),
                    JValue::Object(&crl),
                    JValue::Long(f.now + age),
                ],
            )?
            .l()?;
        let result = env.cast_local::<JString>(result)?.try_to_string(env)?;
        eprintln!("PKIX {name}: {result}");
        if expected == "!OK" {
            assert_ne!(result, "OK", "{name}");
        } else {
            assert!(result.starts_with(expected), "{name}: {result}");
        }
    }
    Ok(())
}
