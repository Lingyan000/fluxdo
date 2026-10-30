import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

/// Lets a mouse press stop scrolling and reach the control under the pointer
/// in the same gesture. Pair with [DesktopScrollInteractionBehavior].
///
/// A Listener is too late: Scrollable's IgnorePointer has already excluded the
/// content from the down event's cached hit path. Stop only hit scrollables
/// before Flutter creates that path; never synthesize or replay pointer events.
mixin DesktopScrollInteractionBinding on GestureBinding {
  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is PointerDownEvent &&
        event.kind == PointerDeviceKind.mouse &&
        (event.buttons == kPrimaryMouseButton ||
            event.buttons == kSecondaryMouseButton)) {
      final visited = <_RenderScrollInteractionBoundary>{};
      while (true) {
        final probe = HitTestResult();
        hitTestInView(probe, event.position, event.viewId);
        final boundaries = probe.path
            .map((entry) => entry.target)
            .whereType<_RenderScrollInteractionBoundary>()
            .where((boundary) => visited.add(boundary))
            .toList();
        var stopped = false;
        for (final boundary in boundaries) {
          stopped = boundary.stopScrolling() || stopped;
        }
        // Stopping an outer scroll can expose a nested carousel that was
        // previously below IgnorePointer. Probe again before the real down.
        if (!stopped) break;
      }
    }
    super.handlePointerEvent(event);
  }
}

/// Application scroll policy. Preserves physics, drag devices and decorations,
/// including local copyWith overrides used by PageView and nested lists.
/// Touch retains Flutter's normal "tap to stop momentum" behavior.
class DesktopScrollInteractionBehavior extends ScrollBehavior {
  const DesktopScrollInteractionBehavior({
    this.delegate = const MaterialScrollBehavior(),
  });

  final ScrollBehavior delegate;

  @override
  ScrollBehavior copyWith({
    bool? scrollbars,
    bool? overscroll,
    Set<PointerDeviceKind>? dragDevices,
    MultitouchDragStrategy? multitouchDragStrategy,
    Set<LogicalKeyboardKey>? pointerAxisModifiers,
    ScrollPhysics? physics,
    TargetPlatform? platform,
    ScrollViewKeyboardDismissBehavior? keyboardDismissBehavior,
  }) => DesktopScrollInteractionBehavior(
    delegate: delegate.copyWith(
      scrollbars: scrollbars,
      overscroll: overscroll,
      dragDevices: dragDevices,
      multitouchDragStrategy: multitouchDragStrategy,
      pointerAxisModifiers: pointerAxisModifiers,
      physics: physics,
      platform: platform,
      keyboardDismissBehavior: keyboardDismissBehavior,
    ),
  );

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    final decorated = delegate.buildScrollbar(context, child, details);
    // Scrollable passes its own context to buildScrollbar. Use the specific
    // state, not controller.position (a controller may serve multiple tabs).
    final state = context is StatefulElement ? context.state : null;
    if (state is! ScrollableState) return decorated;
    return _ScrollInteractionBoundary(scrollable: state, child: decorated);
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => delegate.buildOverscrollIndicator(context, child, details);
  @override
  TargetPlatform getPlatform(BuildContext context) =>
      delegate.getPlatform(context);
  @override
  Set<PointerDeviceKind> get dragDevices => delegate.dragDevices;
  @override
  Set<LogicalKeyboardKey> get pointerAxisModifiers =>
      delegate.pointerAxisModifiers;
  @override
  MultitouchDragStrategy getMultitouchDragStrategy(BuildContext context) =>
      delegate.getMultitouchDragStrategy(context);
  @override
  GestureVelocityTrackerBuilder velocityTrackerBuilder(BuildContext context) =>
      delegate.velocityTrackerBuilder(context);
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      delegate.getScrollPhysics(context);
  @override
  ScrollViewKeyboardDismissBehavior getKeyboardDismissBehavior(
    BuildContext context,
  ) => delegate.getKeyboardDismissBehavior(context);
  @override
  bool shouldNotify(covariant DesktopScrollInteractionBehavior oldDelegate) =>
      delegate.runtimeType != oldDelegate.delegate.runtimeType ||
      delegate.shouldNotify(oldDelegate.delegate);
}

class _ScrollInteractionBoundary extends SingleChildRenderObjectWidget {
  const _ScrollInteractionBoundary({
    required this.scrollable,
    required super.child,
  });
  final ScrollableState scrollable;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderScrollInteractionBoundary(scrollable);
  @override
  void updateRenderObject(
    BuildContext context,
    _RenderScrollInteractionBoundary renderObject,
  ) {
    renderObject.scrollable = scrollable;
  }
}

class _RenderScrollInteractionBoundary extends RenderProxyBox {
  _RenderScrollInteractionBoundary(this.scrollable);
  ScrollableState scrollable;

  bool stopScrolling() {
    if (!attached || !scrollable.mounted) return false;
    final position = scrollable.position;
    if (!position.hasPixels || !position.isScrollingNotifier.value) {
      return false;
    }
    // This is Scrollable's own PointerScrollInertiaCancelEvent path. Unlike
    // jumpTo it does not manufacture a position change; overscroll still settles.
    position.pointerScroll(0);
    return true;
  }
}
