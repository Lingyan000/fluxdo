// 自绘图标的 CustomPainter 集合。
//
// 约定：
//   - painter 始终在 [0, designSize] 坐标系内绘制；调用方通过 scale 适配尺寸。
//   - fill ∈ [0, 1]：0 = 纯线框，1 = 实心；painter 应在中间状态做插值或自适应。
//   - strokeWidth = 2.0 默认；不同设计稿可在 painter 内做归一化。
import 'dart:math' as math;
import 'dart:ui' as ui show PathOperation;

import 'package:flutter/material.dart';

/// 文本框与省略号：文字内容的操作菜单，保持线框以匹配操作类图标。
class ContentActionsPainter extends CustomPainter {
  const ContentActionsPainter({required this.color, required this.strokeWidth});

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 24;
    canvas.save();
    canvas.translate((size.width - 24 * scale) / 2, (size.height - 24 * scale) / 2);
    canvas.scale(scale);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(8, 21)
      ..lineTo(6.5, 21)
      ..quadraticBezierTo(4, 21, 4, 18.5)
      ..lineTo(4, 5.5)
      ..quadraticBezierTo(4, 3, 6.5, 3)
      ..lineTo(17.5, 3)
      ..quadraticBezierTo(20, 3, 20, 5.5)
      ..lineTo(20, 12.5)
      ..moveTo(7.5, 8)
      ..lineTo(16.5, 8)
      ..moveTo(7.5, 12)
      ..lineTo(13.5, 12);
    canvas.drawPath(path, stroke);
    final dot = Paint()..color = color;
    for (final x in [11.5, 15.5, 19.5]) {
      canvas.drawCircle(Offset(x, 19.5), strokeWidth * .55, dot);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ContentActionsPainter oldDelegate) =>
      color != oldDelegate.color || strokeWidth != oldDelegate.strokeWidth;
}

/// 笑脸（emoji tab）。
///
/// 设计参考 Material Symbols Rounded 的 `sentiment_satisfied`，但绘制更圆润、
/// 线条更均匀。线框态：外圆 + 两点眼睛 + 弧形微笑；实心态：填充圆 + 用差集挖
/// 出五官（保证在背景色上清晰可见，不依赖反色对比）。
class SmileyPainter extends CustomPainter {
  final Color color;
  final double fill;
  final double strokeWidth;

  SmileyPainter({
    required this.color,
    required this.fill,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 24.0;
    final s = strokeWidth * scale;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.shortestSide / 2 - s * 0.6;

    if (fill > 0.5) {
      _paintFilled(canvas, cx: cx, cy: cy, r: r, s: s);
    } else {
      _paintOutlined(canvas, cx: cx, cy: cy, r: r, s: s);
    }
  }

  void _paintOutlined(
    Canvas canvas, {
    required double cx,
    required double cy,
    required double r,
    required double s,
  }) {
    // 外圆
    final ring = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(Offset(cx, cy), r, ring);

    // 眼睛
    final eyePaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final eyeR = r * 0.11;
    final eyeY = cy - r * 0.22;
    canvas.drawCircle(Offset(cx - r * 0.36, eyeY), eyeR, eyePaint);
    canvas.drawCircle(Offset(cx + r * 0.36, eyeY), eyeR, eyePaint);

    // 微笑弧线
    final mouth = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = s;
    final mouthRect = Rect.fromCircle(
      center: Offset(cx, cy + r * 0.05),
      radius: r * 0.48,
    );
    const start = math.pi / 6;
    const sweep = math.pi - math.pi / 3;
    canvas.drawArc(mouthRect, start, sweep, false, mouth);
  }

  void _paintFilled(
    Canvas canvas, {
    required double cx,
    required double cy,
    required double r,
    required double s,
  }) {
    final eyeR = r * 0.11;
    final eyeY = cy - r * 0.22;
    final mouthRect = Rect.fromCircle(
      center: Offset(cx, cy + r * 0.05),
      radius: r * 0.48,
    );

    canvas.saveLayer(
      Rect.fromCircle(center: Offset(cx, cy), radius: r + s * 2),
      Paint(),
    );

    // 实心圆
    canvas.drawCircle(Offset(cx, cy), r, Paint()..color = color);

    // 凿空眼睛
    final cutFill = Paint()
      ..blendMode = BlendMode.dstOut
      ..color = Colors.black
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx - r * 0.36, eyeY), eyeR, cutFill);
    canvas.drawCircle(Offset(cx + r * 0.36, eyeY), eyeR, cutFill);

    // 凿空嘴
    final cutStroke = Paint()
      ..blendMode = BlendMode.dstOut
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 1.05
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      mouthRect,
      math.pi / 6,
      math.pi - math.pi / 3,
      false,
      cutStroke,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant SmileyPainter old) =>
      old.color != color ||
      old.fill != fill ||
      old.strokeWidth != strokeWidth;
}

/// 表情包/贴纸包图标（sticker tab）。
///
/// "一摞贴纸"语义：两片重叠的圆角方形（前景片右上角带折角），中间一个小笑脸
/// 表示"是表情贴纸"。线框/实心同结构，仅在描边与填充间切换。
class StickerPainter extends CustomPainter {
  final Color color;
  final double fill;
  final double strokeWidth;

  StickerPainter({
    required this.color,
    required this.fill,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 24.0;
    final s = strokeWidth * scale;

    final pad = s * 0.8;
    final cardW = size.width * 0.7;
    final cardH = size.height * 0.7;
    final corner = cardW * 0.18;

    // 后片：左上角偏移
    final backRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(pad, pad, cardW, cardH),
      Radius.circular(corner),
    );

    // 前片：右下角偏移
    final frontLeft = size.width - cardW - pad;
    final frontTop = size.height - cardH - pad;
    final flapSize = cardW * 0.28;
    final frontRect = Rect.fromLTWH(frontLeft, frontTop, cardW, cardH);

    // 前片主体路径：右上角斜切一块
    final frontPath = Path()
      ..moveTo(frontRect.left + corner, frontRect.top)
      ..lineTo(frontRect.right - flapSize, frontRect.top)
      ..lineTo(frontRect.right, frontRect.top + flapSize)
      ..lineTo(frontRect.right, frontRect.bottom - corner)
      ..arcToPoint(
        Offset(frontRect.right - corner, frontRect.bottom),
        radius: Radius.circular(corner),
      )
      ..lineTo(frontRect.left + corner, frontRect.bottom)
      ..arcToPoint(
        Offset(frontRect.left, frontRect.bottom - corner),
        radius: Radius.circular(corner),
      )
      ..lineTo(frontRect.left, frontRect.top + corner)
      ..arcToPoint(
        Offset(frontRect.left + corner, frontRect.top),
        radius: Radius.circular(corner),
      )
      ..close();

    if (fill > 0.5) {
      _paintFilled(
        canvas,
        backRect: backRect,
        frontPath: frontPath,
        frontRect: frontRect,
        flapSize: flapSize,
        s: s,
      );
    } else {
      _paintOutlined(
        canvas,
        backRect: backRect,
        frontPath: frontPath,
        frontRect: frontRect,
        flapSize: flapSize,
        s: s,
      );
    }
  }

  void _paintOutlined(
    Canvas canvas, {
    required RRect backRect,
    required Path frontPath,
    required Rect frontRect,
    required double flapSize,
    required double s,
  }) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    // 后片：先把被前片完全覆盖的部分裁掉
    final clipBack = Path.combine(
      ui.PathOperation.difference,
      Path()..addRRect(backRect),
      frontPath,
    );
    canvas.drawPath(clipBack, stroke);

    // 前片
    canvas.drawPath(frontPath, stroke);

    // 折角的两条边线
    canvas.drawLine(
      Offset(frontRect.right - flapSize, frontRect.top),
      Offset(frontRect.right - flapSize, frontRect.top + flapSize),
      stroke,
    );
    canvas.drawLine(
      Offset(frontRect.right - flapSize, frontRect.top + flapSize),
      Offset(frontRect.right, frontRect.top + flapSize),
      stroke,
    );

    // 中心小笑脸
    _drawMiniFace(
      canvas,
      Offset(
        (frontRect.left + frontRect.right - flapSize * 0.3) / 2,
        frontRect.center.dy + s * 0.3,
      ),
      r: frontRect.width * 0.2,
      stroke: stroke,
    );
  }

  void _paintFilled(
    Canvas canvas, {
    required RRect backRect,
    required Path frontPath,
    required Rect frontRect,
    required double flapSize,
    required double s,
  }) {
    // 后片：淡一档
    final backPaint = Paint()..color = color.withValues(alpha: 0.45);
    final clipBack = Path.combine(
      ui.PathOperation.difference,
      Path()..addRRect(backRect),
      frontPath,
    );
    canvas.drawPath(clipBack, backPaint);

    // 前片：用 saveLayer 凿空脸 & 折角
    canvas.saveLayer(
      Rect.fromLTWH(
        frontRect.left - s,
        frontRect.top - s,
        frontRect.width + s * 2,
        frontRect.height + s * 2,
      ),
      Paint(),
    );
    canvas.drawPath(frontPath, Paint()..color = color);

    // 折角折痕（凿空两条短线，制造立体感）
    final crease = Paint()
      ..blendMode = BlendMode.dstOut
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.75
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(frontRect.right - flapSize, frontRect.top),
      Offset(frontRect.right - flapSize, frontRect.top + flapSize),
      crease,
    );
    canvas.drawLine(
      Offset(frontRect.right - flapSize, frontRect.top + flapSize),
      Offset(frontRect.right, frontRect.top + flapSize),
      crease,
    );

    // 凿空小笑脸
    _drawMiniFaceCutout(
      canvas,
      Offset(
        (frontRect.left + frontRect.right - flapSize * 0.3) / 2,
        frontRect.center.dy + s * 0.3,
      ),
      r: frontRect.width * 0.2,
      s: s,
    );
    canvas.restore();
  }

  void _drawMiniFace(
    Canvas canvas,
    Offset center, {
    required double r,
    required Paint stroke,
  }) {
    canvas.drawCircle(center, r, stroke);
    final eyeR = r * 0.16;
    final eyeY = center.dy - r * 0.22;
    final eyePaint = Paint()
      ..color = stroke.color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(center.dx - r * 0.42, eyeY), eyeR, eyePaint);
    canvas.drawCircle(Offset(center.dx + r * 0.42, eyeY), eyeR, eyePaint);
    final mouthRect = Rect.fromCircle(
      center: Offset(center.dx, center.dy + r * 0.05),
      radius: r * 0.55,
    );
    canvas.drawArc(
      mouthRect,
      math.pi / 6,
      math.pi - math.pi / 3,
      false,
      stroke,
    );
  }

  void _drawMiniFaceCutout(
    Canvas canvas,
    Offset center, {
    required double r,
    required double s,
  }) {
    final cut = Paint()
      ..blendMode = BlendMode.dstOut
      ..color = Colors.black;
    cut
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.9
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, r, cut);

    cut
      ..style = PaintingStyle.fill
      ..strokeWidth = 0;
    final eyeR = r * 0.16;
    final eyeY = center.dy - r * 0.22;
    canvas.drawCircle(Offset(center.dx - r * 0.42, eyeY), eyeR, cut);
    canvas.drawCircle(Offset(center.dx + r * 0.42, eyeY), eyeR, cut);

    cut
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.9
      ..strokeCap = StrokeCap.round;
    final mouthRect = Rect.fromCircle(
      center: Offset(center.dx, center.dy + r * 0.05),
      radius: r * 0.55,
    );
    canvas.drawArc(
      mouthRect,
      math.pi / 6,
      math.pi - math.pi / 3,
      false,
      cut,
    );
  }

  @override
  bool shouldRepaint(covariant StickerPainter old) =>
      old.color != color ||
      old.fill != fill ||
      old.strokeWidth != strokeWidth;
}
