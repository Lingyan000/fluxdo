import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 节日底纹：极淡的平铺纹样，叠在页面底色上。
///
/// 每种纹样 × 颜色只生成一次可平铺小图并缓存，之后以平铺着色器绘制，
/// 不做动画。
enum FestivalPatternKind {
  /// 祥云（春节、元宵）
  clouds,

  /// 青海波（端午）
  waves,

  /// 星点（七夕、中秋）
  stars,

  /// 小花（重阳）
  petals,

  /// 雪点（腊八、冬至）
  snow;

  static FestivalPatternKind forFestival(String id) => switch (id) {
    'spring' || 'lantern' => clouds,
    'dragonboat' => waves,
    'qixi' || 'midautumn' => stars,
    'chongyang' => petals,
    _ => snow,
  };
}

/// 底纹颜色：强调色的极低透明度，深色下略高一点才看得出。
Color festivalPatternInk(ColorScheme scheme) => scheme.primary.withValues(
  alpha: scheme.brightness == Brightness.light ? 0.07 : 0.09,
);

class FestivalPattern {
  FestivalPattern._();

  static const int tileSize = 180;

  static final Map<(FestivalPatternKind, int), ui.Image> _images = {};
  static final Map<(FestivalPatternKind, int), Future<ui.Image>> _pending = {};

  static ui.Image? cached(FestivalPatternKind kind, Color color) =>
      _images[(kind, color.toARGB32())];

  static Future<ui.Image> obtain(FestivalPatternKind kind, Color color) {
    final key = (kind, color.toARGB32());
    return _pending[key] ??= _generate(kind, color).then((image) {
      _images[key] = image;
      return image;
    });
  }

  static Future<ui.Image> _generate(FestivalPatternKind kind, Color color) {
    const size = tileSize;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color;

    // 平铺无缝：跨边的元素在相邻位置各画一次
    void wrapped(void Function(Offset shift) draw) {
      for (final dx in const [-1, 0, 1]) {
        for (final dy in const [-1, 0, 1]) {
          draw(Offset(dx * size.toDouble(), dy * size.toDouble()));
        }
      }
    }

    switch (kind) {
      case FestivalPatternKind.clouds:
        for (final (c, s, flip) in const [
          (Offset(40, 46), 9.0, false),
          (Offset(132, 120), 9.0, true),
          (Offset(118, 26), 6.0, true),
          (Offset(36, 146), 6.0, false),
        ]) {
          wrapped((shift) => _cloud(canvas, c + shift, s, flip, stroke));
        }
      case FestivalPatternKind.waves:
        // 青海波铺满整个页面，线条要比其他零散纹样更细，整体浓淡才一致
        stroke.strokeWidth = 0.9;
        // 青海波：错行排列的同心半圆
        const r = 22.5; // 180 / 8，保证整除可平铺
        for (var row = 0; row <= size ~/ (r / 2) + 1; row++) {
          final y = row * r / 2;
          final offset = row.isOdd ? r : 0.0;
          for (var x = -r * 2 + offset; x <= size + r * 2; x += r * 2) {
            final c = Offset(x, y);
            for (final k in const [1.0, 0.68, 0.36]) {
              canvas.drawArc(
                Rect.fromCircle(center: c, radius: r * k),
                math.pi,
                math.pi,
                false,
                stroke,
              );
            }
          }
        }
      case FestivalPatternKind.stars:
        final rng = math.Random(7);
        for (var i = 0; i < 7; i++) {
          final c = Offset(rng.nextDouble() * size, rng.nextDouble() * size);
          final r = 3.5 + rng.nextDouble() * 3;
          wrapped((shift) => _sparkle(canvas, c + shift, r, fill));
        }
        for (var i = 0; i < 16; i++) {
          final c = Offset(rng.nextDouble() * size, rng.nextDouble() * size);
          wrapped((shift) => canvas.drawCircle(c + shift, 1.1, fill));
        }
      case FestivalPatternKind.petals:
        final rng = math.Random(11);
        for (var i = 0; i < 6; i++) {
          final c = Offset(rng.nextDouble() * size, rng.nextDouble() * size);
          final turn = rng.nextDouble() * math.pi;
          wrapped((shift) => _flower(canvas, c + shift, 6, turn, stroke));
        }
      case FestivalPatternKind.snow:
        final rng = math.Random(23);
        for (var i = 0; i < 6; i++) {
          final c = Offset(rng.nextDouble() * size, rng.nextDouble() * size);
          wrapped((shift) => _snowflake(canvas, c + shift, 5, stroke));
        }
        for (var i = 0; i < 18; i++) {
          final c = Offset(rng.nextDouble() * size, rng.nextDouble() * size);
          wrapped((shift) => canvas.drawCircle(c + shift, 1.2, fill));
        }
    }
    return recorder.endRecording().toImage(size, size);
  }

  /// 祥云：一大一小两个回旋，尾部拖出一笔
  static void _cloud(Canvas canvas, Offset c, double s, bool flip, Paint p) {
    canvas
      ..save()
      ..translate(c.dx, c.dy);
    if (flip) canvas.scale(-1, 1);
    final path = Path()
      ..addArc(
        Rect.fromCircle(center: Offset.zero, radius: s),
        math.pi * 0.1,
        math.pi * 1.6,
      )
      ..addArc(
        Rect.fromCircle(center: Offset.zero, radius: s * 0.48),
        math.pi * 0.6,
        math.pi * 1.4,
      )
      ..addArc(
        Rect.fromCircle(center: Offset(s * 1.55, s * 0.35), radius: s * 0.62),
        math.pi * 1.0,
        math.pi * 1.3,
      )
      ..moveTo(-s * 0.95, s * 0.35)
      ..quadraticBezierTo(-s * 2.2, s * 0.9, -s * 3.0, s * 0.4);
    canvas
      ..drawPath(path, p)
      ..restore();
  }

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

  static void _flower(Canvas canvas, Offset c, double r, double turn, Paint p) {
    for (var i = 0; i < 5; i++) {
      final a = turn + i * math.pi * 2 / 5;
      final petal = c + Offset(math.cos(a), math.sin(a)) * r * 0.75;
      canvas.drawCircle(petal, r * 0.42, p);
    }
  }

  static void _snowflake(Canvas canvas, Offset c, double r, Paint p) {
    for (var i = 0; i < 3; i++) {
      final a = i * math.pi / 3;
      final d = Offset(math.cos(a), math.sin(a)) * r;
      canvas.drawLine(c - d, c + d, p);
    }
  }
}

/// 节日底纹页面背景：底色 + 平铺纹样（纹样生成前只显示底色）。
class FestivalPatternBackground extends StatefulWidget {
  const FestivalPatternBackground({
    super.key,
    required this.kind,
    required this.color,
    required this.ink,
  });

  final FestivalPatternKind kind;

  /// 页面底色（不透明）
  final Color color;

  /// 纹样颜色（已含透明度）
  final Color ink;

  @override
  State<FestivalPatternBackground> createState() =>
      _FestivalPatternBackgroundState();
}

class _FestivalPatternBackgroundState extends State<FestivalPatternBackground> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FestivalPatternBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind || oldWidget.ink != widget.ink) _load();
  }

  void _load() {
    final kind = widget.kind;
    final ink = widget.ink;
    _image = FestivalPattern.cached(kind, ink);
    if (_image != null) return;
    unawaited(
      FestivalPattern.obtain(kind, ink).then((image) {
        if (mounted && widget.kind == kind && widget.ink == ink) {
          setState(() => _image = image);
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _PatternPainter(widget.color, _image),
    child: const SizedBox.expand(),
  );
}

class _PatternPainter extends CustomPainter {
  _PatternPainter(this.color, this.image);

  final Color color;
  final ui.Image? image;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = color);
    final image = this.image;
    if (image == null) return;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ImageShader(
          image,
          TileMode.repeated,
          TileMode.repeated,
          Matrix4.identity().storage,
        ),
    );
  }

  @override
  bool shouldRepaint(_PatternPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.image != image;
}
