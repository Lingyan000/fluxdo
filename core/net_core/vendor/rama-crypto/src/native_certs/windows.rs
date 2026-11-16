use schannel::cert_context::ValidUses;
use schannel::cert_store::CertStore;

use super::CertificateResult;
use crate::pki_types::CertificateDer;

static PKIX_SERVER_AUTH: &str = "1.3.6.1.5.5.7.3.1";

type OpenStoreFn = for<'a> fn(&'a str) -> std::io::Result<CertStore>;

pub(super) fn load_native_certs() -> CertificateResult {
    let mut result = CertificateResult::default();

    // Read both the per-user and the local-machine ROOT stores. Reading
    // LOCAL_MACHINE in addition to CURRENT_USER matters:
    // enterprise/admin-installed roots typically live under LOCAL_MACHINE\ROOT,
    // which a per-user-only read would miss.
    const OPENERS: &[OpenStoreFn] = &[CertStore::open_current_user, CertStore::open_local_machine];
    // Omit CA: that Windows store contains intermediates, not trust anchors.
    const STORE_NAMES: &[&str] = &["ROOT"];

    for &open in OPENERS {
        for &store_name in STORE_NAMES {
            let store = match open(store_name) {
                Ok(store) => store,
                Err(err) => {
                    result.os_error(err.into(), "failed to open windows certificate store");
                    continue;
                }
            };

            for cert in store.certs() {
                let time_valid = cert.is_time_valid().unwrap_or_default();
                let tls_usable = cert.valid_uses().map(usable_for_tls).unwrap_or_default();
                if time_valid && tls_usable {
                    result
                        .certs
                        .push(CertificateDer::from(cert.to_der().to_vec()));
                }
            }
        }
    }

    // Dedup certs that appear in more than one store (e.g. user and machine).
    result.certs.sort_unstable_by(|a, b| a.cmp(b));
    result.certs.dedup();

    result
}

fn usable_for_tls(uses: ValidUses) -> bool {
    match uses {
        ValidUses::All => true,
        ValidUses::Oids(strs) => strs.iter().any(|x| x == PKIX_SERVER_AUTH),
    }
}
