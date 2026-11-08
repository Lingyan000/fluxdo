import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// One instance per Navigator, including nested Navigators.
/// Keeps visual gesture settlement separate from ownership of new input.
class RouteInteractionObserver extends NavigatorObserver {
  static final _observers = Expando<RouteInteractionObserver>();
  static final _handoffs = <NavigatorState, Route<dynamic>>{};
  Route<dynamic>? _gestureRoute;

  void _register() {
    final nav = navigator;
    if (nav != null) _observers[nav] = this;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _register();
    _handoffs.remove(navigator);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _register();
    final nav = navigator;
    if (nav == null || previousRoute == null) return;
    _handoffs[nav] = previousRoute;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (identical(_handoffs[nav], previousRoute)) _handoffs.remove(nav);
    });
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _handoffs.remove(navigator);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _handoffs.remove(navigator);
  }

  @override
  void didStartUserGesture(
    Route<dynamic> route,
    Route<dynamic>? previousRoute,
  ) {
    _register();
    _gestureRoute = route;
  }

  @override
  void didStopUserGesture() => _gestureRoute = null;

  static bool _isSettling(ModalRoute<dynamic> route) {
    final nav = route.navigator;
    if (nav == null || !nav.userGestureInProgress || !route.isCurrent) {
      return false;
    }
    final gesture = _observers[nav]?._gestureRoute;
    // The controller's ticker distinguishes an automatic settle from a live
    // drag; Animation.status alone also says "forward" during a held drag.
    if (gesture is! TransitionRoute) return false;
    // ignore: invalid_use_of_protected_member
    return gesture.controller?.isAnimating == true;
  }

  /// Called only around hit testing. Navigator absorbs new downs until its
  /// next build after navigation. A committed pop may release that one guard;
  /// an intervening push/replacement invalidates the permission.
  static void hitTestAfterPop(VoidCallback hitTest) {
    final guards = <RenderAbsorbPointer>[];
    for (final entry in _handoffs.entries.toList()) {
      final nav = entry.key;
      if (!nav.mounted || !entry.value.isCurrent) continue;
      final guard = nav.overlay?.context
          .findAncestorRenderObjectOfType<RenderAbsorbPointer>();
      if (guard?.absorbing == true) {
        guard!.absorbing = false;
        guards.add(guard);
      }
    }
    try {
      hitTest();
    } finally {
      for (final guard in guards) {
        if (guard.attached) guard.absorbing = true;
      }
    }
  }
}

/// Excludes the entire exiting route, including custom barriers and detectors.
/// isActive changes synchronously after a committed pop, before the next build.
/// A canceled predictive gesture and a consumed LocalHistoryEntry stay active.
class RouteInputGate extends SingleChildRenderObjectWidget {
  const RouteInputGate({super.key, required this.route, required super.child});
  final ModalRoute<dynamic> route;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RouteInputRender(route);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RouteInputRender).route = route;
  }
}

class _RouteInputRender extends RenderProxyBox {
  _RouteInputRender(this.route);
  ModalRoute<dynamic> route;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      route.isActive && super.hitTest(result, position: position);
}

/// Wrap the unmodified child supplied by ModalRoute.buildTransitions, before
/// adding transition widgets. Only its immediate framework IgnorePointer is
/// temporarily exposed; application IgnorePointers and modal barriers remain.
class RouteContentInteraction extends SingleChildRenderObjectWidget {
  const RouteContentInteraction({
    super.key,
    required this.route,
    required super.child,
  });
  final ModalRoute<dynamic> route;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RouteContentRender(route);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RouteContentRender).route = route;
  }
}

class _RouteContentRender extends RenderProxyBox {
  _RouteContentRender(this.route);
  ModalRoute<dynamic> route;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final guard = child;
    if (guard is! RenderIgnorePointer ||
        !guard.ignoring ||
        !RouteInteractionObserver._isSettling(route)) {
      return super.hitTest(result, position: position);
    }
    guard.ignoring = false;
    try {
      return super.hitTest(result, position: position);
    } finally {
      guard.ignoring = true;
    }
  }
}

/// Shared integration for PopupRoute implementations. Overrides of transitions
/// must call super, or use RouteInputGate and RouteContentInteraction explicitly.
mixin InterruptibleRoute<T> on ModalRoute<T> {
  @override
  Widget buildModalBarrier() =>
      RouteInputGate(route: this, child: super.buildModalBarrier());

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => RouteInputGate(
    route: this,
    child: super.buildTransitions(
      context,
      animation,
      secondaryAnimation,
      RouteContentInteraction(route: this, child: child),
    ),
  );
}

/// Decorates a theme's transitions without changing their visuals or timing.
class InterruptiblePageTransitionsBuilder extends PageTransitionsBuilder {
  const InterruptiblePageTransitionsBuilder(this.delegate);
  final PageTransitionsBuilder delegate;

  @override
  Duration get transitionDuration => delegate.transitionDuration;
  @override
  Duration get reverseTransitionDuration => delegate.reverseTransitionDuration;
  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      delegate.delegatedTransition;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => RouteInputGate(
    route: route,
    child: delegate.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      RouteContentInteraction(route: route, child: child),
    ),
  );
}

/// Material dialog with the shared input policy. Keeps the standard dialog's
/// appearance, focus, theme capture, barrier and result semantics.
Future<T?> showInteractionDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior? traversalEdgeBehavior,
  bool? requestFocus,
  AnimationStyle? animationStyle,
  bool fullscreenDialog = false,
}) {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  return navigator.push<T>(
    _InteractionDialogRoute<T>(
      context: context,
      builder: builder,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierDismissible: barrierDismissible,
      barrierColor:
          barrierColor ??
          DialogTheme.of(context).barrierColor ??
          Theme.of(context).dialogTheme.barrierColor ??
          Colors.black54,
      barrierLabel: barrierLabel,
      useSafeArea: useSafeArea,
      settings: routeSettings,
      anchorPoint: anchorPoint,
      traversalEdgeBehavior:
          traversalEdgeBehavior ?? TraversalEdgeBehavior.closedLoop,
      requestFocus: requestFocus,
      animationStyle: animationStyle,
      fullscreenDialog: fullscreenDialog,
    ),
  );
}

class _InteractionDialogRoute<T> extends DialogRoute<T>
    with InterruptibleRoute<T> {
  _InteractionDialogRoute({
    required super.context,
    required super.builder,
    super.themes,
    super.barrierDismissible,
    super.barrierColor,
    super.barrierLabel,
    super.useSafeArea,
    super.settings,
    super.anchorPoint,
    super.traversalEdgeBehavior,
    super.requestFocus,
    super.animationStyle,
    super.fullscreenDialog,
  });
}

/// Use for application pages so the framework barrier also releases input in
/// the same frame as pop. Theme decoration alone cannot wrap that barrier.
class InteractionPageRoute<T> extends MaterialPageRoute<T>
    with InterruptibleRoute<T> {
  InteractionPageRoute({
    required super.builder,
    super.settings,
    super.requestFocus,
    super.maintainState,
    super.fullscreenDialog,
    super.allowSnapshotting,
    super.barrierDismissible,
    super.traversalEdgeBehavior,
    super.directionalTraversalEdgeBehavior,
  });
}

class InteractionPageRouteBuilder<T> extends PageRouteBuilder<T>
    with InterruptibleRoute<T> {
  InteractionPageRouteBuilder({
    required super.pageBuilder,
    super.settings,
    super.requestFocus,
    super.transitionsBuilder,
    super.transitionDuration,
    super.reverseTransitionDuration,
    super.opaque,
    super.barrierDismissible,
    super.barrierColor,
    super.barrierLabel,
    super.maintainState,
    super.fullscreenDialog,
    super.allowSnapshotting,
  });
}
