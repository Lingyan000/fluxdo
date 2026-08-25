import 'package:flutter/material.dart';

/// 透明模式的用户背景配置。
///
/// 图片文件本体存放在应用私有目录（见 AppBackgroundService），
/// 这里只持久化路径与调节参数。
class AppBackground {
  const AppBackground({
    this.imagePath,
    this.scrimLight = defaultScrimLight,
    this.scrimDark = defaultScrimDark,
    this.blurSigma = 0,
  });

  /// 背景图路径（应用私有目录内）；null 表示未设置。
  final String? imagePath;

  /// 浅色模式下的白色遮罩透明度（0~1，越大内容越清晰、图越淡）。
  final double scrimLight;

  /// 深色模式下的黑色遮罩透明度。明暗分开记忆，互不干扰。
  final double scrimDark;

  /// 背景图高斯模糊强度（sigma，0 表示不模糊）。
  final double blurSigma;

  static const double defaultScrimLight = 0.45;
  static const double defaultScrimDark = 0.55;
  static const double maxBlurSigma = 20;

  bool get hasImage => imagePath != null;

  /// 当前亮度下实际使用的遮罩透明度。
  double scrimFor(Brightness brightness) =>
      brightness == Brightness.light ? scrimLight : scrimDark;

  AppBackground copyWith({
    String? imagePath,
    double? scrimLight,
    double? scrimDark,
    double? blurSigma,
  }) {
    return AppBackground(
      imagePath: imagePath ?? this.imagePath,
      scrimLight: scrimLight ?? this.scrimLight,
      scrimDark: scrimDark ?? this.scrimDark,
      blurSigma: blurSigma ?? this.blurSigma,
    );
  }
}
