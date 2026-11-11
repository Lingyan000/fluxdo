import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 纸张纹理：程序生成的可平铺小图（颗粒 + 纤维 + 轻微斑驳）。
///
/// 每种亮度只生成一次并缓存，之后以平铺着色器绘制，不做任何动画；
/// 纹理本身已烘焙了很低的透明度，直接叠在纸色上即可。
class PaperTexture {
  PaperTexture._();

  static const int tileSize = 256;

  static final Map<Brightness, ui.Image> _images = {};
  static final Map<Brightness, Future<ui.Image>> _pending = {};

  /// 已生成的纹理（未生成时为 null，调用 [obtain] 触发生成）。
  static ui.Image? cached(Brightness brightness) => _images[brightness];

  static Future<ui.Image> obtain(Brightness brightness) =>
      _pending[brightness] ??= _generate(brightness).then((image) {
        _images[brightness] = image;
        return image;
      });

  static Future<ui.Image> _generate(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    const size = tileSize;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final rng = math.Random(20261111);

    // 平铺无缝：跨边的元素在相邻 8 个位置各画一次
    void wrapped(void Function(Offset shift) draw) {
      for (final dx in const [-1, 0, 1]) {
        for (final dy in const [-1, 0, 1]) {
          draw(Offset(dx * size.toDouble(), dy * size.toDouble()));
        }
      }
    }

    // 1. 斑驳：几团很淡的大块明暗，让纸面不是死平
    for (var i = 0; i < 6; i++) {
      final center = Offset(rng.nextDouble() * size, rng.nextDouble() * size);
      final radius = 40 + rng.nextDouble() * 70;
      final light = rng.nextBool();
      final color = (dark ? light : !light)
          ? const Color(0xFFFFFFFF)
          : const Color(0xFF5A4630);
      final paint = Paint()
        ..shader = ui.Gradient.radial(
          Offset.zero,
          radius,
          [color.withValues(alpha: dark ? 0.018 : 0.03), color.withValues(alpha: 0)],
        );
      wrapped((shift) {
        canvas
          ..save()
          ..translate(center.dx + shift.dx, center.dy + shift.dy)
          ..drawCircle(Offset.zero, radius, paint)
          ..restore();
      });
    }

    // 2. 颗粒：细密的深浅点
    final darkSpecks = <Offset>[];
    final lightSpecks = <Offset>[];
    for (var i = 0; i < 2600; i++) {
      final p = Offset(rng.nextDouble() * size, rng.nextDouble() * size);
      (rng.nextDouble() < 0.6 ? darkSpecks : lightSpecks).add(p);
    }
    canvas.drawPoints(
      ui.PointMode.points,
      darkSpecks,
      Paint()
        ..color = dark
            ? const Color(0xFF000000).withValues(alpha: 0.16)
            : const Color(0xFF6B5638).withValues(alpha: 0.10)
        ..strokeWidth = 1,
    );
    canvas.drawPoints(
      ui.PointMode.points,
      lightSpecks,
      Paint()
        ..color = const Color(0xFFFFFFFF).withValues(alpha: dark ? 0.035 : 0.25)
        ..strokeWidth = 1,
    );

    // 3. 纤维：少量随机弯曲的细短线
    final fiber = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 46; i++) {
      final start = Offset(rng.nextDouble() * size, rng.nextDouble() * size);
      final angle = rng.nextDouble() * math.pi * 2;
      final length = 10 + rng.nextDouble() * 26;
      final bend = (rng.nextDouble() - 0.5) * 10;
      final end = start + Offset(math.cos(angle), math.sin(angle)) * length;
      final mid = Offset.lerp(start, end, 0.5)! +
          Offset(-math.sin(angle), math.cos(angle)) * bend;
      fiber
        ..strokeWidth = 0.4 + rng.nextDouble() * 0.6
        ..color = dark
            ? const Color(0xFFFFFFFF).withValues(alpha: 0.025 + rng.nextDouble() * 0.025)
            : const Color(0xFF7A6040).withValues(alpha: 0.05 + rng.nextDouble() * 0.05);
      wrapped((shift) {
        final path = Path()
          ..moveTo(start.dx + shift.dx, start.dy + shift.dy)
          ..quadraticBezierTo(
            mid.dx + shift.dx,
            mid.dy + shift.dy,
            end.dx + shift.dx,
            end.dy + shift.dy,
          );
        canvas.drawPath(path, fiber);
      });
    }

    return recorder.endRecording().toImage(size, size);
  }
}

/// 纸张页面背景：纸色 + 平铺纹理（纹理生成前只显示纸色）。
class PaperBackground extends StatefulWidget {
  const PaperBackground({super.key, required this.color});

  /// 纸色（不透明）。
  final Color color;

  @override
  State<PaperBackground> createState() => _PaperBackgroundState();
}

class _PaperBackgroundState extends State<PaperBackground> {
  ui.Image? _image;
  Brightness? _brightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (brightness == _brightness) return;
    _brightness = brightness;
    _image = PaperTexture.cached(brightness);
    if (_image == null) {
      unawaited(
        PaperTexture.obtain(brightness).then((image) {
          if (mounted && _brightness == brightness) {
            setState(() => _image = image);
          }
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _PaperPainter(widget.color, _image),
      child: const SizedBox.expand(),
    );
  }
}

class _PaperPainter extends CustomPainter {
  _PaperPainter(this.color, this.image);

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
  bool shouldRepaint(_PaperPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.image != image;
}
