import 'dart:async';
import 'dart:math' as math;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'loading_spinner.dart';
import 'm3e_flags.dart';

/// Lets a containing home surface move as one sheet, including its toolbar.
class RefreshRevealNotification extends Notification {
  const RefreshRevealNotification(
    this.progress,
    this.armed,
    this.refreshing, {
    this.dragging = true,
    this.refreshArmed = false,
    this.velocity = 0,
    this.geometry,
    this.handle,
  });
  final double progress;
  final bool armed, refreshing;
  final bool dragging, refreshArmed;

  /// Physical pointer speed, before the containing surface applies resistance.
  final double velocity;
  final RefreshRevealGeometry? geometry;
  final RefreshRevealHandle? handle;
}

/// 外层接住二楼动画后，将同一手势交还发起它的刷新组件。
/// 不持有列表或页面，失效的组件会拒绝接管，实际刷新中的请求也不会被取消。
abstract interface class RefreshRevealHandle {
  bool get canResumeDrag;
  double get resumeExtent;
  void beginResumedDrag(double visibleOffset);
  void updateResumedDrag(double delta);
  void endResumedDrag(double velocity);
  void cancelResumedDrag();
}

/// One coordinate system for resistance, thresholds and the revealed surface.
/// Like two-level refresh layouts, the second floor is armed by the visible
/// header extent, not a separate, unrelated raw pointer distance.
class RefreshRevealGeometry {
  const RefreshRevealGeometry({
    required this.viewportExtent,
    required this.topInset,
    this.contentExtent = 116,
  });
  final double viewportExtent, topInset, contentExtent;
  double get refreshExtent => topInset + contentExtent;
  double get secondaryExtent => refreshExtent + 64;
  double get revealStart => refreshExtent + 16;

  // 进入第二段之前保持固定跟手比例，避免指数阻尼把开启距离越推越远。
  // 过阈值后才渐增阻力，连接处的位置和速度均连续。
  static const _tracking = .9;
  double get _remaining => math.max(viewportExtent - secondaryExtent, 120);
  double offsetFor(double distance) {
    final tracked = math.max(0, distance) * _tracking;
    if (tracked <= secondaryExtent) return tracked;
    return secondaryExtent +
        _remaining * (1 - math.exp(-(tracked - secondaryExtent) / _remaining));
  }

  double distanceFor(double offset) {
    if (offset <= secondaryExtent) return math.max(0, offset) / _tracking;
    return (secondaryExtent -
            _remaining *
                math.log(
                  1 - ((offset - secondaryExtent) / _remaining).clamp(0, .999),
                )) /
        _tracking;
  }

  double velocityFactor(double distance) =>
      _tracking *
      math.exp(
        -math.max(0, distance * _tracking - secondaryExtent) / _remaining,
      );

  // 显露跨越深拉和吸附过程，不在开启阈值附近突然亮出整页。
  double revealProgress(double offset) {
    final span = ((viewportExtent - revealStart) * .32).clamp(64.0, 180.0);
    final t = ((offset - revealStart) / span).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }
}

/// Put this outside the list's usual physics when a containing surface owns
/// leading-edge overscroll. Reversing the finger retracts that surface before
/// the list starts scrolling, on both clamping and bouncing platforms.
class RefreshRevealScrollPhysics extends ScrollPhysics {
  const RefreshRevealScrollPhysics({
    required this.holdLeadingEdge,
    super.parent,
  });

  final bool Function() holdLeadingEdge;

  @override
  RefreshRevealScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      RefreshRevealScrollPhysics(
        holdLeadingEdge: holdLeadingEdge,
        parent: buildParent(ancestor),
      );

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    if (position.pixels == position.minScrollExtent &&
        (value < position.minScrollExtent || holdLeadingEdge())) {
      return value - position.pixels;
    }
    return super.applyBoundaryConditions(position, value);
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (position.pixels == position.minScrollExtent && holdLeadingEdge()) {
      return null;
    }
    return super.createBallisticSimulation(position, velocity);
  }
}

/// Material 3 Expressive 风格下拉刷新。
///
/// 架构:状态机整体移植自 Flutter SDK 的 refresh_indicator.dart
/// (与 pub 上 expressive_refresh 的做法相同,MIT),只替换展示层 ——
/// 拖拽/armed/snap/refresh/done 的全部状态转移、位移(SizeTransition
/// 裁剪式滑出)、退场(缩放消失)都在同一个 State 里闭环。此前
/// 「RefreshIndicator.noSpinner + onStatusChange 外挂表现层」两版
/// 均翻车:SDK 的 onStatusChange 不通知 snap→refresh 与收尾→null
/// 两个转移,外挂层必然漏状态(卡半截/闪现),该路线已废弃。
///
/// 展示层:LoadingSpinner 圆片托底,随下拉从顶缘裁剪滑出(与原生
/// RefreshIndicator 同款揭示式入场,轻拉只露一条边,不会凭空出现
/// 完整小圆片),刷新中形状 morph 即加载状态,完成后缩放收没。
///
/// M3E 开关关闭时回退原生 [RefreshIndicator]。
class M3eRefreshIndicator extends StatefulWidget {
  final Widget child;
  final RefreshCallback onRefresh;
  final RefreshCallback? onSecondaryAction;
  final bool externalReveal;
  final double Function()? revealOffset;
  final Widget Function(BuildContext, double, bool, bool)?
  secondaryActionBuilder;

  /// 指示器顶部偏移(overlay 悬浮头部下方的列表用)。
  final double edgeOffset;

  /// 指示器悬停位(圆片顶边到 [edgeOffset] 的距离)。
  final double displacement;

  final ScrollNotificationPredicate notificationPredicate;

  const M3eRefreshIndicator({
    super.key,
    required this.child,
    required this.onRefresh,
    this.onSecondaryAction,
    this.externalReveal = false,
    this.revealOffset,
    this.secondaryActionBuilder,
    this.edgeOffset = 0.0,
    this.displacement = 40.0,
    this.notificationPredicate = defaultScrollNotificationPredicate,
  });

  @override
  State<M3eRefreshIndicator> createState() => M3eRefreshIndicatorState();
}

/// 对外状态:`GlobalKey<M3eRefreshIndicatorState>` + [show] 编程式触发,
/// 开关开/关两个分支都可用。
class M3eRefreshIndicatorState extends State<M3eRefreshIndicator> {
  final GlobalKey<RefreshIndicatorState> _fallbackKey =
      GlobalKey<RefreshIndicatorState>();
  final GlobalKey<_M3eRefreshCoreState> _coreKey =
      GlobalKey<_M3eRefreshCoreState>();

  bool get isRevealing => _coreKey.currentState?._ownsLeadingEdge ?? false;

  /// 编程式触发刷新(桌面端快捷键等)。
  Future<void> show({bool atTop = true}) {
    final core = _coreKey.currentState;
    if (core != null) return core.show(atTop: atTop);
    final fallback = _fallbackKey.currentState;
    if (fallback != null) return fallback.show(atTop: atTop);
    return widget.onRefresh();
  }

  @override
  Widget build(BuildContext context) {
    if (!M3eFlags.of(context).enabled && widget.onSecondaryAction == null) {
      return RefreshIndicator(
        key: _fallbackKey,
        onRefresh: widget.onRefresh,
        edgeOffset: widget.edgeOffset,
        displacement: widget.displacement,
        notificationPredicate: widget.notificationPredicate,
        child: widget.child,
      );
    }
    return _M3eRefreshCore(
      key: _coreKey,
      onRefresh: widget.onRefresh,
      edgeOffset: widget.edgeOffset,
      displacement: widget.displacement,
      notificationPredicate: widget.notificationPredicate,
      onSecondaryAction: widget.onSecondaryAction,
      externalReveal: widget.externalReveal,
      revealOffset: widget.revealOffset,
      secondaryActionBuilder: widget.secondaryActionBuilder,
      child: widget.child,
    );
  }
}

// ---- 以下为 SDK refresh_indicator.dart 的状态机移植(展示层已替换)----

/// 拖满(positionController=1)所需下拉距离占视口比例,同 SDK。
const double _kDragContainerExtentPercentage = 0.25;

/// 位移因子上限:滑出行程 = (displacement+圆片) × position × 1.5,同 SDK。
const double _kDragSizeFactorLimit = 1.5;

const Duration _kIndicatorSnapDuration = Duration(milliseconds: 150);
const Duration _kIndicatorScaleDuration = Duration(milliseconds: 200);

/// 指示器圆片直径。
const double _kBadgeSize = 44;

/// 圆片四周的阴影留白。elevation 阴影画在布局边界之外,而入场用的
/// SizeTransition 内部是 ClipRect,按布局尺寸硬裁——悬停态 sizeFactor
/// 恰好为 1.0,裁剪框底边压在圆片底边上,不留白阴影会被切出一条直线。
/// 同原生 RefreshProgressIndicator.indicatorMargin(4dp)的用途,
/// 这里 elevation 3 阴影更重,留 6dp。
const double _kBadgeShadowMargin = 6;

class _M3eRefreshCore extends StatefulWidget {
  final bool externalReveal;
  final double Function()? revealOffset;
  final Widget child;
  final RefreshCallback onRefresh;
  final double edgeOffset;
  final double displacement;
  final ScrollNotificationPredicate notificationPredicate;
  final RefreshCallback? onSecondaryAction;
  final Widget Function(BuildContext, double, bool, bool)?
  secondaryActionBuilder;

  const _M3eRefreshCore({
    super.key,
    required this.child,
    required this.onRefresh,
    required this.edgeOffset,
    required this.displacement,
    required this.notificationPredicate,
    this.onSecondaryAction,
    this.externalReveal = false,
    this.revealOffset,
    this.secondaryActionBuilder,
  });

  @override
  State<_M3eRefreshCore> createState() => _M3eRefreshCoreState();
}

class _M3eRefreshCoreState extends State<_M3eRefreshCore>
    with TickerProviderStateMixin
    implements RefreshRevealHandle {
  late final AnimationController _positionController;
  late final AnimationController _scaleController;
  late final Animation<double> _positionFactor;
  late final Animation<double> _scaleFactor;
  late final Animation<double> _opacity;

  RefreshIndicatorStatus? _status;
  late Future<void> _pendingRefreshFuture;
  bool? _isIndicatorAtTop;
  double? _dragOffset;
  bool _secondaryArmed = false;
  bool _secondaryOpening = false;
  bool _resumedDrag = false;
  double? _resumedVelocity;
  double _nativeOverscroll = 0;
  double? _lastDragY;
  VelocityTracker? _velocityTracker;
  int? _primaryPointer;
  int _transition = 0;
  int _secondarySession = 0;
  Completer<void>? _refreshCompleter;
  bool _resettingMode = false;
  bool get _ownsLeadingEdge =>
      widget.externalReveal &&
      ((_dragOffset ?? 0) > 0 ||
          _secondaryOpening ||
          (widget.revealOffset?.call() ?? 0) > 0);
  RefreshRevealGeometry? get _revealGeometry => widget.externalReveal
      ? RefreshRevealGeometry(
          viewportExtent: MediaQuery.sizeOf(context).height,
          topInset: MediaQuery.viewPaddingOf(context).top,
          contentExtent: 80 + MediaQuery.textScalerOf(context).scale(36),
        )
      : null;

  void _notifyReveal() {
    if (!widget.externalReveal || !mounted || _resettingMode) return;
    RefreshRevealNotification(
      _dragging ? (_dragOffset ?? 0) / 168 : _positionController.value,
      _secondaryArmed,
      _status == RefreshIndicatorStatus.refresh ||
          _status == RefreshIndicatorStatus.snap,
      dragging: _dragging && !_secondaryOpening,
      refreshArmed: _status == RefreshIndicatorStatus.armed,
      velocity:
          _resumedVelocity ??
          _velocityTracker?.getVelocity().pixelsPerSecond.dy ??
          0,
      geometry: _revealGeometry,
      handle: this,
    ).dispatch(context);
  }

  @override
  bool get canResumeDrag =>
      mounted &&
      widget.externalReveal &&
      widget.onSecondaryAction != null &&
      _status != RefreshIndicatorStatus.snap &&
      _status != RefreshIndicatorStatus.refresh;

  @override
  double get resumeExtent =>
      mounted ? (_revealGeometry?.secondaryExtent ?? 0) : 0;

  @override
  void beginResumedDrag(double visibleOffset) {
    if (!canResumeDrag) return;
    // 旧二楼 Future 及刷新退场动画都失去收尾权，不能清掉新拖动。
    _secondarySession++;
    _transition++;
    _positionController.stop();
    _scaleController.stop();
    _secondaryOpening = false;
    _secondaryArmed = false;
    _resumedDrag = true;
    _resumedVelocity = 0;
    _primaryPointer = null;
    _velocityTracker = null;
    _lastDragY = null;
    _nativeOverscroll = 0;
    _isIndicatorAtTop = true;
    _status = RefreshIndicatorStatus.drag;
    _scaleController.value = 0;
    _updateTwoStageOffset(_revealGeometry!.distanceFor(visibleOffset));
  }

  @override
  void updateResumedDrag(double delta) {
    if (!canResumeDrag || !_resumedDrag) return;
    _updateTwoStageOffset(((_dragOffset ?? 0) + delta).clamp(0.0, 1000.0));
  }

  @override
  void endResumedDrag(double velocity) {
    if (!mounted || !_resumedDrag) return;
    _resumedDrag = false;
    _resumedVelocity = velocity;
    _releaseTwoStage();
  }

  @override
  void cancelResumedDrag() {
    if (!mounted || !_resumedDrag) return;
    _resumedDrag = false;
    _resumedVelocity = 0;
    _dismiss(RefreshIndicatorStatus.canceled);
  }

  bool get _dragging =>
      _status == RefreshIndicatorStatus.drag ||
      _status == RefreshIndicatorStatus.armed;

  bool _handleTwoStageScroll(ScrollNotification notification) {
    if (!widget.notificationPredicate(notification)) return false;
    if (_resumedDrag || _secondaryOpening) return false;
    // The outer sheet moves the entire page. Cancel the list's own bounce so
    // the toolbar and content travel together, including ballistic recovery.
    if (widget.externalReveal &&
        notification.metrics.axisDirection == AxisDirection.down) {
      final overscroll =
          (notification.metrics.minScrollExtent - notification.metrics.pixels)
              .clamp(0.0, double.infinity);
      if (_nativeOverscroll != overscroll) {
        setState(() => _nativeOverscroll = overscroll);
      }
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null &&
        notification.metrics.axisDirection == AxisDirection.down &&
        notification.metrics.extentBefore == 0 &&
        (_status == null ||
            (widget.externalReveal &&
                (_status == RefreshIndicatorStatus.canceled ||
                    _status == RefreshIndicatorStatus.done))) &&
        !_secondaryOpening) {
      _transition++;
      _positionController.stop();
      _status = null;
      _isIndicatorAtTop = null;
      _dragOffset = null;
      _secondaryArmed = false;
      _resumedVelocity = null;
      _nativeOverscroll = 0;
      _lastDragY = notification.dragDetails!.globalPosition.dy;
      _start(AxisDirection.down);
      setState(() => _status = RefreshIndicatorStatus.drag);
      _updateTwoStageOffset(_dragOffset!);
      return false;
    }
    if (!_dragging) return false;
    if (notification.metrics.axisDirection != AxisDirection.down ||
        notification.metrics.extentBefore > 0) {
      _dismiss(RefreshIndicatorStatus.canceled);
      return false;
    }
    double? delta;
    if (notification is ScrollUpdateNotification) {
      if (notification.dragDetails == null) {
        _releaseTwoStage();
        return false;
      }
      final y = notification.dragDetails!.globalPosition.dy;
      delta = y - (_lastDragY ?? y);
      _lastDragY = y;
    } else if (notification is OverscrollNotification) {
      if (notification.dragDetails == null) {
        _releaseTwoStage();
        return false;
      }
      // A clamping scroll can emit both update and overscroll for one pointer
      // move. Global pointer position counts that move once, and keeps physical
      // pull thresholds identical under clamping and bouncing physics.
      final y = notification.dragDetails!.globalPosition.dy;
      delta = y - (_lastDragY ?? y);
      _lastDragY = y;
    } else if (notification is ScrollEndNotification) {
      _releaseTwoStage();
      return false;
    }
    if (delta != null) {
      final offset = ((_dragOffset ?? 0) + delta).clamp(0.0, 1000.0);
      _nativeOverscroll =
          (notification.metrics.minScrollExtent - notification.metrics.pixels)
              .clamp(0.0, double.infinity);
      _updateTwoStageOffset(offset);
    }
    return false;
  }

  void _updateTwoStageOffset(double offset) {
    final wasSecondary = _secondaryArmed;
    final geometry = _revealGeometry;
    final visibleOffset = geometry?.offsetFor(offset) ?? offset;
    final refreshThreshold = geometry?.refreshExtent ?? 72;
    final secondaryThreshold = geometry?.secondaryExtent ?? 168;
    setState(() {
      _dragOffset = offset;
      if (visibleOffset >= secondaryThreshold) _secondaryArmed = true;
      if (visibleOffset < secondaryThreshold - 20) _secondaryArmed = false;
      if (visibleOffset >= refreshThreshold) {
        _status = RefreshIndicatorStatus.armed;
      }
      if (visibleOffset < refreshThreshold - 16) {
        _status = RefreshIndicatorStatus.drag;
      }
      _positionController.value = (offset / 168).clamp(
        0.0,
        widget.externalReveal ? 4.0 : 1.0,
      );
    });
    _notifyReveal();
    if (!wasSecondary && _secondaryArmed) HapticFeedback.lightImpact();
  }

  void _releaseTwoStage() {
    if (!_dragging || _secondaryOpening) return;
    _notifyReveal();
    if (_secondaryArmed && widget.onSecondaryAction != null) {
      _secondaryOpening = true;
      final session = ++_secondarySession;
      // The parent continues from the current drag position. Keep this frame
      // held until it returns, instead of retracting before opening a route.
      // 外层已经持有当前位移，当次松手直接交接，不再延后一轮事件循环。
      unawaited(() async {
        try {
          if (!widget.externalReveal) {
            await _dismiss(RefreshIndicatorStatus.canceled);
          }
          if (mounted) await widget.onSecondaryAction?.call();
        } finally {
          if (mounted && session == _secondarySession) {
            if (widget.externalReveal) {
              // The parent has already returned its surface to zero. Clear the
              // entire gesture before changing the animation value: its listener
              // must never publish the old deep-pull distance as a new drag.
              setState(() {
                _status = null;
                _dragOffset = null;
                _isIndicatorAtTop = null;
                _nativeOverscroll = 0;
                _lastDragY = null;
                _secondaryArmed = false;
              });
              _positionController.stop();
              _positionController.value = 0;
            }
            _secondaryOpening = false;
            _notifyReveal();
          }
        }
      }());
    } else if (_status == RefreshIndicatorStatus.armed) {
      _show();
    } else {
      _dismiss(RefreshIndicatorStatus.canceled);
    }
  }

  @override
  void initState() {
    super.initState();
    _positionController = AnimationController(
      vsync: this,
      // 预留二楼行程，开关变化时无需重建控制器或列表子树。
      upperBound: 4,
    );
    _positionController.addListener(_notifyReveal);
    _positionFactor = _positionController.drive(
      Tween<double>(begin: 0.0, end: _kDragSizeFactorLimit),
    );
    // 入场淡入:position 到达 armed 阈值(1/1.5)时不透明度拉满,
    // 对应 SDK 的 valueColor alpha 渐变。
    _opacity = _positionController.drive(
      CurveTween(curve: const Interval(0.0, 1.0 / _kDragSizeFactorLimit)),
    );
    _scaleController = AnimationController(vsync: this);
    _scaleFactor = _scaleController.drive(Tween<double>(begin: 1.0, end: 0.0));
  }

  @override
  void didUpdateWidget(_M3eRefreshCore oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.externalReveal == oldWidget.externalReveal &&
        (widget.onSecondaryAction == null) ==
            (oldWidget.onSecondaryAction == null)) {
      return;
    }
    // 切回普通刷新时保留列表子树，只清掉旧的双阶段手势与异步回调。
    _resettingMode = true;
    _transition++;
    _secondarySession++;
    _resumedDrag = false;
    _resumedVelocity = null;
    _positionController.stop();
    _scaleController.stop();
    _status = null;
    _dragOffset = null;
    _isIndicatorAtTop = null;
    _secondaryArmed = _secondaryOpening = false;
    _nativeOverscroll = 0;
    _lastDragY = null;
    _primaryPointer = null;
    _velocityTracker = null;
    _positionController.value = 0;
    _scaleController.value = 0;
    if (_refreshCompleter?.isCompleted == false) _refreshCompleter!.complete();
    _refreshCompleter = null;
    _resettingMode = false;
  }

  @override
  void dispose() {
    if (_refreshCompleter?.isCompleted == false) _refreshCompleter!.complete();
    _positionController.dispose();
    _scaleController.dispose();
    super.dispose();
  }

  bool _shouldStart(ScrollNotification notification) {
    // 仅边缘触发(SDK triggerMode.onEdge):手指驱动的 ScrollStart,
    // 且列表已贴相应边缘,且当前空闲。
    return notification is ScrollStartNotification &&
        notification.dragDetails != null &&
        ((notification.metrics.axisDirection == AxisDirection.up &&
                notification.metrics.extentAfter == 0.0) ||
            (notification.metrics.axisDirection == AxisDirection.down &&
                notification.metrics.extentBefore == 0.0)) &&
        _status == null &&
        _start(notification.metrics.axisDirection);
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (widget.onSecondaryAction != null) {
      return _handleTwoStageScroll(notification);
    }
    if (!widget.notificationPredicate(notification)) return false;
    if (_shouldStart(notification)) {
      setState(() => _status = RefreshIndicatorStatus.drag);
      return false;
    }
    final bool? indicatorAtTopNow =
        switch (notification.metrics.axisDirection) {
          AxisDirection.down || AxisDirection.up => true,
          AxisDirection.left || AxisDirection.right => null,
        };
    if (indicatorAtTopNow != _isIndicatorAtTop) {
      if (_status == RefreshIndicatorStatus.drag ||
          _status == RefreshIndicatorStatus.armed) {
        _dismiss(RefreshIndicatorStatus.canceled);
      }
    } else if (notification is ScrollUpdateNotification) {
      if (_status == RefreshIndicatorStatus.drag ||
          _status == RefreshIndicatorStatus.armed) {
        if (notification.metrics.axisDirection == AxisDirection.down) {
          _dragOffset = _dragOffset! - notification.scrollDelta!;
        } else if (notification.metrics.axisDirection == AxisDirection.up) {
          _dragOffset = _dragOffset! + notification.scrollDelta!;
        }
        _checkDragOffset(notification.metrics.viewportDimension);
      }
      if (_status == RefreshIndicatorStatus.armed &&
          notification.dragDetails == null) {
        // 手指已离开但滚动还在 ballistic:直接进入刷新。
        _show();
      }
    } else if (notification is OverscrollNotification) {
      if (_status == RefreshIndicatorStatus.drag ||
          _status == RefreshIndicatorStatus.armed) {
        if (notification.metrics.axisDirection == AxisDirection.down) {
          _dragOffset = _dragOffset! - notification.overscroll;
        } else if (notification.metrics.axisDirection == AxisDirection.up) {
          _dragOffset = _dragOffset! + notification.overscroll;
        }
        _checkDragOffset(notification.metrics.viewportDimension);
      }
    } else if (notification is ScrollEndNotification) {
      switch (_status) {
        case RefreshIndicatorStatus.armed:
          if (_positionController.value < 1.0) {
            _dismiss(RefreshIndicatorStatus.canceled);
          } else {
            _show();
          }
        case RefreshIndicatorStatus.drag:
          _dismiss(RefreshIndicatorStatus.canceled);
        case RefreshIndicatorStatus.canceled:
        case RefreshIndicatorStatus.done:
        case RefreshIndicatorStatus.refresh:
        case RefreshIndicatorStatus.snap:
        case null:
          break;
      }
    }
    return false;
  }

  bool _handleIndicatorNotification(
    OverscrollIndicatorNotification notification,
  ) {
    if (notification.depth != 0) return false;
    // A held reverse drag reports positive overscroll even at the leading
    // edge. Suppress both platform stretch directions while the sheet owns it.
    if ((widget.externalReveal &&
            widget.onSecondaryAction != null &&
            (notification.leading || _ownsLeadingEdge)) ||
        (notification.leading && _status == RefreshIndicatorStatus.drag)) {
      notification.disallowIndicator();
      return true;
    }
    return false;
  }

  bool _start(AxisDirection direction) {
    assert(_status == null);
    assert(_isIndicatorAtTop == null);
    assert(_dragOffset == null);
    switch (direction) {
      case AxisDirection.down:
      case AxisDirection.up:
        _isIndicatorAtTop = true;
      case AxisDirection.left:
      case AxisDirection.right:
        _isIndicatorAtTop = null;
        return false;
    }
    _dragOffset =
        _revealGeometry?.distanceFor(widget.revealOffset?.call() ?? 0) ?? 0;
    _scaleController.value = 0.0;
    _positionController.value = 0.0;
    return true;
  }

  void _checkDragOffset(double containerExtent) {
    assert(
      _status == RefreshIndicatorStatus.drag ||
          _status == RefreshIndicatorStatus.armed,
    );
    double newValue =
        _dragOffset! / (containerExtent * _kDragContainerExtentPercentage);
    if (_status == RefreshIndicatorStatus.armed) {
      newValue = newValue.clamp(1.0 / _kDragSizeFactorLimit, double.infinity);
    }
    _positionController.value = newValue.clamp(0.0, 1.0);
    if (_status == RefreshIndicatorStatus.drag &&
        _positionController.value >= 1.0 / _kDragSizeFactorLimit) {
      _status = RefreshIndicatorStatus.armed;
      // 过阈值的"武装"时刻给一次轻触感:松手即刷新的信号。
      HapticFeedback.lightImpact();
    }
  }

  Future<void> _dismiss(RefreshIndicatorStatus newMode) async {
    final transition = ++_transition;
    await Future<void>.value();
    if (!mounted || transition != _transition) return;
    assert(
      newMode == RefreshIndicatorStatus.canceled ||
          newMode == RefreshIndicatorStatus.done,
    );
    setState(() => _status = newMode);
    _notifyReveal();
    try {
      final scaleOut =
          newMode == RefreshIndicatorStatus.done && !widget.externalReveal;
      await (scaleOut ? _scaleController : _positionController)
          .animateTo(scaleOut ? 1 : 0, duration: _kIndicatorScaleDuration)
          .orCancel;
    } on TickerCanceled {
      return;
    }
    if (mounted && transition == _transition && _status == newMode) {
      _dragOffset = null;
      _isIndicatorAtTop = null;
      _nativeOverscroll = 0;
      _lastDragY = null;
      _secondaryArmed = false;
      setState(() => _status = null);
    }
  }

  void _show() {
    if (_status == RefreshIndicatorStatus.refresh ||
        _status == RefreshIndicatorStatus.snap) {
      return;
    }
    final transition = ++_transition;
    _secondaryArmed = false;
    assert(_status != RefreshIndicatorStatus.refresh);
    assert(_status != RefreshIndicatorStatus.snap);
    final completer = Completer<void>();
    _refreshCompleter = completer;
    _pendingRefreshFuture = completer.future;
    _status = RefreshIndicatorStatus.snap;
    _notifyReveal();
    _positionController
        .animateTo(
          1.0 / _kDragSizeFactorLimit,
          duration: _kIndicatorSnapDuration,
        )
        .then<void>((void value) {
          if (mounted &&
              transition == _transition &&
              _status == RefreshIndicatorStatus.snap) {
            setState(() => _status = RefreshIndicatorStatus.refresh);
            final refreshResult = widget.onRefresh();
            refreshResult.whenComplete(() {
              if (!completer.isCompleted) completer.complete();
              if (mounted &&
                  transition == _transition &&
                  _status == RefreshIndicatorStatus.refresh) {
                _dismiss(RefreshIndicatorStatus.done);
              }
            });
          }
        });
  }

  Future<void> show({bool atTop = true}) {
    // A committed secondary action owns this gesture until its route returns.
    // Do not interrupt its dismissal animation with a shortcut refresh.
    if (_secondaryOpening) return Future<void>.value();
    if (_status != RefreshIndicatorStatus.refresh &&
        _status != RefreshIndicatorStatus.snap) {
      if (_status == null) {
        _start(atTop ? AxisDirection.down : AxisDirection.up);
      }
      _show();
    }
    return _pendingRefreshFuture;
  }

  @override
  Widget build(BuildContext context) {
    final Widget child = Listener(
      onPointerDown: (event) {
        if (widget.onSecondaryAction == null || _primaryPointer != null) return;
        _primaryPointer = event.pointer;
        _velocityTracker = VelocityTracker.withKind(event.kind)
          ..addPosition(event.timeStamp, event.position);
      },
      onPointerMove: (event) {
        if (event.pointer == _primaryPointer) {
          _velocityTracker?.addPosition(event.timeStamp, event.position);
        }
      },
      onPointerUp: (event) {
        if (event.pointer != _primaryPointer) return;
        _velocityTracker?.addPosition(event.timeStamp, event.position);
        if (widget.onSecondaryAction != null) _releaseTwoStage();
        _primaryPointer = null;
      },
      onPointerCancel: (event) {
        if (event.pointer != _primaryPointer) return;
        _primaryPointer = null;
        _velocityTracker = null;
        if (widget.onSecondaryAction != null && _dragging) {
          _dismiss(RefreshIndicatorStatus.canceled);
        }
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: NotificationListener<OverscrollIndicatorNotification>(
          onNotification: _handleIndicatorNotification,
          child: widget.child,
        ),
      ),
    );
    assert(() {
      if (_status == null) {
        assert(_dragOffset == null);
        assert(_isIndicatorAtTop == null);
      } else {
        assert(_dragOffset != null);
        assert(_isIndicatorAtTop != null);
      }
      return true;
    }());

    // 与 SDK 同构:**永远**返回 Stack,指示器只是条件加入的第二个
    // child。绝不能在 _status==null 时裸返回 child —— drag 状态在
    // "列表在顶+手指拖动"就会翻转,树根形状随之改变会把整个列表
    // 子树拆掉重建(滚动位置归零、KeepAlive/GlobalKey 重挂报错)。
    return Stack(
      children: <Widget>[
        if (widget.onSecondaryAction != null &&
            widget.secondaryActionBuilder != null)
          Positioned(
            top: widget.edgeOffset,
            left: 0,
            right: 0,
            child: AnimatedBuilder(
              animation: _positionController,
              builder: (context, _) => ClipRect(
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: _positionController.value,
                  child: SizedBox(
                    height: 150,
                    child: widget.secondaryActionBuilder!(
                      context,
                      _positionController.value,
                      _secondaryArmed,
                      _status == RefreshIndicatorStatus.refresh ||
                          _status == RefreshIndicatorStatus.snap,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ClipRect(
          child: AnimatedBuilder(
            animation: _positionController,
            child: child,
            builder: (context, child) => Transform.translate(
              offset: Offset(
                0,
                widget.onSecondaryAction == null
                    ? 0
                    : widget.externalReveal
                    ? -_nativeOverscroll
                    : (150 * _positionController.value - _nativeOverscroll)
                          .clamp(0.0, 150.0),
              ),
              child: child,
            ),
          ),
        ),
        if (_status != null && widget.onSecondaryAction == null)
          Positioned(
            top: _isIndicatorAtTop! ? widget.edgeOffset : null,
            bottom: !_isIndicatorAtTop! ? widget.edgeOffset : null,
            left: 0.0,
            right: 0.0,
            // SizeTransition 裁剪式揭示:轻拉只露圆片一条边,与原生同款。
            child: SizeTransition(
              alignment: AlignmentDirectional(
                -1.0,
                _isIndicatorAtTop! ? 1.0 : -1.0,
              ),
              sizeFactor: _positionFactor,
              child: Padding(
                // 扣掉圆片自带的阴影留白,保持"圆片顶边距 edgeOffset 为
                // displacement"的语义不变。
                padding: _isIndicatorAtTop!
                    ? EdgeInsets.only(
                        top: (widget.displacement - _kBadgeShadowMargin).clamp(
                          0.0,
                          double.infinity,
                        ),
                      )
                    : EdgeInsets.only(
                        bottom: (widget.displacement - _kBadgeShadowMargin)
                            .clamp(0.0, double.infinity),
                      ),
                child: Align(
                  alignment: _isIndicatorAtTop!
                      ? Alignment.topCenter
                      : Alignment.bottomCenter,
                  child: ScaleTransition(
                    scale: _scaleFactor,
                    child: FadeTransition(
                      opacity: _opacity,
                      child: const _SpinnerBadge(size: _kBadgeSize),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 加载器托底容器:surfaceContainerHigh 圆片 + 阴影,任意内容上可读。
/// 四周留 [_kBadgeShadowMargin] 吸收阴影,布局尺寸为
/// size + 2 × [_kBadgeShadowMargin]。
class _SpinnerBadge extends StatelessWidget {
  final double size;

  const _SpinnerBadge({required this.size});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(_kBadgeShadowMargin),
      child: Material(
        elevation: 3,
        shape: context.shapes.circle(),
        color: scheme.surfaceContainerHigh,
        shadowColor: scheme.shadow.withValues(alpha: 0.6),
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            // 宿主可替换加载动画（例如节日图案）
            child:
                UiDecor.maybeOf(context)?.loadingIndicator?.call(
                  context,
                  size - 18,
                ) ??
                LoadingSpinner(size: size - 18),
          ),
        ),
      ),
    );
  }
}
