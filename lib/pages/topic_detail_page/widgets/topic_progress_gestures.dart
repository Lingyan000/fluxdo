import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/preferences_provider.dart';
import 'progress_gesture_action_meta.dart';

/// 滑动触发阈值（手指相对起点的距离 ≥ 此值即视为可触发）
const double _kSwipeTriggerDistance = 56.0;

/// 滑动方向判定的死区（小于此值不判断方向）
const double _kSwipeDeadZone = 6.0;

/// 水平 scrub：每移动多少像素切换 1 楼（基础灵敏度）
const double _kScrubPixelsPerFloor = 14.0;

/// 单次左右 scrub 最大跨度（相对按下时楼层），减轻压力并提高细腻度
const int _kScrubMaxDeltaFloors = 10;

/// 拖动中实时跳楼的最小间隔，避免每楼都触发重渲染 / 无障碍树报错
const Duration _kScrubJumpThrottle = Duration(milliseconds: 100);

/// 进度悬浮条手势包装：在 [TopicProgress] 上识别左右 scrub / 上滑与长按
///
/// - 按压进度环：手指落下即在悬浮条边缘累积一圈描边，按住越久环越满，
///   可视化反馈"按压时间"。pan 胜出或松开会让环回缩。
/// - 左右滑动：连续 scrub 跳楼（左=往前/更早，右=往后/更晚），拖动中实时跳转
/// - 上滑：仍走可配置动作，距离 ≥ [_kSwipeTriggerDistance] 后可触发
/// - 长按 200ms：弹出半圆向上展开菜单，拖到目标松开触发；拖到死区取消
/// - tap 由内层 InkWell 处理，本组件只处理 swipe + long press
/// - 总开关关闭时本组件退化为透传
class TopicProgressGestures extends ConsumerStatefulWidget {
  const TopicProgressGestures({
    super.key,
    required this.child,
    required this.onAction,
    required this.currentIndex,
    required this.totalCount,
    required this.onScrubToIndex,
    this.onScrubEnd,
    this.onScrubCancel,
  });

  final Widget child;
  final ValueChanged<ProgressGestureAction> onAction;

  /// 当前楼层号（真实 post_number）
  final int currentIndex;

  /// 最大楼层号
  final int totalCount;

  /// scrub 过程中跳转到目标楼层（真实 post_number；拖动时随楼层变化实时调用）
  final ValueChanged<int> onScrubToIndex;

  /// scrub 松手时的最终楼层（可做完整跳转 / 补齐未加载楼）
  final ValueChanged<int>? onScrubEnd;

  /// scrub 被取消且未 finalize 时解锁页面状态
  final VoidCallback? onScrubCancel;

  @override
  ConsumerState<TopicProgressGestures> createState() =>
      _TopicProgressGesturesState();
}

enum _SwipeDirection { left, right, up }

class _TopicProgressGesturesState extends ConsumerState<TopicProgressGestures>
    with TickerProviderStateMixin {
  // 长按菜单状态
  OverlayEntry? _menuEntry;
  Offset? _menuCenter;
  Rect? _pressArea; // 悬浮条本体的全局矩形，菜单弹出后在此位置画替代显示
  int? _highlightedIndex;
  List<ProgressGestureAction> _menuItems = const [];
  // true 表示已请求菜单收起：overlay 内部反向播放衍生动画，结束后才真正清理
  bool _menuClosing = false;

  /// 缩短的长按触发阈值，让长按更早胜出，避免 swipe 与菜单视觉冲突
  static const Duration _longPressTimeout = Duration(milliseconds: 200);

  /// 按压进度环动画时长。比长按阈值略长，让用户在 200ms 触发时仍能看到
  /// 环还在累积，强化"按住越久越满"的感受
  static const Duration _pressProgressDuration = Duration(milliseconds: 520);

  late final AnimationController _pressController = AnimationController(
    vsync: this,
    duration: _pressProgressDuration,
  );

  // 滑动预览状态
  OverlayEntry? _swipeEntry;
  Offset? _swipeOrigin; // 悬浮条本体中心（用于定位预览药丸）
  Offset? _swipeStart; // 手指按下的全局坐标
  Offset _swipeCurrent = Offset.zero;
  _SwipeDirection? _swipeDirection;
  ProgressGestureAction? _swipeAction;
  bool _swipeTriggerable = false;

  /// 水平 scrub：按下时的楼层（1-based）
  int _scrubStartIndex = 1;

  /// 水平 scrub：当前预览楼层（1-based）
  int? _scrubTargetIndex;

  /// 水平 scrub：最近一次已实际跳转的楼层（避免重复触发）
  int? _scrubAppliedIndex;

  /// 待应用的 scrub 目标（节流队列，只保留最新）
  int? _pendingScrubIndex;

  Timer? _scrubThrottleTimer;

  @override
  void dispose() {
    _scrubThrottleTimer?.cancel();
    _disposeMenuOverlay();
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

  void _disposeMenuOverlay() {
    _menuEntry?.remove();
    _menuEntry = null;
    _menuCenter = null;
    _pressArea = null;
    _highlightedIndex = null;
    _menuItems = const [];
    _menuClosing = false;
  }

  /// 触发菜单收起：先反向播放衍生动画，结束后再调用 [_disposeMenuOverlay]
  void _beginMenuClose() {
    if (_menuEntry == null || _menuClosing) {
      _disposeMenuOverlay();
      return;
    }
    _menuClosing = true;
    _menuEntry?.markNeedsBuild();
  }

  double _radiusForCount(int count) {
    if (count <= 4) return 92;
    if (count <= 6) return 108;
    return 128;
  }

  void _handleLongPressStart(
    LongPressStartDetails details,
    AppPreferences prefs,
  ) {
    if (!prefs.progressGesturesEnabled) return;
    if (!prefs.progressGestureLongPressEnabled) return;
    final items = prefs.progressGestureMenuActions;
    if (items.isEmpty) return;

    // 如果上一轮菜单还在收回动画中，立刻强制清理，避免两个 overlay 叠加
    if (_menuEntry != null) {
      _disposeMenuOverlay();
    }

    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final widgetTopLeft = box.localToGlobal(Offset.zero);
    final widgetTopCenter = widgetTopLeft + Offset(box.size.width / 2, 0);

    _menuCenter = widgetTopCenter;
    _pressArea = Rect.fromLTWH(
      widgetTopLeft.dx,
      widgetTopLeft.dy,
      box.size.width,
      box.size.height,
    );
    _menuItems = items;
    _highlightedIndex = null;

    final overlay = Overlay.of(context, rootOverlay: true);
    _menuEntry = OverlayEntry(builder: (_) => _buildMenuOverlay());
    overlay.insert(_menuEntry!);
    HapticFeedback.mediumImpact();

    // 长按触发，让进度环继续走到 1（视觉上"环走完=菜单完全展开"）
    _pressController.forward();
    _updateHighlight(details.globalPosition);
  }

  void _handleLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (_menuEntry == null) return;
    _updateHighlight(details.globalPosition);
  }

  void _handleLongPressEnd(LongPressEndDetails details) {
    final idx = _highlightedIndex;
    final items = _menuItems;
    final hit = (idx != null && idx >= 0 && idx < items.length)
        ? items[idx]
        : null;
    // 清空高亮，让收回动画里所有项一起向中心回流（避免某一项保留放大态）
    _highlightedIndex = null;
    _beginMenuClose();
    if (hit != null) {
      HapticFeedback.mediumImpact();
      widget.onAction(hit);
    }
  }

  void _handleLongPressCancel() {
    _highlightedIndex = null;
    _beginMenuClose();
  }

  void _updateHighlight(Offset pointer) {
    final center = _menuCenter;
    if (center == null) return;
    final dx = pointer.dx - center.dx;
    final dy = pointer.dy - center.dy;
    final distance = math.sqrt(dx * dx + dy * dy);
    int? newIndex;
    // 死区：紧贴中心（距离极小）或落入下半圆。其余范围根据角度找最近项，
    // 不限制最大距离 —— 手指拖到屏幕远处也能命中对应方向的项
    if (distance < 18 || dy >= 0) {
      newIndex = null;
    } else {
      final angle = math.atan2(dy, dx); // dy < 0 → angle ∈ (-π, 0)
      final n = _menuItems.length;
      if (n == 1) {
        newIndex = 0;
      } else {
        final step = math.pi / (n - 1);
        final normalized = (angle + math.pi) / step;
        newIndex = normalized.round().clamp(0, n - 1);
      }
    }
    final changed = newIndex != _highlightedIndex;
    _highlightedIndex = newIndex;
    if (changed && newIndex != null) {
      HapticFeedback.selectionClick();
    }
    _menuEntry?.markNeedsBuild();
  }

  Widget _buildMenuOverlay() {
    return _RadialMenuOverlay(
      center: _menuCenter ?? Offset.zero,
      pressArea: _pressArea,
      items: _menuItems,
      highlightedIndex: _highlightedIndex,
      radius: _radiusForCount(_menuItems.length),
      closing: _menuClosing,
      onClosed: () {
        // 收回动画跑完，由 overlay 通知我们真正清理资源
        if (!mounted) return;
        _disposeMenuOverlay();
      },
    );
  }

  // ===== 滑动预览 =====

  void _disposeSwipeOverlay() {
    _scrubThrottleTimer?.cancel();
    _scrubThrottleTimer = null;
    _pendingScrubIndex = null;
    _swipeEntry?.remove();
    _swipeEntry = null;
    _swipeOrigin = null;
    _swipeStart = null;
    _swipeCurrent = Offset.zero;
    _swipeDirection = null;
    _swipeAction = null;
    _swipeTriggerable = false;
    _scrubTargetIndex = null;
    _scrubAppliedIndex = null;
  }

  /// 根据水平位移计算 scrub 目标楼层（真实 post_number）
  int _scrubIndexForDelta(double dx) {
    final total = widget.totalCount;
    if (total <= 1) return widget.currentIndex.clamp(1, math.max(1, total));

    // 固定灵敏度：小范围（±10 楼）内更细腻，不再按话题总长放大跨度
    final deltaFloors = (dx / _kScrubPixelsPerFloor)
        .round()
        .clamp(-_kScrubMaxDeltaFloors, _kScrubMaxDeltaFloors);
    final minFloor = math.max(1, _scrubStartIndex - _kScrubMaxDeltaFloors);
    final maxFloor = math.min(total, _scrubStartIndex + _kScrubMaxDeltaFloors);
    return (_scrubStartIndex + deltaFloors).clamp(minFloor, maxFloor);
  }

  /// 节流后应用跳楼：预览立即更新，列表最多约 70ms 跳一次
  void _scheduleScrubJump(int target) {
    if (widget.totalCount <= 1) return;
    if (target == _scrubAppliedIndex) return;

    _pendingScrubIndex = target;
    if (_scrubThrottleTimer?.isActive ?? false) return;

    void apply() {
      final next = _pendingScrubIndex;
      _pendingScrubIndex = null;
      _scrubThrottleTimer = null;
      if (next == null || next == _scrubAppliedIndex) return;
      _scrubAppliedIndex = next;
      widget.onScrubToIndex(next);
    }

    // 首次立刻跳，后续进入节流窗口
    if (_scrubAppliedIndex == _scrubStartIndex ||
        _scrubAppliedIndex == null) {
      apply();
      _scrubThrottleTimer = Timer(_kScrubJumpThrottle, () {
        if (_pendingScrubIndex != null) apply();
      });
      return;
    }

    _scrubThrottleTimer = Timer(_kScrubJumpThrottle, apply);
  }

  /// 松手时冲刷节流队列，保证落到最终预览楼层
  ///
  /// 即使楼层未变也要回调 finalize，以便页面解锁 scrub 态（底栏/分页锁）
  void _flushScrubJump() {
    _scrubThrottleTimer?.cancel();
    _scrubThrottleTimer = null;
    final next = _pendingScrubIndex ??
        _scrubTargetIndex ??
        _scrubAppliedIndex ??
        _scrubStartIndex;
    _pendingScrubIndex = null;
    if (widget.totalCount <= 1) {
      // 单楼话题也走 end，避免锁死
      widget.onScrubEnd?.call(next);
      return;
    }
    _scrubAppliedIndex = next;
    // 优先走 finalize 回调，让页面可做完整跳转并解锁
    final end = widget.onScrubEnd;
    if (end != null) {
      end(next);
    } else {
      widget.onScrubToIndex(next);
    }
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
    _scrubStartIndex = widget.currentIndex.clamp(
      1,
      math.max(1, widget.totalCount),
    );
    _scrubTargetIndex = null;
    _scrubAppliedIndex = _scrubStartIndex;

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

    // 左右：连续 scrub 跳楼；上滑：保留可配置动作
    ProgressGestureAction? action;
    int? scrubTarget;
    var triggerable = false;

    if (direction == _SwipeDirection.left ||
        direction == _SwipeDirection.right) {
      scrubTarget = _scrubIndexForDelta(dx);
      triggerable = scrubTarget != _scrubStartIndex && widget.totalCount > 1;
      action = null;
    } else if (direction == _SwipeDirection.up) {
      action = prefs.progressGestureSwipeUp;
      if (action == ProgressGestureAction.none) {
        action = null;
      }
      triggerable = action != null && maxDelta >= _kSwipeTriggerDistance;
      scrubTarget = null;
    }

    final directionChanged = direction != _swipeDirection;
    final triggerChanged = triggerable != _swipeTriggerable;
    final scrubChanged = scrubTarget != _scrubTargetIndex;
    if (scrubChanged && scrubTarget != null) {
      // 触觉降频：每 3 楼一次，减轻快速拖时的系统开销
      if ((scrubTarget - _scrubStartIndex).abs() % 3 == 0 ||
          scrubTarget == 1 ||
          scrubTarget == widget.totalCount) {
        HapticFeedback.selectionClick();
      }
      // 预览立刻变；实际列表跳转走节流，避免拖太快卡死
      _scheduleScrubJump(scrubTarget);
    } else if (triggerChanged && triggerable) {
      HapticFeedback.lightImpact();
    } else if (directionChanged && direction != null) {
      HapticFeedback.selectionClick();
    }

    _swipeDirection = direction;
    _swipeAction = action;
    _swipeTriggerable = triggerable;
    _scrubTargetIndex = scrubTarget;
    _swipeEntry?.markNeedsBuild();
  }

  void _handlePanEnd(DragEndDetails details) {
    final triggered = _swipeTriggerable;
    final action = _swipeAction;
    final isHorizontal = _swipeDirection == _SwipeDirection.left ||
        _swipeDirection == _SwipeDirection.right;

    if (isHorizontal) {
      _flushScrubJump();
      HapticFeedback.mediumImpact();
      _disposeSwipeOverlay();
      return;
    }

    _disposeSwipeOverlay();
    if (triggered && action != null) {
      HapticFeedback.mediumImpact();
      widget.onAction(action);
    }
  }

  void _handlePanCancel() {
    // 与松手一致冲刷最终楼层；若未发生水平 scrub 也通知取消以解锁
    final isHorizontal = _swipeDirection == _SwipeDirection.left ||
        _swipeDirection == _SwipeDirection.right;
    if (isHorizontal) {
      _flushScrubJump();
    } else {
      widget.onScrubCancel?.call();
    }
    _disposeSwipeOverlay();
  }

  Widget _buildSwipeOverlay() {
    return _SwipePreviewOverlay(
      origin: _swipeOrigin ?? Offset.zero,
      direction: _swipeDirection,
      action: _swipeAction,
      scrubTargetIndex: _scrubTargetIndex,
      totalCount: widget.totalCount,
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

// ============================== 半圆菜单 Overlay ==============================

class _RadialMenuOverlay extends StatefulWidget {
  const _RadialMenuOverlay({
    required this.center,
    required this.pressArea,
    required this.items,
    required this.highlightedIndex,
    required this.radius,
    required this.closing,
    required this.onClosed,
  });

  final Offset center;
  final Rect? pressArea; // 悬浮条本体的全局矩形，作为替代显示的锚点
  final List<ProgressGestureAction> items;
  final int? highlightedIndex;
  final double radius;

  /// 父层请求收起菜单：动画从当前进度反向跑回 0，结束后调用 [onClosed]
  final bool closing;
  final VoidCallback onClosed;

  @override
  State<_RadialMenuOverlay> createState() => _RadialMenuOverlayState();
}

class _RadialMenuOverlayState extends State<_RadialMenuOverlay>
    with SingleTickerProviderStateMixin {
  // 菜单整体衍生 / 收回动画时长（出场略快、收回略慢以表达"被吸回去"）
  static const Duration _enterDuration = Duration(milliseconds: 220);
  static const Duration _exitDuration = Duration(milliseconds: 180);

  // 顶部 tooltip 底部到半圆顶部之间的间隙（顶部项放大时直径 ~58dp）
  static const double _tooltipGap = 64.0;

  // 背景模糊与暗化稳态强度
  static const double _maxBlur = 8.0;
  static const double _maxDim = 0.22;

  // 菜单项尺寸
  static const double _itemSize = 48.0;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _enterDuration,
    reverseDuration: _exitDuration,
  )..forward();

  bool _closeDispatched = false;

  @override
  void didUpdateWidget(covariant _RadialMenuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.closing && !oldWidget.closing) {
      _controller.reverse().whenCompleteOrCancel(() {
        if (!mounted || _closeDispatched) return;
        _closeDispatched = true;
        widget.onClosed();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 进度条本体中心：项的衍生起点
  Offset get _emitterCenter {
    final rect = widget.pressArea;
    if (rect != null) return rect.center;
    return widget.center;
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final highlightedIndex = widget.highlightedIndex;
    final highlightedAction = (highlightedIndex != null &&
            highlightedIndex >= 0 &&
            highlightedIndex < items.length)
        ? items[highlightedIndex]
        : null;

    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          // 入场用 easeOutBack 让项"弹"出来一点；出场用 easeInCubic 让回缩干脆
          final raw = _controller.value;
          final t = widget.closing
              ? Curves.easeInCubic.transform(raw)
              : Curves.easeOutBack.transform(raw).clamp(0.0, 1.0);
          // tooltip / 背景使用线性 t（避免 easeOutBack 的过冲让它跳动）
          final fadeT = raw;
          return Stack(
            children: [
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: _maxBlur * fadeT,
                    sigmaY: _maxBlur * fadeT,
                  ),
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: _maxDim * fadeT),
                  ),
                ),
              ),
              for (int i = 0; i < items.length; i++)
                _buildItem(context, i, items[i], t, fadeT),
              if (widget.pressArea != null)
                _buildPressAreaIndicator(context, widget.pressArea!, fadeT),
              if (highlightedAction != null && !widget.closing)
                _buildHeaderTooltip(context, highlightedAction, fadeT),
            ],
          );
        },
      ),
    );
  }

  /// 半圆目标位置：第 index 项最终落点
  Offset _itemTargetPosition(int index) {
    final n = widget.items.length;
    final double angle;
    if (n == 1) {
      angle = -math.pi / 2;
    } else {
      final step = math.pi / (n - 1);
      angle = -math.pi + index * step;
    }
    return Offset(
      widget.center.dx + widget.radius * math.cos(angle),
      widget.center.dy + widget.radius * math.sin(angle),
    );
  }

  Widget _buildItem(
    BuildContext context,
    int index,
    ProgressGestureAction action,
    double t,
    double fadeT,
  ) {
    final theme = Theme.of(context);
    final meta = progressGestureActionMeta(context, action);
    final isHighlighted = widget.highlightedIndex == index;
    final emitter = _emitterCenter;
    final target = _itemTargetPosition(index);
    // 衍生：项的中心从进度条 emitter 沿直线 lerp 到目标半圆位置
    final pos = Offset.lerp(emitter, target, t)!;
    // 衍生过程中，项尺寸从 0 长到正常；高亮再额外乘 1.2
    final emergeScale = t.clamp(0.0, 1.0);
    final highlightScale = isHighlighted ? 1.2 : 1.0;
    final scale = emergeScale * highlightScale;
    final renderSize = _itemSize * scale;
    if (renderSize < 0.5) {
      // 尺寸接近 0 时直接不渲染，避免一帧闪烁
      return const SizedBox.shrink();
    }

    return Positioned(
      key: ValueKey('progress_gesture_item_$index'),
      left: pos.dx - renderSize / 2,
      top: pos.dy - renderSize / 2,
      width: renderSize,
      height: renderSize,
      child: Opacity(
        // fadeT 让收回时图标也淡出，避免到最后才"啪"一下消失
        opacity: fadeT.clamp(0.0, 1.0),
        child: Material(
          color: isHighlighted
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          shape: const CircleBorder(),
          elevation: isHighlighted ? 6 : 2,
          shadowColor: isHighlighted
              ? theme.colorScheme.primary.withValues(alpha: 0.4)
              : Colors.black26,
          child: Center(
            child: Icon(
              meta.icon,
              size: 24 * highlightScale,
              color: isHighlighted
                  ? theme.colorScheme.onPrimary
                  : theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderTooltip(
    BuildContext context,
    ProgressGestureAction action,
    double opacity,
  ) {
    final theme = Theme.of(context);
    final meta = progressGestureActionMeta(context, action);
    final mq = MediaQuery.of(context);
    final screenWidth = mq.size.width;
    const margin = 16.0;

    // 基于悬浮条本身（center.dx）居中，双栏布局下也正确
    final clampedX = widget.center.dx.clamp(margin, screenWidth - margin);
    final bottomY = (widget.center.dy - widget.radius - _tooltipGap).clamp(
      mq.padding.top + 56.0,
      mq.size.height,
    );

    return Positioned(
      left: clampedX,
      top: bottomY,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -1.0),
        child: Opacity(
          opacity: opacity,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: screenWidth - margin * 2),
            child: Material(
              color: theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(24),
              elevation: 6,
              shadowColor: theme.colorScheme.primary.withValues(alpha: 0.35),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      meta.icon,
                      size: 18,
                      color: theme.colorScheme.onPrimary,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        meta.label,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onPrimary,
                          fontWeight: FontWeight.w600,
                          height: 1.1,
                          letterSpacing: 0.1,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 在悬浮条原位置画一个 primary 实心 pill 作为替代显示，
  /// 让用户在模糊背景下仍能看到"我刚才按的入口"。
  Widget _buildPressAreaIndicator(
    BuildContext context,
    Rect rect,
    double opacity,
  ) {
    final theme = Theme.of(context);
    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: Opacity(
          opacity: opacity,
          child: Material(
            color: theme.colorScheme.primary,
            shape: const StadiumBorder(),
            elevation: 6,
            shadowColor: theme.colorScheme.primary.withValues(alpha: 0.4),
            child: Center(
              child: Icon(
                Symbols.touch_app_rounded,
                size: 20,
                color: theme.colorScheme.onPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================== 滑动预览 Overlay ==============================

class _SwipePreviewOverlay extends StatelessWidget {
  const _SwipePreviewOverlay({
    required this.origin,
    required this.direction,
    required this.action,
    required this.scrubTargetIndex,
    required this.totalCount,
    required this.triggerable,
    required this.delta,
    required this.triggerDistance,
  });

  /// 悬浮条本体的全局坐标（中心点）
  final Offset origin;
  final _SwipeDirection? direction;
  final ProgressGestureAction? action;
  final int? scrubTargetIndex;
  final int totalCount;
  final bool triggerable;
  final Offset delta;
  final double triggerDistance;

  static const double _pillBaseOffset = 56;
  static const double _pillFollowFactor = 0.55;
  static const double _pillFollowMax = 56;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isScrub = direction == _SwipeDirection.left ||
        direction == _SwipeDirection.right;
    if (direction == null) {
      return const IgnorePointer(child: SizedBox.shrink());
    }
    if (isScrub && scrubTargetIndex == null) {
      return const IgnorePointer(child: SizedBox.shrink());
    }
    if (!isScrub && action == null) {
      return const IgnorePointer(child: SizedBox.shrink());
    }

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

    final IconData icon;
    final String label;
    if (isScrub) {
      icon = direction == _SwipeDirection.left
          ? Symbols.keyboard_double_arrow_left_rounded
          : Symbols.keyboard_double_arrow_right_rounded;
      label = '${scrubTargetIndex!}/$totalCount';
    } else {
      final meta = progressGestureActionMeta(context, action!);
      icon = meta.icon;
      label = meta.label;
    }

    final screenSize = MediaQuery.of(context).size;
    final clampedX = pillCenter.dx.clamp(60.0, screenSize.width - 60.0);
    final clampedY = pillCenter.dy.clamp(40.0, screenSize.height - 40.0);

    return IgnorePointer(
      child: ExcludeSemantics(
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
                          Icon(icon, size: 18, color: fgColor),
                          const SizedBox(width: 6),
                          Text(
                            label,
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
      ),
    );
  }
}
