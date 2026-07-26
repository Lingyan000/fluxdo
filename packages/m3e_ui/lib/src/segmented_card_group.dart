import 'package:flutter/material.dart';

/// M3 Expressive 风格分段卡片组
///
/// 参照最新 Material 3 Expressive 列表规范（Chrome / Android 系统设置）：
/// 每个条目独立成块，组首/组尾用大圆角、相邻处用小圆角，块间以细缝分隔，
/// 取代旧式「整卡 + Divider」布局。
class SegmentedCardGroup extends StatelessWidget {
  final List<Widget> children;

  /// 组首/组尾的大圆角
  final double outerRadius;

  /// 相邻条目之间的小圆角
  final double innerRadius;

  /// 条目间距
  final double gap;

  /// 块背景色，默认跟随 cardTheme（surfaceContainerLow）
  final Color? color;

  const SegmentedCardGroup({
    super.key,
    required this.children,
    this.outerRadius = 20,
    this.innerRadius = 5,
    this.gap = 3,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (int i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          SegmentedCardItem(
            index: i,
            count: children.length,
            outerRadius: outerRadius,
            innerRadius: innerRadius,
            color: color,
            child: children[i],
          ),
        ],
      ],
    );
  }
}

/// 分段卡片组中的单个条目块
///
/// 根据 [index] / [count] 决定上下圆角。供 [SegmentedCardGroup] 内部使用；
/// 懒加载列表（ListView.builder）中也可直接按索引使用。
class SegmentedCardItem extends StatelessWidget {
  final int index;
  final int count;
  final double outerRadius;
  final double innerRadius;
  final Color? color;
  final Widget child;

  const SegmentedCardItem({
    super.key,
    required this.index,
    required this.count,
    this.outerRadius = 20,
    this.innerRadius = 5,
    this.color,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background =
        color ?? theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow;

    return Material(
      color: background,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(index == 0 ? outerRadius : innerRadius),
          bottom: Radius.circular(index == count - 1 ? outerRadius : innerRadius),
        ),
      ),
      child: child,
    );
  }
}
