import 'package:flutter/material.dart';

/// 颜色工具类
class ColorUtils {
  /// 解析 hex 颜色字符串为 Color
  ///
  /// 支持格式: "AABBCC", "#AABBCC", "ABC", "#ABC"
  /// 解析失败时返回 [fallback] (默认 Colors.grey)
  static Color parseHex(String hex, {Color fallback = Colors.grey}) {
    var clean = hex.replaceFirst('#', '');

    // 3 字符简写展开: "ABC" → "AABBCC"
    if (clean.length == 3) {
      clean = '${clean[0]}${clean[0]}${clean[1]}${clean[1]}${clean[2]}${clean[2]}';
    }

    if (clean.length == 6) {
      try {
        return Color(int.parse('FF$clean', radix: 16));
      } catch (_) {
        return fallback;
      }
    }

    return fallback;
  }

  /// 解析可空颜色字符串，返回 null 表示无有效颜色
  static Color? tryParseHex(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    final result = parseHex(hex, fallback: Colors.transparent);
    return result == Colors.transparent ? null : result;
  }
}
