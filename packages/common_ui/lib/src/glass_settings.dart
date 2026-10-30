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
@immutable
class GlassSettings {
  const GlassSettings({
    this.enabled = true,
    this.level = GlassEffectLevel.auto,
  });

  final bool enabled;
  final GlassEffectLevel level;

  bool allowsBlur({required bool highContrast, bool locallyEnabled = true}) =>
      enabled && locallyEnabled && !highContrast;

  bool allowsOptics({
    required bool shaderSupported,
    required bool highContrast,
    bool locallyEnabled = true,
  }) =>
      allowsBlur(highContrast: highContrast, locallyEnabled: locallyEnabled) &&
      level != GlassEffectLevel.basic &&
      shaderSupported;

  @override
  bool operator ==(Object other) =>
      other is GlassSettings &&
      other.enabled == enabled &&
      other.level == level;

  @override
  int get hashCode => Object.hash(enabled, level);
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
