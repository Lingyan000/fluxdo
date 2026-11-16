use std::time::{Duration, SystemTime};

use rama_core::error::{BoxError, BoxErrorExt as _, ErrorContext};
use time::OffsetDateTime;

/// Whole-second ASN.1 timestamps; pre-epoch values are unsupported.
pub(super) fn datetime(t: SystemTime) -> Result<OffsetDateTime, BoxError> {
    let secs = t
        .duration_since(SystemTime::UNIX_EPOCH)
        .context("timestamp before unix epoch")?
        .as_secs();
    let secs = i64::try_from(secs).context("timestamp exceeds i64 seconds")?;
    OffsetDateTime::from_unix_timestamp(secs).context("invalid timestamp")
}

/// Inverse of [`datetime`], with the same whole-second, post-epoch range.
pub(super) fn system_time(t: OffsetDateTime) -> Result<SystemTime, BoxError> {
    let secs = u64::try_from(t.unix_timestamp())
        .map_err(|_pre_epoch| BoxError::from_static_str("timestamp before unix epoch"))?;
    SystemTime::UNIX_EPOCH
        .checked_add(Duration::from_secs(secs))
        .ok_or_else(|| BoxError::from_static_str("timestamp exceeds system time range"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn system_time_inverts_datetime() {
        let t = SystemTime::UNIX_EPOCH + Duration::from_secs(1_800_000_000);
        assert_eq!(system_time(datetime(t).unwrap()).unwrap(), t);
        system_time(OffsetDateTime::UNIX_EPOCH - time::Duration::SECOND).unwrap_err();
    }

    #[test]
    fn datetime_bounds() {
        let epoch = SystemTime::UNIX_EPOCH;
        assert_eq!(
            datetime(epoch + Duration::from_nanos(999_999_999)).unwrap(),
            OffsetDateTime::UNIX_EPOCH
        );
        datetime(epoch - Duration::from_secs(1)).unwrap_err();

        let max_asn1 = epoch + Duration::from_secs(253_402_300_799);
        assert_eq!(datetime(max_asn1).unwrap().year(), 9999);

        // Not every platform's SystemTime reaches past time's own range.
        let beyond_range = time::Date::MAX
            .midnight()
            .assume_utc()
            .unix_timestamp()
            .unsigned_abs()
            + 86_400;
        if let Some(t) = epoch.checked_add(Duration::from_secs(beyond_range)) {
            datetime(t).unwrap_err();
        }
    }
}
