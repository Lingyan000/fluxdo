import 'package:flutter/material.dart';
import 'package:common_ui/common_ui.dart';

import 'm3e_motion.dart';

/// 完成态的轻量勾选动效。业务方确认成功后再挂载，并提供对应语义文案。
class M3eSuccessIndicator extends StatelessWidget {
  const M3eSuccessIndicator({super.key, this.size = 72});

  final double size;
  static const _duration = Duration(milliseconds: 520);
  static final _scaleCurve = M3eMotion.defaultSpatial.curveFor(_duration);

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final color = context.emphasis.accent;
    return ExcludeSemantics(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: reduced ? 1 : 0, end: 1),
        duration: reduced ? Duration.zero : _duration,
        builder: (context, progress, _) => Transform.scale(
          scale: 0.85 + 0.15 * _scaleCurve.transform(progress),
          child: CustomPaint(
            size: Size.square(size),
            painter: _SuccessPainter(color, progress),
          ),
        ),
      ),
    );
  }
}

class _SuccessPainter extends CustomPainter {
  const _SuccessPainter(this.color, this.progress);
  final Color color;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    canvas.drawCircle(
      center,
      size.shortestSide / 2,
      Paint()..color = color.withValues(alpha: 0.12 * progress),
    );
    final path = Path()
      ..moveTo(size.width * 0.28, size.height * 0.51)
      ..lineTo(size.width * 0.44, size.height * 0.67)
      ..lineTo(size.width * 0.73, size.height * 0.35);
    final metric = path.computeMetrics().first;
    final stroke = ((progress - 0.15) / 0.7).clamp(0.0, 1.0);
    canvas.drawPath(
      metric.extractPath(
        0,
        metric.length * Curves.easeOutCubic.transform(stroke),
      ),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.shortestSide * 0.055
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SuccessPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.progress != progress;
}
