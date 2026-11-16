use std::{
    collections::{HashMap, hash_map::RandomState},
    convert::TryFrom,
    fmt,
    hash::{BuildHasher, Hash, Hasher},
    iter::{FromIterator, FusedIterator},
    marker::PhantomData,
    mem, ops, ptr, vec,
};

use serde::ser::SerializeSeq as _;

pub use self::{as_header_name::AsHeaderName, into_header_name::IntoHeaderName};
use super::{
    HeaderValue,
    name::{HdrName, HeaderName, InvalidHeaderName},
};
use crate::Error;

/// A specialized [multimap](<https://en.wikipedia.org/wiki/Multimap>) for
/// header names and values.
///
/// # Overview
///
/// `HeaderMap` is designed specifically for efficient manipulation of HTTP
/// headers. It supports multiple values per header name and provides
/// specialized APIs for insertion, retrieval, and iteration.
///
/// The internal implementation is optimized for common usage patterns in HTTP,
/// and may change across versions. For example, the current implementation uses
/// [Robin Hood
/// hashing](<https://en.wikipedia.org/wiki/Hash_table#Robin_Hood_hashing>) to
/// store entries compactly and enable high load factors with good performance.
/// However, the collision resolution strategy and storage mechanism are not
/// part of the public API and may be altered in future releases.
///
/// # Iteration order
///
/// Unless otherwise specified, the order in which items are returned by
/// iterators from `HeaderMap` methods is arbitrary; there is no guaranteed
/// ordering among the elements yielded by such an iterator. Changes to the
/// iteration order are not considered breaking changes, so users must not rely
/// on any incidental order produced by such an iterator. However, for a given
/// crate version, the iteration order will be consistent across all platforms.
///
/// # Adaptive hashing
///
/// `HeaderMap` uses an adaptive strategy for hashing to maintain fast lookups
/// while resisting hash collision attacks. The default hash function
/// prioritizes performance. In scenarios where high collision rates are
/// detected—typically indicative of denial-of-service attacks—the
/// implementation switches to a more secure, collision-resistant hash function.
///
/// # Limitations
///
/// A `HeaderMap` can hold at most 24,576 distinct header names. Once it does,
/// methods that add to the map, even a value under a name it already holds, such as [`insert`](Self::insert),
/// [`append`](Self::append), [`entry`](Self::entry) and [`reserve`](Self::reserve),
/// panic. Their fallible counterparts [`try_insert`](Self::try_insert),
/// [`try_append`](Self::try_append), [`try_entry`](Self::try_entry) and
/// [`try_reserve`](Self::try_reserve) return an error instead.
///
/// [`HeaderName`]: struct.HeaderName.html
/// [`HeaderMap`]: struct.HeaderMap.html
///
/// # Examples
///
/// Basic usage
///
/// ```
/// # use rama_http_types::HeaderMap;
/// # use rama_http_types::header::{CONTENT_LENGTH, HOST, LOCATION};
/// let mut headers = HeaderMap::new();
///
/// headers.insert(HOST, "example.com".parse().unwrap());
/// headers.insert(CONTENT_LENGTH, "123".parse().unwrap());
///
/// assert!(headers.contains_key(HOST));
/// assert!(!headers.contains_key(LOCATION));
///
/// assert_eq!(headers[HOST], "example.com");
///
/// headers.remove(HOST);
///
/// assert!(!headers.contains_key(HOST));
/// ```
#[derive(Clone)]
pub struct HeaderMap<T = HeaderValue> {
    indices: Box<[Pos]>,
    // Safety invariant (links): for every `i < entries.len()` with
    // `entries[i].links == Some(Links { next, tail })`, following `next` from
    // `extra_values[next]` visits distinct in-bounds `extra_values` indices and
    // ends at `tail`, whose `next` is `Link::Entry(i)`. Each visited node's
    // `prev` names the node before it (`Link::Entry(i)` for the first), and no
    // extra value is on two chains. Extra values on no chain are never reached.
    entries: Vec<Bucket<T>>,
    // Safety invariant: see the links invariant on `entries`.
    extra_values: Vec<ExtraValue<T>>,
    // Safety invariant (order): every `Some(link)` names an in-bounds element
    // (`Link::Entry(i)`: `i < entries.len()`, `Link::Extra(i)`:
    // `i < extra_values.len()`) whose `order` field equals that slot's index.
    // An element has one `order` field, so no two slots name the same element.
    order: Vec<Option<Link>>,
    danger: Danger,
}

// # Implementation notes
//
// Below, you will find a fairly large amount of code. Most of this is to
// provide the necessary functions to efficiently manipulate the header
// multimap. The core hashing table is based on robin hood hashing [1]. While
// this is the same hashing algorithm used as part of Rust's `HashMap` in
// stdlib, many implementation details are different. The two primary reasons
// for this divergence are that `HeaderMap` is a multimap and the structure has
// been optimized to take advantage of the characteristics of HTTP headers.
//
// ## Structure Layout
//
// Most of the data contained by `HeaderMap` is *not* stored in the hash table.
// Instead, pairs of header name and *first* associated header value are stored
// in the `entries` vector. If the header name has more than one associated
// header value, then additional values are stored in `extra_values`. The actual
// hash table (`indices`) only maps hash codes to indices in `entries`. This
// means that, when an eviction happens, the actual header name and value stay
// put and only a tiny amount of memory has to be copied.
//
// Extra values associated with a header name are tracked using a linked list.
// Links are formed with offsets into `extra_values` and not pointers.
//
// [1]: https://en.wikipedia.org/wiki/Hash_table#Robin_Hood_hashing

/// `HeaderMap` entry iterator.
///
/// Yields `(&HeaderName, &value)` tuples. The same header name may be yielded
/// more than once if it has more than one associated value.
#[derive(Debug)]
pub struct Iter<'a, T> {
    map: &'a HeaderMap<T>,
    entry: usize,
    cursor: Option<Cursor>,
}

/// `HeaderMap` mutable entry iterator
///
/// Yields `(&HeaderName, &mut value)` tuples. The same header name may be
/// yielded more than once if it has more than one associated value.
#[derive(Debug)]
pub struct IterMut<'a, T> {
    // Raw access avoids reborrowing the whole `HeaderMap` on every `next()`,
    // which would invalidate previously yielded `&mut T`s.
    //
    // Safety invariant: for `'a`, `entries` and `extra_values` are the
    // `as_mut_ptr()` of a map that is mutably borrowed for `'a` and satisfies
    // the `HeaderMap` links invariant; `entries_len` is its `entries.len()`.
    // Values at or after the cursor (`entry`, `cursor`) have not been yielded.
    entries: *mut Bucket<T>,
    entries_len: usize,
    // Safety invariant: see `entries`.
    extra_values: *mut ExtraValue<T>,
    entry: usize,
    cursor: Option<Cursor>,
    lt: PhantomData<&'a mut HeaderMap<T>>,
}

/// An owning iterator over the entries of a `HeaderMap`.
///
/// This struct is created by the `into_iter` method on `HeaderMap`.
pub struct IntoIter<T> {
    // If None, pull from `entries`
    next: Option<usize>,
    entries: vec::IntoIter<Bucket<T>>,
    // Safety invariant: the `HeaderMap` links invariant holds for the chains of
    // the buckets still in `entries` and for the rest of the chain from `next`.
    // Exactly the extra values on those chains are initialized and not yet
    // moved out; `Drop` sets the length to 0 so the `Vec` drops none of them.
    extra_values: Vec<ExtraValue<T>>,
}

/// An iterator over `HeaderMap` entries in their original insertion order.
///
/// Yields `(&HeaderName, &value)` tuples. The same semantic header name may be
/// yielded more than once and each yielded name preserves the casing that was
/// used when that field line was inserted.
#[derive(Debug)]
pub struct OrderedIter<'a, T> {
    map: &'a HeaderMap<T>,
    index: usize,
}

/// A consuming iterator over `HeaderMap` entries in original insertion order.
///
/// Each yielded `HeaderName` preserves the casing that was used when that field
/// line was inserted.
pub struct IntoOrderedIter<T> {
    index: usize,
    // Safety invariant: the `HeaderMap` order invariant holds for the slots
    // `index..`, and slots `..index` are `None`.
    order: Vec<Option<Link>>,
    // Safety invariant: an element of `entries` or `extra_values` has been
    // moved out exactly when a slot below `index` named it; all others are
    // initialized. `Drop` sets both lengths to 0 so the `Vec`s drop none of them.
    entries: Vec<Bucket<T>>,
    // Safety invariant: see `entries`.
    extra_values: Vec<ExtraValue<T>>,
}

/// An iterator over `HeaderMap` keys.
///
/// Each header name is yielded only once, even if it has more than one
/// associated value.
#[derive(Debug)]
pub struct Keys<'a, T> {
    inner: ::std::slice::Iter<'a, Bucket<T>>,
}

/// `HeaderMap` value iterator.
///
/// Each value contained in the `HeaderMap` will be yielded.
#[derive(Debug)]
pub struct Values<'a, T> {
    inner: Iter<'a, T>,
}

/// `HeaderMap` mutable value iterator
#[derive(Debug)]
pub struct ValuesMut<'a, T> {
    inner: IterMut<'a, T>,
}

/// A drain iterator for `HeaderMap`.
#[derive(Debug)]
pub struct Drain<'a, T> {
    idx: usize,
    len: usize,
    // Safety invariant: for `'a`, `entries` addresses the map's entry buffer
    // with its `len` elements from before `drain()`, and only this `Drain`
    // accesses it (the map's `entries` has length 0 and is mutably borrowed).
    // Elements `idx..len` are initialized and not yet moved out; the `links`
    // field of every element stays initialized.
    entries: *mut [Bucket<T>],
    // If None, pull from `entries`
    next: Option<usize>,
    // Safety invariant: for `'a`, points to the map's live `extra_values`, which
    // only this `Drain` accesses.
    extra_values: *mut Vec<ExtraValue<T>>,
    lt: PhantomData<&'a mut HeaderMap<T>>,
}

/// A view to all values stored in a single entry.
///
/// This struct is returned by `HeaderMap::get_all`.
#[derive(Debug)]
pub struct GetAll<'a, T> {
    map: &'a HeaderMap<T>,
    index: Option<usize>,
}

/// A view into a single location in a `HeaderMap`, which may be vacant or occupied.
#[derive(Debug)]
pub enum Entry<'a, T: 'a> {
    /// An occupied entry
    Occupied(OccupiedEntry<'a, T>),

    /// A vacant entry
    Vacant(VacantEntry<'a, T>),
}

/// A view into a single empty location in a `HeaderMap`.
///
/// This struct is returned as part of the `Entry` enum.
#[derive(Debug)]
pub struct VacantEntry<'a, T> {
    map: &'a mut HeaderMap<T>,
    key: HeaderName,
    hash: HashValue,
    probe: usize,
    danger: bool,
}

/// A view into a single occupied location in a `HeaderMap`.
///
/// This struct is returned as part of the `Entry` enum.
#[derive(Debug)]
pub struct OccupiedEntry<'a, T> {
    map: &'a mut HeaderMap<T>,
    probe: usize,
    index: usize,
}

/// An iterator of all values associated with a single header name.
#[derive(Debug)]
pub struct ValueIter<'a, T> {
    map: &'a HeaderMap<T>,
    index: usize,
    front: Option<Cursor>,
    back: Option<Cursor>,
}

/// A mutable iterator of all values associated with a single header name.
#[derive(Debug)]
pub struct ValueIterMut<'a, T> {
    // Raw access avoids reborrowing the whole `HeaderMap` on every step.
    //
    // Safety invariant: for `'a`, `entries` and `extra_values` are the
    // `as_mut_ptr()` of a map that is mutably borrowed for `'a` and satisfies
    // the `HeaderMap` links invariant; `index < entries.len()` of that map.
    // When both cursors are `Some`, the values from `front` to `back` on the
    // chain of entry `index` (head first) have not been yielded; when they are
    // `None`, nothing more is yielded.
    entries: *mut Bucket<T>,
    // Safety invariant: see `entries`.
    extra_values: *mut ExtraValue<T>,
    index: usize,
    front: Option<Cursor>,
    back: Option<Cursor>,
    lt: PhantomData<&'a mut HeaderMap<T>>,
}

/// An drain iterator of all values associated with a single header name.
#[derive(Debug)]
pub struct ValueDrain<'a, T> {
    first: Option<T>,
    next: Option<::std::vec::IntoIter<T>>,
    lt: PhantomData<&'a mut HeaderMap<T>>,
}

/// Error returned when max capacity of `HeaderMap` is exceeded
pub struct MaxSizeReached {
    _priv: (),
}

/// Tracks the value iterator state
#[derive(Debug, Copy, Clone, Eq, PartialEq)]
enum Cursor {
    Head,
    Values(usize),
}

/// Type used for representing the size of a HeaderMap value.
///
/// 32,768 is more than enough entries for a single header map. Setting this
/// limit enables using `u16` to represent all offsets, which takes 2 bytes
/// instead of 8 on 64 bit processors.
///
/// Setting this limit is especially beneficial for `indices`, making it more
/// cache friendly. More hash codes can fit in a cache line.
///
/// You may notice that `u16` may represent more than 32,768 values. This is
/// true, but 32,768 should be plenty and it allows us to reserve the top bit
/// for future usage.
type Size = u16;

/// This limit falls out from above.
const MAX_SIZE: usize = 1 << 15;

/// An entry in the hash table. This represents the full hash code for an entry
/// as well as the position of the entry in the `entries` vector.
#[derive(Copy, Clone)]
struct Pos {
    // Index in the `entries` vec
    index: Size,
    // Full hash value for the entry.
    hash: HashValue,
}

/// Hash values are limited to u16 as well. While `fast_hash` and `Hasher`
/// return `usize` hash codes, limiting the effective hash code to the lower 16
/// bits is fine since we know that the `indices` vector will never grow beyond
/// that size.
#[derive(Debug, Copy, Clone, Eq, PartialEq)]
struct HashValue(u16);

/// Stores the data associated with a `HeaderMap` entry. Only the first value is
/// included in this struct. If a header name has more than one associated
/// value, all extra values are stored in the `extra_values` vector. A doubly
/// linked list of entries is maintained. The doubly linked list is used so that
/// removing a value is constant time. This also has the nice property of
/// enabling double ended iteration.
#[derive(Debug, Clone)]
struct Bucket<T> {
    hash: HashValue,
    key: HeaderName,
    value: T,
    links: Option<Links>,
    order: usize,
}

/// The head and tail of the value linked list.
#[derive(Debug, Copy, Clone)]
struct Links {
    next: usize,
    tail: usize,
}

/// Access to the `links` value in a slice of buckets.
///
/// It's important that no other field is accessed, since it may have been
/// freed in a `Drain` iterator.
#[derive(Debug)]
struct RawLinks<'a, T> {
    // Safety invariant: for `'a`, `ptr` is valid for reads and writes of the
    // (initialized) `links` field of every element of the slice it addresses,
    // and no other path accesses those `links` fields.
    ptr: *mut [Bucket<T>],
    lt: PhantomData<&'a mut [Bucket<T>]>,
}

/// Node in doubly-linked list of header value entries
#[derive(Debug, Clone)]
struct ExtraValue<T> {
    key: HeaderName,
    value: T,
    prev: Link,
    next: Link,
    order: usize,
}

/// A header value node is either linked to another node in the `extra_values`
/// list or it points to an entry in `entries`. The entry in `entries` is the
/// start of the list and holds the associated header name.
#[derive(Debug, Copy, Clone, Eq, PartialEq)]
enum Link {
    Entry(usize),
    Extra(usize),
}

/// Tracks the header map danger level! This relates to the adaptive hashing
/// algorithm. A HeaderMap starts in the "green" state, when a large number of
/// collisions are detected, it transitions to the yellow state. At this point,
/// the header map will either grow and switch back to the green state OR it
/// will transition to the red state.
///
/// When in the red state, a safe hashing algorithm is used and all values in
/// the header map have to be rehashed.
#[derive(Clone)]
enum Danger {
    Green,
    Yellow,
    Red(Box<RandomState>),
}

// Constants related to detecting DOS attacks.
//
// Displacement is the number of entries that get shifted when inserting a new
// value. Forward shift is how far the entry gets stored from the ideal
// position.
//
// The current constant values were picked from another implementation. It could
// be that there are different values better suited to the header map case.
const DISPLACEMENT_THRESHOLD: usize = 128;
const FORWARD_SHIFT_THRESHOLD: usize = 512;

// The default strategy for handling the yellow danger state is to increase the
// header map capacity in order to (hopefully) reduce the number of collisions.
// If growing the hash map would cause the load factor to drop bellow this
// threshold, then instead of growing, the headermap is switched to the red
// danger state and safe hashing is used instead.
const LOAD_FACTOR_THRESHOLD: usize = 5;

// Macro used to iterate the hash table starting at a given point, looping when
// the end is hit.
macro_rules! probe_loop {
    ($label:tt: $probe_var: ident < $len: expr, $body: expr) => {
        debug_assert!($len > 0);
        $label:
        loop {
            if $probe_var < $len {
                $body
                $probe_var += 1;
            } else {
                $probe_var = 0;
            }
        }
    };
    ($probe_var: ident < $len: expr, $body: expr) => {
        debug_assert!($len > 0);
        loop {
            if $probe_var < $len {
                $body
                $probe_var += 1;
            } else {
                $probe_var = 0;
            }
        }
    };
}

// First part of the robinhood algorithm. Given a key, find the slot in which it
// will be inserted. This is done by starting at the "ideal" spot. Then scanning
// until the destination slot is found. A destination slot is either the next
// empty slot or the next slot that is occupied by an entry that has a lower
// displacement (displacement is the distance from the ideal spot).
//
// This is implemented as a macro instead of a function that takes a closure in
// order to guarantee that it is "inlined". There is no way to annotate closures
// to guarantee inlining.
macro_rules! insert_phase_one {
    ($map:ident,
     $key:expr,
     $probe:ident,
     $pos:ident,
     $hash:ident,
     $danger:ident,
     $vacant:expr,
     $occupied:expr,
     $robinhood:expr) =>
    {{
        let $hash = hash_elem_using(&$map.danger, &$key);
        let mut $probe = desired_pos($map.mask(), $hash);
        let mut dist = 0;
        let ret;

        // Start at the ideal position, checking all slots
        probe_loop!('probe: $probe < $map.indices.len(), {
            if let Some(($pos, entry_hash)) = $map.indices[$probe].resolve() {
                // The slot is already occupied, but check if it has a lower
                // displacement.
                let their_dist = probe_distance($map.mask(), entry_hash, $probe);

                if their_dist < dist {
                    // The new key's distance is larger, so claim this spot and
                    // displace the current entry.
                    //
                    // Check if this insertion is above the danger threshold.
                    let $danger =
                        dist >= FORWARD_SHIFT_THRESHOLD && !$map.danger.is_red();

                    ret = $robinhood;
                    break 'probe;
                } else if entry_hash == $hash && $map.entries[$pos].key == $key {
                    // There already is an entry with the same key.
                    ret = $occupied;
                    break 'probe;
                }
            } else {
                // The entry is vacant, use it for this key.
                let $danger =
                    dist >= FORWARD_SHIFT_THRESHOLD && !$map.danger.is_red();

                ret = $vacant;
                break 'probe;
            }

            dist += 1;
        });

        ret
    }}
}

// ===== impl HeaderMap =====

impl HeaderMap {
    /// Create an empty `HeaderMap`.
    ///
    /// The map will be created without any capacity. This function will not
    /// allocate.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// let map = HeaderMap::new();
    ///
    /// assert!(map.is_empty());
    /// assert_eq!(0, map.capacity());
    /// ```
    #[inline]
    pub fn new() -> Self {
        Self::default()
    }
}

impl<T> Default for HeaderMap<T> {
    fn default() -> Self {
        HeaderMap {
            indices: Box::new([]), // as a ZST, this doesn't actually allocate anything
            entries: Vec::new(),
            extra_values: Vec::new(),
            order: Vec::new(),
            danger: Danger::Green,
        }
    }
}

impl<T> HeaderMap<T> {
    /// Create an empty `HeaderMap` with the specified capacity.
    ///
    /// The returned map will allocate internal storage in order to hold about
    /// `capacity` elements without reallocating. However, this is a "best
    /// effort" as there are usage patterns that could cause additional
    /// allocations before `capacity` headers are stored in the map.
    ///
    /// More capacity than requested may be allocated.
    ///
    /// # Panics
    ///
    /// This method panics if capacity exceeds max `HeaderMap` capacity.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// let map: HeaderMap<u32> = HeaderMap::with_capacity(10);
    ///
    /// assert!(map.is_empty());
    /// assert_eq!(12, map.capacity());
    /// ```
    pub fn with_capacity(capacity: usize) -> HeaderMap<T> {
        Self::try_with_capacity(capacity).expect("size overflows MAX_SIZE")
    }

    /// Create an empty `HeaderMap` with the specified capacity.
    ///
    /// The returned map will allocate internal storage in order to hold about
    /// `capacity` elements without reallocating. However, this is a "best
    /// effort" as there are usage patterns that could cause additional
    /// allocations before `capacity` headers are stored in the map.
    ///
    /// More capacity than requested may be allocated.
    ///
    /// # Errors
    ///
    /// This function may return an error if `HeaderMap` exceeds max capacity
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// let map: HeaderMap<u32> = HeaderMap::try_with_capacity(10).unwrap();
    ///
    /// assert!(map.is_empty());
    /// assert_eq!(12, map.capacity());
    /// ```
    pub fn try_with_capacity(capacity: usize) -> Result<HeaderMap<T>, MaxSizeReached> {
        if capacity == 0 {
            Ok(Self::default())
        } else {
            let raw_cap = to_raw_capacity(capacity)?;
            let raw_cap = match raw_cap.checked_next_power_of_two() {
                Some(c) => c,
                None => return Err(MaxSizeReached { _priv: () }),
            };
            if raw_cap > MAX_SIZE {
                return Err(MaxSizeReached { _priv: () });
            }
            debug_assert!(raw_cap > 0);

            Ok(HeaderMap {
                indices: vec![Pos::none(); raw_cap].into_boxed_slice(),
                entries: Vec::with_capacity(usable_capacity(raw_cap)),
                extra_values: Vec::new(),
                order: Vec::with_capacity(capacity),
                danger: Danger::Green,
            })
        }
    }

    /// Returns the number of headers stored in the map.
    ///
    /// This number represents the total number of **values** stored in the map.
    /// This number can be greater than or equal to the number of **keys**
    /// stored given that a single key may have more than one associated value.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::{ACCEPT, HOST};
    /// let mut map = HeaderMap::new();
    ///
    /// assert_eq!(0, map.len());
    ///
    /// map.insert(ACCEPT, "text/plain".parse().unwrap());
    /// map.insert(HOST, "localhost".parse().unwrap());
    ///
    /// assert_eq!(2, map.len());
    ///
    /// map.append(ACCEPT, "text/html".parse().unwrap());
    ///
    /// assert_eq!(3, map.len());
    /// ```
    pub fn len(&self) -> usize {
        self.entries.len() + self.extra_values.len()
    }

    /// Returns the number of keys stored in the map.
    ///
    /// This number will be less than or equal to `len()` as each key may have
    /// more than one associated value.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::{ACCEPT, HOST};
    /// let mut map = HeaderMap::new();
    ///
    /// assert_eq!(0, map.keys_len());
    ///
    /// map.insert(ACCEPT, "text/plain".parse().unwrap());
    /// map.insert(HOST, "localhost".parse().unwrap());
    ///
    /// assert_eq!(2, map.keys_len());
    ///
    /// map.insert(ACCEPT, "text/html".parse().unwrap());
    ///
    /// assert_eq!(2, map.keys_len());
    /// ```
    pub fn keys_len(&self) -> usize {
        self.entries.len()
    }

    /// Returns true if the map contains no elements.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::HOST;
    /// let mut map = HeaderMap::new();
    ///
    /// assert!(map.is_empty());
    ///
    /// map.insert(HOST, "hello.world".parse().unwrap());
    ///
    /// assert!(!map.is_empty());
    /// ```
    pub fn is_empty(&self) -> bool {
        self.entries.len() == 0
    }

    /// Clears the map, removing all key-value pairs. Keeps the allocated memory
    /// for reuse.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::HOST;
    /// let mut map = HeaderMap::new();
    /// map.insert(HOST, "hello.world".parse().unwrap());
    ///
    /// map.clear();
    /// assert!(map.is_empty());
    /// assert!(map.capacity() > 0);
    /// ```
    pub fn clear(&mut self) {
        // Reset the bookkeeping before dropping values: a panicking drop must
        // not leave `order` or `indices` naming removed elements. Entries are
        // cleared before extra values so no entry links to a missing extra.
        self.order.clear();
        self.danger = Danger::Green;
        for e in self.indices.iter_mut() {
            *e = Pos::none();
        }

        self.entries.clear();
        self.extra_values.clear();
    }

    /// Returns the number of headers the map can hold without reallocating.
    ///
    /// This number is an approximation as certain usage patterns could cause
    /// additional allocations before the returned capacity is filled.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::HOST;
    /// let mut map = HeaderMap::new();
    ///
    /// assert_eq!(0, map.capacity());
    ///
    /// map.insert(HOST, "hello.world".parse().unwrap());
    /// assert_eq!(6, map.capacity());
    /// ```
    pub fn capacity(&self) -> usize {
        usable_capacity(self.indices.len())
    }

    /// Reserves capacity for at least `additional` more headers to be inserted
    /// into the `HeaderMap`.
    ///
    /// The header map may reserve more space to avoid frequent reallocations.
    /// Like with `with_capacity`, this will be a "best effort" to avoid
    /// allocations until `additional` more headers are inserted. Certain usage
    /// patterns could cause additional allocations before the number is
    /// reached.
    ///
    /// # Panics
    ///
    /// Panics if reserving the additional capacity would grow the map beyond
    /// its maximum capacity. See the [`HeaderMap`] documentation for the limit,
    /// or use [`try_reserve`](Self::try_reserve) to handle the failure without
    /// panicking.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::HOST;
    /// let mut map = HeaderMap::new();
    /// map.reserve(10);
    /// # map.insert(HOST, "bar".parse().unwrap());
    /// ```
    pub fn reserve(&mut self, additional: usize) {
        self.try_reserve(additional)
            .expect("size overflows MAX_SIZE")
    }

    /// Reserves capacity for at least `additional` more headers to be inserted
    /// into the `HeaderMap`.
    ///
    /// The header map may reserve more space to avoid frequent reallocations.
    /// Like with `with_capacity`, this will be a "best effort" to avoid
    /// allocations until `additional` more headers are inserted. Certain usage
    /// patterns could cause additional allocations before the number is
    /// reached.
    ///
    /// # Errors
    ///
    /// This method differs from `reserve` by returning an error instead of
    /// panicking if the value is too large.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::HOST;
    /// let mut map = HeaderMap::new();
    /// map.try_reserve(10).unwrap();
    /// # map.try_insert(HOST, "bar".parse().unwrap()).unwrap();
    /// ```
    pub fn try_reserve(&mut self, additional: usize) -> Result<(), MaxSizeReached> {
        // TODO: This can't overflow if done properly... since the max # of
        // elements is u16::MAX.
        let cap = self
            .entries
            .len()
            .checked_add(additional)
            .ok_or_else(MaxSizeReached::new)?;

        let raw_cap = to_raw_capacity(cap)?;

        if raw_cap > self.indices.len() {
            let raw_cap = raw_cap
                .checked_next_power_of_two()
                .ok_or_else(MaxSizeReached::new)?;
            if raw_cap > MAX_SIZE {
                return Err(MaxSizeReached::new());
            }

            if self.entries.is_empty() {
                self.indices = vec![Pos::none(); raw_cap].into_boxed_slice();
                let cap = usable_capacity(raw_cap);
                self.entries = Vec::with_capacity(cap);
                self.order.reserve_exact(cap);
            } else {
                self.try_grow(raw_cap)?;
            }
        }

        self.order.reserve(additional);

        Ok(())
    }

    /// Returns a reference to the value associated with the key.
    ///
    /// If there are multiple values associated with the key, then the first one
    /// is returned. Use `get_all` to get all values associated with a given
    /// key. Returns `None` if there are no values associated with the key.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::HOST;
    /// let mut map = HeaderMap::new();
    /// assert!(map.get("host").is_none());
    ///
    /// map.insert(HOST, "hello".parse().unwrap());
    /// assert_eq!(map.get(HOST).unwrap(), &"hello");
    /// assert_eq!(map.get("host").unwrap(), &"hello");
    ///
    /// map.append(HOST, "world".parse().unwrap());
    /// assert_eq!(map.get("host").unwrap(), &"hello");
    /// ```
    pub fn get<K>(&self, key: K) -> Option<&T>
    where
        K: AsHeaderName,
    {
        self.get2(&key)
    }

    fn get2<K>(&self, key: &K) -> Option<&T>
    where
        K: AsHeaderName,
    {
        match key.find(self) {
            Some((_, found)) => {
                let entry = &self.entries[found];
                Some(&entry.value)
            }
            None => None,
        }
    }

    /// Returns a mutable reference to the value associated with the key.
    ///
    /// If there are multiple values associated with the key, then the first one
    /// is returned. Use `entry` to get all values associated with a given
    /// key. Returns `None` if there are no values associated with the key.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::HOST;
    /// let mut map = HeaderMap::default();
    /// map.insert(HOST, "hello".to_string());
    /// map.get_mut("host").unwrap().push_str("-world");
    ///
    /// assert_eq!(map.get(HOST).unwrap(), &"hello-world");
    /// ```
    pub fn get_mut<K>(&mut self, key: K) -> Option<&mut T>
    where
        K: AsHeaderName,
    {
        match key.find(self) {
            Some((_, found)) => {
                let entry = &mut self.entries[found];
                Some(&mut entry.value)
            }
            None => None,
        }
    }

    /// Returns a view of all values associated with a key.
    ///
    /// The returned view does not incur any allocations and allows iterating
    /// the values associated with the key.  See [`GetAll`] for more details.
    /// Returns `None` if there are no values associated with the key.
    ///
    /// [`GetAll`]: struct.GetAll.html
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::HOST;
    /// let mut map = HeaderMap::new();
    ///
    /// map.insert(HOST, "hello".parse().unwrap());
    /// map.append(HOST, "goodbye".parse().unwrap());
    ///
    /// let view = map.get_all("host");
    ///
    /// let mut iter = view.iter();
    /// assert_eq!(&"hello", iter.next().unwrap());
    /// assert_eq!(&"goodbye", iter.next().unwrap());
    /// assert!(iter.next().is_none());
    /// ```
    pub fn get_all<K>(&self, key: K) -> GetAll<'_, T>
    where
        K: AsHeaderName,
    {
        GetAll {
            map: self,
            index: key.find(self).map(|(_, i)| i),
        }
    }

    /// Returns true if the map contains a value for the specified key.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::HOST;
    /// let mut map = HeaderMap::new();
    /// assert!(!map.contains_key(HOST));
    ///
    /// map.insert(HOST, "world".parse().unwrap());
    /// assert!(map.contains_key("host"));
    /// ```
    pub fn contains_key<K>(&self, key: K) -> bool
    where
        K: AsHeaderName,
    {
        key.find(self).is_some()
    }

    /// An iterator visiting all key-value pairs.
    ///
    /// The iteration order is arbitrary, but consistent across platforms for
    /// the same crate version. Each key will be yielded once per associated
    /// value. So, if a key has 3 associated values, it will be yielded 3 times.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::{CONTENT_LENGTH, HOST};
    /// let mut map = HeaderMap::new();
    ///
    /// map.insert(HOST, "hello".parse().unwrap());
    /// map.append(HOST, "goodbye".parse().unwrap());
    /// map.insert(CONTENT_LENGTH, "123".parse().unwrap());
    ///
    /// for (key, value) in map.iter() {
    ///     println!("{:?}: {:?}", key, value);
    /// }
    /// ```
    pub fn iter(&self) -> Iter<'_, T> {
        Iter {
            map: self,
            entry: 0,
            cursor: self.entries.first().map(|_| Cursor::Head),
        }
    }

    /// An iterator visiting all key-value pairs in their original insertion
    /// order.
    ///
    /// Each yielded key preserves the casing that was used for that field line
    /// when it was inserted into the map.
    pub fn ordered_iter(&self) -> OrderedIter<'_, T> {
        OrderedIter {
            map: self,
            index: 0,
        }
    }

    /// An iterator visiting all key-value pairs, with mutable value references.
    ///
    /// The iterator order is arbitrary, but consistent across platforms for the
    /// same crate version. Each key will be yielded once per associated value,
    /// so if a key has 3 associated values, it will be yielded 3 times.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::{CONTENT_LENGTH, HOST};
    /// let mut map = HeaderMap::default();
    ///
    /// map.insert(HOST, "hello".to_string());
    /// map.append(HOST, "goodbye".to_string());
    /// map.insert(CONTENT_LENGTH, "123".to_string());
    ///
    /// for (key, value) in map.iter_mut() {
    ///     value.push_str("-boop");
    /// }
    /// ```
    pub fn iter_mut(&mut self) -> IterMut<'_, T> {
        IterMut {
            entries: self.entries.as_mut_ptr(),
            entries_len: self.entries.len(),
            extra_values: self.extra_values.as_mut_ptr(),
            entry: 0,
            cursor: self.entries.first().map(|_| Cursor::Head),
            lt: PhantomData,
        }
    }

    /// An iterator visiting all keys.
    ///
    /// The iteration order is arbitrary, but consistent across platforms for
    /// the same crate version. Each key will be yielded only once even if it
    /// has multiple associated values.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::{CONTENT_LENGTH, HOST};
    /// let mut map = HeaderMap::new();
    ///
    /// map.insert(HOST, "hello".parse().unwrap());
    /// map.append(HOST, "goodbye".parse().unwrap());
    /// map.insert(CONTENT_LENGTH, "123".parse().unwrap());
    ///
    /// for key in map.keys() {
    ///     println!("{:?}", key);
    /// }
    /// ```
    pub fn keys(&self) -> Keys<'_, T> {
        Keys {
            inner: self.entries.iter(),
        }
    }

    /// An iterator visiting all values.
    ///
    /// The iteration order is arbitrary, but consistent across platforms for
    /// the same crate version.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::{CONTENT_LENGTH, HOST};
    /// let mut map = HeaderMap::new();
    ///
    /// map.insert(HOST, "hello".parse().unwrap());
    /// map.append(HOST, "goodbye".parse().unwrap());
    /// map.insert(CONTENT_LENGTH, "123".parse().unwrap());
    ///
    /// for value in map.values() {
    ///     println!("{:?}", value);
    /// }
    /// ```
    pub fn values(&self) -> Values<'_, T> {
        Values { inner: self.iter() }
    }

    /// An iterator visiting all values mutably.
    ///
    /// The iteration order is arbitrary, but consistent across platforms for
    /// the same crate version.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::{CONTENT_LENGTH, HOST};
    /// let mut map = HeaderMap::default();
    ///
    /// map.insert(HOST, "hello".to_string());
    /// map.append(HOST, "goodbye".to_string());
    /// map.insert(CONTENT_LENGTH, "123".to_string());
    ///
    /// for value in map.values_mut() {
    ///     value.push_str("-boop");
    /// }
    /// ```
    pub fn values_mut(&mut self) -> ValuesMut<'_, T> {
        ValuesMut {
            inner: self.iter_mut(),
        }
    }

    /// Clears the map, returning all entries as an iterator.
    ///
    /// The internal memory is kept for reuse.
    ///
    /// For each yielded item that has `None` provided for the `HeaderName`,
    /// then the associated header name is the same as that of the previously
    /// yielded item. The first yielded item will have `HeaderName` set.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::{CONTENT_LENGTH, HOST};
    /// let mut map = HeaderMap::new();
    ///
    /// map.insert(HOST, "hello".parse().unwrap());
    /// map.append(HOST, "goodbye".parse().unwrap());
    /// map.insert(CONTENT_LENGTH, "123".parse().unwrap());
    ///
    /// let mut drain = map.drain();
    ///
    ///
    /// assert_eq!(drain.next(), Some((Some(HOST), "hello".parse().unwrap())));
    /// assert_eq!(drain.next(), Some((None, "goodbye".parse().unwrap())));
    ///
    /// assert_eq!(drain.next(), Some((Some(CONTENT_LENGTH), "123".parse().unwrap())));
    ///
    /// assert_eq!(drain.next(), None);
    /// ```
    pub fn drain(&mut self) -> Drain<'_, T> {
        for i in self.indices.iter_mut() {
            *i = Pos::none();
        }

        // Memory safety
        //
        // When the Drain is first created, it shortens the length of
        // the source vector to make sure no uninitialized or moved-from
        // elements are accessible at all if the Drain's destructor never
        // gets to run.

        let entries = &raw mut self.entries[..];
        let extra_values = &raw mut self.extra_values;
        let len = self.entries.len();
        // SAFETY: `Vec::set_len(0)` requires `0 <= capacity` and the first 0
        // elements initialized, both trivially true. Postcondition: the `Vec`
        // no longer owns the `len` buckets; the returned `Drain` does (its
        // `entries` field invariant), and leaks them if it is forgotten.
        unsafe {
            self.entries.set_len(0);
        }
        self.order.clear();

        Drain {
            idx: 0,
            len,
            entries,
            extra_values,
            next: None,
            lt: PhantomData,
        }
    }

    fn value_iter(&self, idx: Option<usize>) -> ValueIter<'_, T> {
        use self::Cursor::*;

        if let Some(idx) = idx {
            let back = {
                let entry = &self.entries[idx];

                entry.links.map(|l| Values(l.tail)).unwrap_or(Head)
            };

            ValueIter {
                map: self,
                index: idx,
                front: Some(Head),
                back: Some(back),
            }
        } else {
            ValueIter {
                map: self,
                index: usize::MAX,
                front: None,
                back: None,
            }
        }
    }

    fn value_iter_mut(&mut self, idx: usize) -> ValueIterMut<'_, T> {
        use self::Cursor::*;

        let back = {
            let entry = &self.entries[idx];

            entry.links.map(|l| Values(l.tail)).unwrap_or(Head)
        };

        ValueIterMut {
            entries: self.entries.as_mut_ptr(),
            extra_values: self.extra_values.as_mut_ptr(),
            index: idx,
            front: Some(Head),
            back: Some(back),
            lt: PhantomData,
        }
    }

    /// Gets the given key's corresponding entry in the map for in-place
    /// manipulation.
    ///
    /// # Panics
    ///
    /// This method panics if capacity exceeds max `HeaderMap` capacity
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// let mut map: HeaderMap<u32> = HeaderMap::default();
    ///
    /// let headers = &[
    ///     "content-length",
    ///     "x-hello",
    ///     "Content-Length",
    ///     "x-world",
    /// ];
    ///
    /// for &header in headers {
    ///     let counter = map.entry(header).or_insert(0);
    ///     *counter += 1;
    /// }
    ///
    /// assert_eq!(map["content-length"], 2);
    /// assert_eq!(map["x-hello"], 1);
    /// ```
    pub fn entry<K>(&mut self, key: K) -> Entry<'_, T>
    where
        K: IntoHeaderName,
    {
        key.try_entry(self).expect("size overflows MAX_SIZE")
    }

    /// Gets the given key's corresponding entry in the map for in-place
    /// manipulation.
    ///
    /// # Errors
    ///
    /// This method differs from `entry` by allowing types that may not be
    /// valid `HeaderName`s to passed as the key (such as `String`). If they
    /// do not parse as a valid `HeaderName`, this returns an
    /// `InvalidHeaderName` error.
    ///
    /// If reserving space goes over the maximum, this will also return an
    /// error. However, to prevent breaking changes to the return type, the
    /// error will still say `InvalidHeaderName`, unlike other `try_*` methods
    /// which return a `MaxSizeReached` error.
    pub fn try_entry<K>(&mut self, key: K) -> Result<Entry<'_, T>, InvalidHeaderName>
    where
        K: AsHeaderName,
    {
        key.try_entry(self).map_err(|err| match err {
            as_header_name::TryEntryError::InvalidHeaderName(e) => e,
            as_header_name::TryEntryError::MaxSizeReached(_e) => {
                // Unfortunately, we cannot change the return type of this
                // method, so the max size reached error needs to be converted
                // into an InvalidHeaderName. Yay.
                InvalidHeaderName::new()
            }
        })
    }

    fn try_entry2<K>(&mut self, key: K) -> Result<Entry<'_, T>, MaxSizeReached>
    where
        K: Into<HeaderName>,
    {
        // Ensure that there is space in the map
        self.try_reserve_one()?;
        let key = key.into();

        Ok(insert_phase_one!(
            self,
            key,
            probe,
            pos,
            hash,
            danger,
            Entry::Vacant(VacantEntry {
                map: self,
                hash,
                key: key.into(),
                probe,
                danger,
            }),
            Entry::Occupied(OccupiedEntry {
                map: self,
                index: pos,
                probe,
            }),
            Entry::Vacant(VacantEntry {
                map: self,
                hash,
                key: key.into(),
                probe,
                danger,
            })
        ))
    }

    /// Inserts a key-value pair into the map.
    ///
    /// If the map did not previously have this key present, then `None` is
    /// returned.
    ///
    /// If the map did have this key present, the new value is associated with
    /// the key and all previous values are removed. **Note** that only a single
    /// one of the previous values is returned. If there are multiple values
    /// that have been previously associated with the key, then the first one is
    /// returned. See `insert_mult` on `OccupiedEntry` for an API that returns
    /// all values.
    ///
    /// The key is not updated, though; this matters for types that can be `==`
    /// without being identical.
    ///
    /// # Panics
    ///
    /// This method panics if capacity exceeds max `HeaderMap` capacity
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::HOST;
    /// let mut map = HeaderMap::new();
    /// assert!(map.insert(HOST, "world".parse().unwrap()).is_none());
    /// assert!(!map.is_empty());
    ///
    /// let mut prev = map.insert(HOST, "earth".parse().unwrap()).unwrap();
    /// assert_eq!("world", prev);
    /// ```
    pub fn insert<K>(&mut self, key: K, val: T) -> Option<T>
    where
        K: IntoHeaderName,
    {
        self.try_insert(key, val).expect("size overflows MAX_SIZE")
    }

    /// Inserts a key-value pair into the map.
    ///
    /// If the map did not previously have this key present, then `None` is
    /// returned.
    ///
    /// If the map did have this key present, the new value is associated with
    /// the key and all previous values are removed. **Note** that only a single
    /// one of the previous values is returned. If there are multiple values
    /// that have been previously associated with the key, then the first one is
    /// returned. See `insert_mult` on `OccupiedEntry` for an API that returns
    /// all values.
    ///
    /// The key is not updated, though; this matters for types that can be `==`
    /// without being identical.
    ///
    /// # Errors
    ///
    /// This function may return an error if `HeaderMap` exceeds max capacity
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::HOST;
    /// let mut map = HeaderMap::new();
    /// assert!(map.try_insert(HOST, "world".parse().unwrap()).unwrap().is_none());
    /// assert!(!map.is_empty());
    ///
    /// let mut prev = map.try_insert(HOST, "earth".parse().unwrap()).unwrap().unwrap();
    /// assert_eq!("world", prev);
    /// ```
    pub fn try_insert<K>(&mut self, key: K, val: T) -> Result<Option<T>, MaxSizeReached>
    where
        K: IntoHeaderName,
    {
        key.try_insert(self, val)
    }

    #[inline]
    fn try_insert2<K>(&mut self, key: K, value: T) -> Result<Option<T>, MaxSizeReached>
    where
        K: Into<HeaderName>,
    {
        self.try_reserve_one()?;
        let key = key.into();

        Ok(insert_phase_one!(
            self,
            key,
            probe,
            pos,
            hash,
            danger,
            // Vacant
            {
                if danger {
                    self.danger.set_yellow();
                }
                let index = self.entries.len();
                self.try_insert_entry(hash, key.into(), value)?;
                self.indices[probe] = Pos::new(index, hash);
                None
            },
            // Occupied
            Some(self.insert_occupied(pos, key, value)),
            // Robinhood
            {
                self.try_insert_phase_two(key.into(), value, hash, probe, danger)?;
                None
            }
        ))
    }

    /// Set an occupied bucket to the given value
    #[inline]
    fn insert_occupied(&mut self, index: usize, key: HeaderName, value: T) -> T {
        let old = self.insert_occupied_same_key(index, value);
        self.entries[index].key = key;
        old
    }

    /// Set an occupied bucket to the given value without changing its key.
    #[inline]
    fn insert_occupied_same_key(&mut self, index: usize, value: T) -> T {
        if let Some(links) = self.entries[index].links {
            self.remove_all_extra_values(links.next);
        }

        let entry = &mut self.entries[index];
        mem::replace(&mut entry.value, value)
    }

    fn insert_occupied_mult(
        &mut self,
        index: usize,
        key: HeaderName,
        value: T,
    ) -> ValueDrain<'_, T> {
        self.insert_occupied_mult_inner(index, Some(key), value)
    }

    fn insert_occupied_mult_same_key(&mut self, index: usize, value: T) -> ValueDrain<'_, T> {
        self.insert_occupied_mult_inner(index, None, value)
    }

    fn insert_occupied_mult_inner(
        &mut self,
        index: usize,
        key: Option<HeaderName>,
        value: T,
    ) -> ValueDrain<'_, T> {
        let old;
        let links;

        {
            let entry = &mut self.entries[index];

            old = mem::replace(&mut entry.value, value);
            if let Some(key) = key {
                entry.key = key;
            }
            links = entry.links;
        }

        let next = links.map(|l| self.drain_all_extra_values(l.next).into_iter());

        ValueDrain {
            first: Some(old),
            next,
            lt: PhantomData,
        }
    }

    /// Inserts a key-value pair into the map.
    ///
    /// If the map did not previously have this key present, then `false` is
    /// returned.
    ///
    /// If the map did have this key present, the new value is pushed to the end
    /// of the list of values currently associated with the key. The key is not
    /// updated, though; this matters for types that can be `==` without being
    /// identical.
    ///
    /// # Panics
    ///
    /// This method panics if capacity exceeds max `HeaderMap` capacity
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::HOST;
    /// let mut map = HeaderMap::new();
    /// assert!(map.insert(HOST, "world".parse().unwrap()).is_none());
    /// assert!(!map.is_empty());
    ///
    /// map.append(HOST, "earth".parse().unwrap());
    ///
    /// let values = map.get_all("host");
    /// let mut i = values.iter();
    /// assert_eq!("world", *i.next().unwrap());
    /// assert_eq!("earth", *i.next().unwrap());
    /// ```
    pub fn append<K>(&mut self, key: K, value: T) -> bool
    where
        K: IntoHeaderName,
    {
        self.try_append(key, value)
            .expect("size overflows MAX_SIZE")
    }

    /// Inserts a key-value pair into the map.
    ///
    /// If the map did not previously have this key present, then `false` is
    /// returned.
    ///
    /// If the map did have this key present, the new value is pushed to the end
    /// of the list of values currently associated with the key. The key is not
    /// updated, though; this matters for types that can be `==` without being
    /// identical.
    ///
    /// # Errors
    ///
    /// This function may return an error if `HeaderMap` exceeds max capacity
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::HOST;
    /// let mut map = HeaderMap::new();
    /// assert!(map.try_insert(HOST, "world".parse().unwrap()).unwrap().is_none());
    /// assert!(!map.is_empty());
    ///
    /// map.try_append(HOST, "earth".parse().unwrap()).unwrap();
    ///
    /// let values = map.get_all("host");
    /// let mut i = values.iter();
    /// assert_eq!("world", *i.next().unwrap());
    /// assert_eq!("earth", *i.next().unwrap());
    /// ```
    pub fn try_append<K>(&mut self, key: K, value: T) -> Result<bool, MaxSizeReached>
    where
        K: IntoHeaderName,
    {
        key.try_append(self, value)
    }

    #[inline]
    fn try_append2<K>(&mut self, key: K, value: T) -> Result<bool, MaxSizeReached>
    where
        K: Into<HeaderName>,
    {
        self.try_reserve_one()?;
        let key = key.into();

        Ok(insert_phase_one!(
            self,
            key,
            probe,
            pos,
            hash,
            danger,
            // Vacant
            {
                if danger {
                    self.danger.set_yellow();
                }
                let index = self.entries.len();
                self.try_insert_entry(hash, key.into(), value)?;
                self.indices[probe] = Pos::new(index, hash);
                false
            },
            // Occupied
            {
                self.append_value(pos, key, value);
                true
            },
            // Robinhood
            {
                self.try_insert_phase_two(key.into(), value, hash, probe, danger)?;

                false
            }
        ))
    }

    #[inline]
    fn find<K>(&self, key: &K) -> Option<(usize, usize)>
    where
        K: Hash + Into<HeaderName> + ?Sized,
        HeaderName: PartialEq<K>,
    {
        if self.entries.is_empty() {
            return None;
        }

        let hash = hash_elem_using(&self.danger, key);
        let mask = self.mask();
        let mut probe = desired_pos(mask, hash);
        let mut dist = 0;

        probe_loop!(probe < self.indices.len(), {
            if let Some((i, entry_hash)) = self.indices[probe].resolve() {
                if dist > probe_distance(mask, entry_hash, probe) {
                    // give up when probe distance is too long
                    return None;
                } else if entry_hash == hash && self.entries[i].key == *key {
                    return Some((probe, i));
                }
            } else {
                return None;
            }

            dist += 1;
        });
    }

    /// phase 2 is post-insert where we forward-shift `Pos` in the indices.
    #[inline]
    fn try_insert_phase_two(
        &mut self,
        key: HeaderName,
        value: T,
        hash: HashValue,
        probe: usize,
        danger: bool,
    ) -> Result<usize, MaxSizeReached> {
        // Push the value and get the index
        let index = self.entries.len();
        self.try_insert_entry(hash, key, value)?;

        let num_displaced = do_insert_phase_two(&mut self.indices, probe, Pos::new(index, hash));

        if danger || num_displaced >= DISPLACEMENT_THRESHOLD {
            // Increase danger level
            self.danger.set_yellow();
        }

        Ok(index)
    }

    /// Removes a key from the map, returning the value associated with the key.
    ///
    /// Returns `None` if the map does not contain the key. If there are
    /// multiple values associated with the key, then the first one is returned.
    /// See `remove_entry_mult` on `OccupiedEntry` for an API that yields all
    /// values.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::HOST;
    /// let mut map = HeaderMap::new();
    /// map.insert(HOST, "hello.world".parse().unwrap());
    ///
    /// let prev = map.remove(HOST).unwrap();
    /// assert_eq!("hello.world", prev);
    ///
    /// assert!(map.remove(HOST).is_none());
    /// ```
    pub fn remove<K>(&mut self, key: K) -> Option<T>
    where
        K: AsHeaderName,
    {
        match key.find(self) {
            Some((probe, idx)) => {
                if let Some(links) = self.entries[idx].links {
                    self.remove_all_extra_values(links.next);
                }

                let entry = self.remove_found(probe, idx);

                Some(entry.value)
            }
            None => None,
        }
    }

    /// Remove an entry from the map.
    ///
    /// Warning: To avoid inconsistent state, extra values _must_ be removed
    /// for the `found` index (via `remove_all_extra_values` or similar)
    /// _before_ this method is called.
    #[inline]
    fn remove_found(&mut self, probe: usize, found: usize) -> Bucket<T> {
        self.remove_order(self.entries[found].order);

        // index `probe` and entry `found` is to be removed
        // use swap_remove, but then we need to update the index that points
        // to the other entry that has to move
        self.indices[probe] = Pos::none();
        let entry = self.entries.swap_remove(found);

        // correct index that points to the entry that had to swap places
        if found < self.entries.len() {
            let order = self.entries[found].order;
            self.set_order_link(order, Link::Entry(found));

            let entry = &self.entries[found];
            // was not last element
            // examine new element in `found` and find it in indices
            let mut probe = desired_pos(self.mask(), entry.hash);

            probe_loop!(probe < self.indices.len(), {
                if let Some((i, _)) = self.indices[probe].resolve() {
                    if i >= self.entries.len() {
                        // found it
                        self.indices[probe] = Pos::new(found, entry.hash);
                        break;
                    }
                }
            });

            // Update links
            if let Some(links) = entry.links {
                self.extra_values[links.next].prev = Link::Entry(found);
                self.extra_values[links.tail].next = Link::Entry(found);
            }
        }

        // backward shift deletion in self.indices
        // after probe, shift all non-ideally placed indices backward
        if !self.entries.is_empty() {
            let mut last_probe = probe;
            let mut probe = probe + 1;

            probe_loop!(probe < self.indices.len(), {
                if let Some((_, entry_hash)) = self.indices[probe].resolve() {
                    if probe_distance(self.mask(), entry_hash, probe) > 0 {
                        self.indices[last_probe] = self.indices[probe];
                        self.indices[probe] = Pos::none();
                    } else {
                        break;
                    }
                } else {
                    break;
                }

                last_probe = probe;
            });
        }

        entry
    }

    /// Removes the `ExtraValue` at the given index.
    #[inline]
    fn remove_extra_value(&mut self, idx: usize) -> ExtraValue<T> {
        self.remove_order(self.extra_values[idx].order);

        let raw_links = RawLinks::new(&mut self.entries);
        let extra = remove_extra_value(raw_links, &mut self.extra_values, idx);

        if let Some(moved) = self.extra_values.get(idx) {
            let order = moved.order;
            self.set_order_link(order, Link::Extra(idx));
        }

        extra
    }

    fn remove_all_extra_values(&mut self, mut head: usize) {
        loop {
            let extra = self.remove_extra_value(head);

            if let Link::Extra(idx) = extra.next {
                head = idx;
            } else {
                break;
            }
        }
    }

    fn drain_all_extra_values(&mut self, mut head: usize) -> Vec<T> {
        let mut vec = Vec::new();
        loop {
            let extra = self.remove_extra_value(head);
            vec.push(extra.value);

            if let Link::Extra(idx) = extra.next {
                head = idx;
            } else {
                break;
            }
        }
        vec
    }

    #[inline]
    fn try_insert_entry(
        &mut self,
        hash: HashValue,
        key: HeaderName,
        value: T,
    ) -> Result<(), MaxSizeReached> {
        if self.entries.len() >= MAX_SIZE {
            return Err(MaxSizeReached::new());
        }

        let index = self.entries.len();
        let order = self.order.len();

        self.entries.push(Bucket {
            hash,
            key,
            value,
            links: None,
            order,
        });
        // Pushed after the element, so a panicking push leaves no slot naming
        // a missing element (order invariant).
        self.push_order(Link::Entry(index));

        Ok(())
    }

    fn rebuild(&mut self) {
        let mask = self.mask();
        // Loop over all entries and re-insert them into the map
        'outer: for (index, entry) in self.entries.iter_mut().enumerate() {
            let hash = hash_elem_using(&self.danger, &entry.key);
            let mut probe = desired_pos(mask, hash);
            let mut dist = 0;

            // Update the entry's hash code
            entry.hash = hash;

            probe_loop!(probe < self.indices.len(), {
                if let Some((_, entry_hash)) = self.indices[probe].resolve() {
                    // if existing element probed less than us, swap
                    let their_dist = probe_distance(mask, entry_hash, probe);

                    if their_dist < dist {
                        // Robinhood
                        break;
                    }
                } else {
                    // Vacant slot
                    self.indices[probe] = Pos::new(index, hash);
                    continue 'outer;
                }

                dist += 1;
            });

            do_insert_phase_two(&mut self.indices, probe, Pos::new(index, hash));
        }
    }

    fn reinsert_entry_in_order(&mut self, pos: Pos) {
        if let Some((_, entry_hash)) = pos.resolve() {
            // Find first empty bucket and insert there
            let mut probe = desired_pos(self.mask(), entry_hash);

            probe_loop!(probe < self.indices.len(), {
                if self.indices[probe].resolve().is_none() {
                    // empty bucket, insert here
                    self.indices[probe] = pos;
                    return;
                }
            });
        }
    }

    fn try_reserve_one(&mut self) -> Result<(), MaxSizeReached> {
        let len = self.entries.len();

        if self.danger.is_yellow() {
            // MAX_SIZE (2^15) and LOAD_FACTOR_THRESHOLD is 5, so the product
            // cannot overflow.
            if self.indices.len() < MAX_SIZE
                && self.entries.len() * LOAD_FACTOR_THRESHOLD >= self.indices.len()
            {
                // Transition back to green danger level
                self.danger.set_green();

                // Double the capacity
                let new_cap = self.indices.len() * 2;

                // Grow the capacity
                self.try_grow(new_cap)?;
            } else {
                self.danger.set_red();

                // Rebuild hash table
                for index in self.indices.iter_mut() {
                    *index = Pos::none();
                }

                self.rebuild();
            }
        }

        // A rebuild keeps the capacity, so a full map still has to grow, or refuse at MAX_SIZE.
        if len == self.capacity() {
            if len == 0 {
                let new_raw_cap = 8;

                self.indices = vec![Pos::none(); new_raw_cap].into_boxed_slice();
                let cap = usable_capacity(new_raw_cap);
                self.entries = Vec::with_capacity(cap);
                self.order.reserve_exact(cap);
            } else {
                let raw_cap = self.indices.len();
                self.try_grow(raw_cap << 1)?;
            }
        }

        Ok(())
    }

    #[inline]
    fn try_grow(&mut self, new_raw_cap: usize) -> Result<(), MaxSizeReached> {
        if new_raw_cap > MAX_SIZE {
            return Err(MaxSizeReached::new());
        }

        // find first ideally placed element -- start of cluster
        let mut first_ideal = 0;

        for (i, pos) in self.indices.iter().enumerate() {
            if let Some((_, entry_hash)) = pos.resolve() {
                if 0 == probe_distance(self.mask(), entry_hash, i) {
                    first_ideal = i;
                    break;
                }
            }
        }

        // visit the entries in an order where we can simply reinsert them
        // into self.indices without any bucket stealing.
        let old_indices = mem::replace(
            &mut self.indices,
            vec![Pos::none(); new_raw_cap].into_boxed_slice(),
        );

        for &pos in &old_indices[first_ideal..] {
            self.reinsert_entry_in_order(pos);
        }

        for &pos in &old_indices[..first_ideal] {
            self.reinsert_entry_in_order(pos);
        }

        // Reserve additional entry slots
        let more = self.capacity() - self.entries.len();
        self.entries.reserve_exact(more);
        self.order.reserve_exact(more);
        Ok(())
    }

    #[inline]
    fn mask(&self) -> Size {
        self.indices.len().wrapping_sub(1) as Size
    }

    #[inline]
    fn push_order(&mut self, link: Link) {
        self.order.push(Some(link));
    }

    #[inline]
    fn remove_order(&mut self, index: usize) {
        if let Some(slot) = self.order.get_mut(index) {
            *slot = None;
        }
    }

    #[inline]
    fn set_order_link(&mut self, index: usize, link: Link) {
        if let Some(slot) = self.order.get_mut(index)
            && slot.is_some()
        {
            *slot = Some(link);
        }
    }

    #[inline]
    fn append_value(&mut self, entry_idx: usize, key: HeaderName, value: T) {
        let idx = self.extra_values.len();
        let order = self.order.len();
        let entry = &mut self.entries[entry_idx];

        match entry.links {
            Some(links) => {
                self.extra_values.push(ExtraValue {
                    key,
                    value,
                    prev: Link::Extra(links.tail),
                    next: Link::Entry(entry_idx),
                    order,
                });

                self.extra_values[links.tail].next = Link::Extra(idx);

                entry.links = Some(Links { tail: idx, ..links });
            }
            None => {
                self.extra_values.push(ExtraValue {
                    key,
                    value,
                    prev: Link::Entry(entry_idx),
                    next: Link::Entry(entry_idx),
                    order,
                });

                entry.links = Some(Links {
                    next: idx,
                    tail: idx,
                });
            }
        }
        // Pushed after the element, so a panicking push leaves no slot naming
        // a missing element (order invariant).
        self.push_order(Link::Extra(idx));
    }
}

/// Removes the `ExtraValue` at the given index.
#[inline]
fn remove_extra_value<T>(
    mut raw_links: RawLinks<'_, T>,
    extra_values: &mut Vec<ExtraValue<T>>,
    idx: usize,
) -> ExtraValue<T> {
    let prev;
    let next;

    {
        debug_assert!(extra_values.len() > idx);
        let extra = &extra_values[idx];
        prev = extra.prev;
        next = extra.next;
    }

    // First unlink the extra value
    match (prev, next) {
        (Link::Entry(prev), Link::Entry(next)) => {
            debug_assert_eq!(prev, next);

            raw_links[prev] = None;
        }
        (Link::Entry(prev), Link::Extra(next)) => {
            debug_assert!(raw_links[prev].is_some());

            raw_links[prev].as_mut().unwrap().next = next;

            debug_assert!(extra_values.len() > next);
            extra_values[next].prev = Link::Entry(prev);
        }
        (Link::Extra(prev), Link::Entry(next)) => {
            debug_assert!(raw_links[next].is_some());

            raw_links[next].as_mut().unwrap().tail = prev;

            debug_assert!(extra_values.len() > prev);
            extra_values[prev].next = Link::Entry(next);
        }
        (Link::Extra(prev), Link::Extra(next)) => {
            debug_assert!(extra_values.len() > next);
            debug_assert!(extra_values.len() > prev);

            extra_values[prev].next = Link::Extra(next);
            extra_values[next].prev = Link::Extra(prev);
        }
    }

    // Remove the extra value
    let mut extra = extra_values.swap_remove(idx);

    // This is the index of the value that was moved (possibly `extra`)
    let old_idx = extra_values.len();

    // Update the links
    if extra.prev == Link::Extra(old_idx) {
        extra.prev = Link::Extra(idx);
    }

    if extra.next == Link::Extra(old_idx) {
        extra.next = Link::Extra(idx);
    }

    // Check if another entry was displaced. If it was, then the links
    // need to be fixed.
    if idx != old_idx {
        let next;
        let prev;

        {
            debug_assert!(extra_values.len() > idx);
            let moved = &extra_values[idx];
            next = moved.next;
            prev = moved.prev;
        }

        // An entry was moved, we have to the links
        match prev {
            Link::Entry(entry_idx) => {
                // It is critical that we do not attempt to read the
                // header name or value as that memory may have been
                // "released" already.
                debug_assert!(raw_links[entry_idx].is_some());

                let links = raw_links[entry_idx].as_mut().unwrap();
                links.next = idx;
            }
            Link::Extra(extra_idx) => {
                debug_assert!(extra_values.len() > extra_idx);
                extra_values[extra_idx].next = Link::Extra(idx);
            }
        }

        match next {
            Link::Entry(entry_idx) => {
                debug_assert!(raw_links[entry_idx].is_some());

                let links = raw_links[entry_idx].as_mut().unwrap();
                links.tail = idx;
            }
            Link::Extra(extra_idx) => {
                debug_assert!(extra_values.len() > extra_idx);
                extra_values[extra_idx].prev = Link::Extra(idx);
            }
        }
    }

    debug_assert!({
        for v in &*extra_values {
            assert!(v.next != Link::Extra(old_idx));
            assert!(v.prev != Link::Extra(old_idx));
        }

        true
    });

    extra
}

impl<'a, T> IntoIterator for &'a HeaderMap<T> {
    type Item = (&'a HeaderName, &'a T);
    type IntoIter = Iter<'a, T>;

    fn into_iter(self) -> Iter<'a, T> {
        self.iter()
    }
}

impl<'a, T> IntoIterator for &'a mut HeaderMap<T> {
    type Item = (&'a HeaderName, &'a mut T);
    type IntoIter = IterMut<'a, T>;

    fn into_iter(self) -> IterMut<'a, T> {
        self.iter_mut()
    }
}

impl<T> IntoIterator for HeaderMap<T> {
    type Item = (Option<HeaderName>, T);
    type IntoIter = IntoIter<T>;

    /// Creates a consuming iterator, that is, one that moves keys and values
    /// out of the map in arbitrary order. The map cannot be used after calling
    /// this.
    ///
    /// For each yielded item that has `None` provided for the `HeaderName`,
    /// then the associated header name is the same as that of the previously
    /// yielded item. The first yielded item will have `HeaderName` set.
    ///
    /// # Examples
    ///
    /// Basic usage.
    ///
    /// ```
    /// # use rama_http_types::header;
    /// # use rama_http_types::header::*;
    /// let mut map = HeaderMap::new();
    /// map.insert(header::CONTENT_LENGTH, "123".parse().unwrap());
    /// map.insert(header::CONTENT_TYPE, "json".parse().unwrap());
    ///
    /// let mut iter = map.into_iter();
    /// assert_eq!(iter.next(), Some((Some(header::CONTENT_LENGTH), "123".parse().unwrap())));
    /// assert_eq!(iter.next(), Some((Some(header::CONTENT_TYPE), "json".parse().unwrap())));
    /// assert!(iter.next().is_none());
    /// ```
    ///
    /// Multiple values per key.
    ///
    /// ```
    /// # use rama_http_types::header;
    /// # use rama_http_types::header::*;
    /// let mut map = HeaderMap::new();
    ///
    /// map.append(header::CONTENT_LENGTH, "123".parse().unwrap());
    /// map.append(header::CONTENT_LENGTH, "456".parse().unwrap());
    ///
    /// map.append(header::CONTENT_TYPE, "json".parse().unwrap());
    /// map.append(header::CONTENT_TYPE, "html".parse().unwrap());
    /// map.append(header::CONTENT_TYPE, "xml".parse().unwrap());
    ///
    /// let mut iter = map.into_iter();
    ///
    /// assert_eq!(iter.next(), Some((Some(header::CONTENT_LENGTH), "123".parse().unwrap())));
    /// assert_eq!(iter.next(), Some((None, "456".parse().unwrap())));
    ///
    /// assert_eq!(iter.next(), Some((Some(header::CONTENT_TYPE), "json".parse().unwrap())));
    /// assert_eq!(iter.next(), Some((None, "html".parse().unwrap())));
    /// assert_eq!(iter.next(), Some((None, "xml".parse().unwrap())));
    /// assert!(iter.next().is_none());
    /// ```
    fn into_iter(self) -> IntoIter<T> {
        IntoIter {
            next: None,
            entries: self.entries.into_iter(),
            extra_values: self.extra_values,
        }
    }
}

impl<T> HeaderMap<T> {
    /// Creates a consuming iterator over entries in their original insertion
    /// order.
    ///
    /// Each yielded `HeaderName` preserves the casing that was used for that
    /// field line when it was inserted into the map.
    pub fn into_ordered_iter(self) -> IntoOrderedIter<T> {
        IntoOrderedIter {
            index: 0,
            order: self.order,
            entries: self.entries,
            extra_values: self.extra_values,
        }
    }
}

impl<T> FromIterator<(HeaderName, T)> for HeaderMap<T> {
    fn from_iter<I>(iter: I) -> Self
    where
        I: IntoIterator<Item = (HeaderName, T)>,
    {
        let mut map = HeaderMap::default();
        map.extend(iter);
        map
    }
}

/// Try to convert a `HashMap` into a `HeaderMap`.
///
/// # Examples
///
/// ```
/// use std::collections::HashMap;
/// use std::convert::TryInto;
/// use rama_http_types::HeaderMap;
///
/// let mut map = HashMap::new();
/// map.insert("X-Custom-Header".to_string(), "my value".to_string());
///
/// let headers: HeaderMap = (&map).try_into().expect("valid headers");
/// assert_eq!(headers["X-Custom-Header"], "my value");
/// ```
impl<'a, K, V, S, T> TryFrom<&'a HashMap<K, V, S>> for HeaderMap<T>
where
    K: Eq + Hash,
    HeaderName: TryFrom<&'a K>,
    <HeaderName as TryFrom<&'a K>>::Error: Into<crate::Error>,
    T: TryFrom<&'a V>,
    T::Error: Into<crate::Error>,
{
    type Error = Error;

    fn try_from(c: &'a HashMap<K, V, S>) -> Result<Self, Self::Error> {
        c.iter()
            .map(|(k, v)| -> crate::Result<(HeaderName, T)> {
                let name = TryFrom::try_from(k).map_err(Into::into)?;
                let value = TryFrom::try_from(v).map_err(Into::into)?;
                Ok((name, value))
            })
            .collect()
    }
}

impl<T> Extend<(Option<HeaderName>, T)> for HeaderMap<T> {
    /// Extend a `HeaderMap` with the contents of another `HeaderMap`.
    ///
    /// This function expects the yielded items to follow the same structure as
    /// `IntoIter`.
    ///
    /// # Panics
    ///
    /// This panics if the first yielded item does not have a `HeaderName`.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::*;
    /// let mut map = HeaderMap::new();
    ///
    /// map.insert(ACCEPT, "text/plain".parse().unwrap());
    /// map.insert(HOST, "hello.world".parse().unwrap());
    ///
    /// let mut extra = HeaderMap::new();
    ///
    /// extra.insert(HOST, "foo.bar".parse().unwrap());
    /// extra.insert(COOKIE, "hello".parse().unwrap());
    /// extra.append(COOKIE, "world".parse().unwrap());
    ///
    /// map.extend(extra);
    ///
    /// assert_eq!(map["host"], "foo.bar");
    /// assert_eq!(map["accept"], "text/plain");
    /// assert_eq!(map["cookie"], "hello");
    ///
    /// let v = map.get_all("host");
    /// assert_eq!(1, v.iter().count());
    ///
    /// let v = map.get_all("cookie");
    /// assert_eq!(2, v.iter().count());
    /// ```
    fn extend<I: IntoIterator<Item = (Option<HeaderName>, T)>>(&mut self, iter: I) {
        let mut iter = iter.into_iter();

        // Reserve capacity similar to the (HeaderName, T) impl.
        // Keys may be already present or show multiple times in the iterator.
        // Reserve the entire hint lower bound if the map is empty.
        // Otherwise reserve half the hint (rounded up), so the map
        // will only resize twice in the worst case.
        let hint = if self.is_empty() {
            iter.size_hint().0
        } else {
            (iter.size_hint().0 + 1) / 2
        };

        // Clamp the hint so an over-estimate cannot overflow `reserve`.
        let max_reserve = usable_capacity(MAX_SIZE).saturating_sub(self.entries.len());
        let reserve = hint.min(max_reserve);

        self.reserve(reserve);

        // The structure of this is a bit weird, but it is mostly to make the
        // borrow checker happy.
        let (mut key, mut val) = match iter.next() {
            Some((Some(key), val)) => (key, val),
            Some((None, _)) => panic!("expected a header name, but got None"),
            None => return,
        };

        'outer: loop {
            let mut entry = match self.try_entry2(key).expect("size overflows MAX_SIZE") {
                Entry::Occupied(mut e) => {
                    // Replace all previous values while maintaining a handle to
                    // the entry.
                    e.insert(val);
                    e
                }
                Entry::Vacant(e) => e.insert_entry(val),
            };

            // As long as `HeaderName` is none, keep inserting the value into
            // the current entry
            loop {
                match iter.next() {
                    Some((Some(k), v)) => {
                        key = k;
                        val = v;
                        continue 'outer;
                    }
                    Some((None, v)) => {
                        entry.append(v);
                    }
                    None => {
                        return;
                    }
                }
            }
        }
    }
}

impl<T> Extend<(HeaderName, T)> for HeaderMap<T> {
    fn extend<I: IntoIterator<Item = (HeaderName, T)>>(&mut self, iter: I) {
        // Keys may be already present or show multiple times in the iterator.
        // Reserve the entire hint lower bound if the map is empty.
        // Otherwise reserve half the hint (rounded up), so the map
        // will only resize twice in the worst case.
        let iter = iter.into_iter();

        let hint = if self.is_empty() {
            iter.size_hint().0
        } else {
            (iter.size_hint().0 + 1) / 2
        };

        // Clamp the hint so an over-estimate cannot overflow `reserve`.
        let max_reserve = usable_capacity(MAX_SIZE).saturating_sub(self.entries.len());
        let reserve = hint.min(max_reserve);

        self.reserve(reserve);

        for (k, v) in iter {
            self.append(k, v);
        }
    }
}

impl<T: PartialEq> PartialEq for HeaderMap<T> {
    fn eq(&self, other: &HeaderMap<T>) -> bool {
        if self.len() != other.len() {
            return false;
        }

        self.keys()
            .all(|key| self.get_all(key) == other.get_all(key))
    }
}

impl<T: Eq> Eq for HeaderMap<T> {}

impl<T: fmt::Debug> fmt::Debug for HeaderMap<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_map().entries(self.iter()).finish()
    }
}

impl serde::Serialize for HeaderMap<HeaderValue> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let mut sequence = serializer.serialize_seq(Some(self.len()))?;
        for header in self.ordered_iter() {
            sequence.serialize_element(&header)?;
        }
        sequence.end()
    }
}

impl<'de> serde::Deserialize<'de> for HeaderMap<HeaderValue> {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        Vec::<(HeaderName, HeaderValue)>::deserialize(deserializer)
            .map(|headers| headers.into_iter().collect())
    }
}

impl<K, T> ops::Index<K> for HeaderMap<T>
where
    K: AsHeaderName,
{
    type Output = T;

    /// # Panics
    /// Using the index operator will cause a panic if the header you're querying isn't set.
    #[inline]
    fn index(&self, index: K) -> &T {
        match self.get2(&index) {
            Some(val) => val,
            None => panic!("no entry found for key {:?}", index.as_str()),
        }
    }
}

/// phase 2 is post-insert where we forward-shift `Pos` in the indices.
///
/// returns the number of displaced elements
#[inline]
fn do_insert_phase_two(indices: &mut [Pos], mut probe: usize, mut old_pos: Pos) -> usize {
    let mut num_displaced = 0;

    probe_loop!(probe < indices.len(), {
        let pos = &mut indices[probe];

        if pos.is_none() {
            *pos = old_pos;
            break;
        } else {
            num_displaced += 1;
            old_pos = mem::replace(pos, old_pos);
        }
    });

    num_displaced
}

// ===== impl Iter =====

impl<'a, T> Iterator for Iter<'a, T> {
    type Item = (&'a HeaderName, &'a T);

    fn next(&mut self) -> Option<Self::Item> {
        use self::Cursor::*;

        if self.cursor.is_none() {
            if (self.entry + 1) >= self.map.entries.len() {
                return None;
            }

            self.entry += 1;
            self.cursor = Some(Cursor::Head);
        }

        let entry = &self.map.entries[self.entry];

        match self.cursor.unwrap() {
            Head => {
                self.cursor = entry.links.map(|l| Values(l.next));
                Some((&entry.key, &entry.value))
            }
            Values(idx) => {
                let extra = &self.map.extra_values[idx];

                match extra.next {
                    Link::Entry(_) => self.cursor = None,
                    Link::Extra(i) => self.cursor = Some(Values(i)),
                }

                Some((&entry.key, &extra.value))
            }
        }
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        let map = self.map;
        debug_assert!(map.entries.len() >= self.entry);

        let mut lower = map.entries.len() - self.entry;
        if self.cursor.is_none() {
            // The current entry is exhausted. Saturate for an empty map.
            lower = lower.saturating_sub(1);
        }
        // We could pessimistically guess at the upper bound, saying
        // that its lower + map.extra_values.len(). That could be
        // way over though, such as if we're near the end, and have
        // already gone through several extra values...
        (lower, None)
    }
}

impl<'a, T> FusedIterator for Iter<'a, T> {}

// ===== impl OrderedIter =====

impl<'a, T> Iterator for OrderedIter<'a, T> {
    type Item = (&'a HeaderName, &'a T);

    fn next(&mut self) -> Option<Self::Item> {
        while self.index < self.map.order.len() {
            let link = self.map.order[self.index];
            self.index += 1;

            if let Some(link) = link {
                return match link {
                    Link::Entry(idx) => {
                        let entry = &self.map.entries[idx];
                        Some((&entry.key, &entry.value))
                    }
                    Link::Extra(idx) => {
                        let extra = &self.map.extra_values[idx];
                        Some((&extra.key, &extra.value))
                    }
                };
            }
        }

        None
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        let remaining = self.map.order[self.index..]
            .iter()
            .filter(|link| link.is_some())
            .count();
        (remaining, Some(remaining))
    }
}

impl<'a, T> FusedIterator for OrderedIter<'a, T> {}

// ===== impl IterMut =====

impl<'a, T> IterMut<'a, T> {
    /// # Safety-usable invariant
    ///
    /// A returned `(key, value)` pair points to the key field of an entry and
    /// to a value field (of that entry or an extra value on its chain) of the
    /// map this iterator borrows mutably for `'a`. Both are aligned,
    /// initialized and stay valid for `'a`. Keys are never written through
    /// this iterator, and over the iterator's lifetime each value field is
    /// returned at most once.
    fn next_unsafe(&mut self) -> Option<(*const HeaderName, *mut T)> {
        use self::Cursor::*;

        if self.cursor.is_none() {
            if (self.entry + 1) >= self.entries_len {
                return None;
            }

            self.entry += 1;
            self.cursor = Some(Cursor::Head);
        }

        // `self.entry < self.entries_len`: the cursor is `Some` only after the
        // checks above (or from `iter_mut` on a non-empty map, with entry 0).
        //
        // SAFETY: `ptr::add` requires the result to stay in the allocation.
        // `self.entry < self.entries_len`, and `entries` is the buffer of a
        // `Vec` with that length that stays in place for `'a` (field invariant).
        let entry = unsafe { self.entries.add(self.entry) };

        match self.cursor.unwrap() {
            Head => {
                // SAFETY: the read needs `entry` aligned and pointing to an
                // initialized bucket: it is an in-bounds element of a live
                // `Vec`. Only the `Copy` `links` field is read; no reference to
                // the bucket is created, so yielded `&mut T`s are not aliased.
                self.cursor = unsafe { (*entry).links }.map(|l| Values(l.next));
                // SAFETY: computing in-bounds field addresses of the in-bounds
                // element `entry` creates no reference. Head values are yielded
                // once per entry because `self.entry` only grows.
                let key = unsafe { ptr::addr_of!((*entry).key) };
                // SAFETY: as for `key`.
                let value = unsafe { ptr::addr_of_mut!((*entry).value) };
                Some((key, value))
            }
            Values(idx) => {
                // SAFETY: `ptr::add` requires the result to stay in the
                // allocation. `idx` was read from the chain of entry
                // `self.entry`, so it is in bounds (links invariant).
                let extra = unsafe { self.extra_values.add(idx) };

                // SAFETY: `extra` is an in-bounds initialized element; only
                // its `Copy` `next` field is read.
                match unsafe { (*extra).next } {
                    Link::Entry(_) => self.cursor = None,
                    Link::Extra(i) => self.cursor = Some(Values(i)),
                }

                // SAFETY: in-bounds field address of `entry`, no reference.
                let key = unsafe { ptr::addr_of!((*entry).key) };
                // SAFETY: in-bounds field address of `extra`, no reference.
                // The links invariant puts each extra value on one chain and a
                // chain visits it once, so this value is yielded once.
                let value = unsafe { ptr::addr_of_mut!((*extra).value) };
                Some((key, value))
            }
        }
    }
}

impl<'a, T> Iterator for IterMut<'a, T> {
    type Item = (&'a HeaderName, &'a mut T);

    fn next(&mut self) -> Option<Self::Item> {
        let (key, value) = self.next_unsafe()?;
        // SAFETY: `&*key` needs an aligned pointer to an initialized
        // `HeaderName` that is not mutated for `'a`. The safety-usable
        // invariant of `next_unsafe` gives an aligned, initialized key valid
        // for `'a` that this iterator never writes, and the map is borrowed
        // by this iterator for `'a`, so nothing else writes it either.
        let key = unsafe { &*key };
        // SAFETY: `&mut *value` needs an aligned pointer to an initialized `T`
        // with no other live reference for `'a`. The safety-usable invariant
        // of `next_unsafe` gives an aligned, initialized value valid for `'a`
        // that is returned at most once, so no earlier `&mut` aliases it, and
        // the map is mutably borrowed by this iterator for `'a`.
        let value = unsafe { &mut *value };
        Some((key, value))
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        debug_assert!(self.entries_len >= self.entry);

        let mut lower = self.entries_len - self.entry;
        if self.cursor.is_none() {
            // The current entry is exhausted. Saturate for an empty map.
            lower = lower.saturating_sub(1);
        }
        // We could pessimistically guess at the upper bound, saying
        // that its lower + map.extra_values.len(). That could be
        // way over though, such as if we're near the end, and have
        // already gone through several extra values...
        (lower, None)
    }
}

impl<'a, T> FusedIterator for IterMut<'a, T> {}

// SAFETY: `IterMut` has the access of the `&'a mut HeaderMap<T>` it was made
// from and yields `&'a HeaderName` and `&'a mut T`. Sending it sends that
// exclusive access, which `&mut HeaderMap<T>: Send` allows iff `T: Send`
// (`HeaderName` is `Send + Sync`).
unsafe impl<'a, T: Send> Send for IterMut<'a, T> {}
// SAFETY: `&IterMut` only exposes `size_hint` and `Debug`, which read the
// iterator's own `usize`/cursor fields and print the raw pointers; nothing
// reaches the map, so sharing it adds no access beyond `T: Sync`.
unsafe impl<'a, T: Sync> Sync for IterMut<'a, T> {}

// ===== impl Keys =====

impl<'a, T> Iterator for Keys<'a, T> {
    type Item = &'a HeaderName;

    fn next(&mut self) -> Option<Self::Item> {
        self.inner.next().map(|b| &b.key)
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.inner.size_hint()
    }

    fn nth(&mut self, n: usize) -> Option<Self::Item> {
        self.inner.nth(n).map(|b| &b.key)
    }

    fn count(self) -> usize {
        self.inner.count()
    }

    fn last(self) -> Option<Self::Item> {
        self.inner.last().map(|b| &b.key)
    }
}

impl<'a, T> ExactSizeIterator for Keys<'a, T> {}
impl<'a, T> FusedIterator for Keys<'a, T> {}

// ===== impl Values ====

impl<'a, T> Iterator for Values<'a, T> {
    type Item = &'a T;

    fn next(&mut self) -> Option<Self::Item> {
        self.inner.next().map(|(_, v)| v)
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.inner.size_hint()
    }
}

impl<'a, T> FusedIterator for Values<'a, T> {}

// ===== impl ValuesMut ====

impl<'a, T> Iterator for ValuesMut<'a, T> {
    type Item = &'a mut T;

    fn next(&mut self) -> Option<Self::Item> {
        self.inner.next().map(|(_, v)| v)
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.inner.size_hint()
    }
}

impl<'a, T> FusedIterator for ValuesMut<'a, T> {}

// ===== impl Drain =====

impl<'a, T> Iterator for Drain<'a, T> {
    type Item = (Option<HeaderName>, T);

    fn next(&mut self) -> Option<Self::Item> {
        if let Some(next) = self.next {
            // Remove the extra value

            // SAFETY: `RawLinks::from_raw` requires `self.entries` to be valid
            // for reads and writes of every element's `links` for the
            // borrow, with no other access to them: the `Drain::entries`
            // invariant gives this, and `&mut self` excludes other `Drain` uses.
            let raw_links = unsafe { RawLinks::from_raw(self.entries) };
            // SAFETY: `&mut *self.extra_values` needs a live, aligned `Vec`
            // with no other reference: the `Drain::extra_values` invariant
            // and `&mut self`. The reference ends with this call.
            let extra_values = unsafe { &mut *self.extra_values };
            let extra = remove_extra_value(raw_links, extra_values, next);

            match extra.next {
                Link::Extra(idx) => self.next = Some(idx),
                Link::Entry(_) => self.next = None,
            }

            return Some((None, extra.value));
        }

        let idx = self.idx;

        if idx == self.len {
            return None;
        }

        self.idx += 1;

        // SAFETY: the place `(*self.entries)[idx]` is bounds-checked against
        // the slice length `self.len`; `idx < self.len` and element `idx` is
        // initialized and not yet moved out (`Drain::entries` invariant), so a
        // shared reference to it is valid.
        let entry = unsafe { &(*self.entries)[idx] };

        // SAFETY: `ptr::read` needs an aligned source holding an initialized
        // value: `entry.key` is a field of the initialized bucket above.
        // Postcondition: the key is moved out; `self.idx` is already past
        // `idx`, so this bucket's key and value are not read again.
        let key = unsafe { ptr::read(&raw const entry.key) };
        // SAFETY: as for `key`, for the value field.
        let value = unsafe { ptr::read(&raw const entry.value) };
        self.next = entry.links.map(|l| l.next);

        Some((Some(key), value))
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        // At least this many names... It's unknown if the user wants
        // to count the extra_values on top.
        //
        // For instance, extending a new `HeaderMap` wouldn't need to
        // reserve the upper-bound in `entries`, only the lower-bound.
        let lower = self.len - self.idx;
        // SAFETY: reading through `self.extra_values` needs a live, aligned
        // `Vec` that is not being mutated: the `Drain::extra_values` invariant,
        // and `&self` excludes the `&mut self` paths that mutate it.
        let upper = unsafe { (*self.extra_values).len() } + lower;
        (lower, Some(upper))
    }
}

impl<'a, T> FusedIterator for Drain<'a, T> {}

impl<'a, T> Drop for Drain<'a, T> {
    fn drop(&mut self) {
        struct Guard<'a, 'b, T>(&'a mut Drain<'b, T>);
        struct ExtraValuesGuard<T>(*mut Vec<ExtraValue<T>>);

        impl<T> Drop for ExtraValuesGuard<T> {
            fn drop(&mut self) {
                // SAFETY: `&mut *self.0` needs a live, aligned `Vec` with no
                // other reference: the `Drain::extra_values` invariant, and the
                // `Drain` is no longer used once this guard drops.
                let extra_values = unsafe { &mut *self.0 };
                // SAFETY: `set_len(0)` requires `0 <= capacity` and no
                // elements initialized, trivially true. Postcondition: values
                // the drain did not remove are leaked, never dropped twice.
                unsafe { extra_values.set_len(0) };
            }
        }

        impl<'a, 'b, T> Drop for Guard<'a, 'b, T> {
            fn drop(&mut self) {
                let _extra_values_guard = ExtraValuesGuard(self.0.extra_values);

                for _ in self.0.by_ref() {}
            }
        }

        let guard = Guard(self);

        for _ in guard.0.by_ref() {}
    }
}

// SAFETY: `Drain` has the access of the `&'a mut HeaderMap<T>` it was made from
// and yields owned `HeaderName`s and `T`s. Sending it sends that access, which
// `&mut HeaderMap<T>: Send` allows iff `T: Send`.
unsafe impl<'a, T: Send> Send for Drain<'a, T> {}
// SAFETY: `&Drain` only exposes `size_hint` (reads `usize` fields and the
// `extra_values` length) and `Debug` (prints the raw pointers); every mutation
// needs `&mut Drain`, so sharing it is a shared read of the map: `T: Sync`.
unsafe impl<'a, T: Sync> Sync for Drain<'a, T> {}

// ===== impl Entry =====

impl<'a, T> Entry<'a, T> {
    /// Ensures a value is in the entry by inserting the default if empty.
    ///
    /// Returns a mutable reference to the **first** value in the entry.
    ///
    /// # Panics
    ///
    /// This method panics if capacity exceeds max `HeaderMap` capacity
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// let mut map: HeaderMap<u32> = HeaderMap::default();
    ///
    /// let headers = &[
    ///     "content-length",
    ///     "x-hello",
    ///     "Content-Length",
    ///     "x-world",
    /// ];
    ///
    /// for &header in headers {
    ///     let counter = map.entry(header)
    ///         .or_insert(0);
    ///     *counter += 1;
    /// }
    ///
    /// assert_eq!(map["content-length"], 2);
    /// assert_eq!(map["x-hello"], 1);
    /// ```
    pub fn or_insert(self, default: T) -> &'a mut T {
        self.or_try_insert(default)
            .expect("size overflows MAX_SIZE")
    }

    /// Ensures a value is in the entry by inserting the default if empty.
    ///
    /// Returns a mutable reference to the **first** value in the entry.
    ///
    /// # Errors
    ///
    /// This function may return an error if `HeaderMap` exceeds max capacity
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// let mut map: HeaderMap<u32> = HeaderMap::default();
    ///
    /// let headers = &[
    ///     "content-length",
    ///     "x-hello",
    ///     "Content-Length",
    ///     "x-world",
    /// ];
    ///
    /// for &header in headers {
    ///     let counter = map.entry(header)
    ///         .or_try_insert(0)
    ///         .unwrap();
    ///     *counter += 1;
    /// }
    ///
    /// assert_eq!(map["content-length"], 2);
    /// assert_eq!(map["x-hello"], 1);
    /// ```
    pub fn or_try_insert(self, default: T) -> Result<&'a mut T, MaxSizeReached> {
        use self::Entry::*;

        match self {
            Occupied(e) => Ok(e.into_mut()),
            Vacant(e) => e.try_insert(default),
        }
    }

    /// Ensures a value is in the entry by inserting the result of the default
    /// function if empty.
    ///
    /// The default function is not called if the entry exists in the map.
    /// Returns a mutable reference to the **first** value in the entry.
    ///
    /// # Examples
    ///
    /// Basic usage.
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// let mut map = HeaderMap::new();
    ///
    /// let res = map.entry("x-hello")
    ///     .or_insert_with(|| "world".parse().unwrap());
    ///
    /// assert_eq!(res, "world");
    /// ```
    ///
    /// The default function is not called if the entry exists in the map.
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::HOST;
    /// let mut map = HeaderMap::new();
    /// map.try_insert(HOST, "world".parse().unwrap()).unwrap();
    ///
    /// let res = map.try_entry("host")
    ///     .unwrap()
    ///     .or_try_insert_with(|| unreachable!())
    ///     .unwrap();
    ///
    ///
    /// assert_eq!(res, "world");
    /// ```
    pub fn or_insert_with<F: FnOnce() -> T>(self, default: F) -> &'a mut T {
        self.or_try_insert_with(default)
            .expect("size overflows MAX_SIZE")
    }

    /// Ensures a value is in the entry by inserting the result of the default
    /// function if empty.
    ///
    /// The default function is not called if the entry exists in the map.
    /// Returns a mutable reference to the **first** value in the entry.
    ///
    /// # Examples
    ///
    /// Basic usage.
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// let mut map = HeaderMap::new();
    ///
    /// let res = map.entry("x-hello")
    ///     .or_insert_with(|| "world".parse().unwrap());
    ///
    /// assert_eq!(res, "world");
    /// ```
    ///
    /// The default function is not called if the entry exists in the map.
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::HOST;
    /// let mut map = HeaderMap::new();
    /// map.try_insert(HOST, "world".parse().unwrap()).unwrap();
    ///
    /// let res = map.try_entry("host")
    ///     .unwrap()
    ///     .or_try_insert_with(|| unreachable!())
    ///     .unwrap();
    ///
    ///
    /// assert_eq!(res, "world");
    /// ```
    pub fn or_try_insert_with<F: FnOnce() -> T>(
        self,
        default: F,
    ) -> Result<&'a mut T, MaxSizeReached> {
        use self::Entry::*;

        match self {
            Occupied(e) => Ok(e.into_mut()),
            Vacant(e) => e.try_insert(default()),
        }
    }

    /// Returns a reference to the entry's key
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// let mut map = HeaderMap::new();
    ///
    /// assert_eq!(map.entry("x-hello").key(), "x-hello");
    /// ```
    pub fn key(&self) -> &HeaderName {
        use self::Entry::*;

        match *self {
            Vacant(ref e) => e.key(),
            Occupied(ref e) => e.key(),
        }
    }
}

// ===== impl VacantEntry =====

impl<'a, T> VacantEntry<'a, T> {
    /// Returns a reference to the entry's key
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// let mut map = HeaderMap::new();
    ///
    /// assert_eq!(map.entry("x-hello").key().as_str(), "x-hello");
    /// ```
    pub fn key(&self) -> &HeaderName {
        &self.key
    }

    /// Take ownership of the key
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::{HeaderMap, Entry};
    /// let mut map = HeaderMap::new();
    ///
    /// if let Entry::Vacant(v) = map.entry("x-hello") {
    ///     assert_eq!(v.into_key().as_str(), "x-hello");
    /// }
    /// ```
    pub fn into_key(self) -> HeaderName {
        self.key
    }

    /// Insert the value into the entry.
    ///
    /// The value will be associated with this entry's key. A mutable reference
    /// to the inserted value will be returned.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::{HeaderMap, Entry};
    /// let mut map = HeaderMap::new();
    ///
    /// if let Entry::Vacant(v) = map.entry("x-hello") {
    ///     v.insert("world".parse().unwrap());
    /// }
    ///
    /// assert_eq!(map["x-hello"], "world");
    /// ```
    pub fn insert(self, value: T) -> &'a mut T {
        self.try_insert(value).expect("size overflows MAX_SIZE")
    }

    /// Insert the value into the entry.
    ///
    /// The value will be associated with this entry's key. A mutable reference
    /// to the inserted value will be returned.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::{HeaderMap, Entry};
    /// let mut map = HeaderMap::new();
    ///
    /// if let Entry::Vacant(v) = map.entry("x-hello") {
    ///     v.insert("world".parse().unwrap());
    /// }
    ///
    /// assert_eq!(map["x-hello"], "world");
    /// ```
    pub fn try_insert(self, value: T) -> Result<&'a mut T, MaxSizeReached> {
        // Ensure that there is space in the map
        let index =
            self.map
                .try_insert_phase_two(self.key, value, self.hash, self.probe, self.danger)?;

        Ok(&mut self.map.entries[index].value)
    }

    /// Insert the value into the entry.
    ///
    /// The value will be associated with this entry's key. The new
    /// `OccupiedEntry` is returned, allowing for further manipulation.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::*;
    /// let mut map = HeaderMap::new();
    ///
    /// if let Entry::Vacant(v) = map.try_entry("x-hello").unwrap() {
    ///     let mut e = v.try_insert_entry("world".parse().unwrap()).unwrap();
    ///     e.insert("world2".parse().unwrap());
    /// }
    ///
    /// assert_eq!(map["x-hello"], "world2");
    /// ```
    pub fn insert_entry(self, value: T) -> OccupiedEntry<'a, T> {
        self.try_insert_entry(value)
            .expect("size overflows MAX_SIZE")
    }

    /// Insert the value into the entry.
    ///
    /// The value will be associated with this entry's key. The new
    /// `OccupiedEntry` is returned, allowing for further manipulation.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::*;
    /// let mut map = HeaderMap::new();
    ///
    /// if let Entry::Vacant(v) = map.try_entry("x-hello").unwrap() {
    ///     let mut e = v.try_insert_entry("world".parse().unwrap()).unwrap();
    ///     e.insert("world2".parse().unwrap());
    /// }
    ///
    /// assert_eq!(map["x-hello"], "world2");
    /// ```
    pub fn try_insert_entry(self, value: T) -> Result<OccupiedEntry<'a, T>, MaxSizeReached> {
        // Ensure that there is space in the map
        let index =
            self.map
                .try_insert_phase_two(self.key, value, self.hash, self.probe, self.danger)?;

        Ok(OccupiedEntry {
            map: self.map,
            index,
            probe: self.probe,
        })
    }
}

// ===== impl GetAll =====

impl<'a, T: 'a> GetAll<'a, T> {
    /// Returns an iterator visiting all values associated with the entry.
    ///
    /// Values are iterated in insertion order.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::HeaderMap;
    /// # use rama_http_types::header::HOST;
    /// let mut map = HeaderMap::new();
    /// map.insert(HOST, "hello.world".parse().unwrap());
    /// map.append(HOST, "hello.earth".parse().unwrap());
    ///
    /// let values = map.get_all("host");
    /// let mut iter = values.iter();
    /// assert_eq!(&"hello.world", iter.next().unwrap());
    /// assert_eq!(&"hello.earth", iter.next().unwrap());
    /// assert!(iter.next().is_none());
    /// ```
    pub fn iter(&self) -> ValueIter<'a, T> {
        // This creates a new GetAll struct so that the lifetime
        // isn't bound to &self.
        GetAll {
            map: self.map,
            index: self.index,
        }
        .into_iter()
    }
}

impl<'a, T: PartialEq> PartialEq for GetAll<'a, T> {
    fn eq(&self, other: &Self) -> bool {
        self.iter().eq(other.iter())
    }
}

impl<'a, T> IntoIterator for GetAll<'a, T> {
    type Item = &'a T;
    type IntoIter = ValueIter<'a, T>;

    fn into_iter(self) -> ValueIter<'a, T> {
        self.map.value_iter(self.index)
    }
}

impl<'a, 'b: 'a, T> IntoIterator for &'b GetAll<'a, T> {
    type Item = &'a T;
    type IntoIter = ValueIter<'a, T>;

    fn into_iter(self) -> ValueIter<'a, T> {
        self.map.value_iter(self.index)
    }
}

// ===== impl ValueIter =====

impl<'a, T: 'a> Iterator for ValueIter<'a, T> {
    type Item = &'a T;

    fn next(&mut self) -> Option<Self::Item> {
        use self::Cursor::*;

        match self.front {
            Some(Head) => {
                let entry = &self.map.entries[self.index];

                if self.back == Some(Head) {
                    self.front = None;
                    self.back = None;
                } else {
                    // Update the iterator state
                    match entry.links {
                        Some(links) => {
                            self.front = Some(Values(links.next));
                        }
                        None => unreachable!(),
                    }
                }

                Some(&entry.value)
            }
            Some(Values(idx)) => {
                let extra = &self.map.extra_values[idx];

                if self.front == self.back {
                    self.front = None;
                    self.back = None;
                } else {
                    match extra.next {
                        Link::Entry(_) => self.front = None,
                        Link::Extra(i) => self.front = Some(Values(i)),
                    }
                }

                Some(&extra.value)
            }
            None => None,
        }
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        match (self.front, self.back) {
            // Exactly 1 value...
            (Some(Cursor::Head), Some(Cursor::Head)) => (1, Some(1)),
            // At least 1...
            (Some(_), _) => (1, None),
            // No more values...
            (None, _) => (0, Some(0)),
        }
    }
}

impl<'a, T: 'a> DoubleEndedIterator for ValueIter<'a, T> {
    fn next_back(&mut self) -> Option<Self::Item> {
        use self::Cursor::*;

        match self.back {
            Some(Head) => {
                self.front = None;
                self.back = None;
                Some(&self.map.entries[self.index].value)
            }
            Some(Values(idx)) => {
                let extra = &self.map.extra_values[idx];

                if self.front == self.back {
                    self.front = None;
                    self.back = None;
                } else {
                    match extra.prev {
                        Link::Entry(_) => self.back = Some(Head),
                        Link::Extra(idx) => self.back = Some(Values(idx)),
                    }
                }

                Some(&extra.value)
            }
            None => None,
        }
    }
}

impl<'a, T> FusedIterator for ValueIter<'a, T> {}

// ===== impl ValueIterMut =====

impl<'a, T: 'a> Iterator for ValueIterMut<'a, T> {
    type Item = &'a mut T;

    fn next(&mut self) -> Option<Self::Item> {
        use self::Cursor::*;

        // SAFETY: `ptr::add` requires the result to stay in the allocation:
        // `self.index` is below the map's `entries.len()` (field invariant).
        let entry = unsafe { self.entries.add(self.index) };

        match self.front {
            Some(Head) => {
                if self.back == Some(Head) {
                    self.front = None;
                    self.back = None;
                } else {
                    // Update the iterator state
                    // SAFETY: `entry` is an in-bounds initialized bucket; only
                    // its `Copy` `links` field is read, no reference is made.
                    match unsafe { (*entry).links } {
                        Some(links) => {
                            self.front = Some(Values(links.next));
                        }
                        None => unreachable!(),
                    }
                }

                // SAFETY: in-bounds field address of `entry`, no reference.
                let value = unsafe { ptr::addr_of_mut!((*entry).value) };
                // SAFETY: `&mut *value` needs an aligned, initialized `T` with
                // no other live reference for `'a`. The head value was between
                // `front` and `back`, both cursors moved past it above, so it
                // is yielded once (field invariant), and the map is mutably
                // borrowed for `'a`.
                Some(unsafe { &mut *value })
            }
            Some(Values(idx)) => {
                // SAFETY: `ptr::add` requires the result to stay in the
                // allocation: `idx` is on the chain of entry `self.index`, so
                // it is in bounds (links invariant).
                let extra = unsafe { self.extra_values.add(idx) };

                if self.front == self.back {
                    self.front = None;
                    self.back = None;
                } else {
                    // SAFETY: `extra` is an in-bounds initialized element;
                    // only its `Copy` `next` field is read.
                    match unsafe { (*extra).next } {
                        Link::Entry(_) => self.front = None,
                        Link::Extra(i) => self.front = Some(Values(i)),
                    }
                }

                // SAFETY: in-bounds field address of `extra`, no reference.
                let value = unsafe { ptr::addr_of_mut!((*extra).value) };
                // SAFETY: as for the head value: `front` moved past this node
                // along `next` (or both cursors were cleared), so it is yielded
                // once; the links invariant makes `next`/`prev` mirror each
                // other, so `back` never revisits it.
                Some(unsafe { &mut *value })
            }
            None => None,
        }
    }
}

impl<'a, T: 'a> DoubleEndedIterator for ValueIterMut<'a, T> {
    fn next_back(&mut self) -> Option<Self::Item> {
        use self::Cursor::*;

        // SAFETY: `ptr::add` requires the result to stay in the allocation:
        // `self.index` is below the map's `entries.len()` (field invariant).
        let entry = unsafe { self.entries.add(self.index) };

        match self.back {
            Some(Head) => {
                self.front = None;
                self.back = None;
                // SAFETY: in-bounds field address of `entry`, no reference.
                let value = unsafe { ptr::addr_of_mut!((*entry).value) };
                // SAFETY: `back` reached the head, so every other value is
                // already yielded or past `front`; both cursors are cleared,
                // so this value is yielded once, and the map is mutably
                // borrowed for `'a`.
                Some(unsafe { &mut *value })
            }
            Some(Values(idx)) => {
                // SAFETY: `ptr::add` requires the result to stay in the
                // allocation: `idx` is on the chain of entry `self.index`, so
                // it is in bounds (links invariant).
                let extra = unsafe { self.extra_values.add(idx) };

                if self.front == self.back {
                    self.front = None;
                    self.back = None;
                } else {
                    // SAFETY: `extra` is an in-bounds initialized element;
                    // only its `Copy` `prev` field is read.
                    match unsafe { (*extra).prev } {
                        Link::Entry(_) => self.back = Some(Head),
                        Link::Extra(idx) => self.back = Some(Values(idx)),
                    }
                }

                // SAFETY: in-bounds field address of `extra`, no reference.
                let value = unsafe { ptr::addr_of_mut!((*extra).value) };
                // SAFETY: `back` moved past this node along `prev` (or both
                // cursors were cleared), so it is yielded once; `front` never
                // revisits it because `next`/`prev` mirror (links invariant).
                Some(unsafe { &mut *value })
            }
            None => None,
        }
    }
}

impl<'a, T> FusedIterator for ValueIterMut<'a, T> {}

// SAFETY: `ValueIterMut` has the access of the `&'a mut HeaderMap<T>` it was
// made from and yields `&'a mut T`; sending it is sound iff `T: Send`, as for
// `&mut HeaderMap<T>`.
unsafe impl<'a, T: Send> Send for ValueIterMut<'a, T> {}
// SAFETY: `&ValueIterMut` only exposes `Debug`, which prints the raw pointers
// and cursors; nothing reaches the map, so `T: Sync` suffices.
unsafe impl<'a, T: Sync> Sync for ValueIterMut<'a, T> {}

// ===== impl IntoIter =====

impl<T> Iterator for IntoIter<T> {
    type Item = (Option<HeaderName>, T);

    fn next(&mut self) -> Option<Self::Item> {
        if let Some(next) = self.next {
            let extra = &mut self.extra_values[next];
            self.next = match extra.next {
                Link::Entry(_) => None,
                Link::Extra(v) => Some(v),
            };
            let key = ptr::addr_of_mut!(extra.key);
            let value = ptr::addr_of!(extra.value);

            // SAFETY: `drop_in_place` needs an aligned pointer to an
            // initialized key that is not used afterwards. `next` was on a
            // pending chain, so this extra value is initialized and not moved
            // out (field invariant); `self.next` already moved past it, and it
            // is on no other chain (links invariant), so it is not read again.
            unsafe { ptr::drop_in_place(key) };
            // SAFETY: `ptr::read` needs an aligned source holding an
            // initialized value: the same extra value's untouched value field.
            // Postcondition: the value is moved out and, as above, never read
            // again. A panic in the key drop above leaks the value instead.
            let value = unsafe { ptr::read(value) };

            return Some((None, value));
        }

        if let Some(bucket) = self.entries.next() {
            self.next = bucket.links.map(|l| l.next);
            let name = Some(bucket.key);
            let value = bucket.value;

            return Some((name, value));
        }

        None
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        let (lower, _) = self.entries.size_hint();
        // There could be more than just the entries upper, as there
        // could be items in the `extra_values`. We could guess, saying
        // `upper + extra_values.len()`, but that could overestimate by a lot.
        (lower, None)
    }
}

impl<T> FusedIterator for IntoIter<T> {}

impl<T: fmt::Debug> fmt::Debug for IntoIter<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // `extra_values` holds moved-out values (field invariant), so only the
        // buckets not yet yielded by `entries` are formatted.
        f.debug_struct("IntoIter")
            .field("next", &self.next)
            .field("entries", &self.entries)
            .finish_non_exhaustive()
    }
}

impl<T> Drop for IntoIter<T> {
    fn drop(&mut self) {
        struct Guard<'a, T>(&'a mut IntoIter<T>);

        impl<'a, T> Drop for Guard<'a, T> {
            fn drop(&mut self) {
                // SAFETY: `set_len(0)` requires `0 <= capacity` and no
                // elements initialized, trivially true. Postcondition: the
                // `Vec` drops no extra value; the moved-out ones are not dropped
                // twice, and any left on a chain after a panic are leaked.
                unsafe {
                    self.0.extra_values.set_len(0);
                }
            }
        }

        let guard = Guard(self);

        // Ensure the iterator is consumed
        for _ in guard.0.by_ref() {}
    }
}

// ===== impl IntoOrderedIter =====

impl<T> Iterator for IntoOrderedIter<T> {
    type Item = (HeaderName, T);

    fn next(&mut self) -> Option<Self::Item> {
        while self.index < self.order.len() {
            let slot = self.index;
            let link = self.order[slot].take();
            self.index += 1;

            // By the order invariant, slot `slot` is the only one naming this
            // element, so it is initialized and read here once.
            match link {
                Some(Link::Entry(idx)) => {
                    let Some(entry) = self.entries.get(idx) else {
                        debug_assert!(false, "order slot {slot} names a missing entry");
                        continue;
                    };
                    debug_assert_eq!(entry.order, slot);
                    // SAFETY: `ptr::read` needs an aligned source holding an
                    // initialized value. `entry` is in bounds, and only slot
                    // `slot` names it (order invariant), which `self.index`
                    // has now passed, so it is not yet moved out. Postcondition:
                    // its key and value are moved out, and no later slot names it.
                    let name = unsafe { ptr::read(&raw const entry.key) };
                    // SAFETY: as for `name`, for the value field.
                    let value = unsafe { ptr::read(&raw const entry.value) };
                    return Some((name, value));
                }
                Some(Link::Extra(idx)) => {
                    let Some(extra) = self.extra_values.get(idx) else {
                        debug_assert!(false, "order slot {slot} names a missing extra value");
                        continue;
                    };
                    debug_assert_eq!(extra.order, slot);
                    // SAFETY: as for entries above: `extra` is in bounds and
                    // named only by slot `slot` (order invariant), so its key is
                    // initialized and moved out only here.
                    let name = unsafe { ptr::read(&raw const extra.key) };
                    // SAFETY: as for `name`, for the value field.
                    let value = unsafe { ptr::read(&raw const extra.value) };
                    return Some((name, value));
                }
                None => {}
            }
        }

        None
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        (0, Some(self.entries.len() + self.extra_values.len()))
    }
}

impl<T> FusedIterator for IntoOrderedIter<T> {}

impl<T> fmt::Debug for IntoOrderedIter<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // `entries` and `extra_values` hold moved-out elements (field
        // invariant), so only the position and the remaining count are shown.
        let remaining = self.order[self.index..]
            .iter()
            .filter(|link| link.is_some())
            .count();
        f.debug_struct("IntoOrderedIter")
            .field("index", &self.index)
            .field("remaining", &remaining)
            .finish_non_exhaustive()
    }
}

impl<T> Drop for IntoOrderedIter<T> {
    fn drop(&mut self) {
        struct Guard<'a, T>(&'a mut IntoOrderedIter<T>);

        impl<'a, T> Drop for Guard<'a, T> {
            fn drop(&mut self) {
                // SAFETY: `set_len(0)` requires `0 <= capacity` and no
                // elements initialized, trivially true. Postcondition: the
                // `Vec`s drop no element; moved-out ones are not dropped twice
                // and any still named by an unvisited slot after a panic leak.
                unsafe { self.0.entries.set_len(0) };
                // SAFETY: as above, for `extra_values`.
                unsafe { self.0.extra_values.set_len(0) };
            }
        }

        let guard = Guard(self);

        for _ in guard.0.by_ref() {}
    }
}

// ===== impl OccupiedEntry =====

impl<'a, T> OccupiedEntry<'a, T> {
    /// Returns a reference to the entry's key.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::{HeaderMap, Entry, HOST};
    /// let mut map = HeaderMap::new();
    /// map.insert(HOST, "world".parse().unwrap());
    ///
    /// if let Entry::Occupied(e) = map.entry("host") {
    ///     assert_eq!("host", e.key());
    /// }
    /// ```
    pub fn key(&self) -> &HeaderName {
        &self.map.entries[self.index].key
    }

    /// Get a reference to the first value in the entry.
    ///
    /// Values are stored in insertion order.
    ///
    /// # Panics
    ///
    /// `get` panics if there are no values associated with the entry.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::{HeaderMap, Entry, HOST};
    /// let mut map = HeaderMap::new();
    /// map.insert(HOST, "hello.world".parse().unwrap());
    ///
    /// if let Entry::Occupied(mut e) = map.entry("host") {
    ///     assert_eq!(e.get(), &"hello.world");
    ///
    ///     e.append("hello.earth".parse().unwrap());
    ///
    ///     assert_eq!(e.get(), &"hello.world");
    /// }
    /// ```
    pub fn get(&self) -> &T {
        &self.map.entries[self.index].value
    }

    /// Get a mutable reference to the first value in the entry.
    ///
    /// Values are stored in insertion order.
    ///
    /// # Panics
    ///
    /// `get_mut` panics if there are no values associated with the entry.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::{HeaderMap, Entry, HOST};
    /// let mut map = HeaderMap::default();
    /// map.insert(HOST, "hello.world".to_string());
    ///
    /// if let Entry::Occupied(mut e) = map.entry("host") {
    ///     e.get_mut().push_str("-2");
    ///     assert_eq!(e.get(), &"hello.world-2");
    /// }
    /// ```
    pub fn get_mut(&mut self) -> &mut T {
        &mut self.map.entries[self.index].value
    }

    /// Converts the `OccupiedEntry` into a mutable reference to the **first**
    /// value.
    ///
    /// The lifetime of the returned reference is bound to the original map.
    ///
    /// # Panics
    ///
    /// `into_mut` panics if there are no values associated with the entry.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::{HeaderMap, Entry, HOST};
    /// let mut map = HeaderMap::default();
    /// map.insert(HOST, "hello.world".to_string());
    /// map.append(HOST, "hello.earth".to_string());
    ///
    /// if let Entry::Occupied(e) = map.entry("host") {
    ///     e.into_mut().push_str("-2");
    /// }
    ///
    /// assert_eq!("hello.world-2", map["host"]);
    /// ```
    pub fn into_mut(self) -> &'a mut T {
        &mut self.map.entries[self.index].value
    }

    /// Sets the value of the entry.
    ///
    /// All previous values associated with the entry are removed and the first
    /// one is returned. See `insert_mult` for an API that returns all values.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::{HeaderMap, Entry, HOST};
    /// let mut map = HeaderMap::new();
    /// map.insert(HOST, "hello.world".parse().unwrap());
    ///
    /// if let Entry::Occupied(mut e) = map.entry("host") {
    ///     let mut prev = e.insert("earth".parse().unwrap());
    ///     assert_eq!("hello.world", prev);
    /// }
    ///
    /// assert_eq!("earth", map["host"]);
    /// ```
    pub fn insert(&mut self, value: T) -> T {
        self.map.insert_occupied_same_key(self.index, value)
    }

    /// Sets the value of the entry.
    ///
    /// This function does the same as `insert` except it returns an iterator
    /// that yields all values previously associated with the key.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::{HeaderMap, Entry, HOST};
    /// let mut map = HeaderMap::new();
    /// map.insert(HOST, "world".parse().unwrap());
    /// map.append(HOST, "world2".parse().unwrap());
    ///
    /// if let Entry::Occupied(mut e) = map.entry("host") {
    ///     let mut prev = e.insert_mult("earth".parse().unwrap());
    ///     assert_eq!("world", prev.next().unwrap());
    ///     assert_eq!("world2", prev.next().unwrap());
    ///     assert!(prev.next().is_none());
    /// }
    ///
    /// assert_eq!("earth", map["host"]);
    /// ```
    pub fn insert_mult(&mut self, value: T) -> ValueDrain<'_, T> {
        self.map.insert_occupied_mult_same_key(self.index, value)
    }

    /// Insert the value into the entry.
    ///
    /// The new value is appended to the end of the entry's value list. All
    /// previous values associated with the entry are retained.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::{HeaderMap, Entry, HOST};
    /// let mut map = HeaderMap::new();
    /// map.insert(HOST, "world".parse().unwrap());
    ///
    /// if let Entry::Occupied(mut e) = map.entry("host") {
    ///     e.append("earth".parse().unwrap());
    /// }
    ///
    /// let values = map.get_all("host");
    /// let mut i = values.iter();
    /// assert_eq!("world", *i.next().unwrap());
    /// assert_eq!("earth", *i.next().unwrap());
    /// ```
    pub fn append(&mut self, value: T) {
        let idx = self.index;
        let key = self.map.entries[idx].key.clone();
        self.map.append_value(idx, key, value);
    }

    /// Remove the entry from the map.
    ///
    /// All values associated with the entry are removed and the first one is
    /// returned. See `remove_entry_mult` for an API that returns all values.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::{HeaderMap, Entry, HOST};
    /// let mut map = HeaderMap::new();
    /// map.insert(HOST, "world".parse().unwrap());
    ///
    /// if let Entry::Occupied(e) = map.entry("host") {
    ///     let mut prev = e.remove();
    ///     assert_eq!("world", prev);
    /// }
    ///
    /// assert!(!map.contains_key("host"));
    /// ```
    pub fn remove(self) -> T {
        self.remove_entry().1
    }

    /// Remove the entry from the map.
    ///
    /// The key and all values associated with the entry are removed and the
    /// first one is returned. See `remove_entry_mult` for an API that returns
    /// all values.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::{HeaderMap, Entry, HOST};
    /// let mut map = HeaderMap::new();
    /// map.insert(HOST, "world".parse().unwrap());
    ///
    /// if let Entry::Occupied(e) = map.entry("host") {
    ///     let (key, mut prev) = e.remove_entry();
    ///     assert_eq!("host", key.as_str());
    ///     assert_eq!("world", prev);
    /// }
    ///
    /// assert!(!map.contains_key("host"));
    /// ```
    pub fn remove_entry(self) -> (HeaderName, T) {
        if let Some(links) = self.map.entries[self.index].links {
            self.map.remove_all_extra_values(links.next);
        }

        let entry = self.map.remove_found(self.probe, self.index);

        (entry.key, entry.value)
    }

    /// Remove the entry from the map.
    ///
    /// The key and all values associated with the entry are removed and
    /// returned.
    pub fn remove_entry_mult(self) -> (HeaderName, ValueDrain<'a, T>) {
        let next = self.map.entries[self.index]
            .links
            .map(|l| self.map.drain_all_extra_values(l.next).into_iter());

        let entry = self.map.remove_found(self.probe, self.index);

        let drain = ValueDrain {
            first: Some(entry.value),
            next,
            lt: PhantomData,
        };
        (entry.key, drain)
    }

    /// Returns an iterator visiting all values associated with the entry.
    ///
    /// Values are iterated in insertion order.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::{HeaderMap, Entry, HOST};
    /// let mut map = HeaderMap::new();
    /// map.insert(HOST, "world".parse().unwrap());
    /// map.append(HOST, "earth".parse().unwrap());
    ///
    /// if let Entry::Occupied(e) = map.entry("host") {
    ///     let mut iter = e.iter();
    ///     assert_eq!(&"world", iter.next().unwrap());
    ///     assert_eq!(&"earth", iter.next().unwrap());
    ///     assert!(iter.next().is_none());
    /// }
    /// ```
    pub fn iter(&self) -> ValueIter<'_, T> {
        self.map.value_iter(Some(self.index))
    }

    /// Returns an iterator mutably visiting all values associated with the
    /// entry.
    ///
    /// Values are iterated in insertion order.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::{HeaderMap, Entry, HOST};
    /// let mut map = HeaderMap::default();
    /// map.insert(HOST, "world".to_string());
    /// map.append(HOST, "earth".to_string());
    ///
    /// if let Entry::Occupied(mut e) = map.entry("host") {
    ///     for e in e.iter_mut() {
    ///         e.push_str("-boop");
    ///     }
    /// }
    ///
    /// let mut values = map.get_all("host");
    /// let mut i = values.iter();
    /// assert_eq!(&"world-boop", i.next().unwrap());
    /// assert_eq!(&"earth-boop", i.next().unwrap());
    /// ```
    pub fn iter_mut(&mut self) -> ValueIterMut<'_, T> {
        self.map.value_iter_mut(self.index)
    }
}

impl<'a, T> IntoIterator for OccupiedEntry<'a, T> {
    type Item = &'a mut T;
    type IntoIter = ValueIterMut<'a, T>;

    fn into_iter(self) -> ValueIterMut<'a, T> {
        self.map.value_iter_mut(self.index)
    }
}

impl<'a, 'b: 'a, T> IntoIterator for &'b OccupiedEntry<'a, T> {
    type Item = &'a T;
    type IntoIter = ValueIter<'a, T>;

    fn into_iter(self) -> ValueIter<'a, T> {
        self.iter()
    }
}

impl<'a, 'b: 'a, T> IntoIterator for &'b mut OccupiedEntry<'a, T> {
    type Item = &'a mut T;
    type IntoIter = ValueIterMut<'a, T>;

    fn into_iter(self) -> ValueIterMut<'a, T> {
        self.iter_mut()
    }
}

// ===== impl ValueDrain =====

impl<'a, T> Iterator for ValueDrain<'a, T> {
    type Item = T;

    fn next(&mut self) -> Option<T> {
        if self.first.is_some() {
            self.first.take()
        } else if let Some(ref mut extras) = self.next {
            extras.next()
        } else {
            None
        }
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        match (&self.first, &self.next) {
            // Exactly 1
            (&Some(_), &None) => (1, Some(1)),
            // 1 + extras
            (&Some(_), Some(extras)) => {
                let (l, u) = extras.size_hint();
                (l + 1, u.map(|u| u + 1))
            }
            // Extras only
            (&None, Some(extras)) => extras.size_hint(),
            // No more
            (&None, &None) => (0, Some(0)),
        }
    }
}

impl<'a, T> FusedIterator for ValueDrain<'a, T> {}

impl<'a, T> Drop for ValueDrain<'a, T> {
    fn drop(&mut self) {
        for _ in self.by_ref() {}
    }
}

// ===== impl RawLinks =====

impl<'a, T> RawLinks<'a, T> {
    fn new(entries: &'a mut [Bucket<T>]) -> Self {
        Self {
            // The field invariant holds: `entries` is mutably borrowed for `'a`.
            ptr: entries,
            lt: PhantomData,
        }
    }

    /// # Safety
    ///
    /// The caller must ensure that for `'a`, `ptr` addresses a slice of
    /// buckets in one live allocation, aligned, whose `links` fields are
    /// initialized and valid for reads and writes, and that nothing other than
    /// the returned value accesses those `links` fields. Other fields of the
    /// buckets may be moved out; the returned value never touches them.
    unsafe fn from_raw(ptr: *mut [Bucket<T>]) -> Self {
        Self {
            // The field invariant is this function's precondition.
            ptr,
            lt: PhantomData,
        }
    }
}

impl<T> ops::Index<usize> for RawLinks<'_, T> {
    type Output = Option<Links>;

    fn index(&self, idx: usize) -> &Self::Output {
        // SAFETY: the place `(*self.ptr)[idx]` is bounds-checked against the
        // slice length, and only its `links` field is borrowed, which is
        // initialized and readable for `'a` with no other access (field
        // invariant). The borrow of `self` bounds the reference within `'a`.
        unsafe { &(*self.ptr)[idx].links }
    }
}

impl<T> ops::IndexMut<usize> for RawLinks<'_, T> {
    fn index_mut(&mut self, idx: usize) -> &mut Self::Output {
        // SAFETY: as for `index`; `&mut self` makes this the only reference
        // into the `links` fields while it lives.
        unsafe { &mut (*self.ptr)[idx].links }
    }
}

// ===== impl Pos =====

impl Pos {
    #[inline]
    fn new(index: usize, hash: HashValue) -> Self {
        debug_assert!(index < MAX_SIZE);
        Pos {
            index: index as Size,
            hash,
        }
    }

    #[inline]
    fn none() -> Self {
        Pos {
            index: !0,
            hash: HashValue(0),
        }
    }

    #[inline]
    fn is_some(&self) -> bool {
        !self.is_none()
    }

    #[inline]
    fn is_none(&self) -> bool {
        self.index == !0
    }

    #[inline]
    fn resolve(&self) -> Option<(usize, HashValue)> {
        if self.is_some() {
            Some((self.index as usize, self.hash))
        } else {
            None
        }
    }
}

impl Danger {
    fn is_red(&self) -> bool {
        matches!(*self, Danger::Red(_))
    }

    fn set_red(&mut self) {
        debug_assert!(self.is_yellow());
        *self = Danger::Red(Box::new(RandomState::new()));
    }

    fn is_yellow(&self) -> bool {
        matches!(*self, Danger::Yellow)
    }

    fn set_yellow(&mut self) {
        if let Danger::Green = *self {
            *self = Danger::Yellow;
        }
    }

    fn set_green(&mut self) {
        debug_assert!(self.is_yellow());
        *self = Danger::Green;
    }
}

// ===== impl MaxSizeReached =====

impl MaxSizeReached {
    fn new() -> Self {
        MaxSizeReached { _priv: () }
    }
}

impl fmt::Debug for MaxSizeReached {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.debug_struct("MaxSizeReached")
            // skip _priv noise
            .finish()
    }
}

impl fmt::Display for MaxSizeReached {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("max size reached")
    }
}

impl std::error::Error for MaxSizeReached {}

// ===== impl Utils =====

#[inline]
fn usable_capacity(cap: usize) -> usize {
    cap - cap / 4
}

#[inline]
fn to_raw_capacity(n: usize) -> Result<usize, MaxSizeReached> {
    n.checked_add(n / 3).ok_or_else(MaxSizeReached::new)
}

#[inline]
fn desired_pos(mask: Size, hash: HashValue) -> usize {
    (hash.0 & mask) as usize
}

/// The number of steps that `current` is forward of the desired position for hash
#[inline]
fn probe_distance(mask: Size, hash: HashValue, current: usize) -> usize {
    current.wrapping_sub(desired_pos(mask, hash)) & mask as usize
}

#[inline]
fn hash_elem_using<K>(danger: &Danger, k: &K) -> HashValue
where
    K: Hash + ?Sized,
{
    const MASK: u64 = (MAX_SIZE as u64) - 1;

    let hash = match *danger {
        // Safe hash
        Danger::Red(ref hasher) => {
            let mut h = hasher.build_hasher();
            k.hash(&mut h);
            h.finish()
        }
        // Fast hash
        _ => {
            let mut h = FnvHasher::new();
            k.hash(&mut h);
            h.finish()
        }
    };

    HashValue((hash & MASK) as u16)
}

struct FnvHasher(u64);

impl FnvHasher {
    #[inline]
    fn new() -> Self {
        FnvHasher(0xcbf29ce484222325)
    }
}

impl std::hash::Hasher for FnvHasher {
    #[inline]
    fn finish(&self) -> u64 {
        self.0
    }

    #[inline]
    fn write(&mut self, bytes: &[u8]) {
        let mut hash = self.0;
        for &b in bytes {
            hash ^= b as u64;
            hash = hash.wrapping_mul(0x100000001b3);
        }
        self.0 = hash;
    }
}

/*
 *
 * ===== impl IntoHeaderName / AsHeaderName =====
 *
 */

mod into_header_name {
    use super::{Entry, HdrName, HeaderMap, HeaderName, MaxSizeReached};

    /// A marker trait used to identify values that can be used as insert keys
    /// to a `HeaderMap`.
    pub trait IntoHeaderName: Sealed {}

    // All methods are on this pub(super) trait, instead of `IntoHeaderName`,
    // so that they aren't publicly exposed to the world.
    //
    // Being on the `IntoHeaderName` trait would mean users could call
    // `"host".insert(&mut map, "localhost")`.
    //
    // Ultimately, this allows us to adjust the signatures of these methods
    // without breaking any external crate.
    pub trait Sealed {
        #[doc(hidden)]
        fn try_insert<T>(self, map: &mut HeaderMap<T>, val: T)
        -> Result<Option<T>, MaxSizeReached>;

        #[doc(hidden)]
        fn try_append<T>(self, map: &mut HeaderMap<T>, val: T) -> Result<bool, MaxSizeReached>;

        #[doc(hidden)]
        fn try_entry<T>(self, map: &mut HeaderMap<T>) -> Result<Entry<'_, T>, MaxSizeReached>;
    }

    // ==== impls ====

    impl Sealed for HeaderName {
        #[inline]
        fn try_insert<T>(
            self,
            map: &mut HeaderMap<T>,
            val: T,
        ) -> Result<Option<T>, MaxSizeReached> {
            map.try_insert2(self, val)
        }

        #[inline]
        fn try_append<T>(self, map: &mut HeaderMap<T>, val: T) -> Result<bool, MaxSizeReached> {
            map.try_append2(self, val)
        }

        #[inline]
        fn try_entry<T>(self, map: &mut HeaderMap<T>) -> Result<Entry<'_, T>, MaxSizeReached> {
            map.try_entry2(self)
        }
    }

    impl IntoHeaderName for HeaderName {}

    impl Sealed for &HeaderName {
        #[inline]
        fn try_insert<T>(
            self,
            map: &mut HeaderMap<T>,
            val: T,
        ) -> Result<Option<T>, MaxSizeReached> {
            map.try_insert2(self, val)
        }

        #[inline]
        fn try_append<T>(self, map: &mut HeaderMap<T>, val: T) -> Result<bool, MaxSizeReached> {
            map.try_append2(self, val)
        }

        #[inline]
        fn try_entry<T>(self, map: &mut HeaderMap<T>) -> Result<Entry<'_, T>, MaxSizeReached> {
            map.try_entry2(self)
        }
    }

    impl IntoHeaderName for &HeaderName {}

    impl Sealed for &'static str {
        #[inline]
        fn try_insert<T>(
            self,
            map: &mut HeaderMap<T>,
            val: T,
        ) -> Result<Option<T>, MaxSizeReached> {
            HdrName::from_static(self, move |hdr| map.try_insert2(hdr, val))
        }

        #[inline]
        fn try_append<T>(self, map: &mut HeaderMap<T>, val: T) -> Result<bool, MaxSizeReached> {
            HdrName::from_static(self, move |hdr| map.try_append2(hdr, val))
        }

        #[inline]
        fn try_entry<T>(self, map: &mut HeaderMap<T>) -> Result<Entry<'_, T>, MaxSizeReached> {
            HdrName::from_static(self, move |hdr| map.try_entry2(hdr))
        }
    }

    impl IntoHeaderName for &'static str {}
}

mod as_header_name {
    use super::{Entry, HdrName, HeaderMap, HeaderName, InvalidHeaderName, MaxSizeReached};

    /// A marker trait used to identify values that can be used as search keys
    /// to a `HeaderMap`.
    pub trait AsHeaderName: Sealed {}

    // Debug not currently needed, save on compiling it
    #[allow(missing_debug_implementations)]
    pub enum TryEntryError {
        InvalidHeaderName(InvalidHeaderName),
        MaxSizeReached(MaxSizeReached),
    }

    impl From<InvalidHeaderName> for TryEntryError {
        fn from(e: InvalidHeaderName) -> TryEntryError {
            TryEntryError::InvalidHeaderName(e)
        }
    }

    impl From<MaxSizeReached> for TryEntryError {
        fn from(e: MaxSizeReached) -> TryEntryError {
            TryEntryError::MaxSizeReached(e)
        }
    }

    // All methods are on this pub(super) trait, instead of `AsHeaderName`,
    // so that they aren't publicly exposed to the world.
    //
    // Being on the `AsHeaderName` trait would mean users could call
    // `"host".find(&map)`.
    //
    // Ultimately, this allows us to adjust the signatures of these methods
    // without breaking any external crate.
    pub trait Sealed {
        #[doc(hidden)]
        fn try_entry<T>(self, map: &mut HeaderMap<T>) -> Result<Entry<'_, T>, TryEntryError>;

        #[doc(hidden)]
        fn find<T>(&self, map: &HeaderMap<T>) -> Option<(usize, usize)>;

        #[doc(hidden)]
        fn as_str(&self) -> &str;
    }

    // ==== impls ====

    impl Sealed for HeaderName {
        #[inline]
        fn try_entry<T>(self, map: &mut HeaderMap<T>) -> Result<Entry<'_, T>, TryEntryError> {
            Ok(map.try_entry2(self)?)
        }

        #[inline]
        fn find<T>(&self, map: &HeaderMap<T>) -> Option<(usize, usize)> {
            map.find(self)
        }

        fn as_str(&self) -> &str {
            <HeaderName>::as_str(self)
        }
    }

    impl AsHeaderName for HeaderName {}

    impl Sealed for &HeaderName {
        #[inline]
        fn try_entry<T>(self, map: &mut HeaderMap<T>) -> Result<Entry<'_, T>, TryEntryError> {
            Ok(map.try_entry2(self)?)
        }

        #[inline]
        fn find<T>(&self, map: &HeaderMap<T>) -> Option<(usize, usize)> {
            map.find(*self)
        }

        fn as_str(&self) -> &str {
            <HeaderName>::as_str(self)
        }
    }

    impl AsHeaderName for &HeaderName {}

    impl Sealed for &str {
        #[inline]
        fn try_entry<T>(self, map: &mut HeaderMap<T>) -> Result<Entry<'_, T>, TryEntryError> {
            Ok(HdrName::from_bytes(self.as_bytes(), move |hdr| {
                map.try_entry2(hdr)
            })??)
        }

        #[inline]
        fn find<T>(&self, map: &HeaderMap<T>) -> Option<(usize, usize)> {
            HdrName::from_bytes(self.as_bytes(), move |hdr| map.find(&hdr)).unwrap_or(None)
        }

        fn as_str(&self) -> &str {
            self
        }
    }

    impl AsHeaderName for &str {}

    impl Sealed for String {
        #[inline]
        fn try_entry<T>(self, map: &mut HeaderMap<T>) -> Result<Entry<'_, T>, TryEntryError> {
            self.as_str().try_entry(map)
        }

        #[inline]
        fn find<T>(&self, map: &HeaderMap<T>) -> Option<(usize, usize)> {
            Sealed::find(&self.as_str(), map)
        }

        fn as_str(&self) -> &str {
            self
        }
    }

    impl AsHeaderName for String {}

    impl Sealed for &String {
        #[inline]
        fn try_entry<T>(self, map: &mut HeaderMap<T>) -> Result<Entry<'_, T>, TryEntryError> {
            self.as_str().try_entry(map)
        }

        #[inline]
        fn find<T>(&self, map: &HeaderMap<T>) -> Option<(usize, usize)> {
            Sealed::find(*self, map)
        }

        fn as_str(&self) -> &str {
            self
        }
    }

    impl AsHeaderName for &String {}
}

#[test]
fn test_bounds() {
    fn check_bounds<T: Send + Sync>() {}

    check_bounds::<HeaderMap<()>>();
    check_bounds::<Iter<'static, ()>>();
    check_bounds::<OrderedIter<'static, ()>>();
    check_bounds::<IterMut<'static, ()>>();
    check_bounds::<IntoIter<()>>();
    check_bounds::<IntoOrderedIter<()>>();
    check_bounds::<Keys<'static, ()>>();
    check_bounds::<Values<'static, ()>>();
    check_bounds::<ValuesMut<'static, ()>>();
    check_bounds::<Drain<'static, ()>>();
    check_bounds::<GetAll<'static, ()>>();
    check_bounds::<Entry<'static, ()>>();
    check_bounds::<VacantEntry<'static, ()>>();
    check_bounds::<OccupiedEntry<'static, ()>>();
    check_bounds::<ValueIter<'static, ()>>();
    check_bounds::<ValueIterMut<'static, ()>>();
    check_bounds::<ValueDrain<'static, ()>>();
}

#[test]
fn iter_size_hint_bounds_the_remaining_values() {
    fn check(mut iter: impl Iterator, len: usize) {
        for remaining in (0..=len).rev() {
            let (lower, upper) = iter.size_hint();
            assert!(lower <= remaining, "lower {lower} > remaining {remaining}");
            if let Some(upper) = upper {
                assert!(upper >= remaining, "upper {upper} < remaining {remaining}");
            }
            assert_eq!(iter.next().is_some(), remaining > 0);
        }
        assert_eq!(iter.size_hint().0, 0);
        assert!(iter.next().is_none());
    }

    for counts in [vec![], vec![1], vec![3], vec![1, 1], vec![3, 1, 2]] {
        let mut headers = HeaderMap::new();
        for (i, count) in counts.into_iter().enumerate() {
            let name = HeaderName::from_bytes(format!("header-{i}").as_bytes()).unwrap();
            for _ in 0..count {
                headers.append(name.clone(), HeaderValue::from_static("x"));
            }
        }
        let len = headers.len();
        check(headers.iter(), len);
        check(headers.ordered_iter(), len);
        check(headers.values(), len);
        check(headers.iter_mut(), len);
        check(headers.values_mut(), len);
        check(headers.clone().into_iter(), len);
        check(headers.clone().into_ordered_iter(), len);
        check(headers.drain(), len);
    }
}

#[test]
fn invalid_long_names_never_become_keys() {
    // Past the 64-byte scratch buffer, so the long-name parse path is taken.
    let invalid = format!("x-{}\r\nx-injected: 1", "a".repeat(64));
    let mut map = HeaderMap::new();
    assert!(map.try_entry(invalid.as_str()).is_err());
    assert!(map.try_entry(invalid.clone()).is_err());
    assert!(map.get(invalid.as_str()).is_none());
    assert!(map.is_empty());

    let valid = format!("X-{}", "a".repeat(64));
    map.try_entry(valid.as_str())
        .unwrap()
        .or_insert(HeaderValue::from_static("v"));
    assert_eq!(
        map.get(valid.to_ascii_lowercase().as_str()),
        Some(&HeaderValue::from_static("v"))
    );
    assert_eq!(map.keys().next().unwrap().as_str(), valid);
}

#[test]
#[should_panic(expected = "static str is invalid name")]
fn invalid_long_static_name_panics_like_a_short_one() {
    let mut map = HeaderMap::new();
    map.insert(
        "x-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa invalid",
        HeaderValue::from_static("v"),
    );
}

#[test]
fn extend_size_hint_above_capacity() {
    // A `HeaderMap` may hold more values than the table can index when many
    // values are appended under one name, so an exact size hint can exceed the
    // largest `reserve` request. Extending must not panic in that case.
    let name = HeaderName::from_static("h");
    let value = HeaderValue::from_static("0");
    let pairs: Vec<(HeaderName, HeaderValue)> =
        std::iter::repeat_with(|| (name.clone(), value.clone()))
            .take(24_577)
            .collect();

    let map = HeaderMap::from_iter(pairs);
    assert_eq!(map.len(), 24_577);
    assert_eq!(map.keys_len(), 1);
}

#[cfg(test)]
fn assert_header_map_invariants<T>(map: &HeaderMap<T>) {
    assert_eq!(map.len(), map.entries.len() + map.extra_values.len());
    assert!(
        map.entries.len() <= map.capacity(),
        "{} names exceed the capacity of {}",
        map.entries.len(),
        map.capacity()
    );

    let live_order_slots = map.order.iter().filter(|link| link.is_some()).count();
    assert_eq!(live_order_slots, map.len());

    let mut indexed_entries = vec![false; map.entries.len()];
    for pos in &*map.indices {
        if let Some((idx, hash)) = pos.resolve() {
            assert!(idx < map.entries.len(), "index points past entries: {idx}");
            assert_eq!(map.entries[idx].hash, hash);
            assert!(!indexed_entries[idx], "entry indexed more than once: {idx}");
            indexed_entries[idx] = true;
        }
    }
    assert!(
        indexed_entries.iter().all(|seen| *seen),
        "not every entry is reachable from indices"
    );

    let mut linked_extras = vec![false; map.extra_values.len()];
    for (entry_idx, entry) in map.entries.iter().enumerate() {
        assert_eq!(map.order[entry.order], Some(Link::Entry(entry_idx)));

        let Some(links) = entry.links else {
            continue;
        };

        assert!(links.next < map.extra_values.len());
        assert!(links.tail < map.extra_values.len());

        let mut prev = Link::Entry(entry_idx);
        let mut current = links.next;
        loop {
            assert!(current < map.extra_values.len());
            assert!(
                !linked_extras[current],
                "extra value linked more than once: {current}"
            );
            linked_extras[current] = true;

            let extra = &map.extra_values[current];
            assert_eq!(extra.prev, prev);
            assert_eq!(extra.key, entry.key);
            assert_eq!(map.order[extra.order], Some(Link::Extra(current)));

            match extra.next {
                Link::Entry(idx) => {
                    assert_eq!(idx, entry_idx);
                    assert_eq!(current, links.tail);
                    break;
                }
                Link::Extra(next) => {
                    prev = Link::Extra(current);
                    current = next;
                }
            }
        }
    }
    assert!(
        linked_extras.iter().all(|seen| *seen),
        "not every extra value is linked from an entry"
    );

    for (order_idx, link) in map.order.iter().enumerate() {
        match link {
            Some(Link::Entry(idx)) => {
                assert!(*idx < map.entries.len());
                assert_eq!(map.entries[*idx].order, order_idx);
            }
            Some(Link::Extra(idx)) => {
                assert!(*idx < map.extra_values.len());
                assert_eq!(map.extra_values[*idx].order, order_idx);
            }
            None => {}
        }
    }
}

#[cfg(test)]
#[derive(Clone, Debug)]
struct HeaderMapOps(Vec<HeaderMapOp>);

#[cfg(test)]
#[derive(Clone, Debug)]
enum HeaderMapOp {
    Append { name: u8, value: u8 },
    Insert { name: u8, value: u8 },
    Remove { name: u8 },
    RemoveEntryMult { name: u8 },
    EntryAppend { name: u8, value: u8 },
    EntryInsertMult { name: u8, value: u8 },
}

#[cfg(test)]
#[derive(Clone, Debug, Eq, PartialEq)]
struct ModelHeader {
    semantic_id: usize,
    name: String,
    value: String,
    head: bool,
}

#[cfg(test)]
#[derive(Default)]
struct HeaderMapModel {
    fields: Vec<Option<ModelHeader>>,
}

#[cfg(test)]
impl HeaderMapModel {
    fn len(&self) -> usize {
        self.fields.iter().filter(|field| field.is_some()).count()
    }

    fn ordered(&self) -> Vec<(String, String)> {
        self.fields
            .iter()
            .filter_map(|field| {
                field
                    .as_ref()
                    .map(|field| (field.name.clone(), field.value.clone()))
            })
            .collect()
    }

    fn values_for(&self, semantic_id: usize) -> Vec<String> {
        self.fields
            .iter()
            .filter_map(|field| {
                let field = field.as_ref()?;
                (field.semantic_id == semantic_id).then(|| field.value.clone())
            })
            .collect()
    }

    fn head_index(&self, semantic_id: usize) -> Option<usize> {
        self.fields.iter().position(|field| {
            field
                .as_ref()
                .is_some_and(|field| field.semantic_id == semantic_id && field.head)
        })
    }

    fn remove(&mut self, semantic_id: usize) {
        for field in &mut self.fields {
            if field
                .as_ref()
                .is_some_and(|field| field.semantic_id == semantic_id)
            {
                *field = None;
            }
        }
    }

    fn append(&mut self, semantic_id: usize, name: String, value: String) {
        let head = self.head_index(semantic_id).is_none();
        self.fields.push(Some(ModelHeader {
            semantic_id,
            name,
            value,
            head,
        }));
    }

    fn insert(&mut self, semantic_id: usize, name: String, value: String) {
        if let Some(head_idx) = self.head_index(semantic_id) {
            for (idx, field) in self.fields.iter_mut().enumerate() {
                if idx != head_idx
                    && field
                        .as_ref()
                        .is_some_and(|field| field.semantic_id == semantic_id)
                {
                    *field = None;
                }
            }
            self.fields[head_idx] = Some(ModelHeader {
                semantic_id,
                name,
                value,
                head: true,
            });
        } else {
            self.append(semantic_id, name, value);
        }
    }

    fn entry_append(&mut self, semantic_id: usize, name: String, value: String) {
        if let Some(head_idx) = self.head_index(semantic_id) {
            let entry_name = self.fields[head_idx].as_ref().unwrap().name.clone();
            self.append(semantic_id, entry_name, value);
        } else {
            self.append(semantic_id, name, value);
        }
    }

    fn entry_insert_mult(&mut self, semantic_id: usize, name: String, value: String) {
        if let Some(head_idx) = self.head_index(semantic_id) {
            let entry_name = self.fields[head_idx].as_ref().unwrap().name.clone();
            self.insert(semantic_id, entry_name, value);
        } else {
            self.append(semantic_id, name, value);
        }
    }
}

#[cfg(test)]
impl quickcheck::Arbitrary for HeaderMapOps {
    fn arbitrary(g: &mut quickcheck::Gen) -> Self {
        let len = usize::from(u8::arbitrary(g) % 80);
        let ops = (0..len).map(|_| HeaderMapOp::arbitrary(g)).collect();
        Self(ops)
    }

    fn shrink(&self) -> Box<dyn Iterator<Item = Self>> {
        Box::new(self.0.shrink().map(Self))
    }
}

#[cfg(test)]
impl quickcheck::Arbitrary for HeaderMapOp {
    fn arbitrary(g: &mut quickcheck::Gen) -> Self {
        let name = u8::arbitrary(g);
        let value = u8::arbitrary(g);
        match u8::arbitrary(g) % 6 {
            0 => Self::Append { name, value },
            1 => Self::Insert { name, value },
            2 => Self::Remove { name },
            3 => Self::RemoveEntryMult { name },
            4 => Self::EntryAppend { name, value },
            _ => Self::EntryInsertMult { name, value },
        }
    }
}

#[cfg(test)]
fn model_header_name(selector: u8) -> (&'static str, usize) {
    match selector % 8 {
        0 => ("x-a", 0),
        1 => ("X-A", 0),
        2 => ("x-b", 1),
        3 => ("X-B", 1),
        4 => ("cookie", 2),
        5 => ("Cookie", 2),
        6 => ("x-c", 3),
        _ => ("X-C", 3),
    }
}

#[cfg(test)]
fn model_header_value(value: u8) -> String {
    format!("v{value}")
}

#[cfg(test)]
fn make_header_name(name: &str) -> HeaderName {
    HeaderName::from_bytes(name.as_bytes()).unwrap()
}

#[cfg(test)]
fn model_original_name(name: &str) -> String {
    make_header_name(name).to_string()
}

#[cfg(test)]
fn make_header_value(value: &str) -> HeaderValue {
    HeaderValue::from_bytes(value.as_bytes()).unwrap()
}

#[cfg(test)]
fn assert_header_map_matches_model(map: &HeaderMap, model: &HeaderMapModel) {
    assert_header_map_invariants(map);
    assert_eq!(map.len(), model.len());

    let ordered = map
        .ordered_iter()
        .map(|(name, value)| (name.to_string(), value.to_str().unwrap().to_owned()))
        .collect::<Vec<_>>();
    assert_eq!(ordered, model.ordered());

    let consumed = map
        .clone()
        .into_ordered_iter()
        .map(|(name, value)| (name.to_string(), value.to_str().unwrap().to_owned()))
        .collect::<Vec<_>>();
    assert_eq!(consumed, ordered);

    for (selector, semantic_id) in [
        ("x-a", 0),
        ("X-A", 0),
        ("x-b", 1),
        ("X-B", 1),
        ("cookie", 2),
        ("Cookie", 2),
        ("x-c", 3),
        ("X-C", 3),
    ] {
        let actual = map
            .get_all(make_header_name(selector))
            .iter()
            .map(|value| value.to_str().unwrap().to_owned())
            .collect::<Vec<_>>();
        assert_eq!(actual, model.values_for(semantic_id));
    }
}

#[cfg(test)]
impl HeaderMapOps {
    fn run(self, randomized: bool) {
        let mut map = HeaderMap::new();
        if randomized {
            map.danger.set_yellow();
            map.danger.set_red();
        }
        let mut model = HeaderMapModel::default();

        assert_header_map_matches_model(&map, &model);

        for op in self.0 {
            match op {
                HeaderMapOp::Append { name, value } => {
                    let (name, semantic_id) = model_header_name(name);
                    let value = model_header_value(value);
                    map.append(make_header_name(name), make_header_value(&value));
                    model.append(semantic_id, model_original_name(name), value);
                }
                HeaderMapOp::Insert { name, value } => {
                    let (name, semantic_id) = model_header_name(name);
                    let value = model_header_value(value);
                    map.insert(make_header_name(name), make_header_value(&value));
                    model.insert(semantic_id, model_original_name(name), value);
                }
                HeaderMapOp::Remove { name } => {
                    let (name, semantic_id) = model_header_name(name);
                    map.remove(make_header_name(name));
                    model.remove(semantic_id);
                }
                HeaderMapOp::RemoveEntryMult { name } => {
                    let (name, semantic_id) = model_header_name(name);
                    if let Entry::Occupied(entry) = map.entry(make_header_name(name)) {
                        let _ = entry.remove_entry_mult();
                    }
                    model.remove(semantic_id);
                }
                HeaderMapOp::EntryAppend { name, value } => {
                    let (name, semantic_id) = model_header_name(name);
                    let value = model_header_value(value);
                    match map.entry(make_header_name(name)) {
                        Entry::Occupied(mut entry) => {
                            entry.append(make_header_value(&value));
                        }
                        Entry::Vacant(entry) => {
                            entry.insert_entry(make_header_value(&value));
                        }
                    }
                    model.entry_append(semantic_id, model_original_name(name), value);
                }
                HeaderMapOp::EntryInsertMult { name, value } => {
                    let (name, semantic_id) = model_header_name(name);
                    let value = model_header_value(value);
                    match map.entry(make_header_name(name)) {
                        Entry::Occupied(mut entry) => {
                            let _ = entry.insert_mult(make_header_value(&value));
                        }
                        Entry::Vacant(entry) => {
                            entry.insert_entry(make_header_value(&value));
                        }
                    }
                    model.entry_insert_mult(semantic_id, model_original_name(name), value);
                }
            }

            assert_header_map_matches_model(&map, &model);
        }
    }
}

#[test]
fn quickcheck_header_map_order_and_multivalue_model() {
    fn prop(ops: HeaderMapOps) -> bool {
        ops.clone().run(false);
        ops.run(true);
        true
    }

    quickcheck::QuickCheck::new()
        .tests(500)
        .quickcheck(prop as fn(HeaderMapOps) -> bool);
}

#[test]
fn ensure_miri_itermut_not_violated() {
    let mut headers = HeaderMap::<u32>::default();
    headers.insert(HeaderName::from_static("hello"), 1u32);
    headers.insert(HeaderName::from_static("zomg"), 2u32);

    let mut iter = headers.iter_mut();
    let (_, first) = iter.next().unwrap();
    let (_, second) = iter.next().unwrap();

    *first += 10;
    *second += 20;
}

#[test]
fn ensure_miri_valueitermut_not_violated() {
    let mut headers = HeaderMap::<u32>::default();
    headers.insert(HeaderName::from_static("hello"), 1u32);
    headers.append(HeaderName::from_static("hello"), 2u32);
    headers.append(HeaderName::from_static("hello"), 3u32);

    let mut entry = match headers.entry(HeaderName::from_static("hello")) {
        Entry::Occupied(entry) => entry,
        Entry::Vacant(_) => panic!(),
    };

    let mut iter = entry.iter_mut();
    let first = iter.next().unwrap();
    let second = iter.next().unwrap();

    *first += 10;
    *second += 20;
}

struct ManuallyAllocated {
    ptr: *mut u8,
    panic_on_drop: bool,
}

impl ManuallyAllocated {
    fn new(byte: u8, panic_on_drop: bool) -> Self {
        Self {
            ptr: Box::into_raw(Box::new(byte)),
            panic_on_drop,
        }
    }
}

impl Drop for ManuallyAllocated {
    fn drop(&mut self) {
        // SAFETY: `Box::from_raw` needs a pointer from `Box::into_raw` that is
        // not freed yet: `ptr` comes from `Box::into_raw` in `new`, and `drop`
        // runs at most once per value, so this is its only release.
        unsafe {
            drop(Box::from_raw(self.ptr));
        }

        if self.panic_on_drop {
            panic!("intentional drop panic");
        }
    }
}

#[test]
fn into_iter_drop_panic_after_yielding_extra_value_double_drops() {
    use std::panic::{AssertUnwindSafe, catch_unwind};

    let mut map: HeaderMap<ManuallyAllocated> = HeaderMap::default();
    map.append("x-first", ManuallyAllocated::new(1, false));
    map.append("x-first", ManuallyAllocated::new(2, false));
    map.insert("x-second", ManuallyAllocated::new(3, true));

    let mut iter = map.into_iter();

    // HeaderMap::IntoIter yields extra values with ptr::read from
    // self.extra_values and relies on Drop setting self.extra_values.len() to
    // zero after the iterator has been fully consumed. If a later value's Drop
    // panics while IntoIter::drop is draining the iterator, that set_len(0) is
    // skipped. The Vec then drops already-yielded extra value slots again.
    drop(iter.next().unwrap());
    drop(iter.next().unwrap());

    let _ = catch_unwind(AssertUnwindSafe(|| drop(iter)));
}

#[test]
fn into_ordered_iter_drop_panic_after_yielding_values_does_not_double_drop() {
    use std::panic::{AssertUnwindSafe, catch_unwind};

    let mut map: HeaderMap<ManuallyAllocated> = HeaderMap::default();
    map.append("x-first", ManuallyAllocated::new(1, false));
    map.append("x-first", ManuallyAllocated::new(2, false));
    map.insert("x-second", ManuallyAllocated::new(3, true));

    let mut iter = map.into_ordered_iter();

    drop(iter.next().unwrap());
    drop(iter.next().unwrap());

    let _ = catch_unwind(AssertUnwindSafe(|| drop(iter)));
}

#[test]
fn into_iter_debug_after_partial_consumption_skips_moved_values() {
    let mut map: HeaderMap<String> = HeaderMap::default();
    map.append("x-first", "value-a".to_owned());
    map.append("x-first", "value-b".to_owned());
    map.append("x-second", "value-c".to_owned());

    let mut iter = map.into_iter();
    drop(iter.next().unwrap());
    drop(iter.next().unwrap());

    // Formatting must not read the two values already moved out and dropped.
    let debug = format!("{iter:?}");
    assert!(!debug.contains("value-a") && !debug.contains("value-b"));
    assert!(debug.contains("value-c"));
}

#[test]
fn into_ordered_iter_debug_after_partial_consumption_skips_moved_values() {
    let mut map: HeaderMap<String> = HeaderMap::default();
    map.append("x-first", "value-a".to_owned());
    map.append("x-first", "value-b".to_owned());

    let mut iter = map.into_ordered_iter();
    drop(iter.next().unwrap());

    // Formatting must not read the value already moved out and dropped.
    let debug = format!("{iter:?}");
    assert!(!debug.contains("value-a"));
}

#[test]
fn clear_with_panicking_drop_keeps_ordered_iteration_sound() {
    use std::panic::{AssertUnwindSafe, catch_unwind};

    let mut map: HeaderMap<ManuallyAllocated> = HeaderMap::default();
    map.insert("x-panic", ManuallyAllocated::new(1, true));

    let _ = catch_unwind(AssertUnwindSafe(|| map.clear()));

    // A stale order slot would name the new entry a second time, and the
    // ordered iterator would then move its value out twice.
    map.insert("x-next", ManuallyAllocated::new(2, false));
    let values: Vec<_> = map.into_ordered_iter().collect();
    assert_eq!(values.len(), 1);
}

#[test]
fn drain_drop_panic_leaves_map_empty_and_valid() {
    use std::panic::{AssertUnwindSafe, catch_unwind};

    let mut map: HeaderMap<ManuallyAllocated> = HeaderMap::default();
    map.insert("x-panic", ManuallyAllocated::new(1, true));
    map.append("x-rest", ManuallyAllocated::new(2, false));
    map.append("x-rest", ManuallyAllocated::new(3, false));

    let drain = map.drain();
    let _ = catch_unwind(AssertUnwindSafe(|| drop(drain)));

    assert_header_map_invariants(&map);
}

#[test]
fn skip_duplicates_during_key_iteration() {
    let mut map = HeaderMap::new();
    map.try_append("a", HeaderValue::from_static("a")).unwrap();
    map.try_append("a", HeaderValue::from_static("b")).unwrap();
    assert_eq!(map.keys().count(), map.keys_len());
}

#[test]
fn ordered_iter_size_hint_counts_remaining_live_order_slots() {
    let mut map = HeaderMap::new();
    map.try_insert("a", HeaderValue::from_static("a")).unwrap();
    map.try_insert("b", HeaderValue::from_static("b")).unwrap();
    map.try_insert("c", HeaderValue::from_static("c")).unwrap();
    map.remove("b");

    let mut iter = map.ordered_iter();
    assert_eq!((2, Some(2)), iter.size_hint());
    assert_eq!("a", iter.next().unwrap().0);
    assert_eq!((1, Some(1)), iter.size_hint());
    assert_eq!("c", iter.next().unwrap().0);
    assert_eq!((0, Some(0)), iter.size_hint());
    assert!(iter.next().is_none());
}

#[test]
fn drain_size_hint_counts_remaining_entries_and_extras() {
    let mut map = HeaderMap::new();
    map.append("x-first", HeaderValue::from_static("one"));
    map.append("x-first", HeaderValue::from_static("two"));
    map.insert("x-second", HeaderValue::from_static("three"));

    let mut drain = map.drain();
    assert_eq!(drain.size_hint(), (2, Some(3)));

    assert_eq!(
        drain.next().map(|(name, value)| (
            name.map(|name| name.to_string()),
            value.to_str().unwrap().to_owned()
        )),
        Some((Some("x-first".to_owned()), "one".to_owned()))
    );
    assert_eq!(drain.size_hint(), (1, Some(2)));

    assert_eq!(
        drain.next().map(|(name, value)| (
            name.map(|name| name.to_string()),
            value.to_str().unwrap().to_owned()
        )),
        Some((None, "two".to_owned()))
    );
    assert_eq!(drain.size_hint(), (1, Some(1)));

    assert_eq!(
        drain.next().map(|(name, value)| (
            name.map(|name| name.to_string()),
            value.to_str().unwrap().to_owned()
        )),
        Some((Some("x-second".to_owned()), "three".to_owned()))
    );
    assert_eq!(drain.size_hint(), (0, Some(0)));
    assert!(drain.next().is_none());
}

#[test]
fn into_iter_size_hint_counts_remaining_entries_only() {
    let mut map = HeaderMap::new();
    map.append("x-first", HeaderValue::from_static("one"));
    map.append("x-first", HeaderValue::from_static("two"));
    map.insert("x-second", HeaderValue::from_static("three"));

    let mut iter = map.into_iter();
    assert_eq!(iter.size_hint(), (2, None));

    assert_eq!(
        iter.next().map(|(name, value)| (
            name.map(|name| name.to_string()),
            value.to_str().unwrap().to_owned()
        )),
        Some((Some("x-first".to_owned()), "one".to_owned()))
    );
    assert_eq!(iter.size_hint(), (1, None));

    assert_eq!(
        iter.next().map(|(name, value)| (
            name.map(|name| name.to_string()),
            value.to_str().unwrap().to_owned()
        )),
        Some((None, "two".to_owned()))
    );
    assert_eq!(iter.size_hint(), (1, None));

    assert_eq!(
        iter.next().map(|(name, value)| (
            name.map(|name| name.to_string()),
            value.to_str().unwrap().to_owned()
        )),
        Some((Some("x-second".to_owned()), "three".to_owned()))
    );
    assert_eq!(iter.size_hint(), (0, None));
    assert!(iter.next().is_none());
}

#[test]
fn into_ordered_iter_size_hint_upper_bound_counts_backing_values() {
    let mut map = HeaderMap::new();
    map.append("x-first", HeaderValue::from_static("one"));
    map.append("x-first", HeaderValue::from_static("two"));
    map.insert("x-second", HeaderValue::from_static("three"));

    let mut iter = map.into_ordered_iter();
    assert_eq!(iter.size_hint(), (0, Some(3)));

    assert_eq!(
        iter.next()
            .map(|(name, value)| (name.to_string(), value.to_str().unwrap().to_owned())),
        Some(("x-first".to_owned(), "one".to_owned()))
    );
    assert_eq!(iter.size_hint(), (0, Some(3)));

    assert_eq!(
        iter.next()
            .map(|(name, value)| (name.to_string(), value.to_str().unwrap().to_owned())),
        Some(("x-first".to_owned(), "two".to_owned()))
    );
    assert_eq!(iter.size_hint(), (0, Some(3)));

    assert_eq!(
        iter.next()
            .map(|(name, value)| (name.to_string(), value.to_str().unwrap().to_owned())),
        Some(("x-second".to_owned(), "three".to_owned()))
    );
    assert_eq!(iter.size_hint(), (0, Some(3)));
    assert!(iter.next().is_none());
}

#[test]
fn value_drain_size_hint_counts_remaining_values() {
    let mut map = HeaderMap::new();
    map.append("x-first", HeaderValue::from_static("one"));
    map.append("x-first", HeaderValue::from_static("two"));
    map.append("x-first", HeaderValue::from_static("three"));

    let Entry::Occupied(mut entry) = map.entry("x-first") else {
        panic!("expected x-first header");
    };
    let mut drain = entry.insert_mult(HeaderValue::from_static("replacement"));

    assert_eq!(drain.size_hint(), (3, Some(3)));
    assert_eq!(
        drain.next().map(|value| value.to_str().unwrap().to_owned()),
        Some("one".to_owned())
    );
    assert_eq!(drain.size_hint(), (2, Some(2)));
    assert_eq!(
        drain.next().map(|value| value.to_str().unwrap().to_owned()),
        Some("two".to_owned())
    );
    assert_eq!(drain.size_hint(), (1, Some(1)));
    assert_eq!(
        drain.next().map(|value| value.to_str().unwrap().to_owned()),
        Some("three".to_owned())
    );
    assert_eq!(drain.size_hint(), (0, Some(0)));
    assert!(drain.next().is_none());
}

#[test]
fn dropping_value_drain_drops_remaining_values() {
    use std::{cell::Cell, rc::Rc};

    struct DropCounter(Rc<Cell<usize>>);

    impl Drop for DropCounter {
        fn drop(&mut self) {
            self.0.set(self.0.get() + 1);
        }
    }

    let drops = Rc::new(Cell::new(0));
    let mut map: HeaderMap<DropCounter> = HeaderMap::default();
    map.append("x-first", DropCounter(drops.clone()));
    map.append("x-first", DropCounter(drops.clone()));
    map.append("x-first", DropCounter(drops.clone()));

    let Entry::Occupied(mut entry) = map.entry("x-first") else {
        panic!("expected x-first header");
    };
    let mut drain = entry.insert_mult(DropCounter(drops.clone()));
    drop(drain.next());
    assert_eq!(drops.get(), 1);

    drop(drain);
    assert_eq!(drops.get(), 3);
}

#[test]
fn basic_map_api_contracts_cover_capacity_lookup_and_clear() {
    let empty = HeaderMap::<HeaderValue>::try_with_capacity(0).unwrap();
    assert!(empty.is_empty());
    assert_eq!(empty.capacity(), 0);

    let mut map = HeaderMap::<HeaderValue>::with_capacity(10);
    assert!(map.is_empty());
    assert_eq!(map.len(), 0);
    assert_eq!(map.keys_len(), 0);
    assert_eq!(map.capacity(), 12);
    assert_eq!(map.mask() as usize, 15);

    let mut reserved = HeaderMap::<HeaderValue>::new();
    reserved.reserve(10);
    assert_eq!(reserved.capacity(), 12);
    assert_eq!(reserved.mask() as usize, 15);

    let mut try_reserved = HeaderMap::<HeaderValue>::new();
    try_reserved.try_reserve(10).unwrap();
    assert_eq!(try_reserved.capacity(), 12);
    assert_eq!(try_reserved.mask() as usize, 15);

    let max_capacity =
        HeaderMap::<HeaderValue>::try_with_capacity(usable_capacity(MAX_SIZE)).unwrap();
    assert_eq!(max_capacity.capacity(), usable_capacity(MAX_SIZE));
    assert_eq!(max_capacity.mask() as usize, MAX_SIZE - 1);
    let max_size_err =
        HeaderMap::<HeaderValue>::try_with_capacity(usable_capacity(MAX_SIZE) + 1).unwrap_err();
    assert_eq!(max_size_err.to_string(), "max size reached");
    assert_eq!(format!("{max_size_err:?}"), "MaxSizeReached");
    let mut too_large_reserve = HeaderMap::<HeaderValue>::new();
    assert!(
        too_large_reserve
            .try_reserve(usable_capacity(MAX_SIZE) + 1)
            .is_err()
    );

    let key = HeaderName::from_static("x-basic");
    let key_string = "x-basic".to_owned();
    assert!(!map.contains_key(&key));
    assert!(!map.contains_key(&key_string));
    assert!(map.get(&key).is_none());
    assert!(map.get("x-basic").is_none());
    assert!(map.get(key_string.clone()).is_none());
    assert!(map.get(&key_string).is_none());

    assert!(
        map.insert(key.clone(), HeaderValue::from_static("one"))
            .is_none()
    );
    assert!(!map.is_empty());
    assert_eq!(map.len(), 1);
    assert_eq!(map.keys_len(), 1);
    assert!(map.contains_key(&key));
    assert!(map.contains_key("x-basic"));
    assert!(map.contains_key(key_string.clone()));
    assert!(map.contains_key(&key_string));
    assert_eq!(map.get(&key).unwrap(), "one");
    assert_eq!(map.get(key.clone()).unwrap(), "one");
    assert_eq!(map.get("x-basic").unwrap(), "one");
    assert_eq!(map.get(key_string.clone()).unwrap(), "one");
    assert_eq!(map.get(&key_string).unwrap(), "one");
    assert_eq!(map.get("missing"), None);

    *map.get_mut("x-basic").unwrap() = HeaderValue::from_static("mutated");
    assert_eq!(map.get("x-basic").unwrap(), "mutated");

    assert!(map.append("x-basic", HeaderValue::from_static("two")));
    assert_eq!(map.len(), 2);
    assert_eq!(map.keys_len(), 1);

    let borrowed = HeaderName::from_static("x-borrowed");
    assert!(
        map.insert(&borrowed, HeaderValue::from_static("borrowed"))
            .is_none()
    );
    assert!(map.append(&borrowed, HeaderValue::from_static("borrowed-again")));
    assert_eq!(
        map.get_all(&borrowed)
            .iter()
            .map(|value| value.to_str().unwrap().to_owned())
            .collect::<Vec<_>>(),
        ["borrowed".to_owned(), "borrowed-again".to_owned()]
    );

    map.clear();
    assert!(map.is_empty());
    assert_eq!(map.len(), 0);
    assert_eq!(map.keys_len(), 0);
    assert!(map.capacity() >= 12);
    assert!(!map.contains_key("x-basic"));
}

#[test]
fn extend_try_from_equality_debug_and_serde_contracts() {
    use std::{collections::HashMap, convert::TryFrom};

    let mut raw = HashMap::new();
    raw.insert("x-one".to_owned(), "one".to_owned());
    raw.insert("x-two".to_owned(), "two".to_owned());

    let from_hash = HeaderMap::<HeaderValue>::try_from(&raw).unwrap();
    assert_eq!(from_hash.len(), 2);
    assert_eq!(from_hash.get("x-one").unwrap(), "one");
    assert_eq!(from_hash.get("x-two").unwrap(), "two");

    let mut by_name = HeaderMap::new();
    by_name.extend([
        (
            HeaderName::from_static("x-a"),
            HeaderValue::from_static("a1"),
        ),
        (
            HeaderName::from_static("x-a"),
            HeaderValue::from_static("a2"),
        ),
        (
            HeaderName::from_static("x-b"),
            HeaderValue::from_static("b1"),
        ),
    ]);
    assert_eq!(
        by_name
            .get_all("x-a")
            .iter()
            .map(|value| value.to_str().unwrap().to_owned())
            .collect::<Vec<_>>(),
        ["a1".to_owned(), "a2".to_owned()]
    );

    let mut by_optional_name = HeaderMap::new();
    by_optional_name.extend([
        (
            Some(HeaderName::from_static("x-c")),
            HeaderValue::from_static("c1"),
        ),
        (None, HeaderValue::from_static("c2")),
        (
            Some(HeaderName::from_static("x-d")),
            HeaderValue::from_static("d1"),
        ),
    ]);
    assert_eq!(
        by_optional_name
            .get_all("x-c")
            .iter()
            .map(|value| value.to_str().unwrap().to_owned())
            .collect::<Vec<_>>(),
        ["c1".to_owned(), "c2".to_owned()]
    );

    let same = by_optional_name.clone();
    assert_eq!(by_optional_name, same);
    let mut different = same.clone();
    different.append("x-c", HeaderValue::from_static("c3"));
    assert_ne!(by_optional_name, different);

    let debug = format!("{by_optional_name:?}");
    assert!(debug.contains("x-c"));
    assert!(debug.contains("c1"));

    let json = serde_json::to_string(&by_optional_name).unwrap();
    let roundtrip: HeaderMap = serde_json::from_str(&json).unwrap();
    assert_eq!(
        roundtrip
            .ordered_iter()
            .map(|(name, value)| (name.to_string(), value.to_str().unwrap().to_owned()))
            .collect::<Vec<_>>(),
        by_optional_name
            .ordered_iter()
            .map(|(name, value)| (name.to_string(), value.to_str().unwrap().to_owned()))
            .collect::<Vec<_>>()
    );
}

#[test]
fn unordered_iterators_and_key_value_views_have_stable_contracts() {
    let mut map = HeaderMap::new();
    map.append("x-first", HeaderValue::from_static("one"));
    map.append("x-first", HeaderValue::from_static("two"));
    map.insert("x-second", HeaderValue::from_static("three"));

    let iter = map.iter();
    assert_eq!(iter.size_hint(), (2, None));
    let mut iter = iter;
    let first = iter
        .next()
        .map(|(name, value)| (name.to_string(), value.to_str().unwrap().to_owned()))
        .unwrap();
    assert_eq!(iter.size_hint(), (2, None));
    let mut pairs = iter
        .map(|(name, value)| (name.to_string(), value.to_str().unwrap().to_owned()))
        .collect::<Vec<_>>();
    pairs.push(first);
    pairs.sort();
    assert_eq!(
        pairs,
        [
            ("x-first".to_owned(), "one".to_owned()),
            ("x-first".to_owned(), "two".to_owned()),
            ("x-second".to_owned(), "three".to_owned()),
        ]
    );

    assert_eq!(map.keys().size_hint(), (2, Some(2)));
    let mut keys = map.keys().map(|name| name.to_string()).collect::<Vec<_>>();
    keys.sort();
    assert_eq!(keys, ["x-first".to_owned(), "x-second".to_owned()]);
    assert_eq!(map.keys().count(), 2);
    assert!(map.keys().nth(1).is_some());
    assert!(map.keys().last().is_some());

    assert_eq!(map.values().size_hint(), (2, None));
    let mut values = map
        .values()
        .map(|value| value.to_str().unwrap().to_owned())
        .collect::<Vec<_>>();
    values.sort();
    assert_eq!(
        values,
        ["one".to_owned(), "three".to_owned(), "two".to_owned()]
    );

    let mut mutable: HeaderMap<String> = HeaderMap::default();
    mutable.append("x-first", "one".to_owned());
    mutable.append("x-first", "two".to_owned());
    mutable.insert("x-second", "three".to_owned());

    let mut iter_mut = mutable.iter_mut();
    assert_eq!(iter_mut.size_hint(), (2, None));
    iter_mut.next().unwrap().1.push('!');
    assert_eq!(iter_mut.size_hint(), (2, None));
    for (_, value) in iter_mut {
        value.push('!');
    }
    assert_eq!(mutable.values_mut().size_hint(), (2, None));
    for value in mutable.values_mut() {
        value.push('?');
    }

    let mut values = mutable.values().cloned().collect::<Vec<_>>();
    values.sort();
    assert_eq!(
        values,
        ["one!?".to_owned(), "three!?".to_owned(), "two!?".to_owned()]
    );
}

#[test]
fn per_key_value_iterators_support_forward_and_reverse_traversal() {
    let mut map = HeaderMap::new();
    map.append("x-multi", HeaderValue::from_static("one"));
    map.append("x-multi", HeaderValue::from_static("two"));
    map.append("x-multi", HeaderValue::from_static("three"));
    map.insert("x-other", HeaderValue::from_static("solo"));

    assert_eq!(
        map.get_all("x-multi"),
        map.get_all(&HeaderName::from_static("x-multi"))
    );
    assert_ne!(map.get_all("x-multi"), map.get_all("x-other"));

    let all = map.get_all("x-multi");
    let mut iter = all.iter();
    assert_eq!(iter.size_hint(), (1, None));
    assert_eq!(iter.next().unwrap(), "one");
    assert_eq!(iter.size_hint(), (1, None));
    assert_eq!(iter.next_back().unwrap(), "three");
    assert_eq!(iter.size_hint(), (1, None));
    assert_eq!(iter.next().unwrap(), "two");
    assert_eq!(iter.size_hint(), (0, Some(0)));
    assert!(iter.next().is_none());
    assert!(iter.next_back().is_none());

    let mut mutable: HeaderMap<String> = HeaderMap::default();
    mutable.append("x-multi", "one".to_owned());
    mutable.append("x-multi", "two".to_owned());
    mutable.append("x-multi", "three".to_owned());

    let Entry::Occupied(mut entry) = mutable.entry("x-multi") else {
        panic!("expected x-multi header");
    };
    let mut iter = entry.iter_mut();
    assert_eq!(iter.size_hint(), (0, None));
    iter.next().unwrap().push('1');
    assert_eq!(iter.size_hint(), (0, None));
    iter.next_back().unwrap().push('3');
    assert_eq!(iter.size_hint(), (0, None));
    iter.next().unwrap().push('2');
    assert_eq!(iter.size_hint(), (0, None));
    assert!(iter.next().is_none());
    assert!(iter.next_back().is_none());

    assert_eq!(
        mutable
            .get_all("x-multi")
            .iter()
            .cloned()
            .collect::<Vec<_>>(),
        ["one1".to_owned(), "two2".to_owned(), "three3".to_owned()]
    );
}

#[test]
fn growth_remove_and_lookup_stress_preserves_entries_and_order() {
    let mut map: HeaderMap<String> = HeaderMap::with_capacity(1);

    for i in 0..96 {
        let name = HeaderName::from_bytes(format!("x-grow-{i}").as_bytes()).unwrap();
        map.insert(name, format!("v{i}"));
    }

    assert_eq!(map.len(), 96);
    assert_eq!(map.keys_len(), 96);
    assert!(map.capacity() >= 96);
    assert_header_map_invariants(&map);

    for i in (0..96).step_by(3) {
        let name = HeaderName::from_bytes(format!("x-grow-{i}").as_bytes()).unwrap();
        assert_eq!(map.remove(name), Some(format!("v{i}")));
    }

    assert_eq!(map.len(), 64);
    assert_eq!(map.keys_len(), 64);
    assert_header_map_invariants(&map);

    for i in 0..96 {
        let name = format!("x-grow-{i}");
        if i % 3 == 0 {
            assert!(!map.contains_key(name.as_str()));
            assert!(map.get(name.as_str()).is_none());
        } else {
            assert_eq!(map.get(name.as_str()).unwrap(), &format!("v{i}"));
        }
    }

    for i in (0..96).step_by(3) {
        let name = HeaderName::from_bytes(format!("x-grow-{i}").as_bytes()).unwrap();
        map.insert(name, format!("reinserted-{i}"));
    }

    assert_eq!(map.len(), 96);
    assert_header_map_invariants(&map);
    assert_eq!(map.get("x-grow-0").unwrap(), "reinserted-0");
    assert_eq!(map.get("x-grow-95").unwrap(), "v95");
}

#[test]
fn header_map_invariants_survive_ordered_multi_value_mutations() {
    let mut map = HeaderMap::new();
    assert_header_map_invariants(&map);

    map.append("x-first", HeaderValue::from_static("one"));
    map.append("x-first", HeaderValue::from_static("two"));
    map.append("x-second", HeaderValue::from_static("alpha"));
    map.append("x-second", HeaderValue::from_static("beta"));
    map.insert("x-third", HeaderValue::from_static("single"));
    assert_header_map_invariants(&map);

    assert_eq!(map.remove("x-first").unwrap(), "one");
    assert_header_map_invariants(&map);

    map.append("x-second", HeaderValue::from_static("gamma"));
    assert_header_map_invariants(&map);

    assert_eq!(
        map.insert("x-second", HeaderValue::from_static("replaced"))
            .unwrap(),
        "alpha"
    );
    assert_header_map_invariants(&map);

    map.append("x-second", HeaderValue::from_static("delta"));
    map.append("x-fourth", HeaderValue::from_static("uno"));
    map.append("x-fourth", HeaderValue::from_static("dos"));
    assert_header_map_invariants(&map);

    let Entry::Occupied(fourth) = map.entry("x-fourth") else {
        panic!("expected x-fourth header");
    };
    let (name, values) = fourth.remove_entry_mult();
    assert_eq!(name, "x-fourth");
    assert_eq!(
        values
            .map(|value| value.to_str().unwrap().to_owned())
            .collect::<Vec<_>>(),
        ["uno".to_owned(), "dos".to_owned()]
    );
    assert_header_map_invariants(&map);

    map.append("x-fifth", HeaderValue::from_static("eins"));
    map.append("x-fifth", HeaderValue::from_static("zwei"));
    let Entry::Occupied(mut fifth) = map.entry("x-fifth") else {
        panic!("expected x-fifth header");
    };
    assert_eq!(
        fifth
            .insert_mult(HeaderValue::from_static("new"))
            .map(|value| value.to_str().unwrap().to_owned())
            .collect::<Vec<_>>(),
        ["eins".to_owned(), "zwei".to_owned()]
    );
    assert_header_map_invariants(&map);

    let drained = map.drain().collect::<Vec<_>>();
    assert!(!drained.is_empty());
    assert_header_map_invariants(&map);
}

#[test]
fn remove_entry_mult_then_into_ordered_iter_skips_removed_extras() {
    let mut map = HeaderMap::new();
    map.append("cookie", HeaderValue::from_static("a=1"));
    map.append("cookie", HeaderValue::from_static("b=2"));
    map.append("cookie", HeaderValue::from_static("c=3"));

    let Entry::Occupied(cookie_headers) = map.entry("cookie") else {
        panic!("expected cookie header");
    };
    let (name, values) = cookie_headers.remove_entry_mult();
    let merged = values
        .map(|value| value.to_str().unwrap().to_owned())
        .collect::<Vec<_>>()
        .join("; ");

    map.insert(name, HeaderValue::from_str(&merged).unwrap());

    let ordered = map
        .into_ordered_iter()
        .map(|(name, value)| (name.as_str().to_owned(), value.to_str().unwrap().to_owned()))
        .collect::<Vec<_>>();

    assert_eq!(ordered, [("cookie".to_owned(), "a=1; b=2; c=3".to_owned())]);
}

#[test]
fn insert_mult_then_ordered_iter_updates_moved_extra_order_links() {
    let mut map = HeaderMap::new();
    map.append("x-first", HeaderValue::from_static("one"));
    map.append("x-first", HeaderValue::from_static("two"));
    map.append("x-second", HeaderValue::from_static("alpha"));
    map.append("x-second", HeaderValue::from_static("beta"));

    let Entry::Occupied(mut entry) = map.entry("x-first") else {
        panic!("expected x-first header");
    };
    let old = entry
        .insert_mult(HeaderValue::from_static("replaced"))
        .map(|value| value.to_str().unwrap().to_owned())
        .collect::<Vec<_>>();

    assert_eq!(old, ["one".to_owned(), "two".to_owned()]);

    let ordered = map
        .ordered_iter()
        .map(|(name, value)| (name.as_str().to_owned(), value.to_str().unwrap().to_owned()))
        .collect::<Vec<_>>();

    assert_eq!(
        ordered,
        [
            ("x-first".to_owned(), "replaced".to_owned()),
            ("x-second".to_owned(), "alpha".to_owned()),
            ("x-second".to_owned(), "beta".to_owned()),
        ]
    );
}

#[test]
fn order_capacity_grows_with_entry_capacity() {
    let mut map = HeaderMap::<HeaderValue>::new();
    map.try_insert("a", HeaderValue::from_static("a")).unwrap();

    assert!(
        map.order.capacity() >= map.entries.capacity(),
        "order capacity {} should track entries capacity {}",
        map.order.capacity(),
        map.entries.capacity()
    );

    let initial_order_cap = map.order.capacity();
    let initial_entry_cap = map.entries.capacity();

    for i in 0..initial_entry_cap {
        let name = format!("x-rama-{i}");
        let name = HeaderName::from_bytes(name.as_bytes()).unwrap();
        map.try_insert(name, HeaderValue::from_static("x")).unwrap();
    }

    assert!(
        map.order.capacity() >= map.entries.capacity(),
        "order capacity {} should track grown entries capacity {}",
        map.order.capacity(),
        map.entries.capacity()
    );
    assert!(map.order.capacity() >= initial_order_cap);
}

#[cfg(target_pointer_width = "64")]
#[test]
fn compact_map_layout() {
    assert_eq!(std::mem::size_of::<HeaderMap>(), 104);
    assert_eq!(std::mem::size_of::<crate::request::Parts>(), 160);
}

#[test]
fn order_holes_and_repeated_values_are_not_limited_by_table_capacity() {
    let mut map = HeaderMap::new();
    for _ in 0..70_000 {
        map.insert("x-churn", HeaderValue::from_static("value"));
        map.remove("x-churn");
    }
    for _ in 0..70_000 {
        map.append("set-cookie", HeaderValue::from_static("a=b"));
    }
    assert_header_map_invariants(&map);
    assert_eq!(map.get_all("set-cookie").iter().count(), 70_000);
    map.remove("set-cookie");
    assert_header_map_invariants(&map);
    assert!(map.is_empty());
}

#[test]
fn boxed_flood_hasher_survives_clone_growth_and_clear() {
    let mut map = HeaderMap::new();
    for i in 0..512 {
        let name = HeaderName::from_bytes(format!("x-field-{i}").as_bytes()).unwrap();
        map.append(name, HeaderValue::from_static("value"));
        map.append("set-cookie", HeaderValue::from_static("a=b"));
    }
    map.danger.set_yellow();
    map.danger.set_red();
    for index in &mut *map.indices {
        *index = Pos::none();
    }
    map.rebuild();
    assert_header_map_invariants(&map);
    let mut cloned = map.clone();
    cloned.reserve(2048);
    assert_header_map_invariants(&cloned);
    for i in 0..512 {
        let name = format!("x-field-{i}");
        assert_eq!(cloned.get(name.as_str()).unwrap(), "value");
        cloned.remove(name.as_str());
    }
    assert_eq!(cloned.get_all("set-cookie").iter().count(), 512);
    assert_header_map_invariants(&cloned);
    cloned.clear();
    cloned.insert("x-reused", HeaderValue::from_static("ok"));
    assert_header_map_invariants(&cloned);
    assert!(!cloned.danger.is_red());
    assert_eq!(map.keys_len(), 513);
}

#[test]
fn collision_flood_switches_to_boxed_randomized_hasher() {
    let names: Vec<_> = (0..)
        .map(|i| HeaderName::from_bytes(format!("x-collision-{i}").as_bytes()).unwrap())
        .filter(|name| hash_elem_using(&Danger::Green, name).0 & 32767 == 0)
        .take(600)
        .collect();
    for operation in 0..3 {
        let mut map = HeaderMap::new();
        for name in &names {
            let value = HeaderValue::from_static("value");
            match operation {
                0 => {
                    map.insert(name, value);
                }
                1 => {
                    map.append(name, value);
                }
                _ => {
                    map.entry(name).or_insert(value);
                }
            }
        }
        assert!(map.danger.is_red(), "operation {operation}");
        assert_header_map_invariants(&map);
        for name in &names {
            assert_eq!(map.get(name).unwrap(), "value");
        }
    }
}

#[test]
fn collision_mitigation_at_max_capacity_rehashes_without_growing() {
    let mut map = HeaderMap::with_capacity(usable_capacity(MAX_SIZE));
    for i in 0..7_000 {
        map.insert(
            HeaderName::from_bytes(format!("x-capacity-{i}").as_bytes()).unwrap(),
            HeaderValue::from_static("value"),
        );
    }
    map.danger.set_yellow();
    map.try_append("x-new", HeaderValue::from_static("ok"))
        .unwrap();
    assert!(map.danger.is_red());
    assert_eq!(map.get("x-new").unwrap(), "ok");
    assert_header_map_invariants(&map);
}

#[test]
fn collision_mitigation_at_max_size_still_refuses_beyond_capacity() {
    let capacity = usable_capacity(MAX_SIZE);
    let mut map = HeaderMap::with_capacity(capacity);
    for i in 0..capacity {
        map.insert(
            HeaderName::from_bytes(format!("x-full-{i}").as_bytes()).unwrap(),
            HeaderValue::from_static("value"),
        );
    }
    assert_eq!(map.keys_len(), capacity);
    map.danger.set_yellow();
    assert!(
        map.try_insert("x-one-too-many", HeaderValue::from_static("no"))
            .is_err()
    );
    assert!(
        map.try_append("x-full-0", HeaderValue::from_static("no"))
            .is_err()
    );
    assert_header_map_invariants(&map);
}
