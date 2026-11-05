//! Compile a selected QUIC tuple into ordinary native configuration extensions.
//!
//! The outer UA connect modifier selects and admits a complete connection tuple,
//! then this compiler supplies `TlsClientConfig` and `QuicProfile` extensions.
//! The native connector consumes those settings exactly as it would settings from
//! a custom layer or relay. It owns the endpoint, configuration cache, peer-bound
//! TLS session and connection I/O; it never receives a counted profile.
//!
//! Supply the same fixed policy and provider to the compiler and native connector.
//! Current request overrides retain their ordinary precedence. The common UA
//! modifier applies admitted HTTP settings before connecting and publishes profile
//! facts only after its inner connector succeeds. Its context check is at that
//! boundary; this compiler introduces no native callback or generated-hello check.
//!
//! The ticket namespace combines the stable profile identity with the caller's
//! scope, independently of each connection draw. A private UA marker shares the
//! installed and original scope values so a repeated preparation cannot wrap the
//! namespace again. It holds no native session, provider or TLS configuration.
//!
//! Capability admission covers only the native subset actually compiled here.
//! In particular, HTTP/3 startup/QPACK sequences need their own implementation;
//! a decoded capture alone does not grant replay support.

#[cfg(feature = "boring")]
pub(crate) mod tls;
#[cfg(feature = "boring")]
pub(in crate::profile) mod transport;

use std::sync::Arc;

use crate::tls::QuicClientConfigProvider;
use rama_core::{
    error::BoxError,
    extensions::{Extensions, ExtensionsRef},
};
use rama_net::{AuthorityInputExt, ProtocolInputExt};
use rama_quic_proto::profile::{InitialFlightLayout, QuicProfile};
use rama_tls::client::{TlsClientConfig, TlsDerivedPolicy};
use rama_ua::profile::{
    capture::joint::CapturedSlotKind,
    replay::connection::{
        PreparedConnectionComponents,
        compiler::{
            CompiledConnectionProfile, ConnectionProfileCompiler as Compiler,
            InstalledConnectionProfile,
        },
    },
    selection::variants::ConnectionSelection,
};

#[cfg(feature = "boring")]
use {
    crate::tls::BoringTlsProvider,
    rama_core::{error::BoxErrorExt as _, extensions::Extension, telemetry::tracing},
    rama_net::{
        address::Host,
        tls::{ApplicationProtocol, TlsAlpn},
    },
    rama_tls::{
        alpn::required_alpn_override,
        client::{
            TlsClientConfigProvider as _, TlsConnectionReuse, TlsServerName, TlsSessionProfileScope,
        },
    },
    rama_ua::{
        TlsAgent, UserAgent,
        profile::{
            capture::tls::{TlsCaptureTransport, TlsCapturedExtensionValue},
            replay::request::{
                LoweredProfileItem, ProfilePreservationDifference, ProfilePreservationReport,
            },
        },
    },
    rama_utils::fmt::hex,
};

/// Register with the outer UA connect modifier around a native QUIC connector.
///
/// Supply the same fixed TLS policy and provider as that connector. Request
/// overrides retain their normal precedence. Compile once for each connection
/// input; use a fresh input to select a different native recipe. Captured TLS
/// currently requires BoringSSL; other providers report unsupported components
/// during admission.
#[derive(Debug, Clone)]
pub struct ConnectionProfileCompiler {
    policy: TlsClientConfig,
    provider: Arc<dyn QuicClientConfigProvider>,
}

impl ConnectionProfileCompiler {
    pub fn new(policy: TlsClientConfig, provider: Arc<dyn QuicClientConfigProvider>) -> Self {
        Self { policy, provider }
    }
}

impl<Input> Compiler<Input> for ConnectionProfileCompiler
where
    Input: AuthorityInputExt + ProtocolInputExt + ExtensionsRef,
{
    type Compiled = CompiledConnection;

    fn compile(
        &self,
        input: &Input,
        selection: &ConnectionSelection,
        components: &mut PreparedConnectionComponents,
    ) -> Result<CompiledConnection, BoxError> {
        self.compile_recipe(input, selection, components)
    }
}

#[cfg(feature = "boring")]
fn lower(report: &mut ProfilePreservationReport, item: LoweredProfileItem) {
    report.push(ProfilePreservationDifference::LoweredProfileItem { item });
}

/// Admitted settings moved into the request before the native connector runs.
#[derive(Debug)]
pub struct CompiledConnection {
    native: Option<CompiledQuic>,
    /// Transport replayed under the caller's own TLS configuration.
    caller_tls_transport: Option<QuicProfile>,
}

#[derive(Debug)]
struct CompiledQuic {
    tls: TlsClientConfig,
    transport: Option<QuicProfile>,
    reuse: TlsDerivedPolicy,
    #[cfg(feature = "boring")]
    scope: AppliedSessionScope,
}

// Retry the same request without treating our installed scope as new caller
// input. Arc identity also distinguishes a later caller replacement. Both values
// share their existing storage; no native session or copied settings are kept.
#[cfg(feature = "boring")]
#[derive(Debug, Clone, Extension)]
#[extension(tags(ua))]
struct AppliedSessionScope {
    caller: Option<Arc<TlsSessionProfileScope>>,
    installed: Arc<TlsSessionProfileScope>,
}

impl CompiledConnectionProfile for CompiledConnection {
    fn supports(&self, component: CapturedSlotKind) -> bool {
        let Some(native) = &self.native else {
            return matches!(
                component,
                CapturedSlotKind::QuicParameters | CapturedSlotKind::QuicVersions
            ) && self.caller_tls_transport.is_some();
        };
        match component {
            CapturedSlotKind::QuicTls => true,
            CapturedSlotKind::QuicFirstFlight => native.transport.as_ref().is_some_and(|profile| {
                matches!(
                    profile.packetization().layout(),
                    InitialFlightLayout::Recorded(_)
                )
            }),
            CapturedSlotKind::QuicParameters | CapturedSlotKind::QuicVersions => {
                native.transport.is_some()
            }
            _ => false,
        }
    }
}

impl<Input> InstalledConnectionProfile<Input> for CompiledConnection {
    type Bindings = ();

    fn apply(self, extensions: &Extensions) {
        if let Some(transport) = self.caller_tls_transport {
            extensions.insert(transport);
        }
        if let Some(native) = self.native {
            native.tls.write_to(extensions);
            if let Some(transport) = native.transport {
                extensions.insert(transport);
            }
            extensions.insert(native.reuse);
            #[cfg(feature = "boring")]
            extensions.insert(native.scope);
        }
    }
}

impl ConnectionProfileCompiler {
    #[cfg(not(feature = "boring"))]
    fn compile_recipe(
        &self,
        _input: &(impl AuthorityInputExt + ProtocolInputExt + ExtensionsRef),
        _selection: &ConnectionSelection,
        _components: &mut PreparedConnectionComponents,
    ) -> Result<CompiledConnection, BoxError> {
        let _ = (&self.policy, &self.provider);
        Ok(CompiledConnection {
            native: None,
            caller_tls_transport: None,
        })
    }

    #[cfg(feature = "boring")]
    fn compile_recipe(
        &self,
        input: &(impl AuthorityInputExt + ProtocolInputExt + ExtensionsRef),
        selection: &ConnectionSelection,
        components: &mut PreparedConnectionComponents,
    ) -> Result<CompiledConnection, BoxError> {
        let unsupported = || CompiledConnection {
            native: None,
            caller_tls_transport: None,
        };
        if components.tls.is_none() && caller_keeps_tls(input.extensions()) {
            return caller_tls_transport(input.extensions(), components);
        }
        if self.provider.pool_classifier() != BoringTlsProvider.pool_classifier() {
            return Ok(unsupported());
        }
        let Some(capture) = components.tls.take() else {
            return Ok(unsupported());
        };
        if !matches!(capture.transport, TlsCaptureTransport::Quic) {
            return Ok(unsupported());
        }
        if input
            .target_protocol()
            .is_none_or(|protocol| !protocol.is_secure())
        {
            return Err(BoxError::from_static_str(
                "captured QUIC requires a secure origin",
            ));
        }
        let authority = input
            .target_authority()
            .ok_or_else(|| BoxError::from_static_str("captured QUIC requires a destination"))?;
        // An explicit caller offer replaces the captured one, lowered to carry HTTP/3.
        let caller_alpn = input.extensions().get_ref::<TlsAlpn>().map(|offer| {
            required_alpn_override(ApplicationProtocol::HTTP_3, Some(offer)).map_or_else(
                || offer.clone(),
                |required| TlsAlpn([required].into_iter().collect()),
            )
        });
        let policy = self.policy.clone().with_overrides(input.extensions());
        let identity = policy
            .as_extensions()
            .get_ref::<TlsServerName>()
            .map_or(&authority.host, |name| &name.0);
        let captured_sni = capture.extensions.iter().any(|extension| {
            matches!(
                extension.value,
                TlsCapturedExtensionValue::ServerName { present: true }
            )
        });
        let report = &mut components.preservation_report;
        if captured_sni != matches!(identity, Host::Name(_)) {
            // SNI presence follows the destination identity.
            lower(report, LoweredProfileItem::TlsServerNamePresence);
        }
        let transport = compile_transport(input.extensions(), components, true)?;
        let report = &mut components.preservation_report;
        let mut wire = tls::compile(&policy, &capture, report)?;
        if let Some(caller) = &caller_alpn {
            let captured = wire.as_extensions().get_ref::<TlsAlpn>();
            if captured.is_none_or(|captured| {
                !caller
                    .0
                    .iter()
                    .map(ApplicationProtocol::as_bytes)
                    .eq(captured.0.iter().map(ApplicationProtocol::as_bytes))
            }) {
                lower(report, LoweredProfileItem::CallerTlsAlpn);
                wire.set_alpn(caller.0.clone());
            }
        }
        let current_scope = policy.as_extensions().get_arc::<TlsSessionProfileScope>();
        let caller_scope = match input.extensions().get_ref::<AppliedSessionScope>() {
            Some(previous)
                if current_scope
                    .as_ref()
                    .is_some_and(|current| Arc::ptr_eq(current, &previous.installed)) =>
            {
                previous.caller.clone()
            }
            _ => current_scope,
        };
        let scope = match &caller_scope {
            Some(caller) => format!(
                "rama-quic-profile:{}:scope:{}",
                hex(&selection.profile.0),
                caller.0
            ),
            None => format!("rama-quic-profile:{}:none", hex(&selection.profile.0)),
        };
        let installed = Arc::new(TlsSessionProfileScope(scope.into()));
        wire.as_extensions().insert_arc(installed.clone());
        let caller = TlsConnectionReuse::new(self.provider.clone(), input.extensions());
        let derived = input.extensions().fork();
        wire.write_to(&derived);
        let Some(reuse) = caller.for_derived_settings(&derived) else {
            tracing::debug!("captured QUIC TLS policy is not comparable; using native TLS");
            lower(
                &mut components.preservation_report,
                LoweredProfileItem::TlsNativeConnection,
            );
            return Ok(unsupported());
        };
        Ok(CompiledConnection {
            caller_tls_transport: None,
            native: Some(CompiledQuic {
                tls: wire,
                transport,
                reuse,
                scope: AppliedSessionScope {
                    caller: caller_scope,
                    installed,
                },
            }),
        })
    }
}

/// The caller asked to keep its own TLS via [`TlsAgent::Preserve`].
#[cfg(feature = "boring")]
fn caller_keeps_tls(extensions: &Extensions) -> bool {
    extensions
        .get_ref::<UserAgent>()
        .and_then(UserAgent::tls_agent)
        == Some(TlsAgent::Preserve)
}

/// QUIC transport under the caller's TLS: its ClientHello sizes the Initial
/// packets, so the recorded layout is left out and admission reports the flight.
#[cfg(feature = "boring")]
fn caller_tls_transport(
    extensions: &Extensions,
    components: &mut PreparedConnectionComponents,
) -> Result<CompiledConnection, BoxError> {
    Ok(CompiledConnection {
        native: None,
        caller_tls_transport: compile_transport(extensions, components, false)?,
    })
}

/// Compile the captured parameter tuple unless the caller installed its own transport.
#[cfg(feature = "boring")]
fn compile_transport(
    extensions: &Extensions,
    components: &mut PreparedConnectionComponents,
    recorded_layout: bool,
) -> Result<Option<QuicProfile>, BoxError> {
    let flight = components.quic_first_flight.take();
    let transport = match components.quic_parameters.take() {
        Some(parameters) => transport::prepare(
            &parameters,
            components.quic_versions.take().as_ref(),
            flight.as_ref(),
            recorded_layout,
        )?,
        None => None,
    };
    if transport.as_ref().is_some_and(|transport| {
        extensions
            .get_ref::<QuicProfile>()
            .is_some_and(|caller| caller != transport)
    }) {
        // The caller's transport profile stays installed.
        lower(
            &mut components.preservation_report,
            LoweredProfileItem::CallerQuicProfile,
        );
        return Ok(None);
    }
    Ok(transport)
}
