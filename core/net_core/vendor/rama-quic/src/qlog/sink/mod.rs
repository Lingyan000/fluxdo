use std::sync::Arc;

use super::{EventSchema, NamedQlogEventView, QlogEventView};

/// A cheap borrowed-event selection rule. Stateful filters advance `generation` whenever
/// selection changes, so the connection can provide a fresh recovery snapshot.
pub trait QlogFilter: Send + Sync + 'static {
    /// Return whether this borrowed observation should reach the wrapped sink.
    fn matches(&self, event: &QlogEventView<'_>) -> bool;

    /// Increment when selection changes to request a fresh recovery snapshot.
    /// Stable filters may keep the default.
    fn generation(&self) -> u64 {
        0
    }
}

impl<F: Fn(&QlogEventView<'_>) -> bool + Send + Sync + 'static> QlogFilter for F {
    fn matches(&self, event: &QlogEventView<'_>) -> bool {
        self(event)
    }
}

/// Borrowed observations delivered synchronously inside the QUIC state machine.
///
/// Every method must finish promptly: no blocking I/O, waiting for locks/capacity, or expensive
/// computation. Do not reenter the emitting connection: its state lock may already be held.
/// Lightweight counters and streaming compact encoders can inspect borrowed fields
/// directly. Use [`super::QlogRecorder`] for output that can wait; it reserves capacity before
/// acquiring owned data. Custom implementations are responsible for respecting this contract.
///
/// The event and its borrowed fields are valid only for the callback. To retain them, explicitly
/// acquire ownership with `event.to_owned()` after checking your storage/admission limits.
/// Tuples deliver to both enabled sinks, including when either sink rejects an observation.
pub trait QlogSink: Send + Sync + 'static {
    /// Cheap gate checked before constructing a borrowed view. Defaults to enabled.
    fn is_enabled(&self) -> bool {
        true
    }

    /// Increment when recording selection changes to request a fresh recovery snapshot.
    /// Sinks with fixed selection may keep the default.
    fn generation(&self) -> u64 {
        0
    }

    /// Inspect an event without retaining its borrows.
    ///
    /// Return `true` when handled (including deliberate filtering), or `false` on capacity/error
    /// rejection. Rejection invalidates cached recovery snapshots so a later observation can retry.
    fn emit(&self, event: &QlogEventView<'_>) -> bool;

    /// Whether this sink wants named events of `schema`; checked before building them.
    fn accepts_named(&self, schema: &EventSchema) -> bool;

    /// Inspect a named event of a protocol above QUIC without retaining its borrows.
    /// It may be emitted under protocol state locks: never reenter the connection.
    fn emit_named(&self, event: &NamedQlogEventView<'_>);

    /// Select events without acquiring ownership. The predicate runs on the transport task and
    /// must also be cheap and nonblocking. For mutable selection state, use [`Self::filtered_by`]
    /// with a [`QlogFilter`] that advances its generation.
    fn filtered<F>(self, predicate: F) -> Filtered<Self, F>
    where
        Self: Sized,
        F: Fn(&QlogEventView<'_>) -> bool + Send + Sync + 'static,
    {
        Filtered {
            sink: self,
            predicate,
        }
    }

    /// Wrap this sink with a filter whose generation reports dynamic selection changes.
    fn filtered_by<F: QlogFilter>(self, predicate: F) -> Filtered<Self, F>
    where
        Self: Sized,
    {
        Filtered {
            sink: self,
            predicate,
        }
    }
}

impl<S: QlogSink + ?Sized> QlogSink for Arc<S> {
    fn is_enabled(&self) -> bool {
        (**self).is_enabled()
    }

    fn generation(&self) -> u64 {
        (**self).generation()
    }

    fn emit(&self, event: &QlogEventView<'_>) -> bool {
        (**self).emit(event)
    }

    fn accepts_named(&self, schema: &EventSchema) -> bool {
        (**self).accepts_named(schema)
    }

    fn emit_named(&self, event: &NamedQlogEventView<'_>) {
        (**self).emit_named(event);
    }
}

/// A sink that delivers only matching typed observations and propagates selection generations.
/// Named events are dropped: a typed predicate cannot select them.
/// Construct with [`QlogSink::filtered`] or [`QlogSink::filtered_by`].
pub struct Filtered<S, F> {
    sink: S,
    predicate: F,
}

impl<S: QlogSink, F: QlogFilter> QlogSink for Filtered<S, F> {
    fn is_enabled(&self) -> bool {
        self.sink.is_enabled()
    }

    fn generation(&self) -> u64 {
        self.sink
            .generation()
            .wrapping_add(self.predicate.generation())
    }

    fn emit(&self, event: &QlogEventView<'_>) -> bool {
        !self.predicate.matches(event) || self.sink.emit(event)
    }

    fn accepts_named(&self, _schema: &EventSchema) -> bool {
        false
    }

    fn emit_named(&self, _event: &NamedQlogEventView<'_>) {}
}

impl<A: QlogSink, B: QlogSink> QlogSink for (A, B) {
    fn is_enabled(&self) -> bool {
        self.0.is_enabled() || self.1.is_enabled()
    }

    fn generation(&self) -> u64 {
        self.0.generation().wrapping_add(self.1.generation())
    }

    fn emit(&self, event: &QlogEventView<'_>) -> bool {
        // Evaluate both, even if one rejects. If either rejects, the engine can retry a full
        // recovery snapshot; sinks that accepted may consequently see another snapshot.
        let first = !self.0.is_enabled() || self.0.emit(event);
        let second = !self.1.is_enabled() || self.1.emit(event);
        first && second
    }

    fn accepts_named(&self, schema: &EventSchema) -> bool {
        (self.0.is_enabled() && self.0.accepts_named(schema))
            || (self.1.is_enabled() && self.1.accepts_named(schema))
    }

    fn emit_named(&self, event: &NamedQlogEventView<'_>) {
        if self.0.is_enabled() && self.0.accepts_named(event.schema()) {
            self.0.emit_named(event);
        }
        if self.1.is_enabled() && self.1.accepts_named(event.schema()) {
            self.1.emit_named(event);
        }
    }
}

#[cfg(test)]
mod tests;
