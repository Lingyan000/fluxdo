import 'theme_spec.dart';

/// 内置主题注册表。
///
/// 生成式主题只有元信息，在这里直接声明；固定配色主题以 JSON 资产
/// 提供，与用户导入主题共用 [ThemeSpec.fromJson]。
class ThemeRegistry {
  ThemeRegistry._();

  /// Material：表面随种子色染色，一直以来的默认外观。
  static const String materialId = 'material';

  /// 简约：种子强调色 × 无色相中性灰表面（原"中性"开关）。
  static const String minimalId = 'minimal';

  static const ThemeSpec material = ThemeSpec.generated(
    id: materialId,
    surface: GeneratedSurface.tinted,
  );

  static const ThemeSpec minimal = ThemeSpec.generated(
    id: minimalId,
    surface: GeneratedSurface.neutral,
  );

  static const List<ThemeSpec> builtins = [material, minimal];

  /// 按 id 取主题，找不到（主题被移除、数据损坏）回退 Material。
  static ThemeSpec byId(String? id) {
    for (final spec in builtins) {
      if (spec.id == id) return spec;
    }
    return material;
  }
}
