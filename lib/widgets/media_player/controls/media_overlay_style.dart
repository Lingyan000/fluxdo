import 'package:flutter/material.dart';

/// 媒体覆盖层的共享视觉令牌(黑底白字体系)。
///
/// 所有浮层元素(HUD/提示胶囊/时间气泡/菜单)走同一质感:半透深底 +
/// 发丝白描边 + 柔投影 —— 有层次但不用 BackdropFilter(视频纹理上
/// 每帧重做高斯模糊是已知卡顿源,浮层质感全部用零开销手段构成)。
abstract final class MediaOverlayStyle {
  /// 强调色(倍速非 1x、菜单选中项):暖琥珀,黑底上的唯一彩色信号。
  static const Color accent = Color(0xFFFFD54F);

  /// 主文字/图标。
  static const Color foreground = Colors.white;

  /// 次级文字(总时长、辅助标签)。
  static const Color foregroundDim = Colors.white54;

  /// 浮层胶囊统一装饰。
  static BoxDecoration pill({double radius = 10}) => BoxDecoration(
        color: const Color(0xD91A1A1A),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: const Color(0x1FFFFFFF)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x59000000),
            blurRadius: 12,
            offset: Offset(0, 2),
          ),
        ],
      );

  /// 顶/底控制条 scrim:三段渐变,比两段的落差柔和。
  static const LinearGradient bottomScrim = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [Color(0xB3000000), Color(0x4D000000), Colors.transparent],
    stops: [0.0, 0.55, 1.0],
  );

  static const LinearGradient topScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xB3000000), Color(0x4D000000), Colors.transparent],
    stops: [0.0, 0.55, 1.0],
  );

  /// 控制条出入场。
  static const Duration barDuration = Duration(milliseconds: 240);
  static const Curve barCurve = Curves.easeOutCubic;
}
