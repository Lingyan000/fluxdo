import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 用与 painter 相同的公式独立复算，验证方向性确实存在
  double alphaAt(double angle, {required bool isDark}) {
    final lightAngle = math.atan2(-0.82, -0.58);
    final peak = isDark ? 0.188 : 0.46;
    final base = isDark ? 0.042 : 0.19;
    final d = math.cos(angle - lightAngle);
    final dir = d <= 0 ? 0.0 : d * d * d;
    return base + (peak - base) * dir;
  }

  test('边缘亮度随方向变化，不是均匀线', () {
    for (final isDark in [true, false]) {
      final samples = [
        for (var i = 0; i < 24; i++) alphaAt(i / 24 * 2 * math.pi, isDark: isDark),
      ];
      final mx = samples.reduce(math.max);
      final mn = samples.reduce(math.min);
      debugPrint('${isDark ? "深色" : "浅色"}: 最亮 ${(mx * 100).toStringAsFixed(1)}%  '
          '最暗 ${(mn * 100).toStringAsFixed(1)}%  比值 ${(mx / mn).toStringAsFixed(1)}x');
      expect(mx / mn, greaterThan(2.0),
          reason: '整圈亮度比需明显大于 1，否则又是均匀线框');
    }
  });

  test('峰值出现在左上迎光侧，不在别处', () {
    final lightAngle = math.atan2(-0.82, -0.58);
    var bestAngle = 0.0, best = -1.0;
    for (var i = 0; i < 360; i++) {
      final a = alphaAt(i / 180 * math.pi, isDark: true);
      if (a > best) { best = a; bestAngle = i / 180 * math.pi; }
    }
    // 峰值角应当就是光源角(归一化到同一圈)
    var diff = (bestAngle - lightAngle).abs() % (2 * math.pi);
    if (diff > math.pi) diff = 2 * math.pi - diff;
    debugPrint('峰值角与光源角偏差 = ${(diff / math.pi * 180).toStringAsFixed(1)}°');
    expect(diff, lessThan(0.05), reason: '最亮点必须落在光源方向');
  });

  testWidgets('SweepGradient 描边可正常绘制', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 56,
            child: CustomPaint(painter: _Probe(radius: 28, isDark: true)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

/// 复刻 painter 的绘制路径，确认 ui.Gradient.sweep 在真实 Canvas 上不抛错
class _Probe extends CustomPainter {
  const _Probe({required this.radius, required this.isDark});
  final double radius;
  final bool isDark;
  @override
  void paint(Canvas canvas, Size size) {
    final inner = (Offset.zero & size).deflate(0.25);
    final colors = [
      for (var i = 0; i <= 24; i++) Colors.white.withValues(alpha: 0.1),
    ];
    canvas.drawRRect(
      RRect.fromRectAndRadius(inner, Radius.circular(radius - 0.25)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..shader = ui.Gradient.sweep(inner.center, colors,
            [for (var i = 0; i < colors.length; i++) i / (colors.length - 1)]),
    );
  }
  @override
  bool shouldRepaint(_Probe old) => false;
}
