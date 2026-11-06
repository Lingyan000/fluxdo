//! 有界的离线后备模板；只解析所选档位，不新增采样 WebView 或网络请求。
use crate::mirror::{FingerprintTemplate, TemplateSource};

struct Preset {
    id: &'static str,
    platform: &'static str,
    major: u16,
    json: &'static str,
}
macro_rules! preset {
    ($id:literal, $platform:literal, $major:literal) => {
        Preset {
            id: $id,
            platform: $platform,
            major: $major,
            json: include_str!(concat!("../presets/", $id, ".json")),
        }
    };
}
static PRESETS: &[Preset] = &[
    preset!("android-webview133", "android", 133),
    preset!("android-chrome149", "android", 149),
    preset!("ios-safari17", "ios", 17),
    preset!("ios-safari18", "ios", 18),
    preset!("ios-safari26", "ios", 26),
    preset!("macos-safari18", "macos", 18),
    preset!("macos-safari26", "macos", 26),
    preset!("windows-edge152", "windows", 152),
    preset!("windows-edge153", "windows", 153),
    preset!("windows-edge154", "windows", 154),
];

/// 用户主动选择时按 ID 精确取档，不受宿主平台与缓存影响。
pub(crate) fn by_id(id: &str) -> Option<FingerprintTemplate> {
    let selected = PRESETS.iter().find(|preset| preset.id == id)?;
    let mut template: FingerprintTemplate = serde_json::from_str(selected.json).ok()?;
    template.source = TemplateSource::Builtin(selected.id);
    template.generation = 0;
    Some(template)
}

fn major_after(ua: &str, marker: &str) -> Option<u16> {
    ua.split_once(marker)?
        .1
        .split(|c: char| !c.is_ascii_digit())
        .next()?
        .parse()
        .ok()
}

pub(crate) fn select(platform: &str, ua: Option<&str>) -> Option<FingerprintTemplate> {
    // 平台与内核同时匹配。未知 UA 使用该平台最新档；已知异内核不硬套。
    let major = match (platform, ua.filter(|ua| !ua.is_empty())) {
        ("android" | "windows", Some(ua)) => Some(major_after(ua, "Chrome/")?),
        ("ios" | "macos", Some(ua)) if ua.contains("AppleWebKit/") && !ua.contains("Chrome/") => {
            major_after(ua, "Version/")
        }
        ("android" | "windows" | "ios" | "macos", None) => None,
        _ => return None,
    };
    let selected = PRESETS
        .iter()
        .filter(|p| p.platform == platform)
        // 距离相同时优先较新档，选择只发生在核心启动时，运行期不随机轮换。
        .min_by_key(|p| {
            (
                major.map_or(0, |major| major.abs_diff(p.major)),
                u16::MAX - p.major,
            )
        })?;
    let mut template: FingerprintTemplate = serde_json::from_str(selected.json).ok()?;
    template.source = TemplateSource::Builtin(selected.id);
    template.generation = 0;
    tracing::info!(
        "Fingerprint fallback available: preset={}, platform={}, requested_major={:?}, preset_major={}",
        selected.id,
        platform,
        major,
        selected.major
    );
    Some(template)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn chooses_nearest_same_platform_and_rejects_foreign_engine() {
        let selected = select("android", Some("Android Chrome/133.0 Safari/537.36")).unwrap();
        assert_eq!(
            selected.source,
            TemplateSource::Builtin("android-webview133")
        );
        assert!(select("linux", Some("AppleWebKit/605 Version/27.0")).is_none());
        assert!(select("windows", Some("Gecko/20100101 Firefox/157.0")).is_none());
        assert!(select("macos", Some("AppleWebKit/537 Chrome/154.0")).is_none());
        assert_eq!(
            select("windows", None).unwrap().source,
            TemplateSource::Builtin("windows-edge154")
        );
        assert!(
            select("ios", Some("AppleWebKit/605 Version/18.6"))
                .unwrap()
                .source
                .id()
                .unwrap()
                .starts_with("ios-")
        );
    }
    #[test]
    fn all_presets_parse_and_build_tls_without_rewriting_user_agent() {
        for preset in PRESETS {
            let template: FingerprintTemplate = serde_json::from_str(preset.json).unwrap();
            assert!(template.user_agent.is_none(), "{}", preset.id);
            assert!(
                !serde_json::to_value(&template.early_frames)
                    .unwrap()
                    .as_array()
                    .unwrap()
                    .is_empty(),
                "{}",
                preset.id
            );
            let built = crate::browser_tls::build(
                &template.hello,
                "example.com".parse().unwrap(),
                None,
                None,
            )
            .unwrap_or_else(|error| panic!("{}: {error}", preset.id));
            // 发出真实 ClientHello，确认预置里的脱敏材料被运行时重新生成。
            let emitted = crate::browser_tls::emit_client_hello(built.connector_data).unwrap();
            assert!(!emitted.cipher_suites().is_empty());
        }
    }
}
