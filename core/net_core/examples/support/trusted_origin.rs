//! 诊断专用受信任入口；只允许显式配置当前 tailnet 节点，不改变生产监听器。
use rama::error::BoxError;
use rama::tls::server::ServerAuthData;
use rama_crypto::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
use serde::Deserialize;
use std::{net::Ipv4Addr, path::PathBuf};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TrustedOrigin {
    pub hostname: String,
    pub address: Ipv4Addr,
    pub certificate: PathBuf,
    pub private_key: PathBuf,
}

impl TrustedOrigin {
    pub fn load() -> Result<Option<Self>, BoxError> {
        let Some(path) = std::env::var_os("FLUXDO_TRUSTED_PROBE_CONFIG") else { return Ok(None) };
        let value: Self = serde_json::from_slice(&std::fs::read(path)?)?;
        value.validate()?;
        Ok(Some(value))
    }

    fn validate(&self) -> Result<(), BoxError> {
        let labels: Vec<_> = self.hostname.split('.').collect();
        let label_valid = |s: &str| !s.is_empty() && s.len() <= 63
            && s.bytes().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
            && !s.starts_with('-') && !s.ends_with('-');
        if labels.len() != 4 || labels[2..] != ["ts", "net"]
            || !labels[..2].iter().all(|s| label_valid(s)) {
            return Err("expected exact node.tailnet.ts.net hostname".into());
        }
        let octets = self.address.octets();
        if octets[0] != 100 || !(64..=127).contains(&octets[1]) {
            return Err("trusted probe must bind a tailnet IPv4 address".into());
        }
        Ok(())
    }

    pub fn identity(&self) -> Result<ServerAuthData, BoxError> {
        let certs = CertificateDer::pem_file_iter(&self.certificate)?.collect::<Result<Vec<_>, _>>()?;
        if certs.is_empty() { return Err("empty certificate chain".into()); }
        let key = PrivateKeyDer::from_pem_file(&self.private_key)?;
        Ok(ServerAuthData::new(certs, key))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exact_tailnet_origin_and_address_only() {
        let mut value = TrustedOrigin { hostname: "node.tailnet.ts.net".into(), address: "100.64.0.1".parse().unwrap(), certificate: "cert".into(), private_key: "key".into() };
        assert!(value.validate().is_ok());
        for host in ["example.com", "node.tailnet.ts.net.evil", "-node.tailnet.ts.net", "node.tailnet.ts.net:443", "node..ts.net", "node/evil.tailnet.ts.net"] {
            value.hostname = host.into();
            assert!(value.validate().is_err(), "{host}");
        }
        value.hostname = "node.tailnet.ts.net".into();
        for address in ["0.0.0.0", "127.0.0.1", "100.63.255.255", "100.128.0.0"] {
            value.address = address.parse().unwrap();
            assert!(value.validate().is_err(), "{address}");
        }
    }
}
