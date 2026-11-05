//! Compile a retained parameter tuple using the engine's typed profile builders.

use rama_core::{
    error::{BoxError, BoxErrorExt as _},
    telemetry::tracing,
};
use rama_quic_proto::{
    capture::version_information,
    profile::{
        ConnectionIdProfile, InitialFlightLayout, PacketizationProfile, ParameterOrder,
        QuicProfile, TransportLimits, TransportParameterProfile, initial::RecordedInitialFlight,
    },
    transport_parameters::{RawParameter, TransportParameterId},
    version::{
        ClientVersionPolicy, ReservedQuicVersion, ReservedVersionGrease, VersionInformation,
    },
};
use rama_ua::profile::capture::{
    order::{OrderCaptureLimits, OrderNamespace, OrderedProtocolCapture, ProtocolValue},
    quic::QuicFlightCapture,
};

/// `None` when this engine has no equivalent: the native transport profile is
/// kept and the uncompiled components are reported by admission.
///
/// Without `recorded_layout` the flight only checks the tuple and sizes the destination CID.
pub(in crate::profile) fn prepare(
    parameters: &OrderedProtocolCapture,
    versions: Option<&OrderedProtocolCapture>,
    flight: Option<&QuicFlightCapture>,
    recorded_layout: bool,
) -> Result<Option<QuicProfile>, BoxError> {
    parameters.canonical(OrderCaptureLimits::default())?;
    if !matches!(parameters.namespace, OrderNamespace::QuicParameter) {
        return Err(BoxError::from_static_str(
            "captured QUIC parameters have the wrong namespace",
        ));
    }
    let mut literals = Vec::with_capacity(parameters.fields.len());
    let mut order = Vec::with_capacity(parameters.fields.len());
    let mut local_cid_len = None;
    for field in &parameters.fields {
        let id = TransportParameterId::from(field.id);
        order.push(id);
        match &field.value {
            ProtocolValue::Literal(value) => literals.push(RawParameter {
                id,
                value: value.to_vec(),
            }),
            ProtocolValue::ConnectionLength(length)
                if id == TransportParameterId::InitialSourceConnectionId =>
            {
                local_cid_len = Some(u8::try_from(*length).map_err(|_error| {
                    BoxError::from_static_str("captured QUIC source CID is too long")
                })?);
            }
            ProtocolValue::ConnectionLength(_) => {
                return Ok(unsupported("captured QUIC parameter binding"));
            }
        }
    }
    // Never invent connection identifiers to pass through the raw-value adapter.
    // Its parser reads literals; the engine regenerates the omitted bindings.
    let information = version_information(&literals);
    if information.is_none()
        && literals
            .iter()
            .any(|parameter| parameter.id == TransportParameterId::VersionInformation)
    {
        return Ok(unsupported("malformed captured QUIC version_information"));
    }
    let version_policy = if let Some(information) = &information {
        let Some(policy) = version_policy(information)? else {
            return Ok(unsupported("captured QUIC version policy is unsupported"));
        };
        policy
    } else {
        // RFC 9368's parameter is optional. Safari omits it; the Initial
        // header still supplies an observed version, without a compatible offer.
        let Some(flight) = flight else {
            return Ok(unsupported(
                "QUIC version absent from parameters and flight",
            ));
        };
        let Ok(policy) = ClientVersionPolicy::new(flight.flight.version) else {
            return Ok(unsupported("captured unsupported QUIC flight version"));
        };
        policy.try_with_version_information(false)?
    };
    let chosen = information.as_ref().map(VersionInformation::chosen);
    let available = information
        .as_ref()
        .map_or(&[][..], |info| info.available());
    let local_cid_len = local_cid_len.ok_or_else(|| {
        BoxError::from_static_str("captured QUIC parameters omit the source CID binding")
    })?;
    let mut ids = ConnectionIdProfile::standard().try_with_local_len(local_cid_len)?;
    if let Some(flight) = flight {
        if chosen.is_some_and(|version| flight.flight.version != version)
            || flight.flight.chosen_version != chosen
            || flight.flight.available_versions != available
            || flight.flight.parameters != order
            || flight.flight.scid_len != usize::from(local_cid_len)
        {
            return Err(BoxError::from_static_str(
                "captured QUIC flight and parameter tuple disagree",
            ));
        }
        ids =
            ids.try_with_initial_destination_len(u8::try_from(flight.flight.dcid_len).map_err(
                |_error| BoxError::from_static_str("captured QUIC destination CID is too long"),
            )?)?;
    }
    if let Some(versions) = versions {
        versions.canonical(OrderCaptureLimits::default())?;
        if !matches!(versions.namespace, OrderNamespace::QuicVersion)
            || !versions
                .fields
                .iter()
                .map(|field| field.id)
                .eq(available.iter().map(|version| u64::from(version.as_u32())))
        {
            return Err(BoxError::from_static_str(
                "captured QUIC version list and parameter tuple disagree",
            ));
        }
    }
    let layout = TransportParameterProfile::try_from_sent(&literals)?
        .try_with_order(ParameterOrder::fixed_with_explicit_defaults(order))?;
    let limits = TransportLimits::try_from_sent(&literals)?;
    let mut profile = QuicProfile::standard()
        .with_versions(version_policy)
        .with_transport_parameters(layout)
        .with_connection_ids(ids)
        .with_grease_quic_bit(
            literals
                .iter()
                .any(|parameter| parameter.id == TransportParameterId::GreaseQuicBit),
        )
        .try_with_limits(limits)?;
    if let Some(flight) = flight.filter(|_| recorded_layout) {
        match RecordedInitialFlight::try_from(&flight.flight) {
            Ok(layout) => {
                profile = profile.with_packetization(
                    PacketizationProfile::standard()
                        .with_layout(InitialFlightLayout::Recorded(layout)),
                );
            }
            // Native packetization applies; admission reports the uncompiled flight.
            Err(error) => {
                tracing::debug!(%error, "captured QUIC first flight has no native layout");
            }
        }
    }
    Ok(Some(profile))
}

fn unsupported(shape: &'static str) -> Option<QuicProfile> {
    tracing::debug!(
        shape,
        "captured QUIC transport replays with the native profile"
    );
    None
}

fn version_policy(
    information: &VersionInformation,
) -> Result<Option<ClientVersionPolicy>, BoxError> {
    let mut real = Vec::with_capacity(information.available().len());
    let mut reserved = None;
    for (index, &version) in information.available().iter().enumerate() {
        if version.is_reserved() {
            if reserved.is_some() {
                return Ok(None);
            }
            let literal = ReservedQuicVersion::try_from(version)?;
            reserved = Some(if index == 0 {
                ReservedVersionGrease::FixedFirst(literal)
            } else if index + 1 == information.available().len() {
                ReservedVersionGrease::FixedLast(literal)
            } else {
                return Ok(None);
            });
        } else {
            real.push(version);
        }
    }
    // The capture describes the compatible offer, not a restart policy. Keep
    // the observed first version pinned when a peer sends Version Negotiation.
    let Ok(policy) = ClientVersionPolicy::new(information.chosen())
        .and_then(|policy| policy.try_with_compatible(real))
    else {
        return Ok(None);
    };
    Ok(Some(policy.with_reserved_version_grease(
        reserved.unwrap_or(ReservedVersionGrease::None),
    )))
}
