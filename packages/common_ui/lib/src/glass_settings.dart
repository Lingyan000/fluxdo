import 'package:flutter/widgets.dart';

/// 效果能力档位，不代表模糊浓淡或设备性能跑分。
enum GlassEffectLevel {
  auto,
  basic,
  full;

  static GlassEffectLevel fromStorage(String? value) =>
      GlassEffectLevel.values.firstWhere(
        (level) => level.name == value,
        orElse: () => GlassEffectLevel.auto,
      );
}

/// 应用级玻璃策略。common_ui 只依赖此配置，不依赖应用偏好存储。
///
/// 由宿主把用户偏好（[enabled]、[level]）与当前主题的界面风格
/// （[autoOptics]、[shadows]）合成。优先级：关闭玻璃 > 用户明确选择的
/// 档位 > 主题偏好；主题只决定「自动」档位的取值。
@immutable
class GlassSettings {
  const GlassSettings({
    this.enabled = true,
    this.level = GlassEffectLevel.auto,
    this.autoOptics = true,
    this.shadows = true,
  });

  final bool enabled;
  final GlassEffectLevel level;

  /// 「自动」档位是否使用光学折射，由主题决定；基础磨砂、完整玻璃
  /// 两档是用户的明确选择，不受影响。
  final bool autoOptics;

  /// 玻璃外壳是否投影，跟随主题的阴影开关；关闭时只靠边缘光勾出轮廓。
  final bool shadows;

  bool allowsBlur({required bool highContrast, bool locallyEnabled = true}) =>
      enabled && locallyEnabled && !highContrast;

  bool allowsOptics({
    required bool shaderSupported,
    required bool highContrast,
    bool locallyEnabled = true,
  }) =>
      allowsBlur(highContrast: highContrast, locallyEnabled: locallyEnabled) &&
      switch (level) {
        GlassEffectLevel.auto => autoOptics,
        GlassEffectLevel.basic => false,
        GlassEffectLevel.full => true,
      } &&
      shaderSupported;

  @override
  bool operator ==(Object other) =>
      other is GlassSettings &&
      other.enabled == enabled &&
      other.level == level &&
      other.autoOptics == autoOptics &&
      other.shadows == shadows;

  @override
  int get hashCode => Object.hash(enabled, level, autoOptics, shadows);
}

/// 放在 Navigator 之上，页面、弹出的编辑器与新玻璃组件自动遵循同一策略。
/// 没有作用域的独立预览或测试默认自动开启。
class GlassSettingsScope extends InheritedWidget {
  const GlassSettingsScope({
    super.key,
    required this.settings,
    required super.child,
  });

  final GlassSettings settings;

  static GlassSettings of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<GlassSettingsScope>()
          ?.settings ??
      const GlassSettings();

  @override
  bool updateShouldNotify(GlassSettingsScope oldWidget) =>
      settings != oldWidget.settings;
}
