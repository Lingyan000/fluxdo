import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 设置项分组
class SettingsGroup {
  final String title;
  final IconData icon;
  final List<SettingsModel> items;

  /// 是否用 Card 包裹 items，默认 true。
  /// 对于自定义布局的 section（如主题色网格、图标选择器），设为 false。
  final bool wrapInCard;

  const SettingsGroup({
    required this.title,
    required this.icon,
    required this.items,
    this.wrapInCard = true,
  });
}

/// 设置项基类（sealed）
sealed class SettingsModel {
  /// 唯一标识，用于搜索定位高亮
  final String id;

  /// 搜索标题
  final String title;

  /// 搜索副标题
  final String? subtitle;

  const SettingsModel({
    required this.id,
    required this.title,
    this.subtitle,
  });

  /// 搜索匹配
  bool matchesQuery(String query) {
    final q = query.toLowerCase();
    return title.toLowerCase().contains(q) ||
        (subtitle?.toLowerCase().contains(q) ?? false);
  }

  /// 分组渲染前的可见性判断。
  ///
  /// 分段卡片组（SegmentedCardGroup）按位置决定首尾大圆角，隐藏项必须在
  /// 组装 children 前过滤掉——否则隐藏项以零高占位占走组尾位置，可见的
  /// 最后一项拿不到大圆角。默认恒可见。
  bool isVisible(WidgetRef ref) => true;
}

/// 布尔开关
final class SwitchModel extends SettingsModel {
  final IconData icon;
  final bool Function(WidgetRef ref) getValue;
  final void Function(WidgetRef ref, bool value) onChanged;

  /// 依赖前置开关:返回 false 时本项整行隐藏(如「即时渲染」依赖
  /// 「富文本编辑器」开启才有意义,前置关闭时展示无意义)。null = 恒显示。
  final bool Function(WidgetRef ref)? enabledWhen;

  const SwitchModel({
    required super.id,
    required super.title,
    super.subtitle,
    required this.icon,
    required this.getValue,
    required this.onChanged,
    this.enabledWhen,
  });

  @override
  bool isVisible(WidgetRef ref) => enabledWhen?.call(ref) ?? true;
}

/// 浮点滑块（字体缩放等）
final class DoubleSliderModel extends SettingsModel {
  final IconData icon;
  final double min;
  final double max;
  final int divisions;
  final String Function(double value) labelBuilder;
  final double Function(WidgetRef ref) getValue;
  final void Function(WidgetRef ref, double value) onChanged;
  final void Function(WidgetRef ref)? onReset;

  const DoubleSliderModel({
    required super.id,
    required super.title,
    super.subtitle,
    required this.icon,
    required this.min,
    required this.max,
    required this.divisions,
    required this.labelBuilder,
    required this.getValue,
    required this.onChanged,
    this.onReset,
  });
}

/// 整数滑块（速率限制等）
final class IntSliderModel extends SettingsModel {
  final IconData icon;
  final int min;
  final int max;
  final String? valueSuffix;
  final int Function(WidgetRef ref) getValue;
  final void Function(WidgetRef ref, int value) onChanged;

  const IntSliderModel({
    required super.id,
    required super.title,
    super.subtitle,
    required this.icon,
    required this.min,
    required this.max,
    this.valueSuffix,
    required this.getValue,
    required this.onChanged,
  });
}

/// 点击项（导航/弹出 Dialog）
final class ActionModel extends SettingsModel {
  final IconData icon;

  /// 动态副标题（如当前 URL）
  final String? Function(WidgetRef ref)? getDynamicSubtitle;

  final void Function(BuildContext context, WidgetRef ref) onTap;

  const ActionModel({
    required super.id,
    required super.title,
    super.subtitle,
    required this.icon,
    this.getDynamicSubtitle,
    required this.onTap,
  });
}

/// 自定义 Widget（复杂 UI）
final class CustomModel extends SettingsModel {
  final Widget Function(BuildContext context, WidgetRef ref) builder;

  const CustomModel({
    required super.id,
    required super.title,
    super.subtitle,
    required this.builder,
  });
}

/// 平台条件包装
final class PlatformConditionalModel extends SettingsModel {
  final SettingsModel inner;
  final bool Function() condition;

  PlatformConditionalModel({
    required this.inner,
    required this.condition,
  }) : super(id: inner.id, title: inner.title, subtitle: inner.subtitle);

  bool get shouldShow => condition();

  @override
  bool isVisible(WidgetRef ref) => shouldShow && inner.isVisible(ref);
}
