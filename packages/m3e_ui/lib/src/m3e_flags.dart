import 'package:flutter/material.dart';

/// M3E 组件风格全局开关,以 ThemeExtension 注入。
///
/// 覆盖范围是"动效与组件形态":加载动画([LoadingSpinner] 关闭时回退
/// 转圈)、wavy 进度条、下拉刷新表现层,以及主题层按此值决定的
/// year2023 翻新与按钮按压形变。分段卡片等页面结构不随开关回退。
///
/// 使用 [M3eFlags.of] 读取;宿主未注册时兜底默认值(全开),因此
/// m3e_ui 组件在裸 MaterialApp / 测试环境下行为与注册全开一致。
///
/// 注意:light/dark 两个 ThemeData 必须对称注册 —— ThemeData.lerp
/// 对"单边缺失"的 extension 不做插值而是瞬时并入,明暗切换动画期间
/// 会跳变。
@immutable
class M3eFlags extends ThemeExtension<M3eFlags> {
  /// 总开关:false 时 m3e_ui 组件回退到对应的 Material 3 经典形态。
  final bool enabled;

  const M3eFlags({this.enabled = true});

  static M3eFlags of(BuildContext context) =>
      Theme.of(context).extension<M3eFlags>() ?? const M3eFlags();

  @override
  M3eFlags copyWith({bool? enabled}) =>
      M3eFlags(enabled: enabled ?? this.enabled);

  /// bool 无法插值:主题切换动画半程翻转,是开关型 flag 的唯一合理语义。
  @override
  M3eFlags lerp(ThemeExtension<M3eFlags>? other, double t) {
    if (other is! M3eFlags) return this;
    return t < 0.5 ? this : other;
  }

  // ThemeData 每次 build 都是新实例;extension 不可比较会让 AnimatedTheme
  // 在每次 rebuild 时空转一段 lerp 动画。
  @override
  bool operator ==(Object other) => other is M3eFlags && other.enabled == enabled;

  @override
  int get hashCode => enabled.hashCode;
}
