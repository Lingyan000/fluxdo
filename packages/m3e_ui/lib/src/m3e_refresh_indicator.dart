import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'loading_spinner.dart';
import 'm3e_flags.dart';

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

  /// 指示器顶部偏移(overlay 悬浮头部下方的列表用)。
  final double edgeOffset;

  /// 指示器悬停位(圆片顶边到 [edgeOffset] 的距离)。
  final double displacement;

  final ScrollNotificationPredicate notificationPredicate;

  const M3eRefreshIndicator({
    super.key,
    required this.child,
    required this.onRefresh,
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
    if (!M3eFlags.of(context).enabled) {
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

class _M3eRefreshCore extends StatefulWidget {
  final Widget child;
  final RefreshCallback onRefresh;
  final double edgeOffset;
  final double displacement;
  final ScrollNotificationPredicate notificationPredicate;

  const _M3eRefreshCore({
    super.key,
    required this.child,
    required this.onRefresh,
    required this.edgeOffset,
    required this.displacement,
    required this.notificationPredicate,
  });

  @override
  State<_M3eRefreshCore> createState() => _M3eRefreshCoreState();
}

class _M3eRefreshCoreState extends State<_M3eRefreshCore>
    with TickerProviderStateMixin {
  late final AnimationController _positionController;
  late final AnimationController _scaleController;
  late final Animation<double> _positionFactor;
  late final Animation<double> _scaleFactor;
  late final Animation<double> _opacity;

  RefreshIndicatorStatus? _status;
  late Future<void> _pendingRefreshFuture;
  bool? _isIndicatorAtTop;
  double? _dragOffset;

  @override
  void initState() {
    super.initState();
    _positionController = AnimationController(vsync: this);
    _positionFactor = _positionController.drive(
      Tween<double>(begin: 0.0, end: _kDragSizeFactorLimit),
    );
    // 入场淡入:position 到达 armed 阈值(1/1.5)时不透明度拉满,
    // 对应 SDK 的 valueColor alpha 渐变。
    _opacity = _positionController.drive(
      CurveTween(curve: const Interval(0.0, 1.0 / _kDragSizeFactorLimit)),
    );
    _scaleController = AnimationController(vsync: this);
    _scaleFactor = _scaleController.drive(
      Tween<double>(begin: 1.0, end: 0.0),
    );
  }

  @override
  void dispose() {
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
    if (!widget.notificationPredicate(notification)) return false;
    if (_shouldStart(notification)) {
      setState(() => _status = RefreshIndicatorStatus.drag);
      return false;
    }
    final bool? indicatorAtTopNow = switch (notification.metrics.axisDirection) {
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
    if (notification.depth != 0 || !notification.leading) return false;
    if (_status == RefreshIndicatorStatus.drag) {
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
    _dragOffset = 0.0;
    _scaleController.value = 0.0;
    _positionController.value = 0.0;
    return true;
  }

  void _checkDragOffset(double containerExtent) {
    assert(_status == RefreshIndicatorStatus.drag ||
        _status == RefreshIndicatorStatus.armed);
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
    await Future<void>.value();
    assert(newMode == RefreshIndicatorStatus.canceled ||
        newMode == RefreshIndicatorStatus.done);
    setState(() => _status = newMode);
    switch (_status!) {
      case RefreshIndicatorStatus.done:
        await _scaleController.animateTo(
          1.0,
          duration: _kIndicatorScaleDuration,
        );
      case RefreshIndicatorStatus.canceled:
        await _positionController.animateTo(
          0.0,
          duration: _kIndicatorScaleDuration,
        );
      case RefreshIndicatorStatus.armed:
      case RefreshIndicatorStatus.drag:
      case RefreshIndicatorStatus.refresh:
      case RefreshIndicatorStatus.snap:
        assert(false);
    }
    if (mounted && _status == newMode) {
      _dragOffset = null;
      _isIndicatorAtTop = null;
      setState(() => _status = null);
    }
  }

  void _show() {
    assert(_status != RefreshIndicatorStatus.refresh);
    assert(_status != RefreshIndicatorStatus.snap);
    final completer = Completer<void>();
    _pendingRefreshFuture = completer.future;
    _status = RefreshIndicatorStatus.snap;
    _positionController
        .animateTo(
      1.0 / _kDragSizeFactorLimit,
      duration: _kIndicatorSnapDuration,
    )
        .then<void>((void value) {
      if (mounted && _status == RefreshIndicatorStatus.snap) {
        setState(() => _status = RefreshIndicatorStatus.refresh);
        final refreshResult = widget.onRefresh();
        refreshResult.whenComplete(() {
          if (mounted && _status == RefreshIndicatorStatus.refresh) {
            completer.complete();
            _dismiss(RefreshIndicatorStatus.done);
          }
        });
      }
    });
  }

  Future<void> show({bool atTop = true}) {
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
    final Widget child = NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: NotificationListener<OverscrollIndicatorNotification>(
        onNotification: _handleIndicatorNotification,
        child: widget.child,
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
        child,
        if (_status != null)
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
                padding: _isIndicatorAtTop!
                    ? EdgeInsets.only(top: widget.displacement)
                    : EdgeInsets.only(bottom: widget.displacement),
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
class _SpinnerBadge extends StatelessWidget {
  final double size;

  const _SpinnerBadge({required this.size});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 3,
      shape: const CircleBorder(),
      color: scheme.surfaceContainerHigh,
      shadowColor: scheme.shadow.withValues(alpha: 0.6),
      child: SizedBox(
        width: size,
        height: size,
        child: Center(child: LoadingSpinner(size: size - 18)),
      ),
    );
  }
}
