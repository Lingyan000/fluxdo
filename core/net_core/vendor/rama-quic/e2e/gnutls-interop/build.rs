fn main() {
    println!("cargo:rerun-if-changed=native/bridge.c");
    println!("cargo:rerun-if-env-changed=GNUTLS_DIR");
    let mut build = cc::Build::new();
    if let Some(prefix) = std::env::var_os("GNUTLS_DIR") {
        let prefix = std::path::PathBuf::from(prefix);
        build.include(prefix.join("include"));
        println!(
            "cargo:rustc-link-search=native={}",
            prefix.join("lib").display()
        );
        println!("cargo:rustc-link-lib=gnutls");
    } else {
        let library = pkg_config::Config::new()
            .atleast_version("3.7.2")
            .probe("gnutls")
            .expect("install GnuTLS development headers, or set GNUTLS_DIR to its prefix");
        for directory in library.include_paths {
            build.include(directory);
        }
    }
    build
        .file("native/bridge.c")
        .warnings(true)
        .extra_warnings(true)
        .flag_if_supported("-std=c11")
        .flag_if_supported("-Werror")
        .compile("quic_gnutls_bridge");
}
