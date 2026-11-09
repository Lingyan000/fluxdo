import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:common_ui/common_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../services/navigation/browser_dock_observer.dart';
import '../../services/browser_tabs.dart';
import 'browser_dock_motion.dart';

/// 浏览器和小程序页面共用跟手恢复与收起转场。
class BrowserPageRoute<T> extends InteractionPageRoute<T> {
  BrowserPageRoute({
    required super.builder,
    this.fromDock = false,
    this.motion,
    this.session,
    String name = browserPageRouteName,
  }) : super(settings: RouteSettings(name: name), allowSnapshotting: false) {
    useSnapshotMotion = !fromDock || session?.preview != null;
    _restoringFromDock = fromDock;
  }

  final bool fromDock;
  final BrowserDockMotion? motion;
  final BrowserTabSession? session;
  bool minimizing = false;
  bool useSnapshotMotion = true;
  late bool _restoringFromDock;
  bool _linearDockProgress = false;
  bool _dragging = false;
  bool _userGesture = false;
  bool _disposed = false;
  VoidCallback? onReturnToDock;
  Route<dynamic>? _previousRoute;

  bool get dragging => _dragging;

  /// 真正的路由进度；不受 Hero 预布局时临时完成的 animation 代理影响。
  Animation<double>? get transitionAnimation => controller?.view;

  bool get _usesDockTransition =>
      minimizing ||
      (_restoringFromDock && controller?.status != AnimationStatus.reverse);

  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) =>
      !_usesDockTransition && super.canTransitionFrom(previousRoute);

  @override
  void didChangePrevious(Route<dynamic>? previousRoute) {
    _previousRoute = previousRoute;
    super.didChangePrevious(previousRoute);
  }

  void _refreshPreviousTransition() {
    // 跟手收起尚未 pop，Navigator 不会自动重新绑定下层 secondaryAnimation。
    // 切换转场类型时刷新绑定，否则下拉页面会把底下页面横向带走，露出黑边。
    if (_previousRoute?.isActive == true) _previousRoute!.didChangeNext(this);
  }

  @override
  TickerFuture didPush() {
    final result = super.didPush();
    transitionAnimation?.addStatusListener(_finishMotion);
    if (fromDock && session != null) {
      if (motion?.restoringByDrag(session) == true) {
        _linearDockProgress = true;
        _dragging = true;
        controller!.stop();
        controller!.value = .000001;
        motion?.start(transitionAnimation!, session!, linear: true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_disposed) return;
          _startUserGesture();
          motion?.bindRestoreDrag(setDragProgress, _endRestoreDrag);
        });
      } else {
        motion?.start(transitionAnimation!, session!);
      }
    }
    return result;
  }

  void _startUserGesture() {
    if (_userGesture) return;
    _userGesture = true;
    navigator?.didStartUserGesture();
  }

  void _stopUserGesture() {
    if (!_userGesture) return;
    _userGesture = false;
    navigator?.didStopUserGesture();
  }

  void beginMinimizeDrag(BrowserTabSession tab, {required bool hasSnapshot}) {
    _dragging = true;
    _linearDockProgress = true;
    beginMinimize(tab, hasSnapshot: hasSnapshot);
    _startUserGesture();
    changedInternalState();
  }

  void setDragProgress(double progress) {
    if (!_dragging || _disposed) return;
    // 保留端点状态给松手后的归位，避免拖到边界时提前结束会话。
    controller!.value = progress.clamp(.000001, .999999);
  }

  bool shouldMinimize(double velocity) =>
      velocity > 650 || (velocity >= -650 && controller!.value < .72);

  Future<void> cancelMinimizeDrag() async {
    _dragging = false;
    await _settleExpanded();
  }

  Future<void> _settleExpanded() async {
    try {
      await controller!
          .animateTo(
            1,
            duration: _settleDuration(1 - controller!.value),
            curve: Curves.easeOutCubic,
          )
          .orCancel;
    } on TickerCanceled {
      return;
    }
  }

  void _endRestoreDrag(double velocity) {
    if (!_dragging || _disposed) return;
    _dragging = false;
    motion?.clearRestoreDrag();
    if (velocity > 650 || (velocity >= -650 && controller!.value >= .28)) {
      _settleExpanded();
    } else {
      minimizing = true;
      onReturnToDock?.call();
    }
  }

  Duration _settleDuration(double distance) =>
      Duration(milliseconds: (120 + 220 * distance).round());

  @override
  bool didPop(T? result) {
    _dragging = false;
    final popped = super.didPop(result);
    if (popped && _linearDockProgress && !controller!.isDismissed) {
      controller!.animateBack(
        0,
        duration: _settleDuration(controller!.value),
        curve: Curves.easeOutCubic,
      );
    }
    return popped;
  }

  void beginMinimize(BrowserTabSession tab, {required bool hasSnapshot}) {
    minimizing = true;
    _refreshPreviousTransition();
    useSnapshotMotion = hasSnapshot;
    controller?.reverseDuration = browserDockMinimizeDuration;
    motion?.start(transitionAnimation!, tab, linear: _linearDockProgress);
  }

  void _finishMotion(AnimationStatus status) {
    if (_dragging) return;
    if (status == AnimationStatus.completed) {
      _restoringFromDock = false;
      minimizing = false;
      _linearDockProgress = false;
    }
    if (status != AnimationStatus.completed &&
        status != AnimationStatus.dismissed) {
      return;
    }
    final currentAnimation = transitionAnimation!;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      motion?.finish(currentAnimation);
      if (_disposed) return;
      _stopUserGesture();
      if (status == AnimationStatus.completed) {
        _refreshPreviousTransition();
        changedInternalState();
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _stopUserGesture();
    if (transitionAnimation case final current?) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => motion?.finish(current),
      );
    }
    transitionAnimation?.removeStatusListener(_finishMotion);
    super.dispose();
  }

  @override
  Duration get transitionDuration =>
      fromDock ? browserDockExpandDuration : super.transitionDuration;
  @override
  Duration get reverseTransitionDuration => minimizing
      ? browserDockMinimizeDuration
      : super.reverseTransitionDuration;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final dock = _usesDockTransition;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    // 始终保留主题转场和固定视口两层承载树，切换收起/关闭状态不重挂原生视图。
    // 普通导航完全交给应用主题；收起/恢复时仅将主题主动画固定在完成位置。
    return super.buildTransitions(
      context,
      dock || reduceMotion ? kAlwaysCompleteAnimation : animation,
      reduceMotion ? kAlwaysDismissedAnimation : secondaryAnimation,
      _BrowserRouteSurface(
        animation: animation,
        dock: dock,
        morph: useSnapshotMotion,
        linear: _linearDockProgress,
        child: RouteContentInteraction(route: this, child: child),
      ),
    );
  }
}

class _BrowserRouteSurface extends StatelessWidget {
  const _BrowserRouteSurface({
    required this.animation,
    required this.dock,
    required this.morph,
    required this.linear,
    required this.child,
  });
  final Animation<double> animation;
  final bool dock;
  final bool morph;
  final bool linear;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final viewport = BrowserDockViewport.maybeOf(context);
    final media = viewport?.media ?? MediaQuery.of(context);
    final size = media.size;
    final full = Offset.zero & size;
    final destination = browserDockRect(
      size,
      media.padding.bottom,
      leftInset: viewport?.dockLeftInset ?? 0,
    );
    return OverflowBox(
      alignment: Alignment.topLeft,
      minWidth: size.width,
      maxWidth: size.width,
      minHeight: size.height,
      maxHeight: size.height,
      child: AnimatedBuilder(
        animation: animation,
        child: RepaintBoundary(
          child: MediaQuery(data: media, child: child),
        ),
        builder: (context, content) {
          final value = media.disableAnimations && !linear
              ? 1.0
              : animation.value;
          final t = dock
              ? linear
                    ? value
                    : browserDockOpenProgress(
                        value,
                        closing: animation.status == AnimationStatus.reverse,
                      )
              : 1.0;
          // 截图失败也沿上下方向滑动，只保留全尺寸，避免缩放未就绪的原生画面。
          final rect = !dock
              ? full
              : morph
              ? Rect.lerp(destination, full, t)!
              : full.shift(Offset(0, destination.top * (1 - t)));
          final scale = rect.width / size.width;
          final opacity = dock ? browserDockPageOpacity(t) : 1.0;
          final sheetAppearance = dock
              ? ((1 - t) * destination.top / 32).clamp(0.0, 1.0)
              : 0.0;
          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fromRect(
                rect: rect,
                child: IgnorePointer(
                  ignoring: animation.status != AnimationStatus.completed,
                  child: Opacity(
                    opacity: opacity,
                    child: ClipRRect(
                      key: const ValueKey('browser-route-surface'),
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(
                          lerpDouble(16, 24, t)! * sheetAppearance,
                        ),
                        bottom: Radius.circular(dock ? 16 * (1 - t) : 0),
                      ),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          OverflowBox(
                            alignment: Alignment.topLeft,
                            minWidth: size.width,
                            maxWidth: size.width,
                            minHeight: size.height,
                            maxHeight: size.height,
                            child: Transform.scale(
                              scale: scale,
                              alignment: Alignment.topLeft,
                              child: Transform.translate(
                                offset: Offset(
                                  0,
                                  dock && morph
                                      ? -media.padding.top * (1 - t)
                                      : 0,
                                ),
                                child: content,
                              ),
                            ),
                          ),
                          Positioned(
                            top: 8,
                            left: 0,
                            right: 0,
                            child: Opacity(
                              key: const ValueKey('browser-drag-handle'),
                              opacity:
                                  sheetAppearance * browserDockPageOpacity(t),
                              child: Center(
                                child: Container(
                                  width: 32,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant
                                        .withValues(alpha: .42),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class BrowserDockTransition extends StatefulWidget {
  const BrowserDockTransition({
    super.key,
    required this.animation,
    required this.child,
  });
  final Animation<double> animation;
  final Widget child;

  @override
  State<BrowserDockTransition> createState() => _BrowserDockTransitionState();
}

class _BrowserDockTransitionState extends State<BrowserDockTransition> {
  late CurvedAnimation _motion;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    _motion = CurvedAnimation(
      parent: widget.animation,
      curve: M3eMotion.defaultSpatial.curveFor(
        const Duration(milliseconds: 420),
      ),
      reverseCurve: Curves.easeInOutCubic,
    );
  }

  @override
  void didUpdateWidget(BrowserDockTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animation != oldWidget.animation) {
      _motion.dispose();
      _bind();
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final full = Offset.zero & constraints.biggest;
      // 收起端落到内容区下沿，和外层底栏的占位动画衔接。
      final dock = Rect.fromLTWH(6, full.height - 4, full.width - 12, 56);
      return AnimatedBuilder(
        animation: _motion,
        child: widget.child,
        builder: (context, child) {
          final t = _motion.value.clamp(0.0, 1.0);
          final rect = Rect.lerp(dock, full, t)!;
          return Stack(
            clipBehavior: Clip.hardEdge,
            fit: StackFit.expand,
            children: [
              Positioned.fromRect(
                rect: rect,
                child: Opacity(
                  opacity: (t / .12).clamp(0.0, 1.0),
                  child: ClipRRect(
                    key: const ValueKey('browser-dock-transition'),
                    borderRadius: BorderRadius.circular(lerpDouble(22, 0, t)!),
                    child: OverflowBox(
                      alignment: Alignment.topCenter,
                      minHeight: full.height,
                      maxHeight: full.height,
                      child: child,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}
