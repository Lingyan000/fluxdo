import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'm3e_flags.dart';
import 'm3e_motion.dart';

/// 一个联排按钮项。
class M3eButtonGroupItem<T> {
  final T value;
  final Widget label;
  final Widget? icon;

  const M3eButtonGroupItem({required this.value, required this.label, this.icon});
}

/// Material 3 Expressive 联排按钮组(connected button group)。
///
/// 规格对照 Compose ButtonGroup.kt / ConnectedButtonGroupSmallTokens:
/// - 首/尾外侧全圆角,内侧小圆角,块间细缝(与 SegmentedCardGroup 同构);
/// - **按压联动**:按下项在按住期间展宽 `ExpandedRatio = 0.15`(自身宽度
///   的 15%),相邻项被挤压同量 —— M3E 标志性的"胖瘦联动";
/// - 宽度动画 [M3eMotion.fastSpatial] 弹簧;选中态底色 secondaryContainer;
/// - 选中形状:选中项圆角放大(接近全圆),对照 SelectedContainerShapeRound。
///
/// M3E 开关关闭时回退 [SegmentedButton](单选语义一致)。
class M3eButtonGroup<T> extends StatefulWidget {
  final List<M3eButtonGroupItem<T>> items;
  final T selected;
  final ValueChanged<T> onSelected;

  /// 每项内边距。
  final EdgeInsetsGeometry itemPadding;

  const M3eButtonGroup({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelected,
    this.itemPadding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
  });

  @override
  State<M3eButtonGroup<T>> createState() => _M3eButtonGroupState<T>();
}

/// Compose ButtonGroup 的按压展宽比例。
const double _kExpandedRatio = 0.15;

/// 块间距(ButtonGroupSmallTokens.BetweenSpace 同档)。
const double _kBetweenSpace = 2.0;

/// 外侧全圆用大值近似;内侧小圆角(ConnectedButtonGroup InnerCorner)。
const double _kInnerRadius = 8.0;

class _M3eButtonGroupState<T> extends State<M3eButtonGroup<T>>
    with SingleTickerProviderStateMixin {
  /// 按住中的 index(-1 = 无);驱动展宽/挤压布局动画。
  int _pressedIndex = -1;

  /// initState 创建而非 late final 惰性初始化:回退分支若从未触碰,
  /// dispose 时才首次创建会在挂 ticker 时查已失效的祖先(TickerMode)。
  late final AnimationController _pressAnim;

  static final SpringDescription _spring = M3eMotion.fastSpatial.description;

  @override
  void initState() {
    super.initState();
    _pressAnim = AnimationController.unbounded(vsync: this);
  }

  @override
  void dispose() {
    _pressAnim.dispose();
    super.dispose();
  }

  void _setPressed(int index, bool pressed) {
    final target = pressed ? index : -1;
    if (_pressedIndex == target) return;
    // 按压瞬间轻触感,配合展宽/挤压的"捏一下"观感。
    if (pressed) HapticFeedback.selectionClick();
    setState(() => _pressedIndex = target);
    _pressAnim
      ..stop()
      ..value = pressed ? 0 : 1;
    _pressAnim.animateWith(
      SpringSimulation(_spring, _pressAnim.value, pressed ? 1 : 0, 0),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!M3eFlags.of(context).enabled) {
      return SegmentedButton<T>(
        segments: [
          for (final item in widget.items)
            ButtonSegment<T>(
              value: item.value,
              label: item.label,
              icon: item.icon,
            ),
        ],
        selected: {widget.selected},
        onSelectionChanged: (set) => widget.onSelected(set.first),
        showSelectedIcon: false,
      );
    }

    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _pressAnim,
      builder: (context, _) {
        final press = _pressAnim.value.clamp(0.0, 1.2);
        // Expanded 按 flex 分宽,需要有界宽度约束(设置页调用处均满足)。
        return Row(
          children: [
            for (var i = 0; i < widget.items.length; i++) ...[
              if (i > 0) const SizedBox(width: _kBetweenSpace),
              _buildItem(context, scheme, i, press),
            ],
          ],
        );
      },
    );
  }

  Widget _buildItem(
    BuildContext context,
    ColorScheme scheme,
    int index,
    double press,
  ) {
    final item = widget.items[index];
    final selected = item.value == widget.selected;
    final isPressed = index == _pressedIndex;
    final isNeighbor =
        _pressedIndex >= 0 && (index - _pressedIndex).abs() == 1;

    // 按压项展宽 15%,相邻项挤压同量(Compose animateWidth 语义);
    // 用 flex 权重近似:基准 1000,变化量 150×press。
    final delta = (_kExpandedRatio * 1000 * press).round();
    final flex = 1000 + (isPressed ? delta : 0) - (isNeighbor ? delta : 0);

    final isFirst = index == 0;
    final isLast = index == widget.items.length - 1;
    // 选中项圆角向全圆靠拢(SelectedContainerShapeRound);未选中项
    // 首尾外侧全圆、内侧小圆角。
    final outer = const Radius.circular(999);
    final inner = Radius.circular(selected ? 999 : _kInnerRadius);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.horizontal(
        left: isFirst ? outer : inner,
        right: isLast ? outer : inner,
      ),
    );

    return Expanded(
      // flex 由弹簧逐帧驱动(AnimatedBuilder 重建),布局插值即动画本体。
      flex: flex.clamp(700, 1300),
      child: Material(
        color:
            selected ? scheme.secondaryContainer : scheme.surfaceContainerHigh,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => widget.onSelected(item.value),
          onTapDown: (_) => _setPressed(index, true),
          onTapCancel: () => _setPressed(index, false),
          onTapUp: (_) => _setPressed(index, false),
          child: Padding(
            padding: widget.itemPadding,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item.icon != null) ...[
                  IconTheme.merge(
                    data: IconThemeData(
                      size: 18,
                      color: selected
                          ? scheme.onSecondaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                    child: item.icon!,
                  ),
                  const SizedBox(width: 6),
                ],
                DefaultTextStyle.merge(
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected
                        ? scheme.onSecondaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                  child: item.label,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
