import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import 'route_interaction.dart';

/// Lets a mouse press stop scrolling and reach the control under the pointer
/// in the same gesture. Pair with [DesktopScrollInteractionBehavior].
///
/// A Listener is too late: Scrollable's IgnorePointer has already excluded the
/// content from the down event's cached hit path. Stop only hit scrollables
/// before Flutter creates that path; never synthesize or replay pointer events.
/// Touch can also reach nested drags during a scroll animation, while a tap
/// still only stops scrolling. The historical name is kept for existing users.
/// With touch resampling enabled, retain Flutter's default touch behavior:
/// dispatch may be deferred past this synchronous hit-test preparation.
mixin DesktopScrollInteractionBinding on GestureBinding {
  late final _stopScrollTap = _StopScrollTapRecognizer();

  @override
  void hitTestInView(HitTestResult result, Offset position, int viewId) {
    RouteInteractionObserver.hitTestAfterPop(
      () => super.hitTestInView(result, position, viewId),
    );
  }

  @override
  void handlePointerEvent(PointerEvent event) {
    if (!resamplingEnabled &&
        event is PointerDownEvent &&
        event.kind == PointerDeviceKind.touch &&
        event.buttons == kPrimaryMouseButton) {
      final exposed = <_RenderScrollInteractionBoundary>{};
      try {
        while (true) {
          final probe = HitTestResult();
          hitTestInView(probe, event.position, event.viewId);
          var changed = false;
          for (final boundary
              in probe.path
                  .map((entry) => entry.target)
                  .whereType<_RenderScrollInteractionBoundary>()) {
            if (!exposed.contains(boundary) && boundary.exposeTouchDrag()) {
              exposed.add(boundary);
              changed = true;
            }
          }
          if (!changed) break;
        }
        if (exposed.isNotEmpty) _stopScrollTap.addPointer(event);
        // Scrollable's ordinary onDown now holds each hit position, retaining
        // carried momentum and letting its recognizers arbitrate the new axis.
        super.handlePointerEvent(event);
      } finally {
        for (final boundary in exposed) {
          boundary.restoreIgnorePointer();
        }
      }
      return;
    }
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
/// Touch retains "tap to stop momentum", and can interrupt with a nested drag.
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

  bool exposeTouchDrag() {
    if (!attached || !scrollable.mounted) return false;
    final position = scrollable.position;
    // Never interrupt another finger's live drag. Only temporarily open the
    // scrollable-owned IgnorePointer, not application or route barriers.
    // Flutter exposes no public activity-kind query. Keep this SDK coupling
    // local to the boundary; checking it avoids canceling live multi-touch drags.
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    final activity = position.activity;
    if (!position.shouldIgnorePointer ||
        (activity is! BallisticScrollActivity &&
            activity is! DrivenScrollActivity)) {
      return false;
    }
    final behavior =
        scrollable.widget.scrollBehavior ??
        ScrollConfiguration.of(scrollable.context);
    if (!behavior.dragDevices.contains(PointerDeviceKind.touch)) return false;
    // Use Scrollable's own setter so its flag and RenderIgnorePointer agree.
    // ignore: invalid_use_of_protected_member
    scrollable.setIgnorePointer(false);
    return true;
  }

  void restoreIgnorePointer() {
    if (attached && scrollable.mounted) {
      // ignore: invalid_use_of_protected_member
      scrollable.setIgnorePointer(scrollable.position.shouldIgnorePointer);
    }
  }

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

/// Joins before content recognizers only when a touch exposes a moving
/// scrollable. A stationary release stops scrolling without activating a
/// button; movement yields to ordinary drag/scale recognition.
class _StopScrollTapRecognizer extends OneSequenceGestureRecognizer {
  final _origins = <int, Offset>{};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _origins[event.pointer] = event.position;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    final origin = _origins[event.pointer];
    if (origin == null) return;
    if (event is PointerUpEvent) {
      resolvePointer(event.pointer, GestureDisposition.accepted);
      _stop(event.pointer);
    } else if (event is PointerCancelEvent ||
        (event is PointerMoveEvent &&
            (event.position - origin).distance >
                computeHitSlop(event.kind, gestureSettings))) {
      resolvePointer(event.pointer, GestureDisposition.rejected);
      _stop(event.pointer);
    }
  }

  void _stop(int pointer) {
    _origins.remove(pointer);
    stopTrackingPointer(pointer);
  }

  @override
  void rejectGesture(int pointer) {
    resolvePointer(pointer, GestureDisposition.rejected);
    _stop(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'stop scroll tap';
}
