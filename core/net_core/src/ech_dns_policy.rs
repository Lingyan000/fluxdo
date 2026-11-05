//! 可配置的 Cloudflare 公共 ECH 入口策略。

use serde::{Deserialize, Serialize};

pub const CLOUDFLARE_ECH_QUERY_NAME: &str = "cloudflare-ech.com";
const BUILTIN_DOMAINS: [&str; 2] = ["linux.do", "ldstatic.com"];

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EchDnsPolicy {
    #[serde(default = "enabled_by_default")]
    pub enabled: bool,
    #[serde(default)]
    pub custom_domains: Vec<String>,
}

fn enabled_by_default() -> bool {
    true
}

impl Default for EchDnsPolicy {
    fn default() -> Self {
        Self {
            enabled: true,
            custom_domains: Vec::new(),
        }
    }
}

fn covers(domain: &str, host: &str) -> bool {
    host == domain
        || host
            .strip_suffix(domain)
            .is_some_and(|prefix| prefix.ends_with('.'))
}

impl EchDnsPolicy {
    pub fn normalized(mut self) -> Self {
        let mut domains = Vec::new();
        for value in self.custom_domains {
            let value = value.trim();
            let host = value
                .strip_suffix('.')
                .unwrap_or(value)
                .to_ascii_lowercase();
            let valid = host.len() <= 253
                && host.contains('.')
                && !host.bytes().all(|c| c.is_ascii_digit() || c == b'.')
                && host.split('.').all(|label| {
                    !label.is_empty()
                        && label.len() <= 63
                        && label.as_bytes()[0].is_ascii_alphanumeric()
                        && label.as_bytes()[label.len() - 1].is_ascii_alphanumeric()
                        && label
                            .bytes()
                            .all(|c| c.is_ascii_alphanumeric() || c == b'-')
                });
            if valid
                && !BUILTIN_DOMAINS.iter().any(|domain| covers(domain, &host))
                && !domains.contains(&host)
            {
                domains.push(host);
            }
        }
        self.custom_domains = domains;
        self
    }

    pub fn query_name<'a>(&self, domain: &'a str) -> &'a str {
        if !self.enabled {
            return domain;
        }
        let host = domain
            .strip_suffix('.')
            .unwrap_or(domain)
            .to_ascii_lowercase();
        if BUILTIN_DOMAINS.iter().any(|suffix| covers(suffix, &host))
            || self
                .custom_domains
                .iter()
                .any(|suffix| covers(suffix, &host))
        {
            CLOUDFLARE_ECH_QUERY_NAME
        } else {
            domain
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn custom_domains_include_subdomains_and_switch_disables_all_rules() {
        let mut policy = EchDnsPolicy {
            enabled: true,
            custom_domains: vec![
                " Example.COM. ".into(),
                "bad/path.com".into(),
                "127.0.0.1".into(),
                "cdn.linux.do".into(),
            ],
        }
        .normalized();
        assert_eq!(policy.custom_domains, vec!["example.com"]);
        assert_eq!(
            policy.query_name("CDN.EXAMPLE.COM."),
            CLOUDFLARE_ECH_QUERY_NAME
        );
        assert_eq!(policy.query_name("notexample.com"), "notexample.com");
        assert_eq!(
            policy.query_name("example.com.evil.net"),
            "example.com.evil.net"
        );
        policy.enabled = false;
        for host in ["linux.do", "cdn.ldstatic.com", "cdn.example.com"] {
            assert_eq!(policy.query_name(host), host);
        }
        assert_eq!(policy.custom_domains, vec!["example.com"]);
    }
}
