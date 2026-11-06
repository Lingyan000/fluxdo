//! Public receive values and errors remain usable by applications outside the crate.

use rama_core::{
    bytes::Bytes,
    error::{BoxError, ErrorExt as _, error_chain},
};
use rama_quic::{Chunk, ExportKeyingMaterialError};

#[test]
fn a_received_chunk_exposes_its_offset_and_owned_bytes() {
    let chunk = Chunk {
        offset: 17,
        bytes: Bytes::from_static(b"payload"),
    };
    assert_eq!(chunk.offset, 17);
    assert_eq!(chunk.bytes.as_ref(), b"payload");
    let Chunk { offset, bytes } = chunk;
    assert_eq!(offset, 17);
    assert_eq!(bytes, Bytes::from_static(b"payload"));
}

#[test]
fn exporter_errors_support_standard_propagation_and_rama_context() {
    fn propagate() -> Result<(), BoxError> {
        Err::<(), _>(ExportKeyingMaterialError::new())?;
        Ok(())
    }

    let error = propagate().unwrap_err();
    assert!(error.is::<ExportKeyingMaterialError>());
    assert_eq!(error.to_string(), "failed to export keying material");
    let contextual = ExportKeyingMaterialError::new().context("derive application key");
    assert!(error_chain(contextual.as_ref()).any(|e| e.is::<ExportKeyingMaterialError>()));
}

#[test]
fn time_threshold_rejects_invalid_factors_without_changing_the_configuration() {
    use rama_quic::{ConfigError, TransportConfig};

    let mut config = TransportConfig::default();
    for factor in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY, -1.0] {
        assert_eq!(
            config.try_set_time_threshold(factor).unwrap_err(),
            ConfigError::OutOfBounds
        );
    }
    for factor in [0.0, 0.5, 1.125, f32::MAX] {
        config.try_set_time_threshold(factor).unwrap();
    }
}
