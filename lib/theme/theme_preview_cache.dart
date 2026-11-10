import 'package:flutter/material.dart';

import 'theme_resolver.dart';
import 'theme_spec.dart';

/// 主题缩略图配色缓存（外观页画廊与首帧预热共用）。
///
/// 画廊一次要画十几张缩略图，固定配色主题的推导含对比度二分，逐帧重算
/// 会拖慢外观页首帧；参数组合有限，进程内缓存即可。超限直接清空，省掉
/// 维护 LRU 链的开销。
class ThemePreviewCache {
  ThemePreviewCache._();

  static final Map<String, ColorScheme> _cache = {};
  static const int _maxEntries = 96;

  /// [spec] 在 [brightness] 下的缩略图配色。生成式主题由 [seed] 与
  /// [variant] 决定，固定配色主题由 [accentId] 决定。
  static ColorScheme schemeOf({
    required ThemeSpec spec,
    required Brightness brightness,
    required String? accentId,
    required Color seed,
    required DynamicSchemeVariant variant,
    required bool black,
  }) {
    final key = [
      spec.id,
      brightness.index,
      black,
      if (spec.isGenerated) ...[seed.toARGB32(), variant.index] else accentId,
    ].join('|');
    final cached = _cache[key];
    if (cached != null) return cached;
    if (_cache.length >= _maxEntries) _cache.clear();
    final resolved = ThemeResolver.resolve(
      spec: spec,
      mode: ThemeMode.system,
      black: black,
      transparent: false,
      seed: seed,
      variant: variant,
      accentId: accentId,
    );
    return _cache[key] = brightness == Brightness.light
        ? resolved.light
        : resolved.dark;
  }

  @visibleForTesting
  static void reset() => _cache.clear();
}
