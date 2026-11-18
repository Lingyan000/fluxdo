import 'dart:async';
import 'dart:math' as math;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/preferences_provider.dart';
import '../../../widgets/common/emoji_text.dart';
import '../../../widgets/common/radial_long_press_menu.dart';
import 'progress_gesture_action_meta.dart';
import '../../../utils/time_utils.dart';
import '../controllers/topic_position_info.dart';
import 'topic_bottom_bar.dart';
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
  int _scrubTarget = 1;
  TopicScrubTracker? _tracker;
  final Stopwatch _scrubClock = Stopwatch();
  Duration _lastScrubTime = Duration.zero;
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
  void dispose() {
    _menuSession.dispose();
    // 卸载期不回写 scrubIndexNotifier：监听它的兄弟节点可能同批卸载
    widget.infoSource?.removeListener(_refreshScrubOverlay);
    _scrubEntry?.remove();
    _scrubEntry = null;
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

  void _handleScrubStart(DragStartDetails details) {
    final rect = _globalRect();
    if (rect == null || widget.totalCount <= 1) return;
    _barRect = rect;
    _scrubStartIndex = widget.streamIndexListenable.value.clamp(
      1,
      widget.totalCount,
    );
    _scrubTarget = _scrubStartIndex;
    _excerptIndex = _scrubStartIndex;
    _tracker = TopicScrubTracker(
      startIndex: _scrubStartIndex,
      totalCount: widget.totalCount,
      surfaceWidth:
          math.min(rect.right, _screenWidth - _edgeRight) -
          math.max(rect.left, _edgeLeft),
    );
    _scrubClock
      ..reset()
      ..start();
    _lastScrubTime = Duration.zero;
    _lastHapticTime = Duration.zero;
    widget.scrubIndexNotifier.value = _scrubTarget;
    widget.onScrubStart?.call();

    _scrubEntry = OverlayEntry(builder: (_) => _buildScrubOverlay());
    Overlay.of(context, rootOverlay: true).insert(_scrubEntry!);
    widget.infoSource?.addListener(_refreshScrubOverlay);
    HapticFeedback.selectionClick();
  }

  void _handleScrubUpdate(DragUpdateDetails details) {
    final tracker = _tracker;
    if (_barRect == null || tracker == null) return;
    final now = _scrubClock.elapsed;
    final dt = (now - _lastScrubTime).inMicroseconds / 1e6;
    _lastScrubTime = now;
    final target = tracker.update(details.delta.dx, dt);
    if (target != _scrubTarget) {
      if (target == 1 || target == widget.totalCount) {
        HapticFeedback.lightImpact();
        _lastHapticTime = now;
      } else if (now - _lastHapticTime >= _hapticInterval) {
        // 每过一楼轻震一下；快速划动时按间隔节流
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
    _excerptTimer?.cancel();
    _excerptTimer = null;
    _tracker = null;
    _scrubClock.stop();
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
    final source = widget.infoSource;
    // 悬浮卡片形态的顶角是圆的，进度轨道避开圆角
    final railInset = TopicBottomBarMetrics.isFloating(context)
        ? context.shapes.resolve(24)
        : 0.0;
    return _ScrubIndicatorOverlay(
      barRect: rect,
      railInset: railInset,
      index: _scrubTarget,
      totalCount: widget.totalCount,
      date: source?.dateAt(_scrubTarget),
      excerptIndex: _excerptIndex,
      excerpt: source?.infoAt(_excerptIndex),
      excerptSettled: _excerptIndex == _scrubTarget,
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

// ============================== 拖动定位指示 ==============================

/// 拖动定位时叠在底栏上方的指示：底栏顶边的加粗进度轨道 + 圆形滑块，
/// 上方是指向滑块的固定尺寸气泡（楼层、日期、作者与摘要）。
///
/// 位置跟随目标楼层在话题中的比例（不是手指），三者共用一个短动画平滑
/// 过渡；气泡宽高固定、摘要区常驻，内容变化时不跳动。
class _ScrubIndicatorOverlay extends StatelessWidget {
  const _ScrubIndicatorOverlay({
    required this.barRect,
    required this.railInset,
    required this.index,
    required this.totalCount,
    required this.date,
    required this.excerptIndex,
    required this.excerpt,
    required this.excerptSettled,
  });

  final Rect barRect;
  final double railInset;
  final int index;
  final int totalCount;
  final DateTime? date;
  final int excerptIndex;
  final TopicPositionInfo? excerpt;

  /// 摘要对应的就是当前目标楼层（快速划动途中为 false，显示占位）
  final bool excerptSettled;

  static const double _railHeight = 4;
  static const double _knobSize = 16;
  static const double _bubbleGap = 14;
  static const double _tailSize = 7;
  static const double _bubbleMaxWidth = 300;
  static const double _bubbleRadius = 14;
  static const double _margin = 12;
  static const Duration _follow = Duration(milliseconds: 90);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenWidth = MediaQuery.sizeOf(context).width;
    // 两端至少让出半个滑块：首末楼时滑块完整落在栏内，不被裁掉半边
    final inset = math.max(railInset, _knobSize / 2 + 2);
    final railLeft = barRect.left + inset;
    final railWidth = math.max(0.0, barRect.width - inset * 2);
    final fraction = totalCount > 1 ? (index - 1) / (totalCount - 1) : 0.0;
    final targetX = railLeft + railWidth * fraction;
    // 气泡限制在底栏的水平范围内（宽屏 / 侧边导航时不跑到栏外）
    final minLeft = math.max(_margin, barRect.left);
    final maxRight = math.min(screenWidth - _margin, barRect.right);
    final bubbleWidth = math.min(_bubbleMaxWidth, maxRight - minLeft);
    final bubbleColor = theme.colorScheme.inverseSurface;
    final bubbleRadius = context.shapes.resolve(_bubbleRadius);

    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: targetX),
        duration: _follow,
        curve: Curves.easeOutCubic,
        builder: (context, x, _) {
          final double bubbleLeft = (x - bubbleWidth / 2)
              .clamp(minLeft, math.max(minLeft, maxRight - bubbleWidth))
              .toDouble();
          // 尖角必须连在气泡下沿的直边上：滑块靠边、气泡贴边停住时，
          // 尖角收在圆角以内，斜指向滑块，而不是悬空在气泡外
          final double tailX = x
              .clamp(
                bubbleLeft + bubbleRadius + _tailSize,
                math.max(
                  bubbleLeft + bubbleRadius + _tailSize,
                  bubbleLeft + bubbleWidth - bubbleRadius - _tailSize,
                ),
              )
              .toDouble();
          return Stack(
            children: [
              // 加粗的进度轨道（盖在底栏自身的细进度线上）
              Positioned(
                left: railLeft,
                top: barRect.top - _railHeight / 2,
                width: railWidth,
                height: _railHeight,
                child: CustomPaint(
                  painter: _RailPainter(
                    fill: (x - railLeft).clamp(0.0, railWidth),
                    track: theme.colorScheme.outlineVariant,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              // 滑块
              Positioned(
                left: x - _knobSize / 2,
                top: barRect.top - _knobSize / 2,
                width: _knobSize,
                height: _knobSize,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: theme.colorScheme.surface,
                      width: 2.5,
                    ),
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 4),
                    ],
                  ),
                ),
              ),
              // 指向滑块的尖角
              Positioned(
                left: tailX - _tailSize,
                top: barRect.top - _bubbleGap - 0.5,
                width: _tailSize * 2,
                height: _tailSize,
                child: CustomPaint(painter: _TailPainter(color: bubbleColor)),
              ),
              // 气泡
              Positioned(
                left: bubbleLeft,
                width: bubbleWidth,
                bottom:
                    MediaQuery.sizeOf(context).height -
                    barRect.top +
                    _bubbleGap,
                child: _buildBubble(context, theme, bubbleColor),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBubble(BuildContext context, ThemeData theme, Color color) {
    final foreground = theme.colorScheme.onInverseSurface;
    final secondary = foreground.withValues(alpha: 0.7);
    const tabular = [FontFeature.tabularFigures()];
    final bodyStyle = theme.textTheme.bodySmall?.copyWith(
      color: secondary,
      height: 1.35,
    );
    final lineHeight =
        (bodyStyle?.fontSize ?? 12) * (bodyStyle?.height ?? 1.35);
    return Material(
      color: color,
      shape: RoundedSuperellipseBorder(
        borderRadius: context.shapes.borderRadius(_bubbleRadius),
      ),
      elevation: 6,
      shadowColor: Colors.black26,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
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
                const Spacer(),
                Text(
                  date == null ? '' : TimeUtils.formatSmartDate(date),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: secondary,
                    fontFeatures: tabular,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 摘要区高度固定两行：没取到时显示静态占位，取到后淡入
            SizedBox(
              height: lineHeight * 2,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 140),
                layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.topLeft,
                  children: [...previous, ?current],
                ),
                child: _buildExcerpt(context, foreground, secondary, bodyStyle),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExcerpt(
    BuildContext context,
    Color foreground,
    Color secondary,
    TextStyle? style,
  ) {
    final info = excerpt;
    final username = info?.username;
    final text = info?.excerpt;
    if (!excerptSettled || (username == null && text == null)) {
      return Column(
        key: const ValueKey('placeholder'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _placeholderBar(secondary, 0.9),
          const SizedBox(height: 6),
          _placeholderBar(secondary, 0.55),
        ],
      );
    }
    return Text.rich(
      key: ValueKey(excerptIndex),
      TextSpan(
        children: [
          if (username != null)
            TextSpan(
              // 用字重区分作者与正文，不拼标点（各语言通用）
              text: text == null ? username : '$username  ',
              style: TextStyle(color: foreground, fontWeight: FontWeight.w600),
            ),
          // 摘要由 cooked 还原，短代码已是 cook 判定过的表情：inline
          if (text != null)
            ...EmojiText.buildEmojiSpans(context, text, style, inline: true),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }

  Widget _placeholderBar(Color color, double widthFactor) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        height: 8,
        decoration: ShapeDecoration(
          color: color.withValues(alpha: 0.18),
          shape: const StadiumBorder(),
        ),
      ),
    );
  }
}

class _RailPainter extends CustomPainter {
  const _RailPainter({
    required this.fill,
    required this.track,
    required this.color,
  });

  final double fill;
  final Color track;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, radius),
      Paint()..color = track,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, fill, size.height), radius),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.fill != fill || old.track != track || old.color != color;
}

class _TailPainter extends CustomPainter {
  const _TailPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width / 2, size.height)
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_TailPainter old) => old.color != color;
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
