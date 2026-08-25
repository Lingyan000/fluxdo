import 'package:flutter/material.dart';

import 'accent_colors.dart';

/// 内置调色板：一套有名字的强调色预设。
///
/// 调色板只提供种子色（前四套精选种子来自 Material Theme Builder 经典
/// 配色）；彩色 role 的生成风格跟随用户选中的配色风格（schemeVariant），
/// 中性表面层由主题模式与中性/纯黑/透明开关决定，不受调色板影响。
class AppPalette {
  const AppPalette({required this.id, required this.seedColor});

  /// 稳定标识，用于持久化（不随语言变化）。
  final String id;

  /// 生成强调色的种子色。
  final Color seedColor;
}

class AppPalettes {
  AppPalettes._();

  /// 默认调色板 id（非调色板状态下的简单配色，沿用应用默认蓝）。
  static const String defaultId = 'default';

  static const List<AppPalette> builtins = [
    AppPalette(id: defaultId, seedColor: AccentColors.defaultSeed),
    // 精选四套（Material Theme Builder 经典配色）
    AppPalette(id: 'ocean', seedColor: Color(0xFF116682)), // 海洋
    AppPalette(id: 'sakura', seedColor: Color(0xFF8E4955)), // 樱花
    AppPalette(id: 'spring', seedColor: Color(0xFF4C662B)), // 春
    AppPalette(id: 'autumn', seedColor: Color(0xFF735C0C)), // 秋
    AppPalette(id: 'purple', seedColor: Color(0xFF9C27B0)),
    AppPalette(id: 'green', seedColor: Color(0xFF4CAF50)),
    AppPalette(id: 'orange', seedColor: Color(0xFFFF9800)),
    AppPalette(id: 'pink', seedColor: Color(0xFFE91E63)),
    AppPalette(id: 'teal', seedColor: Color(0xFF009688)),
    AppPalette(id: 'red', seedColor: Color(0xFFF44336)),
    AppPalette(id: 'indigo', seedColor: Color(0xFF3F51B5)),
    AppPalette(id: 'amber', seedColor: Color(0xFFFFC107)),
    AppPalette(id: 'cyan', seedColor: Color(0xFF00BCD4)),
  ];

  static AppPalette byId(String? id) {
    for (final palette in builtins) {
      if (palette.id == id) return palette;
    }
    return builtins.first;
  }

  /// 按种子色反查调色板（用于老数据迁移），查不到返回 null。
  static AppPalette? bySeed(Color seedColor) {
    final argb = seedColor.toARGB32();
    for (final palette in builtins) {
      if (palette.seedColor.toARGB32() == argb) return palette;
    }
    return null;
  }
}
