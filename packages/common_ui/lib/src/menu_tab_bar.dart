import 'dart:math' as math;

import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';

import 'dismissible_popup_menu.dart';
import 'ui_emphasis.dart';

/// 栏目首次点击切换，再次点击选中栏目可打开其筛选菜单。
class MenuTabItem<T> {
  const MenuTabItem({
    required this.label,
    required this.icon,
    this.menuBuilder,
    this.onSelected,
    this.selectedValue,
    this.badgeCount,
  }) : assert(menuBuilder == null || onSelected != null);

  final String label;
  final IconData icon;
  final PopupMenuItemBuilder<T>? menuBuilder;
  final ValueChanged<T>? onSelected;
  final T? selectedValue;

  /// 未读数，为 null 或 0 时不显示。常驻图标时是图标角标，常驻文字时跟在文字后。
  final int? badgeCount;
}

/// 栏目常驻显示的内容，另一部分在选中时显现。两种形态共用尺寸与揭示动画。
enum MenuTabMode {
  /// 常驻图标，选中时展开文字。适合栏目固定、需要省位的导航（如资料页）。
  icon,

  /// 常驻文字，选中时显现图标。适合需要一眼读懂的分类筛选（如通知面板）。
  label,
}

/// 栏目导航。选中项显现另一半内容，菜单复用公共弹层的手势与键盘交互。
class MenuTabBar<T> extends StatefulWidget implements PreferredSizeWidget {
  const MenuTabBar({
    super.key,
    required this.controller,
    required this.items,
    this.mode = MenuTabMode.icon,
    this.showAllLabels = false,
  });

  final TabController controller;
  final List<MenuTabItem<T>> items;
  final MenuTabMode mode;

  /// 所有栏目都显示完整内容（宽屏空间充足时）
  final bool showAllLabels;

  @override
  Size get preferredSize => const Size.fromHeight(48);

  @override
  State<MenuTabBar<T>> createState() => _MenuTabBarState<T>();
}

class _MenuTabBarState<T> extends State<MenuTabBar<T>> {
  late int _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.controller.index;
    widget.controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(MenuTabBar<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
      _selected = widget.controller.index;
    }
  }

  void _onChanged() {
    if (_selected != widget.controller.index) {
      setState(() => _selected = widget.controller.index);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    assert(widget.items.length == widget.controller.length);
    if (widget.items.isEmpty) return const SizedBox(height: 48);
    final theme = Theme.of(context);
    final labelMode = widget.mode == MenuTabMode.label;
    // 常驻文字时未选中项也显示文字，字重降一档避免整排过重
    final style = theme.textTheme.titleSmall!.copyWith(
      fontWeight: labelMode ? FontWeight.w600 : FontWeight.w700,
    );
    final countStyle = theme.textTheme.labelSmall!.copyWith(
      color: context.emphasis.selected,
      fontWeight: FontWeight.w600,
    );
    double measure(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    final widths = <double>[];
    for (var index = 0; index < widget.items.length; index++) {
      final item = widget.items[index];
      final count = labelMode ? _countText(item) : null;
      widths.add(
        44 +
            measure(item.label, style) +
            (count == null ? 0 : 4 + measure(count, countStyle)) +
            (item.menuBuilder == null ? 0 : 22),
      );
    }

    return AnimatedBuilder(
      animation: widget.controller.animation!,
      builder: (context, _) {
        // 横滑过程中 index 尚未更新，展开程度直接跟随页面位置。
        final position = widget.controller.animation!.value;
        final progress = [
          for (var index = 0; index < widget.items.length; index++)
            widget.showAllLabels
                ? 1.0
                : (1 - (position - index).abs()).clamp(0.0, 1.0),
        ];
        return LayoutBuilder(
          builder: (context, constraints) {
            final totalWidth = widths.fold<double>(
              0,
              (sum, width) => sum + width,
            );
            final extra =
                math.max(0.0, constraints.maxWidth - totalWidth) /
                widget.items.length;
            final slotWidth = constraints.maxWidth / widget.items.length;
            final equalSlots =
                !widget.showAllLabels &&
                widths.every((width) => width <= slotWidth);
            return TabBar(
              controller: widget.controller,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelPadding: EdgeInsets.zero,
              labelColor: theme.colorScheme.onSurface,
              unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
              labelStyle: style,
              indicatorSize: TabBarIndicatorSize.tab,
              indicatorColor: context.emphasis.selected,
              indicatorWeight: 3,
              dividerColor: theme.colorScheme.outlineVariant,
              tabs: [
                for (var index = 0; index < widget.items.length; index++)
                  _tab(
                    context,
                    widget.items[index],
                    index,
                    equalSlots ? slotWidth : widths[index] + extra,
                    widths[index] - 44,
                    progress[index],
                    countStyle,
                  ),
              ],
            );
          },
        );
      },
    );
  }

  static String? _countText(MenuTabItem<Object?> item) {
    final count = item.badgeCount ?? 0;
    if (count <= 0) return null;
    return count > 99 ? '99+' : '$count';
  }

  Widget _tab(
    BuildContext context,
    MenuTabItem<T> item,
    int index,
    double width,
    double labelWidth,
    double progress,
    TextStyle countStyle,
  ) {
    final active = index == _selected;
    final direction = Directionality.of(context);
    final labelMode = widget.mode == MenuTabMode.label;
    final count = labelMode ? _countText(item) : null;
    final icon = ExcludeSemantics(
      child: Badge(
        isLabelVisible: !labelMode && _countText(item) != null,
        label: Text(_countText(item) ?? ''),
        child: Icon(item.icon, size: 22),
      ),
    );
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(item.label),
        if (count != null) ...[
          const SizedBox(width: 4),
          Text(count, style: countStyle),
        ],
        if (item.menuBuilder != null) ...[
          const SizedBox(width: 4),
          const ExcludeSemantics(
            child: Icon(Symbols.expand_more_rounded, size: 18),
          ),
        ],
      ],
    );
    // 常驻部分随选中程度让位，显现部分停在最终位置，由软边遮罩从
    // 相邻一侧逐渐露出，避免切断字形或图标。
    final revealWidth = labelMode ? 22.0 : labelWidth;
    final revealEdge = (1 - progress) * (revealWidth + 6) / 2 - 6;
    Widget reveal(Widget child) => Opacity(
      opacity: progress,
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => LinearGradient(
          // 文字从图标一侧（起始侧）露出，图标从文字一侧（末端侧）露出
          begin:
              (labelMode
                      ? AlignmentDirectional.centerEnd
                      : AlignmentDirectional.centerStart)
                  .resolve(direction),
          end:
              (labelMode
                      ? AlignmentDirectional.centerStart
                      : AlignmentDirectional.centerEnd)
                  .resolve(direction),
          colors: const [Colors.transparent, Colors.white],
          stops: [
            (revealEdge / revealWidth).clamp(0.0, 1.0),
            ((revealEdge + 6) / revealWidth).clamp(0.0, 1.0),
          ],
        ).createShader(bounds),
        child: child,
      ),
    );
    final content = SizedBox(
      width: width,
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: labelMode
            ? [
                if (progress > 0)
                  PositionedDirectional(
                    start: (width - 28 - labelWidth) / 2,
                    child: reveal(icon),
                  ),
                PositionedDirectional(
                  start: (width - labelWidth + 28 * progress) / 2,
                  width: labelWidth,
                  child: label,
                ),
              ]
            : [
                PositionedDirectional(
                  start: (width - 22 - (labelWidth + 6) * progress) / 2,
                  child: icon,
                ),
                if (progress > 0 && labelWidth > 0)
                  PositionedDirectional(
                    start: (width + 28 - labelWidth) / 2,
                    width: labelWidth,
                    child: reveal(label),
                  ),
              ],
      ),
    );
    return Tab(
      height: 48,
      child: active && item.menuBuilder != null
          ? SwipeDismissiblePopupMenuButton<T>(
              tooltip: item.label,
              padding: EdgeInsets.zero,
              position: PopupMenuPosition.under,
              initialValue: item.selectedValue,
              itemBuilder: item.menuBuilder!,
              onSelected: item.onSelected,
              child: content,
            )
          : Tooltip(
              message: item.label,
              child: Semantics(
                // 常驻文字时文字本身可读，只需补未读数
                label: active || labelMode
                    ? null
                    : _countText(item) != null
                    ? '${item.label} ${item.badgeCount}'
                    : item.label,
                child: content,
              ),
            ),
    );
  }
}
