import 'dart:async';
import 'dart:math' as math;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/preferences_provider.dart';
import '../../../widgets/common/radial_long_press_menu.dart';
import 'progress_gesture_action_meta.dart';
import '../controllers/topic_position_info.dart';
import 'topic_bottom_bar.dart';
import 'topic_progress_track.dart';
import 'topic_scrub_indicator.dart';
import 'topic_scrub_mapping.dart';

/// 上滑触发阈值（手指相对起点的距离 ≥ 此值即视为可触发）
const double _kSwipeTriggerDistance = 56.0;

/// 屏幕左右边缘留给系统返回 / 路由侧滑返回的最小宽度（路由侧滑的
/// 起手区约 20）；系统声明的手势区更宽时以系统为准
const double _kEdgeGuardMin = 20.0;

/// 话题底栏手势层：整条栏都是手势面，不绑定某个具体控件，布局不受约束。
///
/// - 横向拖动：拖动定位楼层（映射见 [TopicScrubTracker]），跟手气泡
///   预览目标楼层，松手跳转；起手落在屏幕边缘手势区时让给系统
/// - 上滑：可配置动作（[AppPreferences.progressGestureSwipeUp]）
/// - 长按：在手指位置展开半圆菜单，贴边时扇形自动旋转朝向屏幕内侧
/// - 点按交给栏内各控件自己处理；总开关关闭时本组件退化为透传
class TopicBarGestures extends ConsumerStatefulWidget {
  const TopicBarGestures({
    super.key,
    required this.child,
    required this.onAction,
    required this.streamIndexListenable,
    required this.totalCount,
    required this.scrubIndexNotifier,
    required this.onScrubCommit,
    this.infoSource,
    this.onScrubStart,
    this.markerIndex,
  });

  final Widget child;

  /// 上滑与长按菜单触发的动作
  final ValueChanged<ProgressGestureAction> onAction;

  /// 当前楼层（stream 索引，1 起），拖动起点
  final ValueListenable<int> streamIndexListenable;
  final int totalCount;
  final int? markerIndex;

  /// 拖动中的目标楼层，由本组件写入（null = 未在拖动），栏内进度读取
  final ValueNotifier<int?> scrubIndexNotifier;

  /// 松手且目标与起点不同时回调
  final ValueChanged<int> onScrubCommit;

  /// 目标楼层的日期与摘要来源；摘要异步拉到后气泡自动刷新
  final TopicPositionInfoSource? infoSource;

  /// 拖动开始（用于收起首次引导等）
  final VoidCallback? onScrubStart;

  @override
  ConsumerState<TopicBarGestures> createState() => _TopicBarGesturesState();
}

class _TopicBarGesturesState extends ConsumerState<TopicBarGestures>
    with TickerProviderStateMixin {
  // 长按菜单会话（overlay 生命周期 + 高亮命中 + 触觉反馈）
  final RadialMenuSession _menuSession = RadialMenuSession();

  /// 栏内有回复入口、楼层计数等点按目标，长按阈值不能太短：从容的单击
  /// 常超 200ms，会被误判成长按吞掉（与 [RadialLongPressMenu] 同一取值）
  static const Duration _longPressTimeout = Duration(milliseconds: 420);

  /// 当前帧的左右边缘手势区（build 时由 MediaQuery 取得）
  double _edgeLeft = _kEdgeGuardMin;
  double _edgeRight = _kEdgeGuardMin;
  double _screenWidth = 0;
  bool _reduceMotion = false;
  bool _floating = false;
  EdgeInsets _railInsets = EdgeInsets.zero;

  // ===== 拖动定位状态 =====
  OverlayEntry? _scrubEntry;
  late final AnimationController _scrubFade;
  late final _thumbMotion = TopicThumbMotion(this);
  TopicPositionInfoSource? _scrubSource;
  Rect? _barRect;
  int _scrubStartIndex = 1;
  int _scrubTarget = 1;
  TopicScrubTracker? _tracker;
  Axis? _scrubAxis;
  double _anchorExpansion = 0;
  double _anchorProgress = 0;
  Offset _scrubOrigin = Offset.zero;
  Offset _pointer = Offset.zero;
  Offset _verticalDown = Offset.zero;
  Duration _lastHapticTime = Duration.zero;

  /// 逐楼触觉的最小间隔：快速划动时不连成持续震动
  static const Duration _hapticInterval = Duration(milliseconds: 35);

  /// 气泡里显示摘要的楼层：目标停留一小段时间才跟上，快速划动时摘要
  /// 不逐楼闪烁，也不为途经的每一楼拉取摘要
  int _excerptIndex = 1;
  Timer? _excerptTimer;
  static const Duration _excerptSettle = Duration(milliseconds: 160);

  // ===== 上滑状态 =====
  OverlayEntry? _swipeEntry;
  Offset? _swipeStart;
  Offset _swipeCurrent = Offset.zero;
  ProgressGestureAction? _swipeAction;
  bool _swipeTriggerable = false;

  @override
  void initState() {
    super.initState();
    _scrubFade = AnimationController(
      vsync: this,
      duration: TopicProgressTrack.openDuration,
      reverseDuration: TopicProgressTrack.closeDuration,
    );
  }

  @override
  void dispose() {
    _menuSession.dispose();
    // 卸载期不回写 scrubIndexNotifier：监听它的兄弟节点可能同批卸载
    if (_scrubAxis != null) _scrubSource?.removeListener(_refreshScrubOverlay);
    _scrubAxis = null;
    _discardScrubEntry();
    _scrubFade.dispose();
    _thumbMotion.dispose();
    _excerptTimer?.cancel();
    _removeSwipeOverlay();
    super.dispose();
  }

  Rect? _globalRect() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  bool _isOutsideEdgeZones(Offset globalPosition) =>
      globalPosition.dx >= _edgeLeft &&
      globalPosition.dx <= _screenWidth - _edgeRight;

  // ===== 长按菜单 =====

  void _handleLongPressStart(
    LongPressStartDetails details,
    AppPreferences prefs,
  ) {
    if (!prefs.progressGestureLongPressEnabled) return;
    final actions = prefs.progressGestureMenuActions;
    if (actions.isEmpty) return;
    final rect = _globalRect();
    if (rect == null) return;

    final items = [
      for (final action in actions)
        () {
          final meta = progressGestureActionMeta(context, action);
          return RadialMenuItem(
            icon: meta.icon,
            label: meta.label,
            onSelected: () => widget.onAction(action),
          );
        }(),
    ];

    // 圆心钉在手指正上方的栏顶边；扇形窗口按圆心到屏幕两侧的余量求解
    final anchorX = details.globalPosition.dx.clamp(rect.left, rect.right);
    final mq = MediaQuery.of(context);
    final (:radius, :sweepStart, :sweepEnd) = solveRadialFanWindow(
      itemCount: items.length,
      anchorX: anchorX,
      screenWidth: mq.size.width,
      anchorY: rect.top,
      screenHeight: mq.size.height,
      safePadding: mq.padding,
    );
    _menuSession.open(
      context: context,
      center: Offset(anchorX, rect.top),
      // 按压指示画在手指处（不是整条栏），同时作为起手死区
      pressArea: Rect.fromCenter(
        center: Offset(anchorX, rect.center.dy),
        width: 56,
        height: math.min(40, rect.height),
      ),
      items: items,
      radius: radius,
      sweepStart: sweepStart,
      sweepEnd: sweepEnd,
    );
    _menuSession.updatePointer(details.globalPosition);
  }

  // ===== 拖动定位 =====

  double _railWidth(Rect rect) =>
      math.max(1, rect.width - _railInsets.horizontal);

  bool _nearHandle(Rect rect, Offset point) {
    final surface = _floating
        ? TopicProgressSurface.floating
        : TopicProgressSurface.docked;
    final t = TopicProgressTrack.curve.transform(_scrubFade.value);
    final left = surface.insetAt(_railInsets.left, t);
    final right = rect.width - surface.insetAt(_railInsets.right, t);
    final handle = left + (right - left) * _trackProgress(t);
    // 细线延伸到屏幕边缘，首末楼仍可从系统返回区以内抓住。
    final reachable = handle.clamp(
      _railInsets.left,
      _railInsets.left + _railWidth(rect),
    );
    return (point.dx - rect.left - reachable).abs() <= 22;
  }

  double _trackProgress(double expansion) {
    final reading = TopicProgressTrack.fraction(
      widget.streamIndexListenable.value,
      widget.totalCount,
    );
    final tracker = _tracker;
    if (tracker == null) return reading;
    final opening = _scrubAxis != null;
    final target = opening ? tracker.thumbX / tracker.surfaceWidth : reading;
    final remaining = opening ? 1 - _anchorExpansion : _anchorExpansion;
    if (remaining == 0) return target;
    final travel = ((expansion - _anchorExpansion).abs() / remaining).clamp(
      0.0,
      1.0,
    );
    return _anchorProgress + (target - _anchorProgress) * travel;
  }

  // 在动画中松手或重新抓住时，从屏上握柄的实际位置继续。
  void _anchorTrack() {
    final expansion = TopicProgressTrack.curve.transform(_scrubFade.value);
    _anchorProgress = _trackProgress(expansion);
    _anchorExpansion = expansion;
  }

  void _startScrub(Offset origin, Axis axis) {
    final rect = _globalRect();
    if (rect == null || widget.totalCount <= 1 || _scrubAxis != null) return;
    _anchorTrack();
    _thumbMotion.reset();
    _barRect = rect;
    _scrubOrigin = _pointer = origin;
    _scrubAxis = axis;
    _scrubStartIndex = widget.streamIndexListenable.value.clamp(
      1,
      widget.totalCount,
    );
    _tracker = TopicScrubTracker(
      startIndex: _scrubStartIndex,
      totalCount: widget.totalCount,
      surfaceWidth: _railWidth(rect),
      startX: origin.dx - rect.left - _railInsets.left,
    );
    _scrubTarget = _excerptIndex = _tracker!.index;
    _lastHapticTime = Duration.zero;
    widget.scrubIndexNotifier.value = _scrubTarget;
    widget.onScrubStart?.call();

    _scrubSource = widget.infoSource;
    _scrubSource?.addListener(_refreshScrubOverlay);
    if (_scrubEntry == null) {
      _scrubEntry = OverlayEntry(builder: (_) => _buildScrubOverlay());
      Overlay.of(context, rootOverlay: true).insert(_scrubEntry!);
      setState(() {});
    } else {
      _scrubEntry!.markNeedsBuild();
    }
    if (_reduceMotion) {
      _scrubFade.value = 1;
    } else {
      _scrubFade.forward();
    }
    HapticFeedback.selectionClick();
  }

  void _handleScrubUpdate(DragUpdateDetails details) {
    final tracker = _tracker;
    final rect = _barRect;
    if (_scrubAxis == null || rect == null || tracker == null) return;
    if (tracker.totalCount != widget.totalCount) {
      _removeScrubOverlay();
      return;
    }
    _pointer = details.globalPosition;
    final oldScale = tracker.scale;
    final previousX = tracker.thumbX;
    tracker.update(
      _pointer.dx - rect.left - _railInsets.left,
      _scrubOrigin.dy - _pointer.dy,
    );
    if (!_reduceMotion && tracker.scale == oldScale) {
      _thumbMotion.moveBy(tracker.thumbX - previousX);
    }
    final target = tracker.index;
    final now = details.sourceTimeStamp ?? Duration.zero;
    if (tracker.scale != oldScale) {
      HapticFeedback.selectionClick();
      _lastHapticTime = now;
    }
    if (target != _scrubTarget) {
      if (target == 1 || target == widget.totalCount) {
        HapticFeedback.lightImpact();
        _lastHapticTime = now;
      } else if (tracker.scale == TopicScrubScale.single &&
          now - _lastHapticTime >= _hapticInterval) {
        HapticFeedback.selectionClick();
        _lastHapticTime = now;
      }
      _scrubTarget = target;
      widget.scrubIndexNotifier.value = target;
      _excerptTimer?.cancel();
      _excerptTimer = Timer(_excerptSettle, () {
        _excerptIndex = _scrubTarget;
        _scrubEntry?.markNeedsBuild();
      });
    }
    _scrubEntry?.markNeedsBuild();
  }

  void _handleScrubEnd(DragEndDetails details) {
    final tracker = _tracker;
    if (_scrubAxis == null || tracker == null) return;
    final target = _scrubTarget;
    final start = _scrubStartIndex;
    _removeScrubOverlay();
    if (target != start && tracker.totalCount == widget.totalCount) {
      HapticFeedback.lightImpact();
      widget.onScrubCommit(target);
    }
  }

  void _refreshScrubOverlay() => _scrubEntry?.markNeedsBuild();

  void _removeScrubOverlay() {
    if (_scrubAxis == null) return;
    _anchorTrack();
    _scrubAxis = null;
    _excerptTimer?.cancel();
    _excerptTimer = null;
    _scrubSource?.removeListener(_refreshScrubOverlay);
    widget.scrubIndexNotifier.value = null;
    // 立即结束手势并提交楼层，让最后一帧预览与渐变一起淡出。
    if (_reduceMotion || _scrubFade.isDismissed) {
      _scrubFade.value = 0;
      setState(_discardScrubEntry);
    } else {
      _scrubFade.reverse().then<void>((_) {
        if (mounted && _scrubAxis == null) setState(_discardScrubEntry);
      });
    }
  }

  void _discardScrubEntry() {
    _scrubEntry?.remove();
    _scrubEntry?.dispose();
    _scrubEntry = null;
    _scrubSource = null;
    _barRect = null;
    _tracker = null;
  }

  Widget _buildScrubOverlay() {
    final rect = _barRect;
    final tracker = _tracker;
    if (rect == null || tracker == null) return const SizedBox.shrink();
    final source = _scrubSource;
    return TopicScrubIndicator(
      visibility: _scrubFade,
      thumbTravel: _thumbMotion.travel,
      barRect: rect,
      insets: _railInsets,
      floating: _floating,
      progressAt: _trackProgress,
      markerIndex: widget.markerIndex,
      tracker: tracker,
      pointer: _pointer,
      date: source?.dateAt(_scrubTarget),
      excerptIndex: _excerptIndex,
      excerpt: _excerptIndex == _scrubTarget
          ? source?.infoAt(_excerptIndex, loadExcerpt: _scrubAxis != null)
          : null,
    );
  }

  // ===== 上滑 =====

  void _handleSwipeStart(DragStartDetails details, AppPreferences prefs) {
    final rect = _globalRect();
    if (rect != null &&
        TopicScrubTracker.canZoom(widget.totalCount, _railWidth(rect)) &&
        _isOutsideEdgeZones(_verticalDown) &&
        _verticalDown.dy <= rect.top + 22 &&
        details.globalPosition.dy < _verticalDown.dy &&
        (_verticalDown.dy <= rect.top + TopicProgressLine.handleHeight ||
            _nearHandle(rect, _verticalDown))) {
      _startScrub(_verticalDown, Axis.vertical);
      _handleScrubUpdate(
        DragUpdateDetails(
          globalPosition: details.globalPosition,
          sourceTimeStamp: details.sourceTimeStamp,
        ),
      );
      return;
    }
    final action = prefs.progressGestureSwipeUp;
    if (action == ProgressGestureAction.none) return;
    _swipeStart = details.globalPosition;
    _swipeCurrent = details.globalPosition;
    _swipeAction = action;
    _swipeTriggerable = false;
    _swipeEntry = OverlayEntry(builder: (_) => _buildSwipeOverlay());
    Overlay.of(context, rootOverlay: true).insert(_swipeEntry!);
  }

  void _handleSwipeUpdate(DragUpdateDetails details) {
    final start = _swipeStart;
    if (start == null) return;
    _swipeCurrent = details.globalPosition;
    final triggerable = start.dy - _swipeCurrent.dy >= _kSwipeTriggerDistance;
    if (triggerable != _swipeTriggerable && triggerable) {
      HapticFeedback.lightImpact();
    }
    _swipeTriggerable = triggerable;
    _swipeEntry?.markNeedsBuild();
  }

  void _handleSwipeEnd(DragEndDetails details) {
    final triggered = _swipeTriggerable;
    final action = _swipeAction;
    _removeSwipeOverlay();
    if (triggered && action != null) {
      HapticFeedback.mediumImpact();
      widget.onAction(action);
    }
  }

  void _removeSwipeOverlay() {
    _swipeEntry?.remove();
    _swipeEntry = null;
    _swipeStart = null;
    _swipeCurrent = Offset.zero;
    _swipeAction = null;
    _swipeTriggerable = false;
  }

  Widget _buildSwipeOverlay() {
    final start = _swipeStart;
    final action = _swipeAction;
    if (start == null || action == null) return const SizedBox.shrink();
    return _SwipePreviewOverlay(
      origin: start,
      action: action,
      triggerable: _swipeTriggerable,
      delta: _swipeCurrent - start,
      triggerDistance: _kSwipeTriggerDistance,
    );
  }

  // ===== 入口 =====

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(preferencesProvider);

    final mq = MediaQuery.of(context);
    _reduceMotion = mq.disableAnimations || mq.reduceMotion;
    _screenWidth = mq.size.width;
    _edgeLeft = math.max(mq.systemGestureInsets.left, _kEdgeGuardMin);
    _edgeRight = math.max(mq.systemGestureInsets.right, _kEdgeGuardMin);
    _floating = TopicBottomBarMetrics.isFloating(context);
    final corner = _floating
        ? context.shapes.resolve(TopicBottomBarMetrics.floatingRadius) +
              TopicProgressSurface.floating.openThickness / 2 +
              2
        : 0.0;
    _railInsets = EdgeInsets.only(
      left: math.max(corner, _edgeLeft + 4),
      right: math.max(corner, _edgeRight + 4),
    );
    final enabled = prefs.progressGesturesEnabled;
    final hasHandle = enabled && widget.totalCount > 1;
    final surface = Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            top: TopicBottomBarMetrics.progressLineHeight,
          ),
          child: widget.child,
        ),
        if (_scrubEntry == null)
          Positioned(
            left: 0,
            right: 0,
            top:
                TopicProgressLine.centerFromBarTop(_floating, hasHandle) -
                TopicProgressLine.heightFor(hasHandle) / 2,
            child: IgnorePointer(
              child: TopicProgressLine(
                streamIndexListenable: widget.streamIndexListenable,
                totalCount: widget.totalCount,
                markerIndex: widget.markerIndex,
                handleInsets: enabled || _floating ? _railInsets : null,
                floating: _floating,
                showHandle: hasHandle,
              ),
            ),
          ),
      ],
    );
    if (!enabled) return surface;

    return Listener(
      onPointerCancel: (_) {
        if (_tracker != null) _removeScrubOverlay();
        _removeSwipeOverlay();
      },
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(duration: _longPressTimeout),
                (instance) {
                  instance.onLongPressStart = (d) =>
                      _handleLongPressStart(d, prefs);
                  instance.onLongPressMoveUpdate = (d) =>
                      _menuSession.updatePointer(d.globalPosition);
                  instance.onLongPressEnd = (_) =>
                      _menuSession.selectAndClose();
                  instance.onLongPressCancel = _menuSession.cancel;
                },
              ),
          if (widget.totalCount > 1)
            _EdgeGuardedHorizontalDragRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  _EdgeGuardedHorizontalDragRecognizer
                >(
                  () =>
                      _EdgeGuardedHorizontalDragRecognizer(_isOutsideEdgeZones),
                  (instance) {
                    instance.dragStartBehavior = DragStartBehavior.down;
                    instance.onStart = (d) =>
                        _startScrub(d.globalPosition, Axis.horizontal);
                    instance.onUpdate = _handleScrubUpdate;
                    instance.onEnd = _handleScrubEnd;
                    instance.onCancel = () {
                      if (_scrubAxis == Axis.horizontal) _removeScrubOverlay();
                    };
                  },
                ),
          VerticalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                VerticalDragGestureRecognizer
              >(() => VerticalDragGestureRecognizer(), (instance) {
                instance.onDown = (d) => _verticalDown = d.globalPosition;
                instance.onStart = (d) => _handleSwipeStart(d, prefs);
                instance.onUpdate = (d) => _scrubAxis == Axis.vertical
                    ? _handleScrubUpdate(d)
                    : _handleSwipeUpdate(d);
                instance.onEnd = (d) => _scrubAxis == Axis.vertical
                    ? _handleScrubEnd(d)
                    : _handleSwipeEnd(d);
                instance.onCancel = () {
                  if (_scrubAxis == Axis.vertical) _removeScrubOverlay();
                  _removeSwipeOverlay();
                };
              }),
        },
        child: surface,
      ),
    );
  }
}

/// 起手落在屏幕边缘手势区时不参与竞技场，把手势让给系统返回与路由侧滑
class _EdgeGuardedHorizontalDragRecognizer
    extends HorizontalDragGestureRecognizer {
  _EdgeGuardedHorizontalDragRecognizer(this._allowPosition);

  final bool Function(Offset globalPosition) _allowPosition;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      _allowPosition(event.position) && super.isPointerAllowed(event);
}

// ============================== 上滑预览 ==============================

class _SwipePreviewOverlay extends StatelessWidget {
  const _SwipePreviewOverlay({
    required this.origin,
    required this.action,
    required this.triggerable,
    required this.delta,
    required this.triggerDistance,
  });

  /// 手指起手的全局坐标
  final Offset origin;
  final ProgressGestureAction action;
  final bool triggerable;
  final Offset delta;
  final double triggerDistance;

  static const double _pillBaseOffset = 56;
  static const double _pillFollowFactor = 0.55;
  static const double _pillFollowMax = 56;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = progressGestureActionMeta(context, action);
    final progress = (-delta.dy / triggerDistance).clamp(0.0, 1.0);
    final dy =
        (delta.dy * _pillFollowFactor).clamp(-_pillFollowMax, 0.0) -
        _pillBaseOffset;
    final pillCenter = origin + Offset(0, dy);
    final bgColor = triggerable
        ? theme.colorScheme.primary
        : Color.lerp(
            theme.colorScheme.surfaceContainerHighest,
            theme.colorScheme.primary,
            progress * 0.4,
          )!;
    final fgColor = triggerable
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;
    final shadow = triggerable
        ? theme.colorScheme.primary.withValues(alpha: 0.4)
        : Colors.black.withValues(alpha: 0.12);

    final screenSize = MediaQuery.of(context).size;
    final clampedX = pillCenter.dx.clamp(60.0, screenSize.width - 60.0);
    final clampedY = pillCenter.dy.clamp(40.0, screenSize.height - 40.0);

    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            left: clampedX,
            top: clampedY,
            child: FractionalTranslation(
              translation: const Offset(-0.5, -0.5),
              child: AnimatedScale(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutBack,
                scale: triggerable ? 1.04 : 1.0,
                child: Material(
                  color: bgColor,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: context.shapes.borderRadius(20),
                  ),
                  elevation: triggerable ? 6 : 3,
                  shadowColor: shadow,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(meta.icon, size: 18, color: fgColor),
                        const SizedBox(width: 6),
                        Text(
                          meta.label,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: fgColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
