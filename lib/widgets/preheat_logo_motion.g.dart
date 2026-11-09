// 由 tool/gen_splash_motion.dart 根据 tool/splash_motion/logo_motion.json 生成，勿手改。
// 修改动画请改规格文件后执行 `just splash-motion`。

import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart';

import 'preheat_logo_motion.dart';

/// 描线动画总时长
const Duration logoMotionDuration = Duration(milliseconds: 1000);

/// 规格基准 logo 边长（逻辑像素），与原生启动屏 logo 等大
const double logoMotionLogoSize = 108.0;

/// 基准 logo 边长下的描线宽度（逻辑像素），随 logo 尺寸等比缩放
const double logoMotionStrokeWidth = 2.5;

const Cubic logoMotionStrokeCurve = Cubic(0.645, 0.045, 0.355, 1.0);
const Cubic logoMotionFillCurve = Cubic(0.42, 0.0, 0.58, 1.0);
const Cubic logoMotionStrokeFadeCurve = Cubic(0.0, 0.0, 0.58, 1.0);

/// 描线整体淡出区间（占总时长比例）
const double logoMotionStrokeFadeStart = 0.84;
const double logoMotionStrokeFadeEnd = 1.0;

/// 启动页底色，与原生启动屏同值
const Color logoMotionBackgroundLight = Color(0xFFF8F9FF);
const Color logoMotionBackgroundDark = Color(0xFF111418);

/// 描线颜色（品牌色，不随主题变化）
const Color logoMotionStrokeLight = Color(0xFF1C1C1E);
const Color logoMotionStrokeDark = Color(0xFFF0F0F3);

final LogoMotionSpec classicLogoMotion = LogoMotionSpec(
  viewBox: const Rect.fromLTWH(0, 0, 1024, 1024),
  bodyCenter: const Offset(512, 512),
  bodyRadius: 448.0,
  shapes: [
    LogoMotionShape(
      id: 'circle',
      isBody: true,
      fillPath: Path()
        ..moveTo(512, 64)
        ..arcToPoint(
          const Offset(512, 960),
          radius: const Radius.circular(448),
          largeArc: true,
          clockwise: true,
        )
        ..arcToPoint(
          const Offset(512, 64),
          radius: const Radius.circular(448),
          largeArc: true,
          clockwise: true,
        )
        ..close(),
      fillLight: const Color(0xFFF0F0F0),
      fillDark: const Color(0xFFF0F0F0),
      fillStart: 0.45,
      fillEnd: 0.66,
      strokePath: Path()
        ..moveTo(512, 64)
        ..arcToPoint(
          const Offset(512, 960),
          radius: const Radius.circular(448),
          largeArc: true,
          clockwise: true,
        )
        ..arcToPoint(
          const Offset(512, 64),
          radius: const Radius.circular(448),
          largeArc: true,
          clockwise: true,
        )
        ..close(),
      strokeStart: 0.0,
      strokeEnd: 0.45,
    ),
    LogoMotionShape(
      id: 'top',
      fillPath: Path()
        ..moveTo(135.3, 324)
        ..lineTo(888.7, 324)
        ..arcToPoint(
          const Offset(135.3, 324),
          radius: const Radius.circular(421),
          largeArc: false,
          clockwise: false,
        )
        ..close(),
      fillLight: const Color(0xFF1C1C1E),
      fillDark: const Color(0xFF1C1C1E),
      fillStart: 0.52,
      fillEnd: 0.72,
      strokePath: Path()
        ..moveTo(135.3, 324)
        ..lineTo(888.7, 324),
      strokeStart: 0.2,
      strokeEnd: 0.42,
    ),
    LogoMotionShape(
      id: 'middle',
      strokePath: Path()
        ..moveTo(135.3, 700)
        ..lineTo(888.7, 700),
      strokeStart: 0.3,
      strokeEnd: 0.52,
    ),
    LogoMotionShape(
      id: 'bottom',
      fillPath: Path()
        ..moveTo(135.3, 700)
        ..lineTo(888.7, 700)
        ..arcToPoint(
          const Offset(135.3, 700),
          radius: const Radius.circular(421),
          largeArc: false,
          clockwise: true,
        )
        ..close(),
      fillLight: const Color(0xFFFFB003),
      fillDark: const Color(0xFFFFB003),
      fillStart: 0.64,
      fillEnd: 0.84,
    ),
  ],
);

final LogoMotionSpec modernLogoMotion = LogoMotionSpec(
  viewBox: const Rect.fromLTWH(-158, -158, 1890, 1890),
  bodyCenter: const Offset(787, 787),
  bodyRadius: 787.0,
  shapes: [
    LogoMotionShape(
      id: 'circle',
      isBody: true,
      fillPath: Path()
        ..moveTo(787, 0)
        ..arcToPoint(
          const Offset(787, 1574),
          radius: const Radius.circular(787),
          largeArc: true,
          clockwise: false,
        )
        ..arcToPoint(
          const Offset(787, 0),
          radius: const Radius.circular(787),
          largeArc: true,
          clockwise: false,
        )
        ..close(),
      fillLight: const Color(0xFFF0F0F3),
      fillDark: const Color(0xFF1C1C1E),
      fillStart: 0.48,
      fillEnd: 0.68,
      strokePath: Path()
        ..moveTo(787, 0)
        ..arcToPoint(
          const Offset(787, 1574),
          radius: const Radius.circular(787),
          largeArc: true,
          clockwise: false,
        )
        ..arcToPoint(
          const Offset(787, 0),
          radius: const Radius.circular(787),
          largeArc: true,
          clockwise: false,
        )
        ..close(),
      strokeStart: 0.0,
      strokeEnd: 0.45,
    ),
    LogoMotionShape(
      id: 'flag',
      fillPath: Path()
        ..moveTo(783.34, 550.29)
        ..lineTo(413.34, 375.67)
        ..cubicTo(388.37, 363.88, 358.57, 374.57, 346.78, 399.55)
        ..cubicTo(343.63, 406.22, 342, 413.51, 342, 420.89)
        ..lineTo(342, 842)
        ..cubicTo(342, 869.62, 364.38, 892, 392, 892)
        ..lineTo(762, 892)
        ..cubicTo(789.62, 892, 812, 869.62, 812, 842)
        ..lineTo(812, 595.51)
        ..cubicTo(812, 576.16, 800.84, 558.55, 783.34, 550.29)
        ..close(),
      fillLight: const Color(0xFF1C1C1E),
      fillDark: const Color(0xFFF0F0F3),
      fillStart: 0.56,
      fillEnd: 0.76,
      strokePath: Path()
        ..moveTo(783.34, 550.29)
        ..lineTo(413.34, 375.67)
        ..cubicTo(388.37, 363.88, 358.57, 374.57, 346.78, 399.55)
        ..cubicTo(343.63, 406.22, 342, 413.51, 342, 420.89)
        ..lineTo(342, 842)
        ..cubicTo(342, 869.62, 364.38, 892, 392, 892)
        ..lineTo(762, 892)
        ..cubicTo(789.62, 892, 812, 869.62, 812, 842)
        ..lineTo(812, 595.51)
        ..cubicTo(812, 576.16, 800.84, 558.55, 783.34, 550.29)
        ..close(),
      strokeStart: 0.2,
      strokeEnd: 0.5,
    ),
    LogoMotionShape(
      id: 'bar',
      fillPath: Path()
        ..moveTo(392, 1022)
        ..lineTo(1182, 1022)
        ..arcToPoint(
          const Offset(1232, 1072),
          radius: const Radius.circular(50),
          largeArc: false,
          clockwise: true,
        )
        ..lineTo(1232, 1182)
        ..arcToPoint(
          const Offset(1182, 1232),
          radius: const Radius.circular(50),
          largeArc: false,
          clockwise: true,
        )
        ..lineTo(392, 1232)
        ..arcToPoint(
          const Offset(342, 1182),
          radius: const Radius.circular(50),
          largeArc: false,
          clockwise: true,
        )
        ..lineTo(342, 1072)
        ..arcToPoint(
          const Offset(392, 1022),
          radius: const Radius.circular(50),
          largeArc: false,
          clockwise: true,
        )
        ..close(),
      fillLight: const Color(0xFF1C1C1E),
      fillDark: const Color(0xFFF0F0F3),
      fillStart: 0.62,
      fillEnd: 0.82,
      strokePath: Path()
        ..moveTo(392, 1022)
        ..lineTo(1182, 1022)
        ..arcToPoint(
          const Offset(1232, 1072),
          radius: const Radius.circular(50),
          largeArc: false,
          clockwise: true,
        )
        ..lineTo(1232, 1182)
        ..arcToPoint(
          const Offset(1182, 1232),
          radius: const Radius.circular(50),
          largeArc: false,
          clockwise: true,
        )
        ..lineTo(392, 1232)
        ..arcToPoint(
          const Offset(342, 1182),
          radius: const Radius.circular(50),
          largeArc: false,
          clockwise: true,
        )
        ..lineTo(342, 1072)
        ..arcToPoint(
          const Offset(392, 1022),
          radius: const Radius.circular(50),
          largeArc: false,
          clockwise: true,
        )
        ..close(),
      strokeStart: 0.32,
      strokeEnd: 0.54,
    ),
    LogoMotionShape(
      id: 'accent',
      fillPath: Path()
        ..moveTo(1013.34, 658.68)
        ..lineTo(1203.34, 748.37)
        ..cubicTo(1220.84, 756.63, 1232, 774.24, 1232, 793.59)
        ..lineTo(1232, 842)
        ..cubicTo(1232, 869.62, 1209.62, 892, 1182, 892)
        ..lineTo(992, 892)
        ..cubicTo(964.38, 892, 942, 869.62, 942, 842)
        ..lineTo(942, 703.89)
        ..cubicTo(942, 676.28, 964.38, 653.89, 992, 653.89)
        ..cubicTo(999.38, 653.89, 1006.67, 655.53, 1013.34, 658.68)
        ..close(),
      fillLight: const Color(0xFFFFB003),
      fillDark: const Color(0xFFFFB003),
      fillStart: 0.66,
      fillEnd: 0.86,
      strokePath: Path()
        ..moveTo(1013.34, 658.68)
        ..lineTo(1203.34, 748.37)
        ..cubicTo(1220.84, 756.63, 1232, 774.24, 1232, 793.59)
        ..lineTo(1232, 842)
        ..cubicTo(1232, 869.62, 1209.62, 892, 1182, 892)
        ..lineTo(992, 892)
        ..cubicTo(964.38, 892, 942, 869.62, 942, 842)
        ..lineTo(942, 703.89)
        ..cubicTo(942, 676.28, 964.38, 653.89, 992, 653.89)
        ..cubicTo(999.38, 653.89, 1006.67, 655.53, 1013.34, 658.68)
        ..close(),
      strokeStart: 0.42,
      strokeEnd: 0.58,
    ),
  ],
);
