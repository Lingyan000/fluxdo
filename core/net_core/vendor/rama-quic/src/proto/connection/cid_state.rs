//! Maintain the state of local connection IDs
use std::collections::VecDeque;

use rama_core::telemetry::tracing::{debug, trace};
use rustc_hash::FxHashMap;

use crate::proto::{Duration, Instant, shared::IssuedCid};
use rama_quic_proto::{ConnectionId, TransportError};

/// How many retirement batches are tracked at once. A peer that keeps retiring identifiers keeps
/// new ones being issued; past this many, a new one joins the latest batch and so retires a
/// little before its lifetime is up, which is always permitted.
const MAX_RETIREMENT_BATCHES: usize = 64;

/// Local connection ID management
pub(super) struct CidState {
    /// Timestamp when issued cids should be retired
    retire_timestamp: VecDeque<CidTimestamp>,
    /// One past the highest sequence advertised to the peer.
    advertised: u64,
    /// Identifiers not yet retired by the peer, keyed by their sequence numbers.
    /// Retain the value to reject retirement of the enclosing packet's destination.
    active_seq: FxHashMap<u64, ConnectionId>,
    /// Sequence number the peer has already retired all CIDs below at our request via `retire_prior_to`
    prev_retire_seq: u64,
    /// Sequence number to set in retire_prior_to field in NEW_CONNECTION_ID frame
    retire_seq: u64,
    /// cid length used to decode short packet
    cid_len: usize,
    //// cid lifetime
    cid_lifetime: Option<Duration>,
}

impl CidState {
    pub(crate) fn new(
        cid_len: usize,
        cid_lifetime: Option<Duration>,
        now: Instant,
        initial: ConnectionId,
        preferred: Option<ConnectionId>,
    ) -> Self {
        let mut active_seq = FxHashMap::default();
        active_seq.insert(0, initial);
        if let Some(cid) = preferred {
            active_seq.insert(1, cid);
        }
        let issued = active_seq.len() as u64;
        let mut this = Self {
            retire_timestamp: VecDeque::new(),
            advertised: issued,
            active_seq,
            prev_retire_seq: 0,
            retire_seq: 0,
            cid_len,
            cid_lifetime,
        };
        // Track lifetime of CIDs used in handshaking
        for seq in 0..issued {
            this.track_lifetime(seq, now);
        }
        this
    }

    /// Find the next timestamp when previously issued CID should be retired
    pub(crate) fn next_timeout(&self) -> Option<Instant> {
        self.retire_timestamp.front().map(|nc| {
            trace!("CID {} will expire at {:?}", nc.sequence, nc.timestamp);
            nc.timestamp
        })
    }

    /// Track the lifetime of issued cids in `retire_timestamp`
    fn track_lifetime(&mut self, new_cid_seq: u64, now: Instant) {
        let Some(lifetime) = self.cid_lifetime else {
            return;
        };

        let expire_timestamp = now.checked_add(lifetime);
        let Some(expire_at) = expire_timestamp else {
            return;
        };

        let at_bound = self.retire_timestamp.len() >= MAX_RETIREMENT_BATCHES;
        let last_record = self.retire_timestamp.back_mut();
        if let Some(last) = last_record {
            // Compare the timestamp with the last inserted record
            // Combine into a single batch if timestamp of current cid is same as the last record,
            // or when no further batch may be tracked
            if expire_at == last.timestamp || at_bound {
                last.sequence = last.sequence.max(new_cid_seq);
                return;
            }
        }

        self.retire_timestamp.push_back(CidTimestamp {
            sequence: new_cid_seq,
            timestamp: expire_at,
        });
    }

    /// Update local CID state when previously issued CID is retired
    ///
    /// Return whether a new CID needs to be pushed that notifies remote peer to respond `RETIRE_CONNECTION_ID`
    pub(crate) fn on_cid_timeout(&mut self) -> bool {
        // Whether the peer hasn't retired all the CIDs we asked it to yet
        let unretired_ids_found =
            (self.prev_retire_seq..self.retire_seq).any(|seq| self.active_seq.contains_key(&seq));

        let current_retire_prior_to = self.retire_seq;
        let next_retire_sequence = self
            .retire_timestamp
            .pop_front()
            .map(|seq| seq.sequence + 1);

        // According to RFC:
        // Endpoints SHOULD NOT issue updates of the Retire Prior To field
        // before receiving RETIRE_CONNECTION_ID frames that retire all
        // connection IDs indicated by the previous Retire Prior To value.
        // https://tools.ietf.org/html/draft-ietf-quic-transport-29#section-5.1.2
        if !unretired_ids_found {
            // All Cids are retired, `prev_retire_cid_seq` can be assigned to `retire_cid_seq`
            self.prev_retire_seq = self.retire_seq;
            // Advance `retire_seq` if next cid that needs to be retired exists
            if let Some(next_retire_prior_to) = next_retire_sequence {
                self.retire_seq = next_retire_prior_to;
            }
        }

        // Check if retirement of all CIDs that reach their lifetime is still needed
        // According to RFC:
        // An endpoint MUST NOT
        // provide more connection IDs than the peer's limit.  An endpoint MAY
        // send connection IDs that temporarily exceed a peer's limit if the
        // NEW_CONNECTION_ID frame also requires the retirement of any excess,
        // by including a sufficiently large value in the Retire Prior To field.
        //
        // If yes (return true), a new CID must be pushed with updated `retire_prior_to` field to remote peer.
        // If no (return false), it means CIDs that reach the end of lifetime have been retired already. Do not push a new CID in order to avoid violating above RFC.
        (current_retire_prior_to..self.retire_seq).any(|seq| self.active_seq.contains_key(&seq))
    }

    /// Update cid state when `NewIdentifiers` event is received
    pub(crate) fn new_cids(&mut self, ids: &[IssuedCid], now: Instant) {
        // `ids` could be `None` once active_connection_id_limit is set to 1 by peer
        let Some(last_cid) = ids.last() else { return };
        // Record the timestamp of CID with the largest seq number
        let sequence = last_cid.sequence;
        ids.iter().for_each(|frame| {
            self.active_seq.insert(frame.sequence, frame.id);
        });
        self.track_lifetime(sequence, now);
    }

    /// Record an encoded NEW_CONNECTION_ID, including retransmissions.
    pub(crate) fn on_cid_sent(&mut self, sequence: u64) {
        self.advertised = self.advertised.max(sequence + 1);
    }

    /// Update CidState for receipt of a `RETIRE_CONNECTION_ID` frame
    ///
    /// Returns whether a new CID can be issued when the frame retired an identifier still in
    /// use, `None` when it was retired already, or an error if the frame was illegal.
    pub(crate) fn on_cid_retirement(
        &mut self,
        sequence: u64,
        limit: u64,
        received_dcid: ConnectionId,
    ) -> Result<Option<bool>, TransportError> {
        if self.cid_len == 0 {
            return Err(TransportError::PROTOCOL_VIOLATION(
                "RETIRE_CONNECTION_ID when CIDs aren't in use",
            ));
        }
        if sequence >= self.advertised {
            debug!(
                sequence,
                "got RETIRE_CONNECTION_ID for unissued sequence number"
            );
            return Err(TransportError::PROTOCOL_VIOLATION(
                "RETIRE_CONNECTION_ID for unissued sequence number",
            ));
        }
        // RFC 9000 §19.16: the peer must use another identifier for this packet.
        // Check before removing the route, including handshake/preferred-address IDs.
        if self.active_seq.get(&sequence) == Some(&received_dcid) {
            return Err(TransportError::PROTOCOL_VIOLATION(
                "RETIRE_CONNECTION_ID for enclosing packet destination",
            ));
        }
        if self.active_seq.remove(&sequence).is_none() {
            return Ok(None);
        }
        // Consider a scenario where peer A has active remote cid 0,1,2.
        // Peer B first send a NEW_CONNECTION_ID with cid 3 and retire_prior_to set to 1.
        // Peer A processes this NEW_CONNECTION_ID frame; update remote cid to 1,2,3
        // and meanwhile send a RETIRE_CONNECTION_ID to retire cid 0 to peer B.
        // If peer B doesn't check the cid limit here and send a new cid again, peer A will then face CONNECTION_ID_LIMIT_ERROR
        Ok(Some(limit > self.active_seq.len() as u64))
    }

    /// Length of local Connection IDs
    pub(crate) fn cid_len(&self) -> usize {
        self.cid_len
    }

    /// The value for `retire_prior_to` field in `NEW_CONNECTION_ID` frame
    pub(crate) fn retire_prior_to(&self) -> u64 {
        self.retire_seq
    }

    #[cfg(test)]
    pub(crate) fn active_seq(&self) -> (u64, u64) {
        let mut min = u64::MAX;
        let mut max = u64::MIN;
        for n in self.active_seq.keys() {
            if n < &min {
                min = *n;
            }
            if n > &max {
                max = *n;
            }
        }
        (min, max)
    }

    #[cfg(test)]
    pub(crate) fn assign_retire_seq(&mut self, v: u64) -> u64 {
        // Cannot retire more CIDs than what have been issued
        debug_assert!(v <= *self.active_seq.keys().max().unwrap() + 1);
        assert!(v >= self.retire_seq);
        // Already-retired IDs have already been replaced. The test helper
        // must not issue replacements for holes a second time.
        let n = self
            .active_seq
            .keys()
            .filter(|&&seq| (self.retire_seq..v).contains(&seq))
            .count() as u64;
        self.retire_seq = v;
        n
    }
}

/// Data structure that records when issued cids should be retired
#[derive(Copy, Clone, Eq, PartialEq)]
struct CidTimestamp {
    /// Highest cid sequence number created in a batch
    sequence: u64,
    /// Timestamp when cid needs to be retired
    timestamp: Instant,
}

#[cfg(test)]
mod tests {
    use super::*;
    use rama_quic_proto::{RESET_TOKEN_SIZE, ResetToken, TransportErrorCode};

    #[test]
    fn cid_retirement_rejects_unissued_and_packet_destination_before_mutation() {
        let initial = ConnectionId::new(&[1; 8]);
        let preferred = ConnectionId::new(&[2; 8]);
        let another = ConnectionId::new(&[3; 8]);
        let now = Instant::now();

        for with_preferred in [false, true] {
            let mut state =
                CidState::new(8, None, now, initial, with_preferred.then_some(preferred));
            let before = state.active_seq.clone();
            for sequence in [state.advertised, state.advertised + 1, (1 << 62) - 1] {
                let error = state.on_cid_retirement(sequence, 4, another).unwrap_err();
                assert_eq!(error.code, TransportErrorCode::PROTOCOL_VIOLATION);
                assert_eq!(state.active_seq, before);
            }

            // The same admission rule covers IDs supplied in transport parameters
            // and later NEW_CONNECTION_ID frames, not just the handshake ID.
            let next = state.advertised;
            state.new_cids(
                &[IssuedCid {
                    sequence: next,
                    id: another,
                    reset_token: ResetToken::from([4; RESET_TOKEN_SIZE]),
                }],
                now,
            );
            let pending = state.active_seq.clone();
            assert_eq!(
                state.on_cid_retirement(next, 4, initial).unwrap_err().code,
                TransportErrorCode::PROTOCOL_VIOLATION
            );
            assert_eq!(state.active_seq, pending);
            state.on_cid_sent(next);
            state.on_cid_sent(0); // A reordered retransmission cannot lower the bound.
            let before = state.active_seq.clone();
            for (&sequence, &id) in &before {
                let error = state.on_cid_retirement(sequence, 4, id).unwrap_err();
                assert_eq!(error.code, TransportErrorCode::PROTOCOL_VIOLATION);
                assert_eq!(state.active_seq, before);
            }

            assert_eq!(state.on_cid_retirement(0, 4, another).unwrap(), Some(true));
            assert_eq!(state.on_cid_retirement(0, 4, another).unwrap(), None);
            assert_eq!(state.active_seq.len(), before.len() - 1);
        }

        let mut zero = CidState::new(0, None, now, ConnectionId::new(&[]), None);
        assert_eq!(
            zero.on_cid_retirement(0, 4, another).unwrap_err().code,
            TransportErrorCode::PROTOCOL_VIOLATION
        );
        assert_eq!(zero.active_seq.len(), 1);
    }

    /// A peer that retires every identifier it is given keeps new ones being issued; however
    /// long it keeps at it, the retirement schedule stays bounded and still retires the newest.
    #[test]
    fn retirement_batches_stay_bounded_under_identifier_churn() {
        let start = Instant::now();
        let mut state = CidState::new(
            8,
            Some(Duration::from_mins(10)),
            start,
            ConnectionId::new(&[0; 8]),
            None,
        );
        for sequence in 1..10_000u64 {
            let issued = IssuedCid {
                sequence,
                id: ConnectionId::new(&[1; 8]),
                reset_token: ResetToken::from([0; RESET_TOKEN_SIZE]),
            };
            state.new_cids(&[issued], start + Duration::from_millis(sequence));
            assert!(state.retire_timestamp.len() <= MAX_RETIREMENT_BATCHES);
        }
        assert_eq!(state.retire_timestamp.back().unwrap().sequence, 9_999);
        assert_eq!(state.next_timeout(), Some(start + Duration::from_mins(10)));
    }
}
