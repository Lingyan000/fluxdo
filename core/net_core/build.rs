//! Build script: 确保 CA 证书在编译前存在
//!
//! cert.rs 通过 include_str! 在编译时嵌入 certs/ca.crt 和 certs/ca.key。
//! 如果证书文件不存在（首次 clone 或 CI 环境），自动生成占位证书。
//!
//! 注意：这里生成的是编译时默认证书。生产构建应通过
//! `cargo run --bin gen_ca` 或 CI 流程在编译前生成正式证书。

use std::fs;
use std::path::Path;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=certs/ca.crt");
    println!("cargo:rerun-if-changed=certs/ca.key");
    println!("cargo:rerun-if-changed=certs/ca.der");

    // 安卓静态链接 C++ 运行库（见 .cargo/config.toml）：NDK 把它拆成 libc++_static.a 与
    // libc++abi.a，BoringSSL 只声明了前者，异常与类型信息符号在后者里，这里补上。
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android") {
        println!("cargo:rustc-link-lib=c++abi");
    }

    let cert_file = Path::new("certs/ca.crt");
    let key_file = Path::new("certs/ca.key");

    if cert_file.exists() && key_file.exists() {
        return;
    }

    eprintln!("CA certificates not found, generating via gen_ca...");

    // gen_ca 是同一 crate 的 bin target，但 build.rs 阶段不能 cargo run（会递归）。
    // 改用 rustc 直接编译并运行 gen_ca.rs。
    // 但 gen_ca.rs 依赖 doh_proxy lib（也就是当前 crate），同样会循环依赖。
    //
    // 最简单的方案：用 openssl CLI 生成证书。
    // openssl 在 CI runners 和大多数开发机上都可用。
    fs::create_dir_all("certs").expect("Failed to create certs directory");

    let openssl_status = Command::new("openssl")
        .args([
            "req",
            "-x509",
            "-newkey",
            "ec",
            "-pkeyopt",
            "ec_paramgen_curve:prime256v1",
            "-keyout",
            "certs/ca.key",
            "-out",
            "certs/ca.crt",
            "-days",
            "3650",
            "-nodes",
            "-subj",
            "/CN=DOH Proxy CA/O=DOH Proxy/C=CN",
        ])
        .status();

    match openssl_status {
        Ok(s) if s.success() => {
            // 生成 DER 格式
            let _ = Command::new("openssl")
                .args([
                    "x509",
                    "-in",
                    "certs/ca.crt",
                    "-outform",
                    "DER",
                    "-out",
                    "certs/ca.der",
                ])
                .status();

            // 生成 assets PEM（如果 assets 目录存在）
            let assets_dir = Path::new("../../assets/certs");
            if assets_dir.exists() || fs::create_dir_all(assets_dir).is_ok() {
                let _ = fs::copy("certs/ca.crt", assets_dir.join("proxy_ca.pem"));
            }

            // 复制 DER 到 Android res/raw（network_security_config.xml 引用）
            let android_raw_dir = Path::new("../../android/app/src/main/res/raw");
            if android_raw_dir.exists() || fs::create_dir_all(android_raw_dir).is_ok() {
                let _ = fs::copy("certs/ca.der", android_raw_dir.join("proxy_ca.der"));
            }

            eprintln!("CA certificates generated successfully via openssl.");
        }
        _ => {
            panic!(
                "Failed to generate CA certificates. Please run `cargo run --bin gen_ca` \
                 manually, or ensure openssl is available in PATH."
            );
        }
    }
}
