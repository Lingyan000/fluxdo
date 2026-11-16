//! 独立的 QUIC/H3 采样与回放配置。连接标识、密钥、票据及动态表索引不跨连接复制。
use rama::http::proto::h3::{
    self, PseudoHeader, PseudoHeaderOrder, Setting, SettingId, Settings,
    critical_streams::{Order, Preferences, Startup},
    observation::{
        H3ObservationSnapshot, H3RequestObservation, InsertionFieldMatch,
        ObservedEncoderInstruction,
    },
    qpack::{
        FieldSectionBase,
        encoding::{
            FieldPreferences, HeaderPreferences, InsertionNameEncoding, InsertionPreferences,
            InsertionScope,
        },
    },
};
use rama::{
    error::BoxError,
    extensions::ExtensionsRef,
    http::{HeaderName, Request},
    quic::tls::BoringTlsProvider,
    tls::client::{ClientHello, parse_client_hello},
};
use rama_http_core::h3::connection::Config;
use rama_quic_proto::{
    Side,
    capture::{self, FirstFlight},
    profile::{
        ConnectionIdProfile, GreaseParameter, InitialFlightLayout, PacketNumberLength,
        PacketizationProfile, ParameterOrder, ParameterOrderEntry, QuicProfile, TransportLimits,
        TransportParameterProfile,
    },
    transport_parameters::{RawParameter, TransportParameterId},
    version::{ClientVersionPolicy, ReservedQuicVersion, ReservedVersionGrease},
};
use std::sync::Arc;

/// 仅采样端等待已知的逐请求 PRIORITY 控制帧，不把到达先后误当成策略差异。
/// 普通业务请求不经过此等待；缺失必需证据时明确失败。
pub async fn sampled_request_boundary(
    observer: &rama_http_core::h3::observation::H3Observer,
    stream_id: u64,
    expects_priority: bool,
) -> Result<Arc<H3ObservationSnapshot>, BoxError> {
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(2);
    loop {
        let snapshot = observer.snapshot();
        if !expects_priority || snapshot.control.iter().any(|frame|
            frame.frame_type == u64::from(h3::FrameType::PRIORITY_UPDATE_REQUEST)
                && frame.element_id == Some(stream_id)) {
            return Ok(snapshot);
        }
        if snapshot.connection_error.is_some() || tokio::time::Instant::now() >= deadline {
            return Err("sampled H3 request priority boundary unavailable".into());
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
}

#[derive(Default)]
pub struct Templates(parking_lot::Mutex<State>);
#[derive(Default)]
struct State {
    first: Option<(u16, Sample)>,
    ready: Option<Arc<Profile>>,
    ports: Vec<u16>,
    spki: std::collections::BTreeMap<u16, String>,
    #[cfg(debug_assertions)]
    probe_ca_pem: std::collections::BTreeMap<u16, String>,
    error: Option<String>,
    revision: u64,
    epoch: u64,
    activity: std::collections::BTreeMap<u16, std::collections::BTreeMap<&'static str, u64>>,
    #[cfg(debug_assertions)]
    comparison: Option<serde_json::Value>,
}
impl Templates {
    #[cfg(debug_assertions)]
    pub fn calibration_diagnostics(&self) -> Option<serde_json::Value> {
        self.0.lock().comparison.clone()
    }
    pub fn activity(&self, port: u16, event: &'static str) {
        *self
            .0
            .lock()
            .activity
            .entry(port)
            .or_default()
            .entry(event)
            .or_default() += 1;
    }
    pub fn probe_certificate(&self, port: u16, spki: String) {
        self.0.lock().spki.insert(port, spki);
    }
    #[cfg(debug_assertions)]
    pub fn probe_ca(&self, port: u16, pem: String) {
        self.0.lock().probe_ca_pem.insert(port, pem);
    }
    pub fn epoch(&self) -> u64 {
        self.0.lock().epoch
    }
    pub fn reset(&self) {
        let mut s = self.0.lock();
        s.first = None;
        s.ready = None;
        s.error = None;
        s.revision += 1;
        s.epoch += 1;
        s.activity.clear();
        #[cfg(debug_assertions)]
        {
            s.comparison = None;
        }
    }
    pub fn ports(&self, ports: Vec<u16>) {
        self.0.lock().ports = ports;
    }
    pub fn record(&self, epoch: u64, port: u16, sample: Sample) -> Result<(), BoxError> {
        let mut state = self.0.lock();
        if epoch != state.epoch {
            return Err("stale H3 calibration generation".into());
        }
        if state.ready.is_some() {
            return Ok(());
        }
        if state
            .first
            .as_ref()
            .is_some_and(|(previous, _)| *previous == port)
        {
            return Ok(());
        }
        let Some((_, first)) = &state.first else {
            state.first = Some((port, sample));
            return Ok(());
        };
        let result = Profile::calibrate(first, &sample);
        #[cfg(debug_assertions)]
        {
            state.comparison = Some(
                serde_json::json!({"first":first.identity().ok(),"second":sample.identity().ok(),
                    "first_control":first.boundary.control,"second_control":sample.boundary.control}),
            );
        }
        match result {
            Ok(profile) => {
                state.ready = Some(Arc::new(profile));
                state.error = None;
                state.revision += 1;
                Ok(())
            }
            Err(error) => {
                state.ready = None;
                state.error = Some(error.to_string());
                Err(error)
            }
        }
    }
    pub fn snapshot(&self, ua: Option<&str>) -> Option<(u64, Arc<Profile>)> {
        let state = self.0.lock();
        state
            .ready
            .as_ref()
            .filter(|p| ua == Some(p.sample.user_agent.as_str()))
            .map(|p| (state.revision, p.clone()))
    }
    pub fn status(&self) -> serde_json::Value {
        let state = self.0.lock();
        let observed = |event: &str| state.activity.values()
            .any(|counts| counts.get(event).copied().unwrap_or(0) > 0);
        // 仅描述实际观测，不把没有 QUIC 握手推断成浏览器不支持 H3。
        let reason = if state.ready.is_some() {
            "sampled_quic_h3_profile"
        } else if state.error.is_some() {
            "native_quic_h3_calibration_failed"
        } else if state.first.is_some() {
            "native_quic_h3_waiting_for_second_sample"
        } else if observed("quic_connections") {
            "native_quic_observed_profile_pending"
        } else if observed("tcp_requests") {
            "native_probe_only_tcp_observed"
        } else {
            "native_quic_h3_profile_not_calibrated"
        };
        let status=serde_json::json!({"enabled_for_template":state.ready.is_some(), "epoch":state.epoch, "probe_ports":state.ports,"probe_spki":state.spki,
            "observations":if state.ready.is_some() {2} else if state.first.is_some() {1} else {0},
            "activity":state.activity,"error":state.error,"reason":reason});
        #[cfg(debug_assertions)]
        let status={let mut status=status;status["probe_ca_pem"]=serde_json::json!(state.probe_ca_pem);status};
        status
    }
    pub fn failure(&self, error: impl ToString) {
        let mut state = self.0.lock();
        if state.ready.is_none() {
            state.error = Some(error.to_string());
        }
    }
}

/// 只在内存中保留当次进程采样，避免旧缓存跳过 QUIC 的独立校准。
#[derive(Clone, Debug)]
pub struct Sample {
    pub hello: ClientHello,
    pub flight: FirstFlight,
    pub parameters: Vec<RawParameter>,
    pub boundary: Arc<H3ObservationSnapshot>,
    pub headers: HeaderPreferences,
    pub pseudo_order: PseudoHeaderOrder,
    pub header_order: Vec<String>,
    pub user_agent: String,
    pub priority_update: Option<Vec<u8>>,
    pub priority_header: Option<Vec<u8>>,
    pub phases: Vec<HeaderPreferences>,
    pub wire_fields: Vec<Vec<h3::observation::ObservedFieldRepresentation>>,
    pub warm_boundary: Option<Arc<H3ObservationSnapshot>>,
    pub insert_on_reuse: Option<bool>,
}

impl Sample {
    /// 首包包含握手开头及尾部，而中间空洞由后续包填补。
    /// 不根据平台或版本号推断未观察到的分片策略。
    pub fn cross_packet_initial(&self) -> bool {
        let Some(first) = self.flight.frames.first() else { return false; };
        let mut ranges: Vec<_> = first.iter().filter_map(|frame| match frame {
            capture::ObservedFrame::Crypto { offset, len } => Some((*offset, *offset + *len as u64)),
            _ => None,
        }).collect();
        ranges.sort_unstable();
        ranges.first().is_some_and(|range|range.0 == 0)
            && ranges.windows(2).any(|pair|pair[0].1 < pair[1].0)
    }

    /// 多包有序样本只接受前面各包等长、最后一包不超过该长度的完整覆盖。
    pub fn ordered_initial_chunk_size(&self) -> Option<u16> {
        if self.flight.frames.len() < 2 { return None; }
        let mut offset = 0;
        let mut sizes = Vec::new();
        for frames in &self.flight.frames {
            let mut size = None;
            for frame in frames {
                match frame {
                    capture::ObservedFrame::Crypto { offset: start, len } if size.is_none() && *start == offset => {
                        size = Some(*len); offset += *len as u64;
                    }
                    capture::ObservedFrame::Padding { .. } => {}
                    _ => return None,
                }
            }
            sizes.push(size?);
        }
        let limit = sizes[0];
        (limit > 0 && sizes[..sizes.len()-1].iter().all(|size| *size == limit)
            && *sizes.last()? <= limit).then(|| u16::try_from(limit).ok()).flatten()
    }

    pub fn capture<B>(
        datagrams: &[Vec<u8>],
        request: &Request<B>,
        boundary: Arc<H3ObservationSnapshot>,
    ) -> Result<Self, BoxError> {
        let borrowed: Vec<_> = datagrams.iter().map(Vec::as_slice).collect();
        let flight = capture::first_flight(&borrowed, &BoringTlsProvider)?;
        if !flight.complete || flight.token_len != 0 {
            return Err("incomplete or resumed QUIC probe".into());
        }
        let mut initials = Vec::new();
        for packet in datagrams {
            initials.extend(capture::observe(packet)?.unprotect_initials(
                packet,
                &BoringTlsProvider,
                Side::Server,
                None,
            )?);
        }
        let bytes = capture::client_hello(&initials).ok_or("missing QUIC ClientHello")?;
        let parameters = capture::transport_parameters(&bytes)?;
        let hello = parse_client_hello(bytes.get(4..).ok_or("short ClientHello")?)?;
        Self::from_parts(hello, flight, parameters, request, boundary)
    }

    pub fn capture_observation<B>(
        capture: &capture::QuicObservation,
        request: &Request<B>,
        boundary: Arc<H3ObservationSnapshot>,
    ) -> Result<Self, BoxError> {
        if !capture.completeness.is_complete() {
            return Err("incomplete native QUIC observation".into());
        }
        let flight = capture
            .first_flight
            .clone()
            .ok_or("missing QUIC first flight")?;
        if !flight.complete || flight.token_len != 0 {
            return Err("non-fresh QUIC observation".into());
        }
        let hello = parse_client_hello(
            capture
                .client_hello_message
                .get(4..)
                .ok_or("short QUIC hello")?,
        )?;
        Self::from_parts(
            hello,
            flight,
            capture.transport_parameters.clone(),
            request,
            boundary,
        )
    }

    fn from_parts<B>(
        hello: ClientHello,
        flight: FirstFlight,
        parameters: Vec<RawParameter>,
        request: &Request<B>,
        boundary: Arc<H3ObservationSnapshot>,
    ) -> Result<Self, BoxError> {
        if hello
            .extensions()
            .iter()
            .any(|extension| matches!(u16::from(extension.id()), 41 | 42 | 44))
        {
            return Err("resumed or retry TLS cannot calibrate a full QUIC handshake".into());
        }
        let observed = request
            .extensions()
            .get_ref::<H3RequestObservation>()
            .ok_or("missing H3 fields")?;
        let c = boundary.completeness;
        if !boundary.settings_received
            || boundary.connection_error.is_some()
            || !(c.settings
                && c.local_settings
                && c.streams
                && c.control
                && c.qpack
                && c.fields
                && c.snapshot)
            || !observed.fields_complete
            || !boundary
                .encoder_bindings
                .as_ref()
                .is_some_and(|b| b.complete && b.stream_id == observed.stream_id)
        {
            return Err("incomplete H3 first-request boundary".into());
        }
        let pseudo_order = request
            .extensions()
            .get_ref::<PseudoHeaderOrder>()
            .cloned()
            .ok_or("missing H3 pseudo order")?;
        let header_order: Vec<_> = request
            .headers()
            .iter()
            .map(|(n, _)| n.as_str().to_owned())
            .collect();
        let names: Vec<_> = pseudo_order
            .iter()
            .map(|p| p.as_str().to_owned())
            .chain(header_order.iter().cloned())
            .collect();
        if names.len() != observed.fields.len() {
            return Err("H3 field names and wire representations disagree".into());
        }
        let values = sample_values(request, &pseudo_order)?;
        let mut headers = HeaderPreferences::default();
        let mut insertions = std::collections::BTreeMap::new();
        let mut previous = None;
        for binding in &boundary.encoder_bindings.as_ref().unwrap().insertions {
            let InsertionFieldMatch::Unique { field_index } = binding.field else {
                return Err("ambiguous QPACK insertion binding".into());
            };
            if previous.is_some_and(|v| v >= field_index) {
                return Err("QPACK insertion order differs from field order".into());
            }
            previous = Some(field_index);
            let instruction = boundary
                .encoder_instructions
                .get(binding.instruction_index)
                .ok_or("QPACK insertion out of range")?;
            let mut preference = InsertionPreferences {
                scope: InsertionScope::InitialSection,
                ..Default::default()
            };
            match instruction {
                ObservedEncoderInstruction::InsertNameReference {
                    is_static: true,
                    index,
                    value_huffman,
                    ..
                } => {
                    preference.name_encoding = InsertionNameEncoding::StaticName(*index);
                    preference.value_huffman = Some(*value_huffman);
                }
                ObservedEncoderInstruction::InsertLiteral {
                    name_huffman,
                    value_huffman,
                    ..
                } => {
                    preference.name_encoding = InsertionNameEncoding::Literal;
                    preference.name_huffman = Some(*name_huffman);
                    preference.value_huffman = Some(*value_huffman);
                }
                _ => return Err("unsupported initial QPACK insertion".into()),
            }
            insertions.insert(field_index, preference);
        }
        for (index, (name, field)) in names.iter().zip(&observed.fields).enumerate() {
            let mut value =
                FieldPreferences::from_observed(field).ok_or("unsupported QPACK representation")?;
            value.insertion = insertions.remove(&index);
            infer_huffman(&mut value, name.as_bytes(), &values[index]);
            if let Ok(pseudo) = PseudoHeader::from_bytes(name.as_bytes()) {
                headers.pseudo_headers.insert(pseudo, value);
            } else {
                headers
                    .headers
                    .append(HeaderName::from_bytes(name.as_bytes())?, value);
            }
        }
        let user_agent = request
            .headers()
            .get("user-agent")
            .ok_or("missing probe UA")?
            .to_str()?
            .to_owned();
        let priority_update = boundary
            .control
            .iter()
            .find(|f| {
                f.frame_type == u64::from(h3::FrameType::PRIORITY_UPDATE_REQUEST)
                    && f.element_id == Some(observed.stream_id)
            })
            .map(|f| f.value.to_vec());
        let priority_header = request
            .headers()
            .get("priority")
            .map(|v| v.as_bytes().to_vec());
        let phases = vec![headers.clone()];
        Ok(Self {
            hello,
            flight,
            parameters,
            boundary,
            headers,
            pseudo_order,
            header_order,
            user_agent,
            priority_update,
            priority_header,
            phases,
            wire_fields: vec![observed.fields.clone()],
            warm_boundary: None,
            insert_on_reuse: None,
        })
    }

    /// 至少三阶段且连续两次字段策略一致，才认为已经离开动态表启动阶段。
    pub fn warm_fields_stable(&self) -> bool {
        warm_fields_stable(&self.wire_fields)
    }

    /// 用同连接内首次出现、随后重复的新路径测量动态表准入，不按 UA 猜测。
    pub fn observe_value_reuse(&mut self, fields: &[h3::observation::ObservedFieldRepresentation]) -> Result<(), BoxError> {
        self.insert_on_reuse = Some(infer_value_reuse(fields)?);
        Ok(())
    }

    /// 同一连接继续采样，分离首次字段块与动态表建立后的字段策略。
    pub fn observe_warm<B>(&mut self, request: &Request<B>) -> Result<(), BoxError> {
        let observed = request
            .extensions()
            .get_ref::<H3RequestObservation>()
            .ok_or("missing warm H3 observation")?;
        let pseudo = request
            .extensions()
            .get_ref::<PseudoHeaderOrder>()
            .ok_or("missing warm pseudo order")?;
        let names: Vec<_> = pseudo
            .iter()
            .map(|p| p.as_str().to_owned())
            .chain(request.headers().iter().map(|(n, _)| n.as_str().to_owned()))
            .collect();
        let expected: Vec<_> = self
            .pseudo_order
            .iter()
            .map(|p| p.as_str().to_owned())
            .chain(self.header_order.iter().cloned())
            .collect();
        if !observed.fields_complete
            || observed.stream_id != self.phases.len() as u64 * 4
            || names != expected
            || names.len() != observed.fields.len()
            || observed.connection.connection_error.is_some()
        {
            return Err("incomplete or inconsistent warm H3 sample".into());
        }
        let values = sample_values(request, pseudo)?;
        let mut preferences = HeaderPreferences::default();
        for (index, (name, field)) in names.iter().zip(&observed.fields).enumerate() {
            let mut preference =
                FieldPreferences::from_observed(field).ok_or("unsupported warm QPACK field")?;
            infer_huffman(&mut preference, name.as_bytes(), &values[index]);
            if let Ok(pseudo) = PseudoHeader::from_bytes(name.as_bytes()) {
                preferences.pseudo_headers.insert(pseudo, preference);
            } else {
                preferences
                    .headers
                    .append(HeaderName::from_bytes(name.as_bytes())?, preference);
            }
        }
        self.phases.push(preferences);
        self.wire_fields.push(observed.fields.clone());
        self.warm_boundary = Some(observed.connection.clone());
        Ok(())
    }

    /// 两条独立连接只比较稳定字段；随机 GREASE 与当前连接的 CID 不参与能力身份。
    fn identity(&self) -> Result<serde_json::Value, BoxError> {
        let mut parameters: Vec<_> = self
            .parameters
            .iter()
            .filter(|p| !p.id.is_observation_only())
            .map(|p| {
                if p.id.is_reserved() {
                    (u64::MAX, vec![])
                } else if p.id == TransportParameterId::InitialSourceConnectionId {
                    (u64::from(p.id), vec![p.value.len() as u8])
                } else if is_version_information(p.id) {
                    (u64::from(p.id), vec![])
                } else {
                    (u64::from(p.id), p.value.clone())
                }
            })
            .collect();
        parameters.sort();
        let settings: Vec<_> = self
            .boundary
            .settings
            .as_ref()
            .ok_or("missing settings")?
            .iter()
            .map(|s| {
                if s.grease {
                    (u64::MAX, 0)
                } else {
                    (s.id, s.value)
                }
            })
            .collect();
        let versions = sample_version_information(&self.parameters)?
            .map(|info| info.available().to_vec())
            .unwrap_or_default();
        Ok(
            serde_json::json!({"tls":crate::mirror::profile_hash(&ClientHello::new(self.hello.protocol_version(), self.hello.cipher_suites().to_vec(),
                self.hello.compression_algorithms().to_vec(), self.hello.extensions().iter()
                .filter(|e| e.id() != rama::tls::ExtensionId::QUIC_TRANSPORT_PARAMETERS).cloned().collect())),"parameters":parameters,
            "version":self.flight.version,"dcid":self.flight.dcid_len,"scid":self.flight.scid_len,
            "settings":settings,"ua":self.user_agent,"headers":self.header_order,"pseudo":self.pseudo_order,
            "push_credits":self.boundary.control.iter()
                .filter(|frame|h3::FrameType::from(frame.frame_type)==h3::FrameType::MAX_PUSH_ID)
                .map(|frame|frame.element_id).collect::<Vec<_>>(),
            "qpack_phases":self.phases.iter().map(|p|format!("{p:?}")).collect::<Vec<_>>(),
            "insert_on_reuse":self.insert_on_reuse,
            "packet_number_lengths":self.flight.packet_number_lengths,"first_packet":self.flight.first_packet_number,"padding":self.flight.padding,
            "coalesced":self.flight.coalesced,"cross_packet_initial":self.cross_packet_initial(),"ordered_initial_chunk_size":self.ordered_initial_chunk_size(),
            "versions":versions.iter().filter(|v|!v.is_reserved()).map(|v|v.as_u32()).collect::<Vec<_>>(),
            "version_grease_count":versions.iter().filter(|v|v.is_reserved()).count()}),
        )
    }
}

#[derive(Clone, Debug)]
pub struct Profile {
    pub sample: Sample,
    pub quic: QuicProfile,
    pub http: Config,
    pub permute_tls: bool,
    pub permute_version_grease: bool,
}

impl Profile {
    pub fn calibrate(first: &Sample, second: &Sample) -> Result<Self, BoxError> {
        if !first.warm_fields_stable() || !second.warm_fields_stable() {
            return Err("warm H3 field strategy has not stabilized".into());
        }
        if first.insert_on_reuse.is_none() || second.insert_on_reuse.is_none() {
            return Err("QPACK value reuse calibration missing".into());
        }
        if first.identity()? != second.identity()? {
            return Err("QUIC samples have different stable capabilities".into());
        }
        let a: Vec<_> = first
            .hello
            .extensions()
            .iter()
            .filter(|e| !e.id().is_grease())
            .map(|e| e.id())
            .collect();
        let b: Vec<_> = second
            .hello
            .extensions()
            .iter()
            .filter(|e| !e.id().is_grease())
            .map(|e| e.id())
            .collect();
        let first_grease = first
            .parameters
            .iter()
            .find(|p| p.id.is_reserved())
            .map(|p| p.value.len());
        let second_grease = second
            .parameters
            .iter()
            .find(|p| p.id.is_reserved())
            .map(|p| p.value.len());
        let grease_len = if first_grease == second_grease {
            second_grease
        } else {
            None
        };
        let quic = transport(
            second,
            grease_len,
            first
                .parameters
                .iter()
                .map(|p| {
                    if p.id.is_reserved() {
                        u64::MAX
                    } else {
                        u64::from(p.id)
                    }
                })
                .collect::<Vec<_>>()
                != second
                    .parameters
                    .iter()
                    .map(|p| {
                        if p.id.is_reserved() {
                            u64::MAX
                        } else {
                            u64::from(p.id)
                        }
                    })
                    .collect::<Vec<_>>(),
        )?;
        let http = http_config(second)?;
        // 构造真实引擎配置来检查范围；不把被引擎降级的限额悄悄视为完全回放。
        let _ = rama::quic::TransportConfig::from_quic_profile(&quic)?;
        let position = |sample: &Sample| -> Result<Option<usize>, BoxError> {
            Ok(sample_version_information(&sample.parameters)?
                .and_then(|info| info.available().iter().position(|v| v.is_reserved())))
        };
        let permute_version_grease = position(first)? != position(second)?;
        Ok(Self {
            sample: second.clone(),
            quic,
            http,
            permute_tls: a != b,
            permute_version_grease,
        })
    }

    pub fn connection_quic(&self) -> Result<QuicProfile, BoxError> {
        let mut sample = self.sample.clone();
        if let Some(parameter) = sample
            .parameters
            .iter_mut()
            .find(|p| u64::from(p.id) == DRAFT_VERSION_INFORMATION)
        {
            let info = sample_version_information(std::slice::from_ref(parameter))?
                .ok_or("missing draft version information")?;
            let mut bytes = [0; 4];
            rama::tls::boring::core::rand::rand_bytes(&mut bytes)?;
            let mut versions: Vec<_> = info
                .available()
                .iter()
                .copied()
                .filter(|v| !v.is_reserved())
                .collect();
            if info.available().iter().any(|v| v.is_reserved()) {
                let grease = rama_quic_proto::Version::from(
                    (u32::from_le_bytes(bytes) & 0xf0f0f0f0) | 0x0a0a0a0a,
                );
                let first = if self.permute_version_grease {
                    bytes[0] & 1 == 0
                } else {
                    info.available().first().is_some_and(|v| v.is_reserved())
                };
                if first {
                    versions.insert(0, grease);
                } else {
                    versions.push(grease);
                }
            }
            parameter.value = info
                .chosen()
                .as_u32()
                .to_be_bytes()
                .into_iter()
                .chain(versions.iter().flat_map(|v| v.as_u32().to_be_bytes()))
                .collect();
        }
        let grease_len = match self.quic.transport_parameters().grease() {
            GreaseParameter::Random { value_len } => *value_len,
            _ => None,
        };
        let quic = transport(
            &sample,
            grease_len,
            matches!(
                self.quic.transport_parameters().order(),
                ParameterOrder::Shuffled
            ),
        )?;
        let mut versions = quic.versions().clone();
        if !matches!(
            versions.reserved_version_grease(),
            ReservedVersionGrease::None
        ) {
            let mut bytes = [0; 4];
            rama::tls::boring::core::rand::rand_bytes(&mut bytes)?;
            let version = ReservedQuicVersion::try_from(rama_quic_proto::Version::from(
                (u32::from_le_bytes(bytes) & 0xf0f0f0f0) | 0x0a0a0a0a,
            ))?;
            let first = if self.permute_version_grease {
                bytes[0] & 1 == 0
            } else {
                matches!(
                    versions.reserved_version_grease(),
                    ReservedVersionGrease::First
                )
            };
            versions = versions.with_reserved_version_grease(if first {
                ReservedVersionGrease::FixedFirst(version)
            } else {
                ReservedVersionGrease::FixedLast(version)
            });
        }
        Ok(quic.with_versions(versions))
    }

    /// GREASE 每条连接重新生成，保留编码宽度，避免样本随机值变成固定指纹。
    pub fn connection_config(&self) -> Result<Config, BoxError> {
        http_config(&self.sample)
    }

    pub fn apply_request(&self, request: &mut Request) {
        if let Some(value) = &self.sample.priority_header
            && !request.headers().contains_key("priority")
            && let Ok(value) = rama::http::HeaderValue::from_bytes(value)
        {
            request.headers_mut().insert("priority", value);
        }
        if let Some(default) = &self.sample.priority_update {
            let value = request
                .headers()
                .get("priority")
                .map(|v| v.as_bytes())
                .unwrap_or(default)
                .to_vec();
            request
                .extensions()
                .insert(h3::control::RequestPriority(value.into()));
        }
        request
            .extensions()
            .insert(self.sample.pseudo_order.clone());
        request.extensions().insert(self.sample.headers.clone());
        request
            .extensions()
            .insert(h3::qpack::encoding::ConnectionHeaderPreferences(
                self.sample.phases.clone(),
            ));
        request
            .extensions()
            .insert(FieldSectionBase::FromFieldPreferences);
        // 只排字段，不复制采样值，尤其不修改 Cookie、Origin、Referer、CSRF。
        let mut headers = rama::http::HeaderMap::with_capacity(request.headers().len());
        for name in &self.sample.header_order {
            if headers.contains_key(name.as_str()) {
                continue;
            }
            for value in request.headers().get_all(name.as_str()).iter() {
                if let Ok(name) = HeaderName::from_bytes(name.as_bytes()) {
                    headers.append(name, value.clone());
                }
            }
        }
        for (name, value) in request.headers().iter() {
            if !self.sample.header_order.iter().any(|n| n == name.as_str()) {
                headers.append(name.clone(), value.clone());
            }
        }
        *request.headers_mut() = headers;
    }
}

fn transport(
    sample: &Sample,
    grease_len: Option<usize>,
    shuffle: bool,
) -> Result<QuicProfile, BoxError> {
    let mut literals = Vec::new();
    let mut order = Vec::new();
    let mut grease = GreaseParameter::None;
    for p in &sample.parameters {
        if p.id.is_observation_only() {
            continue;
        }
        if p.id.is_reserved() {
            if !matches!(grease, GreaseParameter::None) {
                return Err("multiple reserved QUIC parameters unsupported".into());
            }
            grease = GreaseParameter::Random {
                value_len: grease_len,
            };
            order.push(ParameterOrderEntry::Grease);
        } else {
            order.push(ParameterOrderEntry::Parameter(p.id));
            if p.id != TransportParameterId::InitialSourceConnectionId {
                literals.push(p.clone());
            }
        }
    }
    let mut versions = ClientVersionPolicy::new(sample.flight.version)?;
    if let Some(info) = sample_version_information(&literals)? {
        let mut real = Vec::new();
        let mut reserved = ReservedVersionGrease::None;
        for (i, version) in info.available().iter().copied().enumerate() {
            if version.is_reserved() {
                reserved = if i == 0 {
                    ReservedVersionGrease::First
                } else if i + 1 == info.available().len() {
                    ReservedVersionGrease::Last
                } else {
                    return Err("reserved QUIC version in unsupported position".into());
                };
            } else {
                real.push(version);
            }
        }
        versions = versions
            .try_with_compatible(real)?
            .with_reserved_version_grease(reserved);
    } else {
        versions = versions.try_with_version_information(false)?;
    }
    if literals
        .iter()
        .any(|p| u64::from(p.id) == DRAFT_VERSION_INFORMATION)
    {
        // 草案参数只保留自己的编号，不额外添加 RFC 编号；新随机值在每次建连时生成。
        versions = versions
            .try_with_version_information(false)?
            .with_reserved_version_grease(ReservedVersionGrease::None);
    }
    let layout = TransportParameterProfile::try_from_sent(&literals)?
        .try_with_order(if shuffle {
            ParameterOrder::Shuffled
        } else {
            ParameterOrder::FixedWithExplicitDefaults(order)
        })?
        .try_with_grease(grease)?;
    let limits = TransportLimits::try_from_sent(&literals)?;
    if limits
        .active_connection_id_limit
        .is_some_and(|limit| limit > rama::quic::profile::MAX_ACTIVE_CONNECTION_ID_LIMIT)
    {
        return Err("QUIC CID limit exceeds engine capability".into());
    }
    let ids = ConnectionIdProfile::standard()
        .try_with_local_len(sample.flight.scid_len.try_into()?)?
        .try_with_initial_destination_len(sample.flight.dcid_len.try_into()?)?;
    // 固定帧偏移要求握手字节数完全相同；SNI、GREASE 长度变化会使底层回退。
    // 采样的是布局策略，随机布局使用当前连接的新握手字节重新分片。
    let size = *sample
        .flight
        .datagram_sizes
        .first()
        .ok_or("missing Initial datagram")?;
    if sample.flight.datagram_sizes.iter().any(|s| *s != size) {
        return Err("nonuniform Initial datagram sizes".into());
    }
    let mut offset = 0;
    let mut scrambled = false;
    for frames in &sample.flight.frames {
        // 零次随机细分也可能保持 CRYPTO 顺序；PING 和前置填充仍能提供布局证据。
        scrambled |= frames.iter().any(|frame| matches!(frame, capture::ObservedFrame::Ping))
            || matches!(frames.first(), Some(capture::ObservedFrame::Padding { .. }))
            || frames.iter().filter(|frame| matches!(frame, capture::ObservedFrame::Crypto { .. })).count() > 1;
    }
    for frame in sample.flight.frames.iter().flatten() {
        if let capture::ObservedFrame::Crypto { offset: start, len } = frame {
            scrambled |= *start != offset;
            offset = *start + *len as u64;
        }
    }
    let packets = PacketizationProfile::standard()
        .try_with_initial_datagram_size(size.try_into()?)?
        .try_with_first_packet_number(sample.flight.first_packet_number)?
        .try_with_packet_number_length(PacketNumberLength::AtLeast(
            sample.flight.packet_number_len,
        ))?
        .with_padding(sample.flight.padding)
        .with_coalesce(sample.flight.coalesced)
        .with_layout(if scrambled {
            InitialFlightLayout::Chaos
        } else {
            InitialFlightLayout::Ordered
        });
    Ok(QuicProfile::standard()
        .with_versions(versions)
        .with_transport_parameters(layout)
        .with_connection_ids(ids)
        .with_packetization(packets)
        .with_grease_quic_bit(
            literals
                .iter()
                .any(|p| p.id == TransportParameterId::GreaseQuicBit),
        )
        .try_with_limits(limits)?)
}

fn http_config(sample: &Sample) -> Result<Config, BoxError> {
    let mut settings = Settings::new();
    for s in sample
        .boundary
        .settings
        .as_ref()
        .ok_or("missing settings")?
    {
        settings.insert(Setting {
            id: SettingId::new(if s.grease {
                fresh_reserved(s.id)?
            } else {
                s.id
            }),
            value: if s.grease {
                fresh_integer(s.value)?
            } else {
                s.value
            },
        })?;
    }
    let mut config = Config::default().try_with_captured_client_settings(Arc::new(settings))?;
    // 已采到的未知控制帧不能静默丢掉；请求优先级属于动态请求上下文，单独处理。
    let mut frames = Vec::new();
    for frame in &sample.boundary.control {
        let ty = h3::FrameType::from(frame.frame_type);
        if ty == h3::FrameType::SETTINGS {
            continue;
        }
        if ty == h3::FrameType::MAX_PUSH_ID {
            apply_push_credit(&mut config, frame.element_id)?;
            continue;
        }
        if ty == h3::FrameType::PRIORITY_UPDATE_REQUEST
            && frame.element_id
                == sample
                    .boundary
                    .encoder_bindings
                    .as_ref()
                    .map(|b| b.stream_id)
        {
            continue;
        }
        if ty.name().is_some() {
            return Err(
                format!("unsupported captured H3 control frame {}", frame.frame_type).into(),
            );
        }
        if frame.value.len() as u64 != frame.length {
            return Err("uncaptured H3 control payload".into());
        }
        let mut payload = frame.value.to_vec();
        let ty = if ty.is_reserved() {
            rama::tls::boring::core::rand::rand_bytes(&mut payload)?;
            h3::FrameType::from(fresh_reserved(frame.frame_type)?)
        } else {
            ty
        };
        frames.push(h3::control::ClientControlFrame::Ignored {
            frame_type: ty,
            payload: payload.into(),
        });
    }
    config.client_control = Some(Arc::new(h3::control::ClientControlPreferences {
        frames: frames.into(),
    }));
    let encoder = sample
        .boundary
        .streams
        .iter()
        .find(|s| s.stream_type == h3::StreamType::QPACK_ENCODER.value());
    let decoder = sample
        .boundary
        .streams
        .iter()
        .find(|s| s.stream_type == h3::StreamType::QPACK_DECODER.value());
    let warm = sample
        .warm_boundary
        .as_ref()
        .ok_or("missing warm QPACK stream allocation")?;
    let mut order = None;
    for stream in &warm.streams {
        let observed = match (stream.stream_type, stream.stream_id) {
            (2, 6) | (3, 10) => Some(Order::EncoderFirst),
            (2, 10) | (3, 6) => Some(Order::DecoderFirst),
            (0, 2) => None,
            _ => return Err("unsupported H3 stream allocation".into()),
        };
        if let Some(observed) = observed {
            if order.is_some_and(|v| v != observed) {
                return Err("inconsistent QPACK stream allocation".into());
            }
            order = Some(observed);
        }
    }
    config.critical_streams = Preferences {
        order: order.ok_or("QPACK stream allocation not observed")?,
        encoder: if encoder.is_some() {
            Startup::Immediate
        } else {
            Startup::OnDemand
        },
        decoder: if decoder.is_some() {
            Startup::Immediate
        } else {
            Startup::OnDemand
        },
        ordered_startup: true,
    };
    let capacity = warm.encoder_instructions.iter().find_map(|i| match i {
        ObservedEncoderInstruction::Capacity { capacity } => Some(*capacity),
        _ => None,
    });
    config.encoder.target_capacity = capacity.unwrap_or(0);
    config.encoder.defer_dynamic_first_section = true;
    config.encoder.insert_on_reuse = sample.insert_on_reuse.ok_or("QPACK reuse policy missing")?;
    config.encoder.field_section_base = FieldSectionBase::FromFieldPreferences;
    config.early_requests = false;
    Ok(config)
}

/// 由底层原生状态机发送 MAX_PUSH_ID 并执行额度限制，不能只补发原始字节。
/// 保留既有请求/流/帧内存上限，采样额度超过预算时拒绝模板而非扩大资源占用。
fn apply_push_credit(config: &mut Config, maximum: Option<u64>) -> Result<(), BoxError> {
    let count = maximum
        .and_then(|id| id.checked_add(1))
        .and_then(|count| usize::try_from(count).ok())
        .filter(|count| *count <= config.max_requests)
        .ok_or("captured MAX_PUSH_ID exceeds native resource budget")?;
    if config.max_pushes != 0 {
        return Err("multiple captured MAX_PUSH_ID frames require ordered replay".into());
    }
    config.max_pushes = count;
    Ok(())
}

fn fresh_integer(previous: u64) -> Result<u64, BoxError> {
    let (low, high) = match previous {
        0..=63 => (0, 63),
        64..=16383 => (64, 16383),
        16384..=1073741823 => (16384, 1073741823),
        _ => (1073741824, (1u64 << 62) - 1),
    };
    let mut bytes = [0; 8];
    rama::tls::boring::core::rand::rand_bytes(&mut bytes)?;
    Ok(low + u64::from_le_bytes(bytes) % (high - low + 1))
}
fn fresh_reserved(previous: u64) -> Result<u64, BoxError> {
    // RFC 9114 的保留标识为 0x1f*N+0x21；保留原来的 varint 宽度。
    loop {
        let value = fresh_integer(previous)?;
        let reserved = (value.saturating_sub(0x21) / 0x1f) * 0x1f + 0x21;
        if rama_quic_proto::VarInt::try_from(reserved)?.size()
            == rama_quic_proto::VarInt::try_from(previous)?.size()
        {
            return Ok(reserved);
        }
    }
}

/// 样本只用于判断编码规则；相同编码更短时继承动态选择，避免把某个值的 Huffman 位固定到所有业务值。
fn infer_huffman(preference: &mut FieldPreferences, name: &[u8], value: &[u8]) {
    fn infer(choice: &mut Option<bool>, bytes: &[u8], prefix: u8) {
        let shorter = h3::qpack::prefix::string_encoded_len(bytes, prefix, true)
            < h3::qpack::prefix::string_encoded_len(bytes, prefix, false);
        if *choice == Some(shorter) {
            *choice = None;
        }
    }
    infer(&mut preference.name_huffman, name, 3);
    infer(&mut preference.value_huffman, value, 7);
    if let Some(insertion) = &mut preference.insertion {
        infer(&mut insertion.name_huffman, name, 5);
        infer(&mut insertion.value_huffman, value, 7);
    }
}

fn infer_value_reuse(fields: &[h3::observation::ObservedFieldRepresentation]) -> Result<bool, BoxError> {
    use h3::observation::FieldRepresentation as R;
    let [first, second] = fields else { return Err("value reuse observations missing".into()); };
    if fields.iter().any(|f| f.never_index || FieldPreferences::from_observed(f).is_none()) {
        return Err("invalid value reuse probe fields".into());
    }
    match (first.representation, second.representation) {
        (R::LiteralStaticName, R::DynamicPostBaseIndex) => Ok(true),
        (R::DynamicIndex | R::DynamicPostBaseIndex, R::DynamicIndex | R::DynamicPostBaseIndex) => Ok(false),
        _ => Err("unsupported measured QPACK value reuse strategy".into()),
    }
}

fn warm_fields_stable(phases: &[Vec<h3::observation::ObservedFieldRepresentation>]) -> bool {
    if phases.len() < 3 { return false; }
    let last = &phases[phases.len() - 1];
    let previous = &phases[phases.len() - 2];
    last.len() == previous.len() && !last.is_empty() && last.iter().zip(previous).all(|(a, b)| {
        FieldPreferences::from_observed(a).is_some_and(|a| FieldPreferences::from_observed(b) == Some(a))
    })
}
fn sample_values<B>(
    request: &Request<B>,
    order: &PseudoHeaderOrder,
) -> Result<Vec<Vec<u8>>, BoxError> {
    let mut values = Vec::new();
    for pseudo in order.iter() {
        let mut value = Vec::new();
        match pseudo {
            PseudoHeader::Method => value.extend_from_slice(request.method().as_str().as_bytes()),
            PseudoHeader::Scheme => value.extend_from_slice(
                request
                    .uri()
                    .scheme()
                    .ok_or("missing probe scheme")?
                    .as_str()
                    .as_bytes(),
            ),
            PseudoHeader::Authority => {
                request.uri().write_h2_authority(&mut value)?;
            }
            PseudoHeader::Path => request.uri().write_h2_path(&mut value),
            _ => return Err("unexpected probe pseudo field".into()),
        }
        values.push(value);
    }
    values.extend(request.headers().iter().map(|(_, v)| v.as_bytes().to_vec()));
    Ok(values)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn value_reuse_policy_requires_complete_supported_observations() {
        use h3::observation::{FieldRepresentation as R, ObservedFieldRepresentation as F};
        let literal = F { representation: R::LiteralStaticName, index: Some(1),
            name_huffman: false, value_huffman: true, never_index: false };
        let post = F { representation: R::DynamicPostBaseIndex, index: Some(0),
            value_huffman: false, ..literal };
        let before = F { representation: R::DynamicIndex, ..post };
        assert!(infer_value_reuse(&[literal, post]).unwrap());
        assert!(!infer_value_reuse(&[before, before]).unwrap());
        assert!(infer_value_reuse(&[]).is_err());
        assert!(infer_value_reuse(&[literal, literal]).is_err());
        assert!(infer_value_reuse(&[literal, F { never_index: true, ..post }]).is_err());
        assert!(infer_value_reuse(&[literal, F { index: None, ..post }]).is_err());
    }
    #[test]
    fn warm_strategy_must_leave_post_base_startup_before_reuse() {
        use h3::observation::{FieldRepresentation as R, ObservedFieldRepresentation as F};
        let field = |representation, index| F { representation, index: Some(index),
            name_huffman: false, value_huffman: false, never_index: false };
        let mut phases = vec![vec![field(R::LiteralStaticName, 0)], vec![field(R::LiteralStaticName, 0)],
            vec![field(R::DynamicPostBaseIndex, 0)]];
        assert!(!warm_fields_stable(&phases));
        phases.push(vec![field(R::DynamicIndex, 2)]);
        assert!(!warm_fields_stable(&phases));
        // 新连接的动态索引数字不是规则；稳定比较只看编码策略。
        phases.push(vec![field(R::DynamicIndex, 3)]);
        assert!(warm_fields_stable(&phases));
        phases.last_mut().unwrap()[0].never_index = true;
        assert!(!warm_fields_stable(&phases));
        assert!(!warm_fields_stable(&[vec![], vec![], vec![]]));
    }
    #[test]
    fn sampled_push_credit_uses_native_quota_and_rejects_excess_or_repeated_frames() {
        let mut config = Config::default();
        apply_push_credit(&mut config, Some(99)).unwrap();
        assert_eq!(config.max_pushes, 100);
        assert!(apply_push_credit(&mut config, Some(99)).is_err());
        for value in [
            None,
            Some(u64::MAX),
            Some(Config::default().max_requests as u64),
        ] {
            let mut config = Config::default();
            assert!(apply_push_credit(&mut config, value).is_err());
            assert_eq!(config.max_pushes, 0);
        }
    }
    #[test]
    fn regenerated_reserved_values_keep_wire_width_and_reserved_pattern() {
        for previous in [
            0x21,
            0x21 + 31 * 100,
            0x21 + 31 * 100000,
            0x21 + 31 * 1000000000,
        ] {
            let mut values = std::collections::BTreeSet::new();
            for _ in 0..32 {
                let value = fresh_reserved(previous).unwrap();
                assert!(SettingId::new(value).is_reserved());
                assert_eq!(
                    rama_quic_proto::VarInt::try_from(value).unwrap().size(),
                    rama_quic_proto::VarInt::try_from(previous).unwrap().size()
                );
                values.insert(value);
            }
            if previous > 63 {
                assert!(values.len() > 1);
            }
        }
    }
    #[test]
    fn sampled_literal_uses_size_policy_without_overriding_explicit_difference() {
        let mut preference = FieldPreferences {
            value_huffman: Some(false),
            ..Default::default()
        };
        infer_huffman(&mut preference, b"x-value", b"~");
        assert_eq!(preference.value_huffman, None);
        let mut preference = FieldPreferences {
            value_huffman: Some(false),
            ..Default::default()
        };
        infer_huffman(&mut preference, b"x-value", b"aaaaaaaaaaaaaaaaaaaa");
        assert_eq!(preference.value_huffman, Some(false));
    }
    #[test]
    fn reset_invalidates_sampling_generation_and_clears_diagnostic_error() {
        let templates = Templates::default();
        let epoch = templates.epoch();
        assert_eq!(templates.status()["epoch"], epoch);
        templates.ports(vec![10001, 10002]);
        templates.failure("prior error");
        templates.reset();
        assert_ne!(epoch, templates.epoch());
        let state = templates.status();
        assert_eq!(state["epoch"], templates.epoch());
        assert_eq!(state["epoch"], epoch + 1);
        assert!(state["error"].is_null());
        assert_eq!(state["probe_ports"], serde_json::json!([10001, 10002]));
        assert!(templates.snapshot(Some("ua")).is_none());
    }
}

/// draft-ietf-quic-version-negotiation 使用的参数编号；能力由报文决定，与浏览器名称无关。
const DRAFT_VERSION_INFORMATION: u64 = 0xff73db;
fn is_version_information(id: TransportParameterId) -> bool {
    id == TransportParameterId::VersionInformation || u64::from(id) == DRAFT_VERSION_INFORMATION
}
fn sample_version_information(
    parameters: &[RawParameter],
) -> Result<Option<rama_quic_proto::version::VersionInformation>, BoxError> {
    let mut selected = parameters.iter().filter(|p| is_version_information(p.id));
    let Some(parameter) = selected.next() else {
        return Ok(None);
    };
    if selected.next().is_some() {
        return Err("ambiguous QUIC version information parameters".into());
    }
    let normalized = RawParameter {
        id: TransportParameterId::VersionInformation,
        value: parameter.value.clone(),
    };
    capture::version_information(&[normalized])
        .map(Some)
        .ok_or_else(|| "invalid QUIC version information".into())
}
