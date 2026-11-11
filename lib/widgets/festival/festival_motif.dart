import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 节日图案：按 24×24 栅格设计的线稿，描边粗细与 Material Symbols 一致，
/// 颜色取主题（描边强调色、浅色填充、点缀第三色），明暗主题下都协调。
///
/// 每个图案有自己的一段循环动画：
/// - [phase]：循环进度，取小数部分，0 与 1 首尾相接；
/// - [intensity]：动效强度，0 为静止图案，1 为完整动画。加载时恒为 1，
///   点一下播一遍时由调用方先升后降，首尾都能平滑回到静止。
class FestivalMotif extends StatelessWidget {
  const FestivalMotif({
    super.key,
    required this.festivalId,
    this.size = 24,
    this.phase = 0,
    this.intensity = 0,
  });

  /// 节日 id（与 `assets/festivals/festivals.json` 一致）
  final String festivalId;
  final double size;
  final double phase;
  final double intensity;

  /// 有自绘图案的节日
  static const ids = [
    'spring',
    'lantern',
    'dragonboat',
    'qixi',
    'midautumn',
    'chongyang',
    'laba',
    'winter',
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: FestivalMotifPainter(
          festivalId: festivalId,
          line: scheme.primary,
          fill: scheme.primary.withValues(alpha: 0.14),
          accent: scheme.tertiary,
          phase: phase,
          intensity: intensity,
        ),
      ),
    );
  }
}

class FestivalMotifPainter extends CustomPainter {
  const FestivalMotifPainter({
    required this.festivalId,
    required this.line,
    required this.fill,
    required this.accent,
    this.phase = 0,
    this.intensity = 0,
  });

  final String festivalId;
  final Color line;
  final Color fill;
  final Color accent;
  final double phase;
  final double intensity;

  static const double _grid = 24;
  static const double _stroke = 1.8;

  // 插画几何（24 栅格单位），不是界面圆角，不随主题的圆角风格变化
  static const double _envelopeCorner = 2.5;
  static const double _cloudBaseCorner = 1.3;
  static const double _petalHalfWidth = 1.15;

  /// 循环进度的小数部分
  double get _t => phase - phase.floorToDouble();

  /// 以循环进度为角度的正弦，首尾相接
  double _wave([double cycles = 1, double offset = 0]) =>
      math.sin((_t * cycles + offset) * math.pi * 2);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / _grid;
    canvas
      ..save()
      ..translate(
        (size.width - _grid * scale) / 2,
        (size.height - _grid * scale) / 2,
      )
      ..scale(scale);
    // 光学尺寸：与 Material Symbols 一样，图案越大描边相对越细
    final stroke = _stroke * math.pow(_grid / size.shortestSide, 0.35);
    final p = _Pens(line, fill, accent, stroke.clamp(0.9, 2.2).toDouble());
    final a = intensity.clamp(0.0, 1.0);
    switch (festivalId) {
      case 'spring':
        _redEnvelope(canvas, p, a);
      case 'lantern':
        _lantern(canvas, p, a);
      case 'dragonboat':
        _zongzi(canvas, p, a);
      case 'qixi':
        _magpieBridge(canvas, p, a);
      case 'midautumn':
        _moon(canvas, p, a);
      case 'chongyang':
        _chrysanthemum(canvas, p, a);
      case 'laba':
        _porridge(canvas, p, a);
      case 'winter':
        _dumpling(canvas, p, a);
    }
    canvas.restore();
  }

  /// 红包：封口掀开 → 金币升起闪光 → 落回 → 合上
  void _redEnvelope(Canvas canvas, _Pens p, double a) {
    final t = _t;
    double ease(double x) => Curves.easeInOut.transform(x.clamp(0.0, 1.0));
    // 0~0.25 掀开，0.75~1 合上
    final open = a * (t < 0.5 ? ease(t / 0.25) : ease((1 - t) / 0.25));
    // 0.25~0.75 金币升起再落回
    final rise = a * math.sin(((t - 0.25) / 0.5).clamp(0.0, 1.0) * math.pi);

    final body = RRect.fromLTRBR(
      5,
      3,
      19,
      21,
      const Radius.circular(_envelopeCorner),
    );
    canvas
      ..drawRRect(body, p.fill)
      ..drawRRect(body, p.line);
    // 封口：V 形弧线从向下（合）翻到向上（开）
    final flap = Path()
      ..moveTo(5, 8)
      ..quadraticBezierTo(12, 14 - open * 12, 19, 8);
    canvas.drawPath(flap, p.line);
    // 金币
    final coin = Offset(12, 13 - rise * 9);
    canvas.drawCircle(coin, 2.4, p.accentFill);
    if (rise > 0.6) {
      final glow = (rise - 0.6) / 0.4;
      for (var i = 0; i < 4; i++) {
        final dir = Offset.fromDirection(i * math.pi / 2 + math.pi / 4);
        canvas.drawLine(
          coin + dir * 3.4,
          coin + dir * (3.4 + 1.8 * glow),
          p.accentLine,
        );
      }
    }
  }

  /// 灯笼：钟摆式摆动，流苏滞后跟随；灯光一明一暗
  void _lantern(Canvas canvas, _Pens p, double a) {
    final swing = _wave() * 0.22 * a;
    final lag = _wave(1, -0.12) * 0.4 * a;
    canvas
      ..save()
      ..translate(12, 2)
      ..rotate(swing)
      ..translate(-12, -2)
      ..drawLine(const Offset(12, 2), const Offset(12, 4.6), p.line)
      ..drawLine(const Offset(9.2, 4.6), const Offset(14.8, 4.6), p.line);
    const body = Rect.fromLTRB(4.6, 5.6, 19.4, 17.4);
    final glow = 0.14 + (0.5 + 0.5 * _wave(2)) * 0.26 * a;
    canvas
      ..drawOval(body, Paint()..color = line.withValues(alpha: glow))
      ..drawOval(body, p.line)
      ..drawOval(const Rect.fromLTRB(9.2, 5.6, 14.8, 17.4), p.thinLine)
      ..drawLine(const Offset(9.2, 18.4), const Offset(14.8, 18.4), p.line);
    // 流苏：根部固定，末端随惯性落后摆动
    for (final x in const [10.6, 12.0, 13.4]) {
      final tassel = Path()
        ..moveTo(x, 19.6)
        ..quadraticBezierTo(x, 21, x + lag * 4, 22);
      canvas.drawPath(tassel, p.accentLine);
    }
    canvas.restore();
  }

  /// 粽子：带挤压拉伸的弹跳，上方热气不断升起
  void _zongzi(Canvas canvas, _Pens p, double a) {
    // 一个循环跳两下
    final bounce = math.sin(_t * math.pi * 2).abs();
    final lift = bounce * 2.4 * a;
    // 落地时压扁、腾空时拉长
    final squash = 1 + (bounce - 0.5) * 0.16 * a;
    canvas
      ..save()
      ..translate(12, 19.4 - lift)
      ..scale(1 / squash, squash)
      ..translate(-12, -19.4);
    final body = Path()
      ..moveTo(10.6, 4.6)
      ..quadraticBezierTo(12, 2.6, 13.4, 4.6)
      ..lineTo(20.2, 16.6)
      ..quadraticBezierTo(21, 19.4, 18.2, 19.4)
      ..lineTo(5.8, 19.4)
      ..quadraticBezierTo(3, 19.4, 3.8, 16.6)
      ..close();
    canvas
      ..drawPath(body, p.fill)
      ..drawPath(body, p.line);
    final fold = Path()
      ..moveTo(12, 4.4)
      ..quadraticBezierTo(13.6, 12, 17.6, 19.4);
    canvas
      ..drawPath(fold, p.thinLine)
      ..drawLine(
        const Offset(6.4, 13.6),
        const Offset(17.6, 13.6),
        p.accentLine,
      )
      ..drawCircle(const Offset(12, 13.6), 1.2, p.accentFill)
      ..restore();
    _steam(canvas, p, a, const [8.0, 16.0], base: 3.4, height: 3.2);
  }

  /// 七夕：两颗星沿鹊桥相向而行，桥顶相会时闪光
  void _magpieBridge(Canvas canvas, _Pens p, double a) {
    final bridge = Path()
      ..moveTo(3, 18.5)
      ..quadraticBezierTo(12, 7.5, 21, 18.5);
    canvas
      ..drawPath(bridge, p.line)
      ..drawLine(const Offset(3, 21), const Offset(21, 21), p.thinLine);
    const leftEnd = Offset(5.5, 7);
    const rightEnd = Offset(18.5, 7);
    if (a == 0) {
      _sparkle(canvas, leftEnd, 3.2, p.accentFill);
      _sparkle(canvas, rightEnd, 3.2, p.accentFill);
      canvas.drawCircle(const Offset(12, 4), 0.9, p.accentFill);
      return;
    }
    // 0~0.6 沿弧线相向而行，0.6~0.8 相会闪光，0.8~1 在两端重新出现
    final t = _t;
    final walk = Curves.easeInOut.transform((t / 0.6).clamp(0.0, 1.0)) * a;
    final meet = t < 0.6 ? 0.0 : math.sin(((t - 0.6) / 0.4) * math.pi);
    const top = Offset(12, 3.6);
    Offset path(Offset from, double u) =>
        _quadPoint(from, Offset(from.dx, top.dy - 1), top, u);
    if (t < 0.8) {
      final paint = Paint()
        ..color = accent.withValues(alpha: 1 - meet * 0.7 * a);
      _sparkle(canvas, path(leftEnd, walk), 3.2, paint);
      _sparkle(canvas, path(rightEnd, walk), 3.2, paint);
    } else {
      final paint = Paint()
        ..color = accent.withValues(alpha: 1 - a + a * (t - 0.8) / 0.2);
      _sparkle(canvas, leftEnd, 3.2, paint);
      _sparkle(canvas, rightEnd, 3.2, paint);
    }
    if (meet > 0) _sparkle(canvas, top, 1.4 + meet * 3.6 * a, p.accentFill);
  }

  /// 中秋：云从月前飘过，循环往复；月晕呼吸
  void _moon(Canvas canvas, _Pens p, double a) {
    // 静止时云停在左下；动起来后从左外侧飘到右外侧，两朵相隔半个周期
    final clouds = a == 0
        ? [_cloudPath(const Offset(7.4, 17.2))]
        : [
            for (final shift in const [0.0, 0.5])
              _cloudPath(Offset(-8 + ((_t + shift) % 1) * 40, 16.6)),
          ];
    final moon = Path()
      ..addOval(Rect.fromCircle(center: const Offset(13.6, 10), radius: 7));
    var visibleMoon = moon;
    for (final cloud in clouds) {
      visibleMoon = Path.combine(
        PathOperation.difference,
        visibleMoon,
        _inflate(cloud, 1.6),
      );
    }
    if (a > 0) {
      final halo = 8.4 + (0.5 + 0.5 * _wave()) * 1.6;
      canvas.drawCircle(
        const Offset(13.6, 10),
        halo,
        Paint()..color = line.withValues(alpha: 0.10 * a),
      );
    }
    canvas
      ..drawPath(visibleMoon, p.fill)
      ..drawPath(visibleMoon, p.line)
      ..save()
      ..clipRect(const Rect.fromLTWH(0, 0, _grid, _grid));
    for (final cloud in clouds) {
      canvas
        ..drawPath(cloud, p.accentSoft)
        ..drawPath(cloud, p.accentLine);
    }
    canvas.restore();
  }

  /// 祥云：三团圆弧堆成的云朵
  static Path _cloudPath(Offset o) {
    final path = Path()
      ..addOval(
        Rect.fromCircle(center: o + const Offset(-2.6, 0.8), radius: 2.6),
      )
      ..addOval(
        Rect.fromCircle(center: o + const Offset(0.6, -0.8), radius: 3.4),
      )
      ..addOval(Rect.fromCircle(center: o + const Offset(4.0, 0.8), radius: 2.6))
      ..addRRect(
        RRect.fromLTRBR(
          o.dx - 5.2,
          o.dy + 0.8,
          o.dx + 6.6,
          o.dy + 3.4,
          const Radius.circular(_cloudBaseCorner),
        ),
      );
    return Path.combine(PathOperation.union, path, Path());
  }

  /// 以包围盒中心等比放大，得到比原形状外扩约 [by] 的轮廓（挖空留缝用）
  static Path _inflate(Path path, double by) {
    final b = path.getBounds();
    final k = (b.width + by * 2) / b.width;
    final c = b.center;
    final m = Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..scaleByDouble(k, k, 1, 1)
      ..translateByDouble(-c.dx, -c.dy, 0, 1);
    return path.transform(m.storage);
  }

  /// 重阳：花瓣依次舒展成波浪，整朵花缓缓旋转
  void _chrysanthemum(Canvas canvas, _Pens p, double a) {
    const center = Offset(12, 12);
    // 12 瓣对称，每个循环转一瓣的角度，首尾无缝
    final turn = _t * math.pi / 6 * a;
    for (var i = 0; i < 12; i++) {
      // 花瓣长度沿圆周依次起伏，形成绕花一圈的波浪
      final reach = _wave(1, i / 12) * 1.3 * a;
      canvas
        ..save()
        ..translate(center.dx, center.dy)
        ..rotate(i * math.pi / 6 + turn);
      final petal = RRect.fromLTRBR(
        -_petalHalfWidth,
        -9.8 - reach,
        _petalHalfWidth,
        -3.4,
        const Radius.circular(_petalHalfWidth),
      );
      canvas
        ..drawRRect(petal, p.fill)
        ..drawRRect(petal, p.line)
        ..restore();
    }
    canvas.drawCircle(
      center,
      2.1 + (0.5 + 0.5 * _wave(2)) * 0.4 * a,
      p.accentFill,
    );
  }

  /// 腊八：热气持续上升消散，豆子在粥面起伏
  void _porridge(Canvas canvas, _Pens p, double a) {
    final bowl = Path()
      ..moveTo(3.4, 12)
      ..lineTo(20.6, 12)
      ..arcToPoint(
        const Offset(3.4, 12),
        radius: const Radius.elliptical(8.6, 7),
      );
    canvas
      ..drawPath(bowl, p.fill)
      ..drawPath(bowl, p.line)
      ..drawLine(const Offset(9.4, 21), const Offset(14.6, 21), p.line);
    const beans = [Offset(9, 10.4), Offset(12, 9.8), Offset(15, 10.4)];
    for (var i = 0; i < beans.length; i++) {
      final bob = _wave(1, i / 3) * 0.7 * a;
      canvas.drawCircle(beans[i] + Offset(0, bob), 1, p.accentFill);
    }
    if (a == 0) {
      for (final x in const [9.0, 15.0]) {
        final steam = Path()
          ..moveTo(x, 7.4)
          ..cubicTo(x - 1.4, 6, x + 1.4, 4.6, x, 3);
        canvas.drawPath(steam, p.thinLine);
      }
      return;
    }
    _steam(canvas, p, a, const [9.0, 12.0, 15.0], base: 7.6, height: 5.6);
  }

  /// 冬至：饺子在沸水里浮沉，水面波动、气泡上升
  void _dumpling(Canvas canvas, _Pens p, double a) {
    final bob = _wave() * 1.4 * a;
    final tilt = _wave(1, 0.25) * 0.08 * a;
    canvas
      ..save()
      ..translate(12, 12 + bob)
      ..rotate(tilt)
      ..translate(-12, -12);
    const ca = Offset(3.2, 15.2);
    const cc = Offset(12, 3.2);
    const cb = Offset(20.8, 15.2);
    final body = Path()
      ..moveTo(ca.dx, ca.dy)
      ..quadraticBezierTo(cc.dx, cc.dy, cb.dx, cb.dy)
      ..quadraticBezierTo(12, 19.6, ca.dx, ca.dy)
      ..close();
    canvas
      ..drawPath(body, p.fill)
      ..drawPath(body, p.line);
    // 褶边：沿上沿排一串小弧，弧口朝里
    for (var i = 0; i < 6; i++) {
      final t0 = 0.2 + i * 0.1;
      final p0 = _quadPoint(ca, cc, cb, t0);
      final p1 = _quadPoint(ca, cc, cb, t0 + 0.1);
      final mid = Offset.lerp(p0, p1, 0.5)!;
      final normal = _normal(ca, cc, cb, t0 + 0.05);
      final pleat = Path()
        ..moveTo(p0.dx, p0.dy)
        ..quadraticBezierTo(
          mid.dx + normal.dx * 2.6,
          mid.dy + normal.dy * 2.6,
          p1.dx,
          p1.dy,
        );
      canvas.drawPath(pleat, p.thinLine);
    }
    canvas.restore();
    if (a == 0) return;
    // 水面：向右流动的波纹
    final water = Path()..moveTo(1, 19);
    for (var x = 1.0; x <= 23; x += 0.5) {
      water.lineTo(x, 19 + math.sin((x / 6 - _t) * math.pi * 2) * 0.8);
    }
    canvas.drawPath(
      water,
      Paint()
        ..color = accent.withValues(alpha: a)
        ..style = PaintingStyle.stroke
        ..strokeWidth = p.thinLine.strokeWidth
        ..strokeCap = StrokeCap.round,
    );
    // 气泡：从水面往上冒，越高越淡
    for (final (x, offset) in const [(6.0, 0.0), (17.0, 0.45), (11.0, 0.7)]) {
      final u = (_t + offset) % 1;
      canvas.drawCircle(
        Offset(x, 19 - u * 5),
        0.5 + u * 0.5,
        Paint()..color = accent.withValues(alpha: (1 - u) * a),
      );
    }
  }

  /// 热气：几缕 S 形曲线从 [base] 向上升起 [height]，越高越淡
  void _steam(
    Canvas canvas,
    _Pens p,
    double a,
    List<double> xs, {
    required double base,
    required double height,
  }) {
    if (a == 0) return;
    for (var i = 0; i < xs.length; i++) {
      final u = (_t + i / xs.length) % 1;
      final y = base - u * height;
      final x = xs[i] + math.sin((u + i * 0.3) * math.pi * 2) * 0.6;
      final steam = Path()
        ..moveTo(x, y + 2.4)
        ..cubicTo(x - 1.2, y + 1.4, x + 1.2, y + 0.6, x, y - 0.8);
      canvas.drawPath(
        steam,
        Paint()
          ..color = line.withValues(alpha: (1 - u) * a)
          ..style = PaintingStyle.stroke
          ..strokeWidth = p.thinLine.strokeWidth
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  static Offset _quadPoint(Offset a, Offset c, Offset b, double t) {
    final u = 1 - t;
    return a * (u * u) + c * (2 * u * t) + b * (t * t);
  }

  /// 二次贝塞尔在 t 处指向曲线内侧（下方）的单位法向
  static Offset _normal(Offset a, Offset c, Offset b, double t) {
    final d = (c - a) * (2 * (1 - t)) + (b - c) * (2 * t);
    final n = Offset(-d.dy, d.dx);
    final unit = n / n.distance;
    return unit.dy < 0 ? -unit : unit;
  }

  /// 四角星
  static void _sparkle(Canvas canvas, Offset c, double r, Paint paint) {
    final k = r * 0.28;
    final path = Path()
      ..moveTo(c.dx, c.dy - r)
      ..quadraticBezierTo(c.dx + k, c.dy - k, c.dx + r, c.dy)
      ..quadraticBezierTo(c.dx + k, c.dy + k, c.dx, c.dy + r)
      ..quadraticBezierTo(c.dx - k, c.dy + k, c.dx - r, c.dy)
      ..quadraticBezierTo(c.dx - k, c.dy - k, c.dx, c.dy - r)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(FestivalMotifPainter oldDelegate) =>
      oldDelegate.festivalId != festivalId ||
      oldDelegate.line != line ||
      oldDelegate.fill != fill ||
      oldDelegate.accent != accent ||
      oldDelegate.phase != phase ||
      oldDelegate.intensity != intensity;
}

class _Pens {
  _Pens(Color line, Color fill, Color accent, double stroke)
    : line = _stroke(line, stroke),
      thinLine = _stroke(line, stroke * 0.6),
      accentLine = _stroke(accent, stroke * 0.85),
      fill = Paint()..color = fill,
      accentFill = Paint()..color = accent,
      accentSoft = Paint()..color = accent.withValues(alpha: 0.24);

  final Paint line;
  final Paint thinLine;
  final Paint accentLine;
  final Paint fill;
  final Paint accentFill;
  final Paint accentSoft;

  static Paint _stroke(Color color, double width) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
}
