//! 生成 MITM 用的 CA 证书：`cargo run --bin gen_ca`
//!
//! 产物同时同步到 Flutter 资源与 Android res/raw（network_security_config.xml 引用）。

use std::fs;
use std::path::Path;

use rama::tls::boring::core::x509::X509;

fn main() {
    println!("Generating CA certificate for FluxDO network core...");

    let (cert_pem, key_pem) = fluxdo_net::cert::generate_ca_pem().expect("Failed to generate CA");

    let certs_dir = Path::new("certs");
    fs::create_dir_all(certs_dir).expect("Failed to create certs directory");

    let cert_path = certs_dir.join("ca.crt");
    fs::write(&cert_path, &cert_pem).expect("Failed to write CA certificate");
    println!("CA certificate written to: {}", cert_path.display());

    let key_path = certs_dir.join("ca.key");
    fs::write(&key_path, &key_pem).expect("Failed to write CA key");
    println!("CA private key written to: {}", key_path.display());

    // Android 的 network_security_config.xml 只认 DER
    let der = X509::from_pem(cert_pem.as_bytes())
        .and_then(|cert| cert.to_der())
        .expect("Failed to encode CA certificate as DER");
    let der_path = certs_dir.join("ca.der");
    fs::write(&der_path, &der).expect("Failed to write CA DER");
    println!("CA certificate (DER) written to: {}", der_path.display());

    let assets_dir = Path::new("../../assets/certs");
    fs::create_dir_all(assets_dir).expect("Failed to create assets/certs directory");
    let assets_pem_path = assets_dir.join("proxy_ca.pem");
    fs::write(&assets_pem_path, &cert_pem).expect("Failed to write assets PEM");
    println!(
        "CA certificate (PEM) written to: {}",
        assets_pem_path.display()
    );

    let android_raw_dir = Path::new("../../android/app/src/main/res/raw");
    fs::create_dir_all(android_raw_dir).expect("Failed to create android res/raw directory");
    let android_der_path = android_raw_dir.join("proxy_ca.der");
    fs::write(&android_der_path, &der).expect("Failed to write android DER");
    println!(
        "CA certificate (DER) written to: {}",
        android_der_path.display()
    );

    println!("\nDone.");
}
