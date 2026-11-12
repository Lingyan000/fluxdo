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
  }) : assert(menuBuilder == null || onSelected != null);

  final String label;
  final IconData icon;
  final PopupMenuItemBuilder<T>? menuBuilder;
  final ValueChanged<T>? onSelected;
  final T? selectedValue;
}

/// 图标栏目导航。选中项展开文字，菜单复用公共弹层的手势与键盘交互。
class MenuTabBar<T> extends StatefulWidget implements PreferredSizeWidget {
  const MenuTabBar({
    super.key,
    required this.controller,
    required this.items,
    this.showAllLabels = false,
  });

  final TabController controller;
  final List<MenuTabItem<T>> items;
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
    final style = theme.textTheme.titleSmall!.copyWith(
      fontWeight: FontWeight.w700,
    );
    final widths = <double>[];
    for (var index = 0; index < widget.items.length; index++) {
      final item = widget.items[index];
      final painter = TextPainter(
        text: TextSpan(text: item.label, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      widths.add(44 + painter.width + (item.menuBuilder == null ? 0 : 22));
      painter.dispose();
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
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _tab(
    BuildContext context,
    MenuTabItem<T> item,
    int index,
    double width,
    double labelWidth,
    double progress,
  ) {
    final active = index == _selected;
    final direction = Directionality.of(context);
    final labelStart = (width + 28 - labelWidth) / 2;
    final iconStart = (width - 22 - (labelWidth + 6) * progress) / 2;
    // 文字保持最终位置，从图标旁逐渐显露，软边遮罩避免切断字形。
    final revealEdge = (1 - progress) * (labelWidth + 6) / 2 - 6;
    final content = SizedBox(
      width: width,
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          PositionedDirectional(
            start: iconStart,
            child: ExcludeSemantics(child: Icon(item.icon, size: 22)),
          ),
          if (progress > 0 && labelWidth > 0)
            PositionedDirectional(
              start: labelStart,
              width: labelWidth,
              child: Opacity(
                opacity: progress,
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (bounds) => LinearGradient(
                    begin: AlignmentDirectional.centerStart.resolve(direction),
                    end: AlignmentDirectional.centerEnd.resolve(direction),
                    colors: const [Colors.transparent, Colors.white],
                    stops: [
                      (revealEdge / labelWidth).clamp(0.0, 1.0),
                      ((revealEdge + 6) / labelWidth).clamp(0.0, 1.0),
                    ],
                  ).createShader(bounds),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(item.label),
                      if (item.menuBuilder != null) ...[
                        const SizedBox(width: 4),
                        const ExcludeSemantics(
                          child: Icon(Symbols.expand_more_rounded, size: 18),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
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
                label: active ? null : item.label,
                child: content,
              ),
            ),
    );
  }
}
