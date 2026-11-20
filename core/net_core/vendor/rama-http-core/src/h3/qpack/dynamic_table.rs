//! The QPACK dynamic table (RFC 9204 §3.2), shared by the encoder and decoder.
//!
//! Entries are addressed by *absolute* index, assigned in insertion order and never reused. The
//! oldest present entry has absolute index `dropped()`; the next entry to be inserted will have
//! absolute index `insert_count()`. Reference counts are used only by the encoder, which must not
//! evict an entry still referenced by an unacknowledged field section (RFC 9204 §2.1.1.1); the
//! decoder never adds references, so its eviction is always permitted.

use std::collections::VecDeque;

use rama_core::bytes::Bytes;

/// Per-entry overhead added to the name and value lengths for accounting (RFC 9204 §3.2.1).
pub const ENTRY_OVERHEAD: u64 = 32;

/// The byte size an entry with the given name and value occupies in the table (RFC 9204 §3.2.1).
#[must_use]
pub fn entry_size(name: &[u8], value: &[u8]) -> u64 {
    name.len() as u64 + value.len() as u64 + ENTRY_OVERHEAD
}

#[derive(Clone)]
struct Entry {
    name: Bytes,
    value: Bytes,
    refs: usize,
}

impl Entry {
    fn size(&self) -> u64 {
        entry_size(&self.name, &self.value)
    }
}

/// Why an insertion could not be performed.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum InsertError {
    /// The entry is larger than the table's current capacity, so it can never fit.
    TooLarge,
    /// Making room would require evicting an entry that is still referenced.
    Blocked,
    /// The absolute insertion count cannot be represented.
    InsertCountOverflow,
}

/// The QPACK dynamic table.
#[derive(Clone)]
pub struct DynamicTable {
    entries: VecDeque<Entry>,
    /// The current maximum capacity (set by Set Dynamic Table Capacity), never above `max_capacity`.
    capacity: u64,
    /// The upper bound on capacity, from `SETTINGS_QPACK_MAX_TABLE_CAPACITY`.
    max_capacity: u64,
    /// The current size (sum of entry sizes).
    size: u64,
    /// The total number of entries ever inserted (the next absolute index).
    inserted: u64,
}

impl DynamicTable {
    /// Create a table whose capacity may grow up to `max_capacity` bytes. Its current capacity
    /// starts at zero until a Set Dynamic Table Capacity instruction raises it.
    #[must_use]
    pub fn new(max_capacity: u64) -> Self {
        Self {
            entries: VecDeque::new(),
            capacity: 0,
            max_capacity,
            size: 0,
            inserted: 0,
        }
    }

    /// The configured maximum capacity (`SETTINGS_QPACK_MAX_TABLE_CAPACITY`).
    #[must_use]
    pub fn max_capacity(&self) -> u64 {
        self.max_capacity
    }

    /// The current maximum capacity.
    #[must_use]
    pub fn capacity(&self) -> u64 {
        self.capacity
    }

    /// The current size in bytes.
    #[must_use]
    pub fn size(&self) -> u64 {
        self.size
    }

    /// `MaxEntries = floor(MaxTableCapacity / 32)` (RFC 9204 §3.2.2), from the *configured maximum*
    /// capacity. Used for Required Insert Count wraparound.
    #[must_use]
    pub fn max_entries(&self) -> u64 {
        self.max_capacity / ENTRY_OVERHEAD
    }

    /// The total number of entries ever inserted; equivalently, the next absolute index.
    #[must_use]
    pub fn insert_count(&self) -> u64 {
        self.inserted
    }

    /// The absolute index of the oldest entry still present (equal to `insert_count` when empty).
    #[must_use]
    pub fn dropped(&self) -> u64 {
        self.inserted - self.entries.len() as u64
    }

    fn slot(&self, abs: u64) -> Option<usize> {
        if abs < self.dropped() || abs >= self.inserted {
            return None;
        }
        usize::try_from(abs - self.dropped()).ok()
    }

    /// The name and value of the entry at absolute index `abs`, if present.
    #[must_use]
    pub fn get(&self, abs: u64) -> Option<(Bytes, Bytes)> {
        let slot = self.slot(abs)?;
        let e = &self.entries[slot];
        Some((e.name.clone(), e.value.clone()))
    }

    /// Borrow an entry while inspecting its octets, without retaining table storage.
    pub(super) fn get_ref(&self, abs: u64) -> Option<(&[u8], &[u8])> {
        let entry = &self.entries[self.slot(abs)?];
        Some((&entry.name, &entry.value))
    }

    /// Set the current maximum capacity (RFC 9204 §3.2.3), evicting oldest entries until the size
    /// fits. Returns `false` if `capacity` exceeds the configured maximum.
    ///
    /// This performs unconditional eviction, so a caller that tracks references must not reduce
    /// capacity below its referenced entries.
    pub fn set_capacity(&mut self, capacity: u64) -> bool {
        if capacity > self.max_capacity {
            return false;
        }
        self.capacity = capacity;
        // Eviction stops with the entries even if the size accounting were ever wrong.
        while self.size > self.capacity && self.evict_front().is_some() {}
        true
    }

    fn evict_front(&mut self) -> Option<u64> {
        let entry = self.entries.pop_front()?;
        self.size -= entry.size();
        Some(self.dropped() - 1)
    }

    /// Check insertion before allocating or mutating the table. An encoder supplies its Known
    /// Received Count; a decoder supplies `None` because encoder-stream ordering permits eviction.
    pub fn can_insert(&self, need: u64, acknowledged: Option<u64>) -> Result<(), InsertError> {
        if self.inserted == u64::MAX {
            return Err(InsertError::InsertCountOverflow);
        }
        if need > self.capacity {
            return Err(InsertError::TooLarge);
        }
        if let Some(known_received_count) = acknowledged {
            let mut freed = self.capacity - self.size;
            for (offset, entry) in self.entries.iter().enumerate() {
                if freed >= need {
                    break;
                }
                if entry.refs > 0 || self.dropped() + offset as u64 >= known_received_count {
                    return Err(InsertError::Blocked);
                }
                freed += entry.size();
            }
        }
        Ok(())
    }

    /// Preflight a batch whose new entries must coexist without intervening acknowledgments.
    /// Capacity initialization is allowed only for an empty table; ordinary insertions
    /// retain the existing per-entry path and eviction policy.
    pub(super) fn can_insert_batch(
        &self,
        capacity: u64,
        count: u64,
        bytes: u64,
        acknowledged: u64,
    ) -> Result<(), InsertError> {
        if self.inserted.checked_add(count).is_none() {
            return Err(InsertError::InsertCountOverflow);
        }
        if capacity > self.max_capacity || bytes > capacity {
            return Err(InsertError::TooLarge);
        }
        if capacity == self.capacity {
            self.can_insert(bytes, Some(acknowledged))
        } else if self.entries.is_empty() {
            Ok(())
        } else {
            Err(InsertError::Blocked)
        }
    }

    /// Insert an entry, evicting as needed (RFC 9204 §3.2.2). An encoder must supply its
    /// Known Received Count: even an unreferenced entry cannot be evicted until acknowledged.
    /// The decoder supplies `None` and applies the peer's ordered instructions unconditionally.
    pub fn insert(
        &mut self,
        name: Bytes,
        value: Bytes,
        acknowledged: Option<u64>,
    ) -> Result<u64, InsertError> {
        let need = entry_size(&name, &value);
        self.can_insert(need, acknowledged)?;
        while self.capacity.saturating_sub(self.size) < need && self.evict_front().is_some() {}
        self.entries.push_back(Entry {
            name,
            value,
            refs: 0,
        });
        self.size += need;
        self.inserted += 1;
        Ok(self.inserted - 1)
    }

    /// Add a reference to the entry at absolute index `abs` (encoder only).
    pub fn add_ref(&mut self, abs: u64) {
        if let Some(slot) = self.slot(abs) {
            self.entries[slot].refs += 1;
        }
    }

    /// Release a reference from the entry at absolute index `abs` (encoder only).
    pub fn release_ref(&mut self, abs: u64) {
        if let Some(slot) = self.slot(abs) {
            self.entries[slot].refs = self.entries[slot].refs.saturating_sub(1);
        }
    }

    /// Whether the entry at absolute index `abs` currently has outstanding references.
    #[must_use]
    pub fn is_referenced(&self, abs: u64) -> bool {
        self.slot(abs)
            .is_some_and(|slot| self.entries[slot].refs > 0)
    }

    /// The absolute index of the newest entry whose name and value both match, if any.
    #[must_use]
    pub fn find(&self, name: &[u8], value: &[u8]) -> Option<u64> {
        self.entries
            .iter()
            .enumerate()
            .rev()
            .find(|(_, e)| e.name == name && e.value == value)
            .map(|(i, _)| self.dropped() + i as u64)
    }

    /// The absolute index of the newest entry whose name matches, if any.
    #[must_use]
    pub fn find_name(&self, name: &[u8]) -> Option<u64> {
        self.entries
            .iter()
            .enumerate()
            .rev()
            .find(|(_, e)| e.name == name)
            .map(|(i, _)| self.dropped() + i as u64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn b(s: impl AsRef<[u8]>) -> Bytes {
        Bytes::copy_from_slice(s.as_ref())
    }

    #[test]
    fn insertion_preflight_limits_and_ack_boundary() {
        let mut t = DynamicTable::new(102);
        t.set_capacity(102);
        assert_eq!(t.can_insert(103, None), Err(InsertError::TooLarge));
        assert_eq!(t.can_insert(102, None), Ok(()));
        t.insert(b("a"), b("b"), None).unwrap();
        t.insert(b("c"), b("d"), None).unwrap();
        // An exact fit does not need eviction, including when inserts are not acknowledged.
        assert_eq!(t.can_insert(34, Some(0)), Ok(()));
        assert_eq!(t.can_insert(35, Some(0)), Err(InsertError::Blocked));
        assert_eq!(t.can_insert(35, Some(1)), Ok(()));
        t.add_ref(0);
        assert_eq!(t.can_insert(35, Some(2)), Err(InsertError::Blocked));
        t.release_ref(0);
        assert_eq!(t.can_insert(102, Some(1)), Err(InsertError::Blocked));
        assert_eq!(t.can_insert(102, Some(2)), Ok(()));
        // Absolute positions must account for entries already dropped, as well as candidate offset.
        t.insert(b("e"), b("f"), None).unwrap();
        t.insert(b("g"), b("h"), None).unwrap();
        assert_eq!(t.dropped(), 1);
        assert_eq!(t.can_insert(35, Some(2)), Err(InsertError::Blocked));
        assert_eq!(t.can_insert(35, Some(3)), Ok(()));
        t.inserted = u64::MAX;
        assert_eq!(t.can_insert(0, None), Err(InsertError::InsertCountOverflow));
    }

    #[test]
    fn insert_and_index() {
        let mut t = DynamicTable::new(220);
        assert!(t.set_capacity(220));
        assert_eq!(t.max_entries(), 6);
        let a0 = t
            .insert(b(":authority"), b("www.example.com"), None)
            .unwrap();
        let a1 = t.insert(b(":path"), b("/sample/path"), None).unwrap();
        assert_eq!((a0, a1), (0, 1));
        assert_eq!(t.insert_count(), 2);
        assert_eq!(t.get(0), Some((b(":authority"), b("www.example.com"))));
        assert_eq!(t.get(1), Some((b(":path"), b("/sample/path"))));
        assert_eq!(
            t.size(),
            entry_size(b":authority", b"www.example.com") + entry_size(b":path", b"/sample/path")
        );
    }

    #[test]
    fn eviction_on_capacity() {
        let mut t = DynamicTable::new(220);
        t.set_capacity(220);
        t.insert(b(":authority"), b("www.example.com"), None)
            .unwrap(); // abs 0, size 57
        t.insert(b(":path"), b("/sample/path"), None).unwrap(); // abs 1, size 49
        t.insert(b("custom-key"), b("custom-value"), None).unwrap(); // abs 2, size 54; total 160
        t.insert(b(":authority"), b("www.example.com"), None)
            .unwrap(); // abs 3 (dup), 57; total 217
        assert_eq!(t.dropped(), 0, "nothing evicted yet");
        // B.5: insert custom-key=custom-value2 (55) -> 272 > 220, evicts abs 0.
        t.insert(b("custom-key"), b("custom-value2"), None).unwrap();
        assert_eq!(t.dropped(), 1, "oldest entry evicted");
        assert_eq!(t.get(0), None);
        assert_eq!(t.insert_count(), 5);
    }

    #[test]
    fn too_large_entry() {
        let mut t = DynamicTable::new(64);
        t.set_capacity(64);
        // entry size = 10 + 30 + 32 = 72 > 64
        assert_eq!(
            t.insert(b("0123456789"), b("012345678901234567890123456789"), None),
            Err(InsertError::TooLarge)
        );
    }

    #[test]
    fn referenced_entry_blocks_eviction() {
        let mut t = DynamicTable::new(128);
        t.set_capacity(128); // room for ~2 small entries
        let a0 = t.insert(b("aa"), b("bb"), Some(u64::MAX)).unwrap(); // 36
        t.add_ref(a0);
        t.insert(b("cc"), b("dd"), Some(u64::MAX)).unwrap(); // 36, total 72
        // now try to insert something that requires evicting a0 (referenced)
        let big = t.insert(b("ee"), b([b'x'; 60]), Some(u64::MAX)); // 94, needs eviction of a0
        assert_eq!(big, Err(InsertError::Blocked));
        // release and retry
        t.release_ref(a0);
        t.insert(b("ee"), b([b'x'; 60]), Some(u64::MAX)).unwrap();
        assert_eq!(t.get(a0), None);
    }

    #[test]
    fn set_capacity_rejects_above_max() {
        let mut t = DynamicTable::new(100);
        assert!(!t.set_capacity(101));
        assert!(t.set_capacity(100));
    }

    #[test]
    fn zero_capacity_never_inserts() {
        let mut t = DynamicTable::new(0);
        assert_eq!(t.max_entries(), 0);
        assert!(t.set_capacity(0));
        assert_eq!(t.insert(b("a"), b("b"), None), Err(InsertError::TooLarge));
    }
}
