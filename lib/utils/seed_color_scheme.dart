import 'package:flutter/material.dart';

/// 带进程级缓存的 [ColorScheme.fromSeed]。
///
/// 框架侧对种子配色没有任何缓存：[ColorScheme.fromSeed] 每次都会重建
/// `DynamicScheme` 并逐个求解 50 多个 color role；material_color_utilities
/// 内部的 `DynamicColor._hctCache` 又以 `DynamicScheme` 的**实例**为键
/// （该类没有重写 `==`），且超过 4 条就整表清空，实际命中率为零。
///
/// 外观设置页一帧要为色卡网格、配色风格卡、主题模式卡算 20 多次，实测
/// 单次约 1ms、首次进入合计 50ms 量级，是首次进入掉帧的主要来源之一。
/// 这里按 (种子色, 亮暗, 配色风格) 缓存结果，命中后成本近似为零。
///
/// 只适用于固定色集（预设色、自定义色、动态色、9 种配色风格）。取色器
/// 拖动滑块会产生大量一次性种子色，不要走这里，以免把常用项挤出缓存。
class SeedColorScheme {
  SeedColorScheme._();

  static final Map<(int, int, int), ColorScheme> _cache = {};

  /// 缓存上限。外观页最多用到 30 个左右的组合，留足余量；
  /// 超限直接清空，省掉维护 LRU 链的开销。
  static const int _maxEntries = 64;

  /// 与 [ColorScheme.fromSeed] 等价，但相同入参只计算一次。
  static ColorScheme from({
    required Color seedColor,
    Brightness brightness = Brightness.light,
    DynamicSchemeVariant variant = DynamicSchemeVariant.tonalSpot,
  }) {
    final key = (seedColor.toARGB32(), brightness.index, variant.index);
    final cached = _cache[key];
    if (cached != null) return cached;

    if (_cache.length >= _maxEntries) _cache.clear();

    final scheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
      dynamicSchemeVariant: variant,
    );
    _cache[key] = scheme;
    return scheme;
  }

  @visibleForTesting
  static void resetCache() => _cache.clear();

  @visibleForTesting
  static int get cachedCount => _cache.length;

  @visibleForTesting
  static int get maxEntries => _maxEntries;
}
