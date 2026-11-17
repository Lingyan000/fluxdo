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
import '../../../utils/time_utils.dart';
import '../controllers/topic_position_info.dart';
import 'topic_scrub_mapping.dart';

/// 上滑触发阈值（手指相对起点的距离 ≥ 此值即视为可触发）
const double _kSwipeTriggerDistance = 56.0;

/// 屏幕左右边缘留给系统返回 / 路由侧滑返回的最小宽度（路由侧滑的
/// 起手区约 20）；系统声明的手势区更宽时以系统为准
const double _kEdgeGuardMin = 20.0;

/// 话题底栏手势层：整条栏都是手势面，不绑定某个具体控件，布局不受约束。
///
/// - 横向拖动：拖动定位楼层（映射见 [topicScrubTargetIndex]），跟手气泡
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
  });

  final Widget child;

  /// 上滑与长按菜单触发的动作
  final ValueChanged<ProgressGestureAction> onAction;

  /// 当前楼层（stream 索引，1 起），拖动起点
  final ValueListenable<int> streamIndexListenable;
  final int totalCount;

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

class _TopicBarGesturesState extends ConsumerState<TopicBarGestures> {
  // 长按菜单会话（overlay 生命周期 + 高亮命中 + 触觉反馈）
  final RadialMenuSession _menuSession = RadialMenuSession();

  /// 栏内有回复入口、楼层计数等点按目标，长按阈值不能太短：从容的单击
  /// 常超 200ms，会被误判成长按吞掉（与 [RadialLongPressMenu] 同一取值）
  static const Duration _longPressTimeout = Duration(milliseconds: 420);

  /// 当前帧的左右边缘手势区（build 时由 MediaQuery 取得）
  double _edgeLeft = _kEdgeGuardMin;
  double _edgeRight = _kEdgeGuardMin;
  double _screenWidth = 0;

  // ===== 拖动定位状态 =====
  OverlayEntry? _scrubEntry;
  Rect? _barRect;
  int _scrubStartIndex = 1;
  double _scrubStartX = 0;
  double _scrubFingerX = 0;
  int _scrubTarget = 1;

  // ===== 上滑状态 =====
  OverlayEntry? _swipeEntry;
  Offset? _swipeStart;
  Offset _swipeCurrent = Offset.zero;
  ProgressGestureAction? _swipeAction;
  bool _swipeTriggerable = false;

  @override
  void dispose() {
    _menuSession.dispose();
    // 卸载期不回写 scrubIndexNotifier：监听它的兄弟节点可能同批卸载
    widget.infoSource?.removeListener(_refreshScrubOverlay);
    _scrubEntry?.remove();
    _scrubEntry = null;
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

  void _handleScrubStart(DragStartDetails details) {
    final rect = _globalRect();
    if (rect == null || widget.totalCount <= 1) return;
    _barRect = rect;
    _scrubStartIndex = widget.streamIndexListenable.value.clamp(
      1,
      widget.totalCount,
    );
    _scrubTarget = _scrubStartIndex;
    _scrubStartX = details.globalPosition.dx;
    _scrubFingerX = _scrubStartX;
    widget.scrubIndexNotifier.value = _scrubTarget;
    widget.onScrubStart?.call();

    _scrubEntry = OverlayEntry(builder: (_) => _buildScrubOverlay());
    Overlay.of(context, rootOverlay: true).insert(_scrubEntry!);
    widget.infoSource?.addListener(_refreshScrubOverlay);
    HapticFeedback.selectionClick();
  }

  void _handleScrubUpdate(DragUpdateDetails details) {
    final rect = _barRect;
    if (rect == null) return;
    _scrubFingerX = details.globalPosition.dx;
    final target = topicScrubTargetIndex(
      startIndex: _scrubStartIndex,
      totalCount: widget.totalCount,
      startX: _scrubStartX,
      currentX: _scrubFingerX,
      surfaceLeft: math.max(rect.left, _edgeLeft),
      surfaceRight: math.min(rect.right, _screenWidth - _edgeRight),
    );
    if (target != _scrubTarget) {
      final stepped = (target - _scrubStartIndex).abs() <= 3;
      if (target == 1 || target == widget.totalCount) {
        HapticFeedback.lightImpact();
      } else if (stepped) {
        // 步进段每跨一楼轻震；加速段楼层变化太密，不逐楼震动
        HapticFeedback.selectionClick();
      }
      _scrubTarget = target;
      widget.scrubIndexNotifier.value = target;
    }
    _scrubEntry?.markNeedsBuild();
  }

  void _handleScrubEnd(DragEndDetails details) {
    final target = _scrubTarget;
    final start = _scrubStartIndex;
    _removeScrubOverlay();
    if (target != start) {
      HapticFeedback.lightImpact();
      widget.onScrubCommit(target);
    }
  }

  void _refreshScrubOverlay() => _scrubEntry?.markNeedsBuild();

  void _removeScrubOverlay() {
    widget.infoSource?.removeListener(_refreshScrubOverlay);
    _scrubEntry?.remove();
    _scrubEntry = null;
    _barRect = null;
    if (widget.scrubIndexNotifier.value != null) {
      widget.scrubIndexNotifier.value = null;
    }
  }

  Widget _buildScrubOverlay() {
    final rect = _barRect;
    if (rect == null) return const SizedBox.shrink();
    return _ScrubBubbleOverlay(
      fingerX: _scrubFingerX,
      barTop: rect.top,
      index: _scrubTarget,
      totalCount: widget.totalCount,
      info: widget.infoSource?.infoAt(_scrubTarget),
    );
  }

  // ===== 上滑 =====

  void _handleSwipeStart(DragStartDetails details, AppPreferences prefs) {
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
    if (!prefs.progressGesturesEnabled) return widget.child;

    final mq = MediaQuery.of(context);
    _screenWidth = mq.size.width;
    _edgeLeft = math.max(mq.systemGestureInsets.left, _kEdgeGuardMin);
    _edgeRight = math.max(mq.systemGestureInsets.right, _kEdgeGuardMin);

    return RawGestureDetector(
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
                instance.onLongPressEnd = (_) => _menuSession.selectAndClose();
                instance.onLongPressCancel = _menuSession.cancel;
              },
            ),
        _EdgeGuardedHorizontalDragRecognizer:
            GestureRecognizerFactoryWithHandlers<
              _EdgeGuardedHorizontalDragRecognizer
            >(() => _EdgeGuardedHorizontalDragRecognizer(_isOutsideEdgeZones), (
              instance,
            ) {
              instance.onStart = _handleScrubStart;
              instance.onUpdate = _handleScrubUpdate;
              instance.onEnd = _handleScrubEnd;
              instance.onCancel = _removeScrubOverlay;
            }),
        VerticalDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<VerticalDragGestureRecognizer>(
              () => VerticalDragGestureRecognizer(),
              (instance) {
                instance.onStart = (d) => _handleSwipeStart(d, prefs);
                instance.onUpdate = _handleSwipeUpdate;
                instance.onEnd = _handleSwipeEnd;
                instance.onCancel = _removeSwipeOverlay;
              },
            ),
      },
      child: widget.child,
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

// ============================== 拖动定位气泡 ==============================

class _ScrubBubbleOverlay extends StatelessWidget {
  const _ScrubBubbleOverlay({
    required this.fingerX,
    required this.barTop,
    required this.index,
    required this.totalCount,
    required this.info,
  });

  final double fingerX;

  /// 栏顶边的全局 y，气泡底边悬在其上方
  final double barTop;
  final int index;
  final int totalCount;
  final TopicPositionInfo? info;

  static const double _gap = 12;
  static const double _maxWidth = 260;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = theme.colorScheme.onInverseSurface;
    final secondary = foreground.withValues(alpha: 0.7);
    const tabular = [FontFeature.tabularFigures()];
    final date = info?.date;
    final username = info?.username;
    final excerpt = info?.excerpt;
    return IgnorePointer(
      child: CustomSingleChildLayout(
        delegate: _BubbleLayoutDelegate(
          anchor: Offset(fingerX, barTop - _gap),
          safeInsets: MediaQuery.paddingOf(context),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxWidth),
          child: Material(
            color: theme.colorScheme.inverseSurface,
            shape: RoundedSuperellipseBorder(
              borderRadius: context.shapes.borderRadius(16),
            ),
            elevation: 6,
            shadowColor: Colors.black26,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        '$index',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: foreground,
                          fontWeight: FontWeight.w600,
                          fontFeatures: tabular,
                        ),
                      ),
                      Text(
                        ' / $totalCount',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: secondary,
                          fontFeatures: tabular,
                        ),
                      ),
                      if (date != null) ...[
                        const SizedBox(width: 10),
                        Text(
                          TimeUtils.formatSmartDate(date),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: secondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (username != null || excerpt != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text.rich(
                        TextSpan(
                          children: [
                            if (username != null)
                              TextSpan(
                                // 用字重区分作者与正文，不拼标点（各语言通用）
                                text: excerpt == null
                                    ? username
                                    : '$username  ',
                                style: TextStyle(
                                  color: foreground,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            if (excerpt != null) TextSpan(text: excerpt),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: secondary,
                          height: 1.35,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 气泡以 [anchor] 为底边中点摆放，测得实际尺寸后整体 clamp 在屏幕内
class _BubbleLayoutDelegate extends SingleChildLayoutDelegate {
  const _BubbleLayoutDelegate({required this.anchor, required this.safeInsets});

  final Offset anchor;
  final EdgeInsets safeInsets;

  static const double _margin = 12;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final minX = safeInsets.left + _margin;
    final maxX = size.width - safeInsets.right - _margin - childSize.width;
    final double x = (anchor.dx - childSize.width / 2)
        .clamp(minX, math.max(minX, maxX))
        .toDouble();
    final double y = math.max(safeInsets.top, anchor.dy - childSize.height);
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_BubbleLayoutDelegate old) =>
      anchor != old.anchor || safeInsets != old.safeInsets;
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
