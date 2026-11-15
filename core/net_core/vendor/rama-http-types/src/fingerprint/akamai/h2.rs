//! Akamai HTTP2 Fingerprinting implementation for Rama.
//!
//! The fingerprint format is: `S[;]|WU|P[,]#|PS[,]`
//!
//! Where:
//! - S = SETTINGS frame parameters (id:value pairs, semicolon-separated)
//! - WU = WINDOW_UPDATE increment value (or "00" if not present)
//! - P = PRIORITY frames (stream_id:exclusive:depends_on:weight, comma-separated, or "0" if not present)
//! - PS = Pseudo-header order (m=method, p=path, a=authority, s=scheme, comma-separated)

use std::{fmt, io};

use rama_core::extensions::Extensions;

use crate::proto::h2::{
    PseudoHeader, PseudoHeaderOrder,
    frame::{
        EarlyFrame, EarlyFrameCapture,
        SettingId::{
            EnableConnectProtocol, EnablePush, HeaderTableSize, InitialWindowSize,
            MaxConcurrentStreams, MaxFrameSize, MaxHeaderListSize, NoRfc7540Priorities, Unknown,
        },
        StreamId,
    },
};

#[derive(Clone)]
pub struct AkamaiH2 {
    settings: Vec<(u16, u32)>,
    window_update: Option<u32>,
    priority_frames: Vec<AkamaiPriorityFrame>,
    pseudo_header_order: Vec<char>,
}

#[derive(Clone, Debug)]
struct AkamaiPriorityFrame {
    stream_id: u32,
    exclusive: bool,
    depends_on: u32,
    weight: u8,
}

impl AkamaiH2 {
    pub fn compute(ext: &Extensions) -> Result<Self, AkamaiH2ComputeError> {
        let early_frames = ext
            .get_ref::<EarlyFrameCapture>()
            .ok_or(AkamaiH2ComputeError::MissingEarlyFrames)?;
        if !early_frames.is_complete() {
            return Err(AkamaiH2ComputeError::IncompleteCapture);
        }

        let pseudo_header_order = ext
            .get_ref::<PseudoHeaderOrder>()
            .ok_or(AkamaiH2ComputeError::MissingPseudoHeaders)?;

        let mut settings = Vec::new();
        let mut window_update = None;
        let mut priority_frames = Vec::new();

        for frame in early_frames.iter() {
            match frame {
                EarlyFrame::Settings(s) => {
                    if !s.flags.is_ack() {
                        if let Some(observed) = &s.observation {
                            if !observed.complete {
                                return Err(AkamaiH2ComputeError::IncompleteCapture);
                            }
                            settings.extend(
                                observed
                                    .entries
                                    .iter()
                                    .map(|entry| (entry.id.into(), entry.value)),
                            );
                            continue;
                        }
                        let order = s
                            .config
                            .setting_order
                            .as_ref()
                            .ok_or(AkamaiH2ComputeError::MissingSettingOrder)?;

                        for setting_id in order.iter() {
                            let value = match setting_id {
                                HeaderTableSize => s.config.header_table_size,
                                EnablePush => s.config.enable_push,
                                MaxConcurrentStreams => s.config.max_concurrent_streams,
                                InitialWindowSize => s.config.initial_window_size,
                                MaxFrameSize => s.config.max_frame_size,
                                MaxHeaderListSize => s.config.max_header_list_size,
                                EnableConnectProtocol => s.config.enable_connect_protocol,
                                NoRfc7540Priorities => s.config.no_rfc7540_priorities,
                                Unknown(_) => None,
                            };
                            if let Some(val) = value {
                                settings.push((setting_id.into(), val));
                            }
                        }
                    }
                }
                EarlyFrame::WindowUpdate(wu) => {
                    // Only capture connection-level WINDOW_UPDATE (stream_id == 0)
                    if wu.stream_id == StreamId::zero() && window_update.is_none() {
                        window_update = Some(wu.size_increment);
                    }
                }
                EarlyFrame::Priority(p) => {
                    priority_frames.push(AkamaiPriorityFrame {
                        stream_id: p.stream_id.into(),
                        exclusive: p.dependency.is_exclusive,
                        depends_on: p.dependency.dependency_id.into(),
                        weight: p.dependency.weight,
                    });
                }
            }
        }

        if settings.is_empty() {
            return Err(AkamaiH2ComputeError::NoSettings);
        }

        let pseudo_order = pseudo_header_order
            .iter()
            .filter_map(|ph| match ph {
                PseudoHeader::Method => Some('m'),
                PseudoHeader::Path => Some('p'),
                PseudoHeader::Authority => Some('a'),
                PseudoHeader::Scheme => Some('s'),
                _ => None,
            })
            .collect();

        Ok(Self {
            settings,
            window_update,
            priority_frames,
            pseudo_header_order: pseudo_order,
        })
    }
}

macro_rules! impl_write_to {
    ($w:ident, $this:ident) => {{
        let mut first = true;
        for (id, val) in &$this.settings {
            if !first {
                write!($w, ";")?;
            }
            write!($w, "{id}:{val}")?;
            first = false;
        }
        write!($w, "|")?;

        match $this.window_update {
            Some(v) => write!($w, "{v}")?,
            None => write!($w, "00")?,
        }

        write!($w, "|")?;

        if $this.priority_frames.is_empty() {
            write!($w, "0")?;
        } else {
            let mut first = true;
            for p in &$this.priority_frames {
                if !first {
                    write!($w, ",")?;
                }
                write!(
                    $w,
                    "{}:{}:{}:{}",
                    p.stream_id,
                    if p.exclusive { 1 } else { 0 },
                    p.depends_on,
                    p.weight
                )?;
                first = false;
            }
        }
        write!($w, "|")?;

        let mut first = true;
        for ch in &$this.pseudo_header_order {
            if !first {
                write!($w, ",")?;
            }
            write!($w, "{ch}")?;
            first = false;
        }
        Ok(())
    }};
}

impl AkamaiH2 {
    fn write_to_io(&self, w: &mut impl io::Write) -> io::Result<()> {
        impl_write_to!(w, self)
    }

    fn write_to_fmt(&self, w: &mut impl fmt::Write) -> fmt::Result {
        impl_write_to!(w, self)
    }
}

impl fmt::Display for AkamaiH2 {
    #[inline]
    #[expect(
        clippy::panic,
        reason = "debug-only assertion: md5::Context::write_all is infallible in practice"
    )]
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut ctx = md5::Context::new();
        _ = self.write_to_io(&mut ctx).inspect_err(|err| {
            if cfg!(debug_assertions) {
                panic!("md5 ingest failed: {err:?}");
            }
        });
        let digest = ctx.finalize();
        write!(f, "{digest:x}")
    }
}

impl fmt::Debug for AkamaiH2 {
    #[inline]
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.write_to_fmt(f)
    }
}

#[derive(Debug, Clone)]
pub enum AkamaiH2ComputeError {
    MissingEarlyFrames,
    IncompleteCapture,
    MissingPseudoHeaders,
    MissingSettingOrder,
    NoSettings,
}

impl fmt::Display for AkamaiH2ComputeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingEarlyFrames => {
                write!(f, "AkamaiH2 Compute Error: missing early frame capture")
            }
            Self::IncompleteCapture => f.write_str("AkamaiH2 Compute Error: incomplete capture"),
            Self::MissingPseudoHeaders => {
                write!(f, "AkamaiH2 Compute Error: missing pseudo-header order")
            }
            Self::MissingSettingOrder => {
                write!(
                    f,
                    "AkamaiH2 Compute Error: settings frame without setting order"
                )
            }
            Self::NoSettings => {
                write!(f, "AkamaiH2 Compute Error: no settings found")
            }
        }
    }
}

impl std::error::Error for AkamaiH2ComputeError {}

rama_utils::macros::serde_str::impl_serde_str!(serialize display AkamaiH2);

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proto::h2::frame::{
        EarlyFrameStreamContext, Head, Kind, Priority, SettingOrder, Settings, SettingsConfig,
        StreamDependency, WindowUpdate,
    };

    // Common pseudo-header orders
    const FIREFOX_ORDER: &[PseudoHeader] = &[
        PseudoHeader::Method,
        PseudoHeader::Path,
        PseudoHeader::Authority,
        PseudoHeader::Scheme,
    ];

    const CHROME_ORDER: &[PseudoHeader] = &[
        PseudoHeader::Method,
        PseudoHeader::Authority,
        PseudoHeader::Scheme,
        PseudoHeader::Path,
    ];

    const CURL_ORDER: &[PseudoHeader] = &[
        PseudoHeader::Method,
        PseudoHeader::Path,
        PseudoHeader::Scheme,
        PseudoHeader::Authority,
    ];

    fn create_early_frame_capture(frames: &[EarlyFrame]) -> EarlyFrameCapture {
        let mut recorder = EarlyFrameStreamContext::new_recorder();
        for frame in frames {
            match frame {
                EarlyFrame::Settings(settings) => recorder.record_settings_frame(settings),
                EarlyFrame::Priority(priority) => recorder.record_priority_frame(priority),
                EarlyFrame::WindowUpdate(window) => recorder.record_windows_update_frame(*window),
            }
        }
        recorder.freeze_recorder().unwrap()
    }

    fn add_priority_frame(
        frames: &mut Vec<EarlyFrame>,
        stream_id: u32,
        depends_on: u32,
        weight: u8,
        exclusive: bool,
    ) {
        frames.push(EarlyFrame::Priority(Priority {
            stream_id: StreamId::from(stream_id),
            dependency: StreamDependency {
                dependency_id: StreamId::from(depends_on),
                weight,
                is_exclusive: exclusive,
            },
        }));
    }

    fn create_pseudo_header_order(headers: &[PseudoHeader]) -> PseudoHeaderOrder {
        let mut order = PseudoHeaderOrder::new();
        for header in headers {
            order.push(*header);
        }
        order
    }

    // Common priority frame patterns
    fn add_firefox_priority_frames(frames: &mut Vec<EarlyFrame>) {
        add_priority_frame(frames, 3, 0, 201, false);
        add_priority_frame(frames, 5, 0, 101, false);
        add_priority_frame(frames, 7, 0, 1, false);
        add_priority_frame(frames, 9, 7, 1, false);
        add_priority_frame(frames, 11, 3, 1, false);
    }

    #[test]
    fn test_akamai_h2_basic() {
        let ext = Extensions::default();

        ext.insert(create_pseudo_header_order(FIREFOX_ORDER));

        let mut frames = Vec::new();

        let settings_config = SettingsConfig {
            header_table_size: Some(65536),
            enable_push: Some(0),
            initial_window_size: Some(131072),
            max_frame_size: Some(16384),
            setting_order: Some(SettingOrder::from_iter([
                HeaderTableSize,
                EnablePush,
                InitialWindowSize,
                MaxFrameSize,
            ])),
            ..Default::default()
        };
        frames.push(EarlyFrame::Settings(Settings {
            observation: None,
            config: settings_config,
            flags: Default::default(),
        }));

        frames.push(EarlyFrame::WindowUpdate(WindowUpdate {
            stream_id: StreamId::zero(),
            size_increment: 12517377,
        }));

        ext.insert(create_early_frame_capture(&frames));

        let akamai_h2 = AkamaiH2::compute(&ext).expect("compute akamai h2");

        let debug_str = format!("{akamai_h2:?}");
        assert_eq!(debug_str, "1:65536;2:0;4:131072;5:16384|12517377|0|m,p,a,s");

        let hash_str = format!("{akamai_h2}");
        assert_eq!(hash_str, "6ea73faa8fc5aac76bded7bd238f6433");
    }

    #[test]
    fn test_akamai_h2_with_priority() {
        let ext = Extensions::default();

        ext.insert(create_pseudo_header_order(FIREFOX_ORDER));

        let mut frames = Vec::new();

        let settings_config = SettingsConfig {
            header_table_size: Some(65536),
            setting_order: Some(SettingOrder::from_iter([HeaderTableSize])),
            ..Default::default()
        };
        frames.push(EarlyFrame::Settings(Settings {
            observation: None,
            config: settings_config,
            flags: Default::default(),
        }));

        add_priority_frame(&mut frames, 3, 0, 200, false);

        ext.insert(create_early_frame_capture(&frames));

        let akamai_h2 = AkamaiH2::compute(&ext).expect("compute akamai h2");

        let debug_str = format!("{akamai_h2:?}");
        assert!(debug_str.contains("3:0:0:200"), "debug_str: {debug_str}");
    }

    #[test]
    fn test_akamai_h2_no_window_update() {
        let ext = Extensions::default();
        ext.insert(create_pseudo_header_order(CURL_ORDER));

        let mut frames = Vec::new();

        let settings_config = SettingsConfig {
            header_table_size: Some(4096),
            enable_push: Some(1),
            setting_order: Some(SettingOrder::from_iter([HeaderTableSize, EnablePush])),
            ..Default::default()
        };
        frames.push(EarlyFrame::Settings(Settings {
            observation: None,
            config: settings_config,
            flags: Default::default(),
        }));

        ext.insert(create_early_frame_capture(&frames));

        let akamai_h2 = AkamaiH2::compute(&ext).expect("compute akamai h2");

        // "00" for window update when not present
        let debug_str = format!("{akamai_h2:?}");
        assert!(debug_str.contains("|00|"), "debug_str: {debug_str}");
        assert_eq!(debug_str, "1:4096;2:1|00|0|m,p,s,a");
    }

    #[test]
    fn test_akamai_h2_multiple_priorities() {
        let ext = Extensions::default();

        ext.insert(create_pseudo_header_order(FIREFOX_ORDER));

        let mut frames = Vec::new();

        let settings_config = SettingsConfig {
            initial_window_size: Some(65535),
            setting_order: Some(SettingOrder::from_iter([InitialWindowSize])),
            ..Default::default()
        };
        frames.push(EarlyFrame::Settings(Settings {
            observation: None,
            config: settings_config,
            flags: Default::default(),
        }));

        add_priority_frame(&mut frames, 3, 0, 200, false);
        add_priority_frame(&mut frames, 5, 0, 100, true);
        add_priority_frame(&mut frames, 7, 5, 50, false);

        ext.insert(create_early_frame_capture(&frames));

        let akamai_h2 = AkamaiH2::compute(&ext).expect("compute akamai h2");

        let debug_str = format!("{akamai_h2:?}");
        assert!(debug_str.contains("3:0:0:200"), "debug_str: {debug_str}");
        assert!(debug_str.contains("5:1:0:100"), "debug_str: {debug_str}");
        assert!(debug_str.contains("7:0:5:50"), "debug_str: {debug_str}");
    }

    #[test]
    fn test_akamai_h2_chrome_like() {
        let ext = Extensions::default();

        ext.insert(create_pseudo_header_order(CHROME_ORDER));

        let mut frames = Vec::new();

        let settings_config = SettingsConfig {
            header_table_size: Some(65536),
            enable_push: Some(0),
            max_concurrent_streams: Some(1000),
            initial_window_size: Some(6291456),
            max_frame_size: Some(16384),
            max_header_list_size: Some(262144),
            setting_order: Some(SettingOrder::from_iter([
                HeaderTableSize,
                EnablePush,
                MaxConcurrentStreams,
                InitialWindowSize,
                MaxFrameSize,
                MaxHeaderListSize,
            ])),
            ..Default::default()
        };
        frames.push(EarlyFrame::Settings(Settings {
            observation: None,
            config: settings_config,
            flags: Default::default(),
        }));

        frames.push(EarlyFrame::WindowUpdate(WindowUpdate {
            stream_id: StreamId::zero(),
            size_increment: 15663105,
        }));

        ext.insert(create_early_frame_capture(&frames));

        let akamai_h2 = AkamaiH2::compute(&ext).expect("compute akamai h2");

        let debug_str = format!("{akamai_h2:?}");
        assert!(debug_str.ends_with("m,a,s,p"), "debug_str: {debug_str}");
        assert!(debug_str.contains("1:65536;2:0;3:1000;4:6291456;5:16384;6:262144"));
    }

    #[test]
    fn test_paper_example_5_firefox_53_macos() {
        // From Blackhat EU-17 Paper, Example 5
        // User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10.11; rv:53.0) Gecko/20100101 Firefox/53.0
        let ext = Extensions::default();

        ext.insert(create_pseudo_header_order(FIREFOX_ORDER));

        let mut frames = Vec::new();

        let settings_config = SettingsConfig {
            header_table_size: Some(65536),
            initial_window_size: Some(131072),
            max_frame_size: Some(16384),
            setting_order: Some(SettingOrder::from_iter([
                HeaderTableSize,
                InitialWindowSize,
                MaxFrameSize,
            ])),
            ..Default::default()
        };
        frames.push(EarlyFrame::Settings(Settings {
            observation: None,
            config: settings_config,
            flags: Default::default(),
        }));

        frames.push(EarlyFrame::WindowUpdate(WindowUpdate {
            stream_id: StreamId::zero(),
            size_increment: 12517377,
        }));

        // Priority frames
        add_firefox_priority_frames(&mut frames);

        ext.insert(create_early_frame_capture(&frames));

        let akamai_h2 = AkamaiH2::compute(&ext).expect("compute akamai h2");

        let debug_str = format!("{akamai_h2:?}");
        assert_eq!(
            debug_str,
            "1:65536;4:131072;5:16384|12517377|3:0:0:201,5:0:0:101,7:0:0:1,9:0:7:1,11:0:3:1|m,p,a,s"
        );
    }

    #[test]
    fn test_paper_example_1_chrome_58_macos() {
        // From Blackhat EU-17 Paper, Example 1
        // User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.96 Safari/537.36
        let ext = Extensions::default();

        ext.insert(create_pseudo_header_order(CHROME_ORDER));

        let mut frames = Vec::new();

        let settings_config = SettingsConfig {
            header_table_size: Some(65536),
            max_concurrent_streams: Some(1000),
            initial_window_size: Some(6291456),
            setting_order: Some(SettingOrder::from_iter([
                HeaderTableSize,
                MaxConcurrentStreams,
                InitialWindowSize,
            ])),
            ..Default::default()
        };
        frames.push(EarlyFrame::Settings(Settings {
            observation: None,
            config: settings_config,
            flags: Default::default(),
        }));

        frames.push(EarlyFrame::WindowUpdate(WindowUpdate {
            stream_id: StreamId::zero(),
            size_increment: 15663105,
        }));

        ext.insert(create_early_frame_capture(&frames));

        let akamai_h2 = AkamaiH2::compute(&ext).expect("compute akamai h2");

        let debug_str = format!("{akamai_h2:?}");
        assert_eq!(debug_str, "1:65536;3:1000;4:6291456|15663105|0|m,a,s,p");
    }

    #[test]
    fn test_paper_example_3_edge_14() {
        // From Blackhat EU-17 Paper, Example 3
        // User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/51.0.2704.79 Safari/537.36 Edge/14.14393
        let ext = Extensions::default();

        ext.insert(create_pseudo_header_order(CHROME_ORDER));

        let mut frames = Vec::new();

        let settings_config = SettingsConfig {
            max_concurrent_streams: Some(1024),
            initial_window_size: Some(10485760),
            setting_order: Some(SettingOrder::from_iter([
                MaxConcurrentStreams,
                InitialWindowSize,
            ])),
            ..Default::default()
        };
        frames.push(EarlyFrame::Settings(Settings {
            observation: None,
            config: settings_config,
            flags: Default::default(),
        }));

        frames.push(EarlyFrame::WindowUpdate(WindowUpdate {
            stream_id: StreamId::zero(),
            size_increment: 10420225,
        }));

        ext.insert(create_early_frame_capture(&frames));

        let akamai_h2 = AkamaiH2::compute(&ext).expect("compute akamai h2");

        let debug_str = format!("{akamai_h2:?}");
        assert_eq!(debug_str, "3:1024;4:10485760|10420225|0|m,a,s,p");
    }

    #[test]
    fn test_paper_example_6_firefox_53_android() {
        // From Blackhat EU-17 Paper, Example 6
        // User-Agent: Mozilla/5.0 (Android 7.1.2; Mobile; rv:53.0) Gecko/53.0 Firefox/53.0
        let ext = Extensions::default();

        ext.insert(create_pseudo_header_order(FIREFOX_ORDER));

        let mut frames = Vec::new();

        let settings_config = SettingsConfig {
            header_table_size: Some(4096),
            initial_window_size: Some(32768),
            max_frame_size: Some(16384),
            setting_order: Some(SettingOrder::from_iter([
                HeaderTableSize,
                InitialWindowSize,
                MaxFrameSize,
            ])),
            ..Default::default()
        };
        frames.push(EarlyFrame::Settings(Settings {
            observation: None,
            config: settings_config,
            flags: Default::default(),
        }));

        frames.push(EarlyFrame::WindowUpdate(WindowUpdate {
            stream_id: StreamId::zero(),
            size_increment: 12517377,
        }));

        add_firefox_priority_frames(&mut frames);

        ext.insert(create_early_frame_capture(&frames));

        let akamai_h2 = AkamaiH2::compute(&ext).expect("compute akamai h2");

        let debug_str = format!("{akamai_h2:?}");
        assert_eq!(
            debug_str,
            "1:4096;4:32768;5:16384|12517377|3:0:0:201,5:0:0:101,7:0:0:1,9:0:7:1,11:0:3:1|m,p,a,s"
        );
    }

    #[test]
    fn test_paper_example_9_nghttp2() {
        // From Blackhat EU-17 Paper, Example 9
        // User-Agent: nghttp2/1.22.0
        let ext = Extensions::default();

        ext.insert(create_pseudo_header_order(CURL_ORDER));

        let mut frames = Vec::new();

        let settings_config = SettingsConfig {
            max_concurrent_streams: Some(100),
            initial_window_size: Some(65535),
            setting_order: Some(SettingOrder::from_iter([
                MaxConcurrentStreams,
                InitialWindowSize,
            ])),
            ..Default::default()
        };
        frames.push(EarlyFrame::Settings(Settings {
            observation: None,
            config: settings_config,
            flags: Default::default(),
        }));

        // Priority frames
        add_firefox_priority_frames(&mut frames);

        ext.insert(create_early_frame_capture(&frames));

        let akamai_h2 = AkamaiH2::compute(&ext).expect("compute akamai h2");

        let debug_str = format!("{akamai_h2:?}");
        assert_eq!(
            debug_str,
            "3:100;4:65535|00|3:0:0:201,5:0:0:101,7:0:0:1,9:0:7:1,11:0:3:1|m,p,s,a"
        );
    }
    fn observed_settings(entries: &[(u16, u32)]) -> EarlyFrame {
        let payload: Vec<_> = entries
            .iter()
            .flat_map(|(id, value)| id.to_be_bytes().into_iter().chain(value.to_be_bytes()))
            .collect();
        EarlyFrame::Settings(
            Settings::load_observed(
                Head::new(Kind::Settings, 0, StreamId::zero()),
                &payload,
                true,
            )
            .unwrap(),
        )
    }

    #[test]
    fn akamai_uses_wire_settings_without_collapsing_unknowns_or_duplicates() {
        let ext = Extensions::new();
        ext.insert(create_pseudo_header_order(CURL_ORDER));
        ext.insert(create_early_frame_capture(&[observed_settings(&[
            (1, 1024),
            (0xfefe, 7),
            (1, 4096),
        ])]));
        assert_eq!(
            format!("{:?}", AkamaiH2::compute(&ext).unwrap()),
            "1:1024;65278:7;1:4096|00|0|m,p,s,a"
        );
    }

    #[test]
    fn akamai_does_not_fingerprint_incomplete_or_legacy_capture() {
        let complete = create_early_frame_capture(&[observed_settings(&[(1, 4096)])]);
        let legacy: EarlyFrameCapture =
            serde_json::from_slice(&serde_json::to_vec(&complete).unwrap()).unwrap();
        let truncated_settings =
            create_early_frame_capture(&[observed_settings(&vec![(0xffff, 1); 257])]);
        let truncated_prefix =
            create_early_frame_capture(&vec![observed_settings(&[(1, 4096)]); 17]);
        for capture in [legacy, truncated_settings, truncated_prefix] {
            let ext = Extensions::new();
            ext.insert(create_pseudo_header_order(CURL_ORDER));
            ext.insert(capture);
            assert!(matches!(
                AkamaiH2::compute(&ext).unwrap_err(),
                AkamaiH2ComputeError::IncompleteCapture
            ));
        }
    }
}
