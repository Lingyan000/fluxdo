use super::{ElementPatchMode, Namespace};
use crate::sse::{
    Event, EventBuildError, EventDataLineReader, EventDataRead, EventDataWrite,
    datastar::EventType, parser::is_lf,
};
use rama_core::error::BoxErrorExt as _;
use rama_core::error::{BoxError, ErrorContext};
use rama_core::telemetry::tracing;
use rama_utils::str::{NonEmptyStr, arcstr::ArcStr};

/// [`PatchElements`] patches HTML elements into the DOM.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PatchElements {
    /// The elements to be patched into the DOM.
    pub elements: Option<NonEmptyStr>,
    /// The CSS selector used to patch the elements.
    pub selector: Option<NonEmptyStr>,
    /// The mode in which elements are patched into the DOM.
    ///
    /// If not provided the Datastar client side will default to [`ElementPatchMode::Outer`].
    pub mode: ElementPatchMode,
    /// Whether to use view transitions.
    ///
    /// If not provided the Datastar client side will default to `false`.
    pub use_view_transition: bool,
    /// The CSS selector for the scoped view transition.
    pub view_transition_selector: Option<NonEmptyStr>,
    /// The namespace in which elements are created.
    ///
    /// If not provided the Datastar client side will default to [`Namespace::Html`].
    pub namespace: Namespace,
}

#[derive(Default, Debug, Clone, PartialEq, Eq, Hash)]
struct PatchElementsBuilder {
    elements: Option<String>,
    selector: Option<NonEmptyStr>,
    mode: ElementPatchMode,
    use_view_transition: bool,
    view_transition_selector: Option<NonEmptyStr>,
    namespace: Namespace,
}

impl PatchElements {
    pub const TYPE: EventType = EventType::PatchElements;

    /// Create a new [`PatchElements`] data blob.
    #[must_use]
    pub const fn new(elements: NonEmptyStr) -> Self {
        Self {
            elements: Some(elements),
            selector: None,
            mode: ElementPatchMode::Outer,
            use_view_transition: false,
            view_transition_selector: None,
            namespace: Namespace::Html,
        }
    }

    /// Create a new [`PatchElements`] data blob for removal
    #[must_use]
    pub const fn new_remove(selector: NonEmptyStr) -> Self {
        Self {
            elements: None,
            selector: Some(selector),
            mode: ElementPatchMode::Remove,
            use_view_transition: false,
            view_transition_selector: None,
            namespace: Namespace::Html,
        }
    }

    /// Consume `self` as an [`Event`].
    pub fn try_into_sse_event(self) -> Result<Event<Self>, EventBuildError> {
        Ok(Event::new()
            .try_with_event(Self::TYPE.as_smol_str())?
            .with_data(self))
    }

    /// Consume `self` as a [`super::DatastarEvent`].
    pub fn try_into_datastar_event<T>(self) -> Result<super::DatastarEvent<T>, EventBuildError> {
        Ok(Event::new()
            .try_with_event(Self::TYPE.as_smol_str())?
            .with_data(super::EventData::PatchElements(self)))
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set the CSS selector used to patch the elements.
        pub fn selector(mut self, selector: NonEmptyStr) -> Self {
            self.selector = Some(selector);
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set mode in which elements are patched into the DOM.
        pub fn mode(mut self, mode: ElementPatchMode) -> Self {
            self.mode = mode;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets whether to use view transitions.
        pub fn use_view_transition(mut self, use_view_transition: bool) -> Self {
            self.use_view_transition = use_view_transition;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set the CSS selector for the scoped view transition.
        pub fn view_transition_selector(mut self, selector: NonEmptyStr) -> Self {
            self.view_transition_selector = Some(selector);
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set the namespace in which elements are created.
        pub fn namespace(mut self, namespace: Namespace) -> Self {
            self.namespace = namespace;
            self
        }
    }
}

impl TryFrom<PatchElements> for Event<PatchElements> {
    type Error = EventBuildError;

    #[inline(always)]
    fn try_from(value: PatchElements) -> Result<Self, Self::Error> {
        value.try_into_sse_event()
    }
}

impl<T> TryFrom<PatchElements> for super::DatastarEvent<T> {
    type Error = EventBuildError;

    #[inline(always)]
    fn try_from(value: PatchElements) -> Result<Self, Self::Error> {
        value.try_into_datastar_event()
    }
}

impl EventDataWrite for PatchElements {
    fn write_data(&self, w: &mut impl std::io::Write) -> Result<(), BoxError> {
        let mut sep = "";

        if let Some(selector) = &self.selector {
            write!(w, "selector {selector}").context("PatchElements: write selector")?;
            sep = "\n";
        }

        if self.mode != ElementPatchMode::default() {
            write!(w, "{sep}mode {}", self.mode).context("PatchElements: write mode")?;
            sep = "\n";
        }

        if self.use_view_transition {
            write!(w, "{sep}useViewTransition true")
                .context("PatchElements: write view transition usage")?;
            sep = "\n";

            if let Some(selector) = &self.view_transition_selector {
                write!(w, "{sep}viewTransitionSelector {selector}")
                    .context("PatchElements: write view transition selector")?;
            }
        }

        if self.namespace != Namespace::default() {
            write!(w, "{sep}namespace {}", self.namespace)
                .context("PatchElements: write namespace")?;
            sep = "\n";
        }

        if let Some(mut elements) = self.elements.as_deref() {
            if elements.chars().last().map(is_lf).unwrap_or_default() {
                elements = &elements[..elements.len() - 1];
            }

            let mut elements = elements.lines();
            let mut next_element = elements
                .next()
                .context("PatchElements: no elements specified")?;
            for element in elements {
                write!(w, "{sep}elements {next_element}")
                    .context("PatchElements: write elements")?;
                next_element = element;
                sep = "\n"
            }
            write!(w, "{sep}elements {next_element}")
                .context("PatchElements: write last elements")?;
        }

        Ok(())
    }
}

/// [`EventDataLineReader`] for the [`EventDataRead`] implementation of [`PatchElements`].
#[derive(Debug)]
pub struct PatchElementsReader(Option<PatchElementsBuilder>);

impl EventDataRead for PatchElements {
    type Reader = PatchElementsReader;

    fn line_reader() -> Self::Reader {
        PatchElementsReader(None)
    }
}

impl EventDataLineReader for PatchElementsReader {
    type Data = PatchElements;

    fn read_line(&mut self, line: &str) -> Result<(), BoxError> {
        let line = line.trim_start();
        if line.is_empty() {
            return Ok(());
        };

        let patch_elements = self.0.get_or_insert_default();

        let (keyword, value) = line
            .split_once(' ')
            // in case of empty value
            .unwrap_or((line, ""));

        if keyword.eq_ignore_ascii_case("selector") {
            if value.is_empty() {
                tracing::trace!("ignore selector property with empty value");
            } else {
                // SAFETY: `NonEmptyStr::new_unchecked` requires a non-empty
                // string; `value` is non-empty in this branch and `ArcStr::from`
                // copies it unchanged.
                patch_elements.selector =
                    Some(unsafe { NonEmptyStr::new_unchecked(ArcStr::from(value)) });
            }
        } else if keyword.eq_ignore_ascii_case("mode") {
            if value.is_empty() {
                tracing::trace!("ignore mode property with empty value");
            } else {
                patch_elements.mode = value.into();
            }
        } else if keyword.eq_ignore_ascii_case("useViewTransition") {
            patch_elements.use_view_transition = value
                .parse()
                .context("PatchElementsReader: parse useViewTransition")?;
        } else if keyword.eq_ignore_ascii_case("viewTransitionSelector") {
            if value.is_empty() {
                tracing::trace!("ignore viewTransitionSelector property with empty value");
            } else {
                // SAFETY: `NonEmptyStr::new_unchecked` requires a non-empty
                // string; `value` is non-empty in this branch and `ArcStr::from`
                // copies it unchanged.
                patch_elements.view_transition_selector =
                    Some(unsafe { NonEmptyStr::new_unchecked(ArcStr::from(value)) });
            }
        } else if keyword.eq_ignore_ascii_case("namespace") {
            if value.is_empty() {
                tracing::trace!("ignore namespace property with empty value");
            } else {
                patch_elements.namespace = value.into();
            }
        } else if keyword.eq_ignore_ascii_case("elements") {
            let elements = patch_elements.elements.get_or_insert_default();
            elements.push_str(value);
            elements.push('\n');
        } else {
            tracing::debug!(
                "PatchElementsReader: ignore unknown line: keyword = {}; value = {}",
                keyword,
                value,
            );
        }

        Ok(())
    }

    fn data(&mut self, event: Option<&str>) -> Result<Option<Self::Data>, BoxError> {
        let Some(PatchElementsBuilder {
            elements,
            selector,
            mode,
            use_view_transition,
            view_transition_selector,
            namespace,
        }) = self.0.take()
        else {
            return Ok(None);
        };

        if !event
            .and_then(|e| {
                e.parse::<EventType>()
                    .ok()
                    .map(|t| t == EventType::PatchElements)
            })
            .unwrap_or_default()
        {
            return Err(BoxError::from_static_str(
                "PatchElementsReader: unexpected event type: expected: datastar-patch-elements",
            ));
        }

        Ok(Some(PatchElements {
            elements: elements
                .map(|mut s| {
                    if s.chars().last().map(is_lf).unwrap_or_default() {
                        _ = s.pop();
                    }
                    s.try_into()
                })
                .transpose()
                .context("PatchElementsReader: unexpected empty Some(String)")?,
            selector,
            mode,
            use_view_transition,
            view_transition_selector,
            namespace,
        }))
    }
}

#[cfg(test)]
mod tests {
    use rama_utils::str::non_empty_str;

    use super::*;

    fn read_patch_elements(input: &str) -> PatchElements {
        let mut reader = PatchElements::line_reader();
        for line in input.lines() {
            reader.read_line(line).unwrap();
        }
        reader
            .data(Some("datastar-patch-elements"))
            .unwrap()
            .unwrap()
    }

    #[test]
    fn test_deserialize_minimal() {
        let data = read_patch_elements(r##"elements <div id="foo">Hello, world!</div>"##);
        assert_eq!(
            data.elements.as_deref(),
            Some(r##"<div id="foo">Hello, world!</div>"##)
        );
        assert_eq!(data.mode, ElementPatchMode::Outer);
        assert_eq!(data.selector, None);
        assert_eq!(data.namespace, Namespace::Html);
        assert_eq!(data.view_transition_selector, None);
        assert!(!data.use_view_transition);
    }

    #[test]
    fn test_deserialize_preserves_element_whitespace() {
        let data = read_patch_elements("elements   indented text  ");

        assert_eq!(data.elements.as_deref(), Some("  indented text  "));
    }

    #[test]
    fn test_serialize_current_protocol_options() {
        let mut buf = Vec::new();
        PatchElements::new(non_empty_str!("<circle id=\"dot\" />"))
            .with_selector(non_empty_str!("#vis"))
            .with_mode(ElementPatchMode::Append)
            .with_use_view_transition(true)
            .with_view_transition_selector(non_empty_str!("#main"))
            .with_namespace(Namespace::Svg)
            .write_data(&mut buf)
            .unwrap();

        assert_eq!(
            String::from_utf8(buf).unwrap(),
            concat!(
                "selector #vis\n",
                "mode append\n",
                "useViewTransition true\n",
                "viewTransitionSelector #main\n",
                "namespace svg\n",
                "elements <circle id=\"dot\" />",
            )
        );
    }

    #[test]
    fn test_serialize_omits_default_and_inactive_options() {
        let mut buf = Vec::new();
        PatchElements::new(non_empty_str!("<div id=\"message\">Hello</div>"))
            .with_view_transition_selector(non_empty_str!("#main"))
            .write_data(&mut buf)
            .unwrap();

        assert_eq!(
            String::from_utf8(buf).unwrap(),
            "elements <div id=\"message\">Hello</div>"
        );
    }

    #[test]
    fn test_serialize_remove() {
        let mut buf = Vec::new();
        PatchElements::new_remove(non_empty_str!("#message"))
            .write_data(&mut buf)
            .unwrap();

        assert_eq!(
            String::from_utf8(buf).unwrap(),
            "selector #message\nmode remove"
        );
    }

    #[test]
    fn test_event_conversions() {
        let patch = PatchElements::new(non_empty_str!("<div>hello</div>"));

        let event: Event<PatchElements> = patch.clone().try_into().unwrap();
        assert_eq!(event.event(), Some(EventType::PatchElements.as_str()));

        let event: crate::body::sse::datastar::DatastarEvent = patch.try_into().unwrap();
        assert_eq!(event.event(), Some(EventType::PatchElements.as_str()));
    }

    #[test]
    fn test_serialize_trims_one_trailing_line_ending() {
        let mut buf = Vec::new();
        PatchElements::new(non_empty_str!("<div>hello</div>\n"))
            .write_data(&mut buf)
            .unwrap();

        assert_eq!(String::from_utf8(buf).unwrap(), "elements <div>hello</div>");
    }

    #[test]
    fn test_serialize_deserialize_reflect() {
        let expected_data = PatchElements::new(non_empty_str!("<div>\nHello, world!\n</div>"))
            .with_selector(non_empty_str!("#foo"))
            .with_mode(ElementPatchMode::Append)
            .with_use_view_transition(true)
            .with_view_transition_selector(non_empty_str!("#main"))
            .with_namespace(Namespace::Svg);

        let mut buf = Vec::new();
        expected_data.write_data(&mut buf).unwrap();

        let input = String::from_utf8(buf).unwrap();
        let data = read_patch_elements(&input);

        assert_eq!(expected_data, data);
    }

    #[test]
    fn test_deserialize_ignores_empty_and_unknown_properties() {
        let data = read_patch_elements(concat!(
            "selector\n",
            "mode\n",
            "viewTransitionSelector\n",
            "namespace\n",
            "unknown value\n",
            "elements <div>hello</div>",
        ));

        assert_eq!(data.selector, None);
        assert_eq!(data.mode, ElementPatchMode::Outer);
        assert_eq!(data.view_transition_selector, None);
        assert_eq!(data.namespace, Namespace::Html);
    }

    #[test]
    fn test_deserialize_rejects_invalid_input() {
        let mut reader = PatchElements::line_reader();
        assert!(reader.read_line("useViewTransition perhaps").is_err());

        let mut reader = PatchElements::line_reader();
        reader.read_line("elements <div></div>").unwrap();
        reader.data(Some("datastar-patch-signals")).unwrap_err();

        let mut reader = PatchElements::line_reader();
        assert!(
            reader
                .data(Some("datastar-patch-elements"))
                .unwrap()
                .is_none()
        );
    }
}
