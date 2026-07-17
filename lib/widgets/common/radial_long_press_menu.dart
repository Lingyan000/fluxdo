import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart';

/// 径向菜单项（图标 + 标签 + 选中回调）
class RadialMenuItem {
  const RadialMenuItem({
    required this.icon,
    required this.label,
    required this.onSelected,
  });

  final IconData icon;
  final String label;
  final VoidCallback onSelected;
}

/// 半圆展开方向：
/// - [up] 锚点上方半圆（进度悬浮条场景，锚点在屏幕底部）
/// - [down] 锚点下方半圆（头像贴近屏幕顶部时翻转使用）
enum RadialMenuDirection { up, down }

/// 把角度归一到 (-π, π]
double _wrapAngle(double a) {
  var r = a % (2 * math.pi);
  if (r > math.pi) r -= 2 * math.pi;
  if (r <= -math.pi) r += 2 * math.pi;
  return r;
}

/// 径向菜单会话：管理 OverlayEntry 生命周期、高亮命中与触觉反馈。
///
/// 角度统一使用「极轴偏角 φ」坐标系：φ = 0 指向展开方向的正前方
/// （up 为正上、down 为正下），左负右正 —— 两方向下第 0 项都在左侧，
/// 且不经过 atan2 的 ±π 接缝。默认窗口 [-π/2, π/2] 即完整半圆。
///
/// 调用方负责手势识别（长按/拖动），把事件转发给本会话：
/// - onLongPressStart → [open] + [updatePointer]
/// - onLongPressMoveUpdate → [updatePointer]
/// - onLongPressEnd → [selectAndClose]
/// - onLongPressCancel → [cancel]
/// - State.dispose → [dispose]
class RadialMenuSession {
  OverlayEntry? _menuEntry;
  Offset? _menuCenter;
  Rect? _pressArea;
  int? _highlightedIndex;
  List<RadialMenuItem> _items = const [];
  RadialMenuDirection _direction = RadialMenuDirection.up;
  double _radius = 92;
  double _sweepStart = -math.pi / 2;
  double _sweepEnd = math.pi / 2;
  Widget Function(BuildContext context, Rect rect, double opacity)?
  _pressAreaIndicatorBuilder;
  // true 表示已请求菜单收起：overlay 内部反向播放衍生动画，结束后才真正清理
  bool _menuClosing = false;

  bool get isActive => _menuEntry != null;

  /// 根据菜单项数取半径（项越多半圆越大，避免图标拥挤）
  static double radiusForCount(int count) {
    if (count <= 4) return 92;
    if (count <= 6) return 108;
    return 128;
  }

  /// 插入菜单 overlay 并触发中等触觉反馈。
  ///
  /// [center] 扇形圆心（全局坐标）；[pressArea] 按压区域的全局矩形，
  /// 菜单弹出后在此位置画替代显示；[radius] 缺省按项数取 [radiusForCount]。
  /// [sweepStart]/[sweepEnd] 为扇形角度窗口（极轴偏角 φ，φ=0 指向展开
  /// 方向正前方、左负右正），默认 [-π/2, π/2] 完整半圆。
  void open({
    required BuildContext context,
    required Offset center,
    Rect? pressArea,
    required List<RadialMenuItem> items,
    RadialMenuDirection direction = RadialMenuDirection.up,
    double? radius,
    double sweepStart = -math.pi / 2,
    double sweepEnd = math.pi / 2,
    Widget Function(BuildContext context, Rect rect, double opacity)?
    pressAreaIndicatorBuilder,
  }) {
    if (items.isEmpty) return;
    // 如果上一轮菜单还在收回动画中，立刻强制清理，避免两个 overlay 叠加
    if (_menuEntry != null) {
      dispose();
    }

    _menuCenter = center;
    _pressArea = pressArea;
    _items = items;
    _direction = direction;
    _radius = radius ?? radiusForCount(items.length);
    _sweepStart = sweepStart;
    _sweepEnd = sweepEnd;
    _pressAreaIndicatorBuilder = pressAreaIndicatorBuilder;
    _highlightedIndex = null;

    final overlay = Overlay.of(context, rootOverlay: true);
    _menuEntry = OverlayEntry(builder: (_) => _buildOverlay());
    overlay.insert(_menuEntry!);
    HapticFeedback.mediumImpact();
  }

  /// 根据手指全局坐标更新高亮项
  void updatePointer(Offset pointer) {
    final center = _menuCenter;
    if (center == null || _menuEntry == null) return;
    final dx = pointer.dx - center.dx;
    final dy = pointer.dy - center.dy;
    final distance = math.sqrt(dx * dx + dy * dy);
    int? newIndex;
    // 极轴偏角 φ：0 = 展开方向正前方（up 为正上、down 为正下），左负右正。
    // up: 正上为屏幕角 -π/2 → φ = angle + π/2
    // down: 正下为屏幕角 π/2，且屏幕左侧同样映射为 φ 负 → φ = π/2 - angle
    final up = _direction == RadialMenuDirection.up;
    final angle = math.atan2(dy, dx);
    final phi = up
        ? _wrapAngle(angle + math.pi / 2)
        : _wrapAngle(math.pi / 2 - angle);
    // 死区三条：紧贴圆心；手指还停在按压区域上（长按起手位置，避免
    // 倾斜窗口下菜单一弹出就误高亮端项）；落在窗口背面（偏离窗口中线
    // 超过 π/2 或窗口半宽+余量，即明显拖回按压侧）。
    // 窗口内及边缘附近可命中，超窗 clamp 到端项。
    final mid = (_sweepStart + _sweepEnd) / 2;
    final offMid = (phi - mid).abs();
    final halfSweep = (_sweepEnd - _sweepStart) / 2;
    final deadBeyond = math.max(halfSweep + 0.35, math.pi / 2);
    final onPressArea =
        _pressArea != null && _pressArea!.inflate(6).contains(pointer);
    if (distance < 18 || onPressArea || offMid > deadBeyond) {
      newIndex = null;
    } else {
      final n = _items.length;
      final step = n > 1 ? (_sweepEnd - _sweepStart) / (n - 1) : 0.0;
      if (n == 1 || step <= 1e-6) {
        newIndex = 0;
      } else {
        final normalized = (phi - _sweepStart) / step;
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

  /// 松手：触发当前高亮项（若有）并开始收回动画
  void selectAndClose() {
    final idx = _highlightedIndex;
    final items = _items;
    final hit = (idx != null && idx >= 0 && idx < items.length)
        ? items[idx]
        : null;
    // 清空高亮，让收回动画里所有项一起向中心回流（避免某一项保留放大态）
    _highlightedIndex = null;
    _beginClose();
    if (hit != null) {
      HapticFeedback.mediumImpact();
      hit.onSelected();
    }
  }

  /// 手势取消：直接开始收回动画
  void cancel() {
    _highlightedIndex = null;
    _beginClose();
  }

  /// 立即移除 overlay 并清理状态（State.dispose 时调用）
  void dispose() {
    _menuEntry?.remove();
    _menuEntry = null;
    _menuCenter = null;
    _pressArea = null;
    _highlightedIndex = null;
    _items = const [];
    _pressAreaIndicatorBuilder = null;
    _menuClosing = false;
  }

  /// 触发菜单收起：先反向播放衍生动画，结束后再调用 [dispose]
  void _beginClose() {
    if (_menuEntry == null || _menuClosing) {
      dispose();
      return;
    }
    _menuClosing = true;
    _menuEntry?.markNeedsBuild();
  }

  Widget _buildOverlay() {
    return RadialMenuOverlay(
      center: _menuCenter ?? Offset.zero,
      pressArea: _pressArea,
      items: _items,
      highlightedIndex: _highlightedIndex,
      radius: _radius,
      direction: _direction,
      sweepStart: _sweepStart,
      sweepEnd: _sweepEnd,
      closing: _menuClosing,
      pressAreaIndicatorBuilder: _pressAreaIndicatorBuilder,
      onClosed: dispose,
    );
  }
}

/// 径向菜单 Overlay：背景模糊 + 半圆衍生菜单项 + 高亮 tooltip
class RadialMenuOverlay extends StatefulWidget {
  const RadialMenuOverlay({
    super.key,
    required this.center,
    required this.pressArea,
    required this.items,
    required this.highlightedIndex,
    required this.radius,
    required this.closing,
    required this.onClosed,
    this.direction = RadialMenuDirection.up,
    this.sweepStart = -math.pi / 2,
    this.sweepEnd = math.pi / 2,
    this.pressAreaIndicatorBuilder,
  });

  final Offset center;

  /// 按压区域的全局矩形，作为替代显示的锚点
  final Rect? pressArea;
  final List<RadialMenuItem> items;
  final int? highlightedIndex;
  final double radius;
  final RadialMenuDirection direction;

  /// 扇形角度窗口（极轴偏角 φ：0 = 展开方向正前方，左负右正）。
  /// 屏幕边缘时旋转/收窄窗口可让弧始终锚定圆心，而不是把圆心挪走。
  final double sweepStart;
  final double sweepEnd;

  /// 父层请求收起菜单：动画从当前进度反向跑回 0，结束后调用 [onClosed]
  final bool closing;
  final VoidCallback onClosed;

  /// 按压区域替代显示的自定义 builder；null 时用默认的 primary 胶囊 + 触摸图标
  final Widget Function(BuildContext context, Rect rect, double opacity)?
  pressAreaIndicatorBuilder;

  @override
  State<RadialMenuOverlay> createState() => _RadialMenuOverlayState();
}

class _RadialMenuOverlayState extends State<RadialMenuOverlay>
    with SingleTickerProviderStateMixin {
  // 菜单整体衍生 / 收回动画时长（出场略快、收回略慢以表达"被吸回去"）
  static const Duration _enterDuration = Duration(milliseconds: 220);
  static const Duration _exitDuration = Duration(milliseconds: 180);

  // tooltip 与半圆弧顶之间的间隙（顶部项放大时直径 ~58dp）
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
  void didUpdateWidget(covariant RadialMenuOverlay oldWidget) {
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

  /// 按压区域中心：项的衍生起点
  Offset get _emitterCenter {
    final rect = widget.pressArea;
    if (rect != null) return rect.center;
    return widget.center;
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final highlightedIndex = widget.highlightedIndex;
    final highlightedItem =
        (highlightedIndex != null &&
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
              if (highlightedItem != null && !widget.closing)
                _buildHeaderTooltip(context, highlightedItem, fadeT),
            ],
          );
        },
      ),
    );
  }

  /// 扇形目标位置：第 index 项最终落点
  Offset _itemTargetPosition(int index) {
    final n = widget.items.length;
    final up = widget.direction == RadialMenuDirection.up;
    // 极轴偏角 φ：单项放窗口中点，多项沿窗口均匀分布
    final double phi;
    if (n == 1) {
      phi = (widget.sweepStart + widget.sweepEnd) / 2;
    } else {
      final step = (widget.sweepEnd - widget.sweepStart) / (n - 1);
      phi = widget.sweepStart + index * step;
    }
    // 换回屏幕角（与 updatePointer 的映射互逆）：
    // up: angle = φ - π/2；down: angle = π/2 - φ
    final angle = up ? phi - math.pi / 2 : math.pi / 2 - phi;
    return Offset(
      widget.center.dx + widget.radius * math.cos(angle),
      widget.center.dy + widget.radius * math.sin(angle),
    );
  }

  Widget _buildItem(
    BuildContext context,
    int index,
    RadialMenuItem item,
    double t,
    double fadeT,
  ) {
    final theme = Theme.of(context);
    final isHighlighted = widget.highlightedIndex == index;
    final emitter = _emitterCenter;
    final target = _itemTargetPosition(index);
    // 衍生：项的中心从按压区域 emitter 沿直线 lerp 到目标半圆位置
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
      key: ValueKey('radial_menu_item_$index'),
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
              item.icon,
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
    RadialMenuItem item,
    double opacity,
  ) {
    final theme = Theme.of(context);
    final mq = MediaQuery.of(context);
    final up = widget.direction == RadialMenuDirection.up;

    // 水平锚定在扇形窗口的角中线上（而非圆心正上方）：
    // 贴边旋转窗口时 tooltip 跟着弧走，与菜单项视觉成组
    final mid = (widget.sweepStart + widget.sweepEnd) / 2;
    final anchorX = widget.center.dx + widget.radius * math.sin(mid);
    // up: 药丸底边贴弧顶上方 gap 处；down: 药丸顶边贴弧底下方 gap 处
    final anchorY = up
        ? widget.center.dy - widget.radius - _tooltipGap
        : widget.center.dy + widget.radius + _tooltipGap;

    return Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _TooltipLayoutDelegate(
          anchor: Offset(anchorX, anchorY),
          growsDown: !up,
          safeInsets: mq.padding,
        ),
        child: Opacity(
          opacity: opacity,
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
                    item.icon,
                    size: 18,
                    color: theme.colorScheme.onPrimary,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      item.label,
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
    );
  }

  /// 在按压区域原位置画替代显示，让用户在模糊背景下仍能看到"我刚才按的入口"。
  /// 默认实现：primary 实心 pill + 触摸图标（进度悬浮条样式）。
  Widget _buildPressAreaIndicator(
    BuildContext context,
    Rect rect,
    double opacity,
  ) {
    final custom = widget.pressAreaIndicatorBuilder;
    if (custom != null) {
      return Positioned.fromRect(
        rect: rect,
        child: IgnorePointer(child: custom(context, rect, opacity)),
      );
    }
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

/// tooltip 药丸定位：以 [anchor] 为水平中心 / 垂直端点摆放，
/// 测得药丸实际尺寸后整体 clamp 在屏幕安全区内，任何标签长度都不会溢出。
class _TooltipLayoutDelegate extends SingleChildLayoutDelegate {
  const _TooltipLayoutDelegate({
    required this.anchor,
    required this.growsDown,
    required this.safeInsets,
  });

  /// 锚点：up 方向为药丸底边中点，down 方向（[growsDown]）为顶边中点
  final Offset anchor;
  final bool growsDown;
  final EdgeInsets safeInsets;

  static const double _margin = 12.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      maxWidth: math.max(0, constraints.maxWidth - _margin * 2),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double x = (anchor.dx - childSize.width / 2).clamp(
      _margin,
      math.max(_margin, size.width - _margin - childSize.width),
    );
    final rawY = growsDown ? anchor.dy : anchor.dy - childSize.height;
    final double y = rawY.clamp(
      safeInsets.top + _margin,
      math.max(
        safeInsets.top + _margin,
        size.height - safeInsets.bottom - _margin - childSize.height,
      ),
    );
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_TooltipLayoutDelegate oldDelegate) =>
      anchor != oldDelegate.anchor ||
      growsDown != oldDelegate.growsDown ||
      safeInsets != oldDelegate.safeInsets;
}

/// 长按弹出径向菜单的便捷包装：内置 tap + 长按手势与 [RadialMenuSession]。
///
/// 自动处理锚点越界（与进度悬浮条不同，锚点可能在列表任意位置）：
/// - 上方放不下时翻转为向下展开（列表顶部的头像）
/// - 贴左右屏幕边缘时**圆心保持锚定在锚点上**，优先「旋转扇形窗口」
///   （如贴左边缘时扇形从"左→上→右"转为"上→右→右下"），其次收窄窗口，
///   仅当窗口窄到项拥挤时才加大半径 —— 保证菜单项始终紧贴锚点展开
class RadialLongPressMenu extends StatefulWidget {
  const RadialLongPressMenu({
    super.key,
    required this.child,
    required this.itemsBuilder,
    this.onTap,
    // 略低于 kLongPressTimeout(500ms)保持跟手,但远高于曾用的 200ms——
    // 从容的单击(尤其触摸板)按压常超 200ms,会被误判为长按吞掉 onTap
    this.longPressDuration = const Duration(milliseconds: 420),
    this.pressAreaIndicatorBuilder,
  });

  final Widget child;

  /// 长按触发瞬间求值；返回空列表则不弹菜单
  final List<RadialMenuItem> Function() itemsBuilder;

  /// 透传单击（如头像点击弹用户卡片）
  final VoidCallback? onTap;

  final Duration longPressDuration;

  /// 按压区域替代显示（如画头像本身），null 用默认 pill
  final Widget Function(BuildContext context, Rect rect, double opacity)?
  pressAreaIndicatorBuilder;

  @override
  State<RadialLongPressMenu> createState() => _RadialLongPressMenuState();
}

class _RadialLongPressMenuState extends State<RadialLongPressMenu> {
  final RadialMenuSession _session = RadialMenuSession();

  /// 项放大态的最大半径（48 * 1.2 / 2），加边距用于越界判断
  static const double _itemHalf = 29.0;
  static const double _edgeMargin = 8.0;

  /// 相邻项圆心间的最小弧长（48 项径 + 8 间隙）
  static const double _minArcPerItem = 56.0;

  /// 扇形单侧最大偏角（弧度，~115°）：允许窗口越过水平线一点，
  /// 让贴边时的扇子有足够展开空间，但不至于绕到锚点背面
  static const double _maxTilt = 2.0;

  /// 半径补偿上限（仅在窗口收窄仍不够时启用）
  static const double _maxRadius = 150.0;

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  void _handleLongPressStart(LongPressStartDetails details) {
    final items = widget.itemsBuilder();
    if (items.isEmpty) return;

    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final topLeft = box.localToGlobal(Offset.zero);
    final rect = topLeft & box.size;

    final mq = MediaQuery.of(context);
    final cx = rect.center.dx;
    final xMin = _edgeMargin + _itemHalf;
    final xMax = mq.size.width - _edgeMargin - _itemHalf;

    // 求扇形窗口（极轴偏角 φ，0 = 正前方，左负右正），圆心钉死在锚点：
    // 1) 由屏幕左右边界反解 φ 允许区间 [lo, hi]（项水平偏移 = R·sin φ）
    // 2) 优先只用水平线以内的部分 [loPref, hiPref]（屏幕中部即完整半圆）
    // 3) 不够排下所有项时向水平线外延伸到刚好够（旋转+收窄，不挪圆心）
    // 4) 仍不够才加大半径重算（半径越大约束越松、所需角度越小）
    double radius = RadialMenuSession.radiusForCount(items.length);
    double sweepStart = -math.pi / 2;
    double sweepEnd = math.pi / 2;
    for (var i = 0; i < 3; i++) {
      final sMin = (xMin - cx) / radius;
      final sMax = (xMax - cx) / radius;
      final lo = sMin <= -1 ? -_maxTilt : math.asin(sMin.clamp(-1.0, 1.0));
      final hi = sMax >= 1 ? _maxTilt : math.asin(sMax.clamp(-1.0, 1.0));
      final loPref = math.max(lo, -math.pi / 2);
      final hiPref = math.min(hi, math.pi / 2);
      final needed = items.length > 1
          ? _minArcPerItem * (items.length - 1) / radius
          : 0.0;
      if (hiPref - loPref >= needed) {
        sweepStart = loPref;
        sweepEnd = hiPref;
        break;
      }
      if (hi - lo >= needed) {
        sweepStart = (-needed / 2).clamp(lo, hi - needed);
        sweepEnd = sweepStart + needed;
        break;
      }
      // 整个允许区间都排不下：加大半径（或已到上限时用满区间兜底）
      sweepStart = lo;
      sweepEnd = hi;
      if (radius >= _maxRadius) break;
      radius = math.min(
        _minArcPerItem * (items.length - 1) / math.max(hi - lo, 0.3),
        _maxRadius,
      );
    }

    // 垂直：优先向上展开；上方放不下（贴近屏幕顶部）则翻转向下。
    // 不做圆心下移 clamp——那会让按压点落到圆心上方，长按瞬间误高亮某一项。
    final fitExtent = radius + _itemHalf + _edgeMargin;
    final up = rect.top - fitExtent >= mq.padding.top;
    final direction = up ? RadialMenuDirection.up : RadialMenuDirection.down;
    final anchorY = up ? rect.top : rect.bottom;

    _session.open(
      context: context,
      center: Offset(cx, anchorY),
      pressArea: rect,
      items: items,
      direction: direction,
      radius: radius,
      sweepStart: sweepStart,
      sweepEnd: sweepEnd,
      pressAreaIndicatorBuilder: widget.pressAreaIndicatorBuilder,
    );
    _session.updatePointer(details.globalPosition);
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.deferToChild,
      gestures: <Type, GestureRecognizerFactory>{
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              () => TapGestureRecognizer(),
              (instance) {
                instance.onTap = widget.onTap;
              },
            ),
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () =>
                  LongPressGestureRecognizer(duration: widget.longPressDuration),
              (instance) {
                instance.onLongPressStart = _handleLongPressStart;
                instance.onLongPressMoveUpdate = (d) =>
                    _session.updatePointer(d.globalPosition);
                instance.onLongPressEnd = (_) => _session.selectAndClose();
                instance.onLongPressCancel = _session.cancel;
              },
            ),
      },
      child: widget.child,
    );
  }
}
