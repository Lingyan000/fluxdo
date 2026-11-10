import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'theme_spec.dart';

/// 主题注册表。
///
/// 生成式主题只有元信息，在这里直接声明；固定配色主题以 JSON 资产
/// （`assets/themes/`）提供，启动时由 [loadBuiltins] 加载，与用户导入
/// 主题共用 [ThemeSpec.fromJson]。资产清单从 AssetManifest 动态读取，
/// 新增主题只需放入 JSON 文件。
class ThemeRegistry {
  ThemeRegistry._();

  /// Material：表面随种子色染色，一直以来的默认外观。
  static const String materialId = 'material';

  /// 简约：种子强调色 × 无色相中性灰表面（原"中性"开关）。
  static const String minimalId = 'minimal';

  static const String _assetDir = 'assets/themes/';

  static const ThemeSpec material = ThemeSpec.generated(
    id: materialId,
    surface: GeneratedSurface.tinted,
  );

  static const ThemeSpec minimal = ThemeSpec.generated(
    id: minimalId,
    surface: GeneratedSurface.neutral,
    order: 1,
  );

  static const List<ThemeSpec> builtins = [material, minimal];

  static List<ThemeSpec> _fixed = const [];
  static List<ThemeSpec> _custom = const [];

  /// 内置固定配色主题（[loadBuiltins] 之后可用）。
  static List<ThemeSpec> get fixed => _fixed;

  /// 用户自定义 / 导入的主题。
  static List<ThemeSpec> get custom => _custom;

  /// 全部可选主题，按分组与 [ThemeSpec.order] 排序。
  static List<ThemeSpec> get all => [...builtins, ..._fixed, ..._custom];

  /// 按 id 取主题，找不到（主题被移除、数据损坏）回退 Material。
  static ThemeSpec byId(String? id) {
    for (final spec in all) {
      if (spec.id == id) return spec;
    }
    return material;
  }

  /// 与 [spec] 同族的全部主题（含自身），按 order 排序。
  static List<ThemeSpec> familyOf(ThemeSpec spec) =>
      all.where((s) => s.familyId == spec.familyId).toList()
        ..sort((a, b) => a.order.compareTo(b.order));

  /// 从资产加载内置固定配色主题。单个文件解析失败只跳过该主题，
  /// 不阻塞启动。
  static Future<void> loadBuiltins([AssetBundle? bundle]) async {
    final assets = bundle ?? rootBundle;
    final manifest = await AssetManifest.loadFromAssetBundle(assets);
    final paths =
        manifest
            .listAssets()
            .where((p) => p.startsWith(_assetDir) && p.endsWith('.json'))
            .toList()
          ..sort();
    final specs = <ThemeSpec>[];
    for (final path in paths) {
      try {
        final json = jsonDecode(await assets.loadString(path));
        specs.add(ThemeSpec.fromJson(json as Map<String, dynamic>));
      } catch (e) {
        debugPrint('[ThemeRegistry] 跳过无效主题 $path: $e');
      }
    }
    setFixed(specs);
  }

  /// 设置内置固定配色主题（测试与 [loadBuiltins] 使用）。
  @visibleForTesting
  static void setFixed(List<ThemeSpec> specs) {
    _fixed = List.unmodifiable(
      [...specs]..sort((a, b) {
        final g = a.group.index.compareTo(b.group.index);
        return g != 0 ? g : a.order.compareTo(b.order);
      }),
    );
  }

  /// 设置用户主题。
  static void setCustom(List<ThemeSpec> specs) {
    _custom = List.unmodifiable(specs);
  }
}
