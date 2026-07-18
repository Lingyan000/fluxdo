import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/preferences_provider.dart';
import '../../../widgets/common/radial_long_press_menu.dart';
import 'progress_gesture_action_meta.dart';

/// 滑动触发阈值（手指相对起点的距离 ≥ 此值即视为可触发）
const double _kSwipeTriggerDistance = 56.0;

/// 滑动方向判定的死区（小于此值不判断方向）
const double _kSwipeDeadZone = 6.0;

/// 进度悬浮条手势包装：在 [TopicProgress] 上识别左/右/上滑与长按
///
/// - 按压进度环：手指落下即在悬浮条边缘累积一圈描边，按住越久环越满，
///   可视化反馈"按压时间"。pan 胜出或松开会让环回缩。
/// - 左/右/上滑：实时显示预览药丸，距离 ≥ [_kSwipeTriggerDistance] 后可触发
/// - 长按 200ms：弹出半圆向上展开菜单，拖到目标松开触发；拖到死区取消
/// - tap 由内层 InkWell 处理，本组件只处理 swipe + long press
/// - 总开关关闭时本组件退化为透传
class TopicProgressGestures extends ConsumerStatefulWidget {
  const TopicProgressGestures({
    super.key,
    required this.child,
    required this.onAction,
  });

  final Widget child;
  final ValueChanged<ProgressGestureAction> onAction;

  @override
  ConsumerState<TopicProgressGestures> createState() =>
      _TopicProgressGesturesState();
}

enum _SwipeDirection { left, right, up }

class _TopicProgressGesturesState extends ConsumerState<TopicProgressGestures>
    with TickerProviderStateMixin {
  // 长按菜单会话（overlay 生命周期 + 高亮命中 + 触觉反馈）
  final RadialMenuSession _menuSession = RadialMenuSession();

  /// 缩短的长按触发阈值，让长按更早胜出，避免 swipe 与菜单视觉冲突
  static const Duration _longPressTimeout = Duration(milliseconds: 200);

  /// 按压进度环动画时长。比长按阈值略长，让用户在 200ms 触发时仍能看到
  /// 环还在累积，强化"按住越久越满"的感受
  static const Duration _pressProgressDuration = Duration(milliseconds: 520);

  late final AnimationController _pressController;

  // 滑动预览状态
  OverlayEntry? _swipeEntry;
  Offset? _swipeOrigin; // 悬浮条本体中心（用于定位预览药丸）
  Offset? _swipeStart; // 手指按下的全局坐标
  Offset _swipeCurrent = Offset.zero;
  _SwipeDirection? _swipeDirection;
  ProgressGestureAction? _swipeAction;
  bool _swipeTriggerable = false;

  @override
  void initState() {
    super.initState();
    _pressController = AnimationController(
      vsync: this,
      duration: _pressProgressDuration,
    );
  }

  @override
  void dispose() {
    _menuSession.dispose();
    _disposeSwipeOverlay();
    _pressController.dispose();
    super.dispose();
  }

  // ===== 按压进度环 =====

  void _handlePointerDown(PointerDownEvent event) {
    _pressController.forward(from: 0);
  }

  void _handlePointerUp(PointerUpEvent event) {
    _retractPressRing();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _retractPressRing();
  }

  /// 让进度环回缩到 0（带 120ms 平滑过渡，避免突然消失）
  void _retractPressRing() {
    if (_pressController.value == 0 && !_pressController.isAnimating) return;
    _pressController.animateTo(
      0,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeIn,
    );
  }

  // ===== 长按菜单 =====

  void _handleLongPressStart(
    LongPressStartDetails details,
    AppPreferences prefs,
  ) {
    if (!prefs.progressGesturesEnabled) return;
    if (!prefs.progressGestureLongPressEnabled) return;
    final actions = prefs.progressGestureMenuActions;
    if (actions.isEmpty) return;

    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final widgetTopLeft = box.localToGlobal(Offset.zero);
    final widgetTopCenter = widgetTopLeft + Offset(box.size.width / 2, 0);

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

    _menuSession.open(
      context: context,
      center: widgetTopCenter,
      pressArea: Rect.fromLTWH(
        widgetTopLeft.dx,
        widgetTopLeft.dy,
        box.size.width,
        box.size.height,
      ),
      items: items,
    );

    // 长按触发，让进度环继续走到 1（视觉上"环走完=菜单完全展开"）
    _pressController.forward();
    _menuSession.updatePointer(details.globalPosition);
  }

  void _handleLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    _menuSession.updatePointer(details.globalPosition);
  }

  void _handleLongPressEnd(LongPressEndDetails details) {
    _menuSession.selectAndClose();
  }

  void _handleLongPressCancel() {
    _menuSession.cancel();
  }

  // ===== 滑动预览 =====

  void _disposeSwipeOverlay() {
    _swipeEntry?.remove();
    _swipeEntry = null;
    _swipeOrigin = null;
    _swipeStart = null;
    _swipeCurrent = Offset.zero;
    _swipeDirection = null;
    _swipeAction = null;
    _swipeTriggerable = false;
  }

  void _handlePanStart(DragStartDetails details, AppPreferences prefs) {
    if (!prefs.progressGesturesEnabled) return;

    // pan 胜出，按压进度环立刻回缩（不再有"按住"的语义）
    _retractPressRing();

    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    _swipeStart = details.globalPosition;
    _swipeCurrent = details.globalPosition;
    _swipeOrigin = box.localToGlobal(
      Offset(box.size.width / 2, box.size.height / 2),
    );
    _swipeDirection = null;
    _swipeAction = null;
    _swipeTriggerable = false;

    final overlay = Overlay.of(context, rootOverlay: true);
    _swipeEntry = OverlayEntry(builder: (_) => _buildSwipeOverlay());
    overlay.insert(_swipeEntry!);
  }

  void _handlePanUpdate(DragUpdateDetails details, AppPreferences prefs) {
    final start = _swipeStart;
    if (start == null) return;
    _swipeCurrent = details.globalPosition;

    final dx = _swipeCurrent.dx - start.dx;
    final dy = _swipeCurrent.dy - start.dy;
    final absDx = dx.abs();
    final absDy = dy.abs();
    final maxDelta = math.max(absDx, absDy);

    _SwipeDirection? direction;
    if (maxDelta >= _kSwipeDeadZone) {
      if (absDx > absDy) {
        direction = dx < 0 ? _SwipeDirection.left : _SwipeDirection.right;
      } else if (dy < 0) {
        direction = _SwipeDirection.up;
      }
    }

    ProgressGestureAction? action;
    switch (direction) {
      case _SwipeDirection.left:
        action = prefs.progressGestureSwipeLeft;
      case _SwipeDirection.right:
        action = prefs.progressGestureSwipeRight;
      case _SwipeDirection.up:
        action = prefs.progressGestureSwipeUp;
      case null:
        action = null;
    }
    // 绑定为「无」时等同于未绑定：不显示 pill、不可触发
    if (action == ProgressGestureAction.none) {
      action = null;
    }

    final triggerable = action != null && maxDelta >= _kSwipeTriggerDistance;

    final directionChanged = direction != _swipeDirection;
    final triggerChanged = triggerable != _swipeTriggerable;
    if (triggerChanged && triggerable) {
      HapticFeedback.lightImpact();
    } else if (directionChanged && direction != null) {
      HapticFeedback.selectionClick();
    }

    _swipeDirection = direction;
    _swipeAction = action;
    _swipeTriggerable = triggerable;
    _swipeEntry?.markNeedsBuild();
  }

  void _handlePanEnd(DragEndDetails details) {
    final triggered = _swipeTriggerable;
    final action = _swipeAction;
    _disposeSwipeOverlay();
    if (triggered && action != null) {
      HapticFeedback.mediumImpact();
      widget.onAction(action);
    }
  }

  void _handlePanCancel() {
    _disposeSwipeOverlay();
  }

  Widget _buildSwipeOverlay() {
    return _SwipePreviewOverlay(
      origin: _swipeOrigin ?? Offset.zero,
      direction: _swipeDirection,
      action: _swipeAction,
      triggerable: _swipeTriggerable,
      delta: (_swipeStart == null)
          ? Offset.zero
          : _swipeCurrent - _swipeStart!,
      triggerDistance: _kSwipeTriggerDistance,
    );
  }

  // ===== 入口 =====

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(preferencesProvider);
    if (!prefs.progressGesturesEnabled) {
      return widget.child;
    }
    final ringColor = Theme.of(context).colorScheme.primary;
    return Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: _handlePointerDown,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: RawGestureDetector(
        behavior: HitTestBehavior.deferToChild,
        gestures: <Type, GestureRecognizerFactory>{
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(duration: _longPressTimeout),
                (instance) {
                  instance.onLongPressStart =
                      (d) => _handleLongPressStart(d, prefs);
                  instance.onLongPressMoveUpdate = _handleLongPressMoveUpdate;
                  instance.onLongPressEnd = _handleLongPressEnd;
                  instance.onLongPressCancel = _handleLongPressCancel;
                },
              ),
          PanGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
                () => PanGestureRecognizer(),
                (instance) {
                  instance.onStart = (d) => _handlePanStart(d, prefs);
                  instance.onUpdate = (d) => _handlePanUpdate(d, prefs);
                  instance.onEnd = _handlePanEnd;
                  instance.onCancel = _handlePanCancel;
                },
              ),
        },
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            widget.child,
            Positioned.fill(
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _pressController,
                    builder: (context, _) {
                      return CustomPaint(
                        painter: _StadiumProgressPainter(
                          progress: _pressController.value,
                          color: ringColor,
                          strokeWidth: 2.5,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================== 进度环 painter ==============================

/// 在 stadium 形状（圆角胶囊）边缘画一圈描边，从顶部中点向左右两侧对称扩散。
/// progress = 0 时不画任何东西；progress = 1 时画完整一圈。
class _StadiumProgressPainter extends CustomPainter {
  const _StadiumProgressPainter({
    required this.progress,
    required this.color,
    required this.strokeWidth,
  });

  final double progress;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final inset = strokeWidth / 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - inset * 2,
      size.height - inset * 2,
    );
    final radius = rect.height / 2;
    final cx = rect.center.dx;

    // 右半路径：顶部中点 → 右上 → 右弧 → 右下 → 底部中点
    final rightPath = Path()
      ..moveTo(cx, rect.top)
      ..lineTo(rect.right - radius, rect.top)
      ..arcToPoint(
        Offset(rect.right - radius, rect.bottom),
        radius: Radius.circular(radius),
        clockwise: true,
      )
      ..lineTo(cx, rect.bottom);

    // 左半路径：顶部中点 → 左上 → 左弧 → 左下 → 底部中点（逆时针）
    final leftPath = Path()
      ..moveTo(cx, rect.top)
      ..lineTo(rect.left + radius, rect.top)
      ..arcToPoint(
        Offset(rect.left + radius, rect.bottom),
        radius: Radius.circular(radius),
        clockwise: false,
      )
      ..lineTo(cx, rect.bottom);

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final p = progress.clamp(0.0, 1.0);
    for (final path in [rightPath, leftPath]) {
      for (final metric in path.computeMetrics()) {
        final sub = metric.extractPath(0, metric.length * p);
        canvas.drawPath(sub, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_StadiumProgressPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
}

// ============================== 滑动预览 Overlay ==============================

class _SwipePreviewOverlay extends StatelessWidget {
  const _SwipePreviewOverlay({
    required this.origin,
    required this.direction,
    required this.action,
    required this.triggerable,
    required this.delta,
    required this.triggerDistance,
  });

  /// 悬浮条本体的全局坐标（中心点）
  final Offset origin;
  final _SwipeDirection? direction;
  final ProgressGestureAction? action;
  final bool triggerable;
  final Offset delta;
  final double triggerDistance;

  static const double _pillBaseOffset = 56;
  static const double _pillFollowFactor = 0.55;
  static const double _pillFollowMax = 56;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (action == null || direction == null) {
      return const IgnorePointer(child: SizedBox.shrink());
    }
    final meta = progressGestureActionMeta(context, action!);
    final progress = (math.max(delta.dx.abs(), delta.dy.abs()) / triggerDistance)
        .clamp(0.0, 1.0);

    Offset pillOffset;
    switch (direction!) {
      case _SwipeDirection.left:
        final dx = (delta.dx * _pillFollowFactor).clamp(-_pillFollowMax, 0.0);
        pillOffset = Offset(dx, -_pillBaseOffset);
      case _SwipeDirection.right:
        final dx = (delta.dx * _pillFollowFactor).clamp(0.0, _pillFollowMax);
        pillOffset = Offset(dx, -_pillBaseOffset);
      case _SwipeDirection.up:
        final dy =
            (delta.dy * _pillFollowFactor).clamp(-_pillFollowMax, 0.0) -
                _pillBaseOffset;
        pillOffset = Offset(0, dy);
    }

    final pillCenter = origin + pillOffset;
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
                  borderRadius: BorderRadius.circular(20),
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
