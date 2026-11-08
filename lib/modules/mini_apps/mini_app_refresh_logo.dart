import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show PathMetric, VertexMode, Vertices;

import 'package:flutter/material.dart';

/// A translucent three-tone rendition of the classic logo. Light flows along
/// its bands and smoothly around the rim; the silhouette stays still.
/// Pull, refresh and settle share the same phase.
class MiniAppRefreshLogo extends StatefulWidget {
  const MiniAppRefreshLogo({
    super.key,
    required this.progress,
    required this.refreshing,
  });

  final double progress;
  final bool refreshing;

  @override
  State<MiniAppRefreshLogo> createState() => _MiniAppRefreshLogoState();
}

class _MiniAppRefreshLogoState extends State<MiniAppRefreshLogo>
    with SingleTickerProviderStateMixin {
  late final _flow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  );
  double _phaseAtRelease = 0;
  double? _finishingPhase;
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _syncMotion();
  }

  @override
  void didUpdateWidget(MiniAppRefreshLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.refreshing && widget.refreshing) {
      _phaseAtRelease = _pullPhase(oldWidget.progress);
      _finishingPhase = null;
      _flow.value = 0;
    } else if (oldWidget.refreshing && !widget.refreshing) {
      _finishingPhase = _phaseAtRelease + _flow.value;
    } else if (!widget.refreshing && widget.progress > oldWidget.progress) {
      _finishingPhase = null;
    }
    _syncMotion();
  }

  void _syncMotion() {
    if (widget.refreshing && !_reduceMotion) {
      if (!_flow.isAnimating) _flow.repeat();
    } else {
      _flow.stop();
    }
  }

  double _pullPhase(double progress) => (progress * .22).clamp(0, .3);

  @override
  void dispose() {
    _flow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: _flow,
      builder: (context, _) => CustomPaint(
        key: const ValueKey('mini-app-refresh-logo-paint'),
        size: const Size.square(40),
        painter: _PathFlowLogoPainter(
          phase: _reduceMotion
              ? null
              : widget.refreshing
              ? (_phaseAtRelease + _flow.value) % 1
              : (_finishingPhase ?? _pullPhase(widget.progress)) % 1,
          colors: Theme.of(context).colorScheme,
        ),
      ),
    ),
  );
}

class _PathFlowLogoPainter extends CustomPainter {
  const _PathFlowLogoPainter({required this.phase, required this.colors});
  final double? phase;
  final ColorScheme colors;

  // assets/logo.svg, normalized from its 1024 viewBox. The selected "airy"
  // treatment distinguishes the three bands by opacity instead of saturation.
  static const _bounds = Rect.fromLTRB(6.25, 6.25, 93.75, 93.75);
  static final _circle = Path()..addOval(_bounds);
  static final _inside = Path()
    ..addOval(
      Rect.fromCircle(center: const Offset(50, 50), radius: 421 / 1024 * 100),
    );
  static final _rim = Path.combine(PathOperation.difference, _circle, _inside);
  static const _top = 324 / 1024 * 100;
  static const _bottom = 700 / 1024 * 100;
  static final _upperBand = Path.combine(
    PathOperation.intersect,
    _inside,
    Path()..addRect(const Rect.fromLTRB(0, 0, 100, _top)),
  );
  static final _lowerBand = Path.combine(
    PathOperation.intersect,
    _inside,
    Path()..addRect(const Rect.fromLTRB(0, _bottom, 100, 100)),
  );
  static final _bandMask = Path.combine(
    PathOperation.union,
    _upperBand,
    _lowerBand,
  );
  static final PathMetric _route = _buildRoute().computeMetrics().single;
  static const _segments = 180;
  static final _positions = _buildRibbon();
  static const _rimSegments = 256;
  static final _rimFlow = _buildRimFlow();

  static Path _buildRoute() {
    const radius = (448 + 421) / 2 / 1024 * 100;
    final angle = math.asin((50 - _top) / radius);
    final reach = math.sqrt(radius * radius - (50 - _top) * (50 - _top));
    return Path()
      ..moveTo(10, 22)
      ..lineTo(68, 22)
      ..quadraticBezierTo(85, 22, 50 + reach, _top)
      ..arcTo(
        Rect.fromCircle(center: const Offset(50, 50), radius: radius),
        -angle,
        angle * 2,
        false,
      )
      ..quadraticBezierTo(85, 78, 68, 78)
      ..lineTo(10, 78);
  }

  static Float32List _buildRibbon() {
    final positions = Float32List((_segments + 1) * 4);
    for (var i = 0; i <= _segments; i++) {
      final tangent = _route.getTangentForOffset(
        _route.length * i / _segments,
      )!;
      // Narrow the light as it enters the rim. A broad ribbon folds over
      // itself on tight bends, causing bright triangular artifacts.
      final approach = math
          .min(
            (tangent.position.dy - 22) / (_top - 22),
            (78 - tangent.position.dy) / (78 - _bottom),
          )
          .clamp(0.0, 1.0);
      final blend = approach * approach * (3 - 2 * approach);
      const rimHalfWidth = (448 - 421) / 2 / 1024 * 100;
      final width = 17 + (rimHalfWidth - 17) * blend;
      final normal = Offset(-tangent.vector.dy, tangent.vector.dx) * width;
      final left = tangent.position + normal;
      final right = tangent.position - normal;
      positions.setAll(i * 4, [left.dx, left.dy, right.dx, right.dy]);
    }
    return positions;
  }

  static ({Float32List positions, Float32List offsets, Float32List weights})
  _buildRimFlow() {
    const outerRadius = 448 / 1024 * 100;
    const innerRadius = 421 / 1024 * 100;
    const radius = (outerRadius + innerRadius) / 2;
    const center = Offset(50, 50);
    final positions = Float32List((_rimSegments + 1) * 4);
    final offsets = Float32List(_rimSegments + 1);
    final weights = Float32List(_rimSegments + 1);
    final samples = [
      for (var i = 0; i <= _segments; i++)
        _route.getTangentForOffset(_route.length * i / _segments)!.position,
    ];
    for (var i = 0; i <= _rimSegments; i++) {
      final angle = (i % _rimSegments) * math.pi * 2 / _rimSegments;
      final direction = Offset(math.cos(angle), math.sin(angle));
      final point = center + direction * radius;
      final outer = center + direction * outerRadius;
      final inner = center + direction * innerRadius;
      positions.setAll(i * 4, [outer.dx, outer.dy, inner.dx, inner.dy]);

      // Project the rim onto the same light route as the bands. This keeps
      // their phase aligned, including the top and bottom of the circle.
      var nearest = double.infinity;
      for (var j = 0; j < _segments; j++) {
        final segment = samples[j + 1] - samples[j];
        final relative = point - samples[j];
        final t =
            ((relative.dx * segment.dx + relative.dy * segment.dy) /
                    segment.distanceSquared)
                .clamp(0.0, 1.0);
        final distance = (relative - segment * t).distanceSquared;
        if (distance < nearest) {
          nearest = distance;
          offsets[i] = _route.length * (j + t) / _segments;
        }
      }
      // Fade out continuously towards the left joins. A rectangular half-
      // circle clip leaves a vertical brightness step at twelve / six o'clock;
      // allowing the whole wide ribbon onto the rim creates corner spurs.
      final fade = ((point.dx - 14) / 36).clamp(0.0, 1.0);
      weights[i] = fade * fade * (3 - 2 * fade);
    }
    return (positions: positions, offsets: offsets, weights: weights);
  }

  static double _lightStrength(double offset, double head, double tail) {
    final t = (offset - head + tail) / tail;
    if (t <= 0 || t >= 1) return 0;
    final fraction = t < .65 ? t / .65 : (1 - t) / .35;
    return fraction * fraction * (3 - 2 * fraction);
  }

  static void _drawFlow(
    Canvas canvas,
    Path clip,
    Float32List positions,
    Int32List shades,
  ) {
    canvas.save();
    canvas.clipPath(clip);
    final mesh = Vertices.raw(
      VertexMode.triangleStrip,
      positions,
      colors: shades,
    );
    canvas.drawVertices(mesh, BlendMode.dst, Paint());
    mesh.dispose();
    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);
    final dark = colors.brightness == Brightness.dark;
    final neutral = dark ? const Color(0xFFE3E5E8) : const Color(0xFF4F555E);
    final upper = neutral.withValues(alpha: dark ? .18 : .20);
    final middle = Colors.white.withValues(alpha: dark ? .055 : .25);
    final lower = neutral.withValues(alpha: dark ? .29 : .10);
    // Paint the three tones together: separately antialiased translucent
    // rectangles leave a hairline of background along their shared edges.
    canvas.drawPath(
      _inside,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [upper, upper, middle, middle, lower, lower],
          stops: [0, _top / 100, _top / 100, _bottom / 100, _bottom / 100, 1],
        ).createShader(const Rect.fromLTWH(0, 0, 100, 100)),
    );
    canvas.drawPath(_rim, Paint()..color = neutral.withValues(alpha: .14));
    if (phase != null) {
      final length = _route.length;
      final tail = length * .76;
      final head = phase! * (length + tail);
      final light = dark ? const Color(0xFFE0E3EA) : const Color(0xFF7C8491);
      // One connected gradient mesh avoids the seams and alpha accumulation
      // of many individually antialiased strokes. Geometry stays cached;
      // only brightness travels along it, with a soft head and longer tail.
      final shades = Int32List((_segments + 1) * 2);
      for (var i = 0; i <= _segments; i++) {
        final strength = _lightStrength(length * i / _segments, head, tail);
        final color = light.withValues(alpha: strength * .64).toARGB32();
        shades[i * 2] = color;
        shades[i * 2 + 1] = color;
      }
      _drawFlow(canvas, _bandMask, _positions, shades);
      final rimShades = Int32List((_rimSegments + 1) * 2);
      for (var i = 0; i <= _rimSegments; i++) {
        final strength = _lightStrength(_rimFlow.offsets[i], head, tail);
        final color = light
            .withValues(alpha: strength * _rimFlow.weights[i] * .64)
            .toARGB32();
        rimShades[i * 2] = color;
        rimShades[i * 2 + 1] = color;
      }
      _drawFlow(canvas, _rim, _rimFlow.positions, rimShades);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PathFlowLogoPainter oldDelegate) =>
      phase != oldDelegate.phase || colors != oldDelegate.colors;
}
