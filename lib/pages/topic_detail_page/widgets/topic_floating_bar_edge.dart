import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// 悬浮底栏上沿的描边中心线，进度、握柄和渐变共用同一组弧长坐标。
class TopicFloatingBarEdge {
  TopicFloatingBarEdge(this.size, this.shape);

  final Size size;
  final RoundedSuperellipseBorder shape;

  static const strokeWidth = 1.5;
  static const inset = strokeWidth / 2;
  late final Rect _rect = (Offset.zero & size).deflate(inset);
  late final double _radius = shape.borderRadius.resolve(null).topLeft.x;
  late final _metric = shape
      .copyWith(side: const BorderSide(width: inset))
      .getInnerPath(Offset.zero & size)
      .computeMetrics()
      .first;

  // 原生闭合路径的起点和绕行方向由渲染后端决定。从顶边中点向两端量弧长。
  late final ({double offset, double direction}) _top = _locateTop();
  ({double offset, double direction}) _locateTop() {
    final length = _metric.length;
    final center = _rect.topCenter;
    final step = length / 8;
    var best = double.infinity;
    var nearest = 0.0;
    for (var i = 0; i < 8; i++) {
      final d = i * step;
      final distance =
          (_metric.getTangentForOffset(d)!.position - center).distanceSquared;
      if (distance < best) {
        nearest = d;
        best = distance;
      }
    }
    // 沿切线校正弧长；落在平直段上时一步即到中点。
    var tangent = _metric.getTangentForOffset(nearest)!;
    for (var i = 0; i < 8; i++) {
      final delta = center - tangent.position;
      final along = delta.dx * tangent.vector.dx + delta.dy * tangent.vector.dy;
      if (along.abs() < .01) break;
      nearest = (nearest + along) % length;
      tangent = _metric.getTangentForOffset(nearest)!;
    }
    return (offset: nearest, direction: tangent.vector.dx.sign);
  }

  // 左右侧中点之间的上沿占周长一半，小圆角再扣除两侧多出来的直边。
  late final double _shoulderDepth = math.min(
    _rect.height / 2,
    2 * math.max(0.0, _radius - inset),
  );
  late final double _shoulderLength = _radius <= inset || _rect.isEmpty
      ? math.max(0.0, _rect.width)
      : _metric.length / 2 - 2 * (_rect.height / 2 - _shoulderDepth);

  Offset _fromTopCenter(double arc) {
    if (_rect.isEmpty) return size.center(Offset.zero);
    if (_radius <= inset) {
      return _rect.topCenter + Offset(arc, 0);
    }
    final distance = _top.offset + _top.direction * arc;
    return _metric.getTangentForOffset(distance % _metric.length)!.position;
  }

  // 阅读线留在顶边，只取刚进入圆角的一小段。渐变仍从底栏的整个上沿衔接。
  late final double _trackLength = () {
    if (_radius <= inset || _rect.isEmpty) return _shoulderLength;
    final drop = math.min(2.0, (_radius - inset) * .18);
    var low = 0.0, high = _shoulderLength / 2;
    while (high - low > .02) {
      final mid = (low + high) / 2;
      if (_fromTopCenter(mid).dy <= _rect.top + drop) {
        low = mid;
      } else {
        high = mid;
      }
    }
    return low * 2;
  }();

  Offset at(double fraction) => _fromTopCenter((fraction - .5) * _trackLength);

  List<double> _fractions(double length, double extent, double spacing) {
    final reach = math.min(length / 2, extent);
    final steps = math.max(1, (reach / spacing).ceil());
    final fractions = <double>{0, 1};
    for (var i = 1; i <= steps && length > 0; i++) {
      final f = reach * i / steps / length;
      fractions.addAll([f, 1 - f]);
    }
    return fractions.toList()..sort();
  }

  // 弯角密采样，中间的直边只需连接两端。尺寸、主题或圆角变化时才重新取样。
  late final _knots = [
    for (final f in _fractions(_trackLength, 2 * _shoulderDepth, 2))
      (fraction: f, point: at(f)),
  ];

  /// 阅读时只有分界位置在变，整条顶边的路径可逐帧复用。
  late final Path _readingPath = Path()
    ..addPolygon([for (final knot in _knots) knot.point], false);

  Path trace(double fraction, double expansion, Offset start, Offset end) {
    if (expansion == 0 && fraction == 1) return _readingPath;
    Offset morph(Offset point, double f) =>
        Offset.lerp(point, Offset.lerp(start, end, f)!, expansion)!;
    final first = morph(_knots.first.point, 0);
    final path = Path()..moveTo(first.dx, first.dy);
    for (final knot in _knots.skip(1)) {
      if (knot.fraction >= fraction) break;
      final p = morph(knot.point, knot.fraction);
      path.lineTo(p.dx, p.dy);
    }
    final tip = morph(at(fraction), fraction);
    return path..lineTo(tip.dx, tip.dy);
  }

  // 上方把两肩的羽化拉宽，根部则沿圆角贴紧底栏。两者之间共用相邻的顶点。
  late final double sideFeather = math.min(120.0, size.width * .18);
  late final _columns = [
    for (final f in _fractions(
      _shoulderLength,
      math.max(sideFeather, 3 * _shoulderDepth),
      5,
    ))
      (
        root: _fromTopCenter((f - .5) * _shoulderLength),
        sideDistance: math.min(f, 1 - f) * _shoulderLength,
      ),
  ];
}

/// 底色从底栏的同色轮廓向上生长，两肩和摘要上方分别平滑透出正文。
class TopicFloatingScrubBackdrop extends CustomPainter {
  TopicFloatingScrubBackdrop({
    required this.edge,
    required this.visibility,
    required this.feather,
    required this.container,
    required this.surface,
    required this.accent,
  }) : super(repaint: visibility);

  final TopicFloatingBarEdge edge;
  final Animation<double> visibility;
  final double feather;
  final Color container, surface, accent;

  static const _fadeSteps = 10;
  static double _smooth(double x) => x * x * (3 - 2 * x);

  @override
  void paint(Canvas canvas, Size size) {
    final t = visibility.value;
    if (size.isEmpty || t == 0 || edge._shoulderLength <= 0) return;
    final growth = Curves.easeOutCubic.transform(t);
    final barTop = size.height - edge.size.height / 2;
    final tint = Color.alphaBlend(accent.withValues(alpha: .08), container);
    final topFeather = feather.clamp(0.0, math.max(0.0, barTop));
    final rootFeather = math.min(22.0, edge.sideFeather);
    final positions = <Offset>[], colors = <Color>[], indices = <int>[];
    for (final column in edge._columns) {
      final root = column.root;
      final y = barTop + root.dy;
      final toSide = math.min(root.dx, size.width - root.dx);
      final shoulderHeight = math.max(1.0, math.min(y, edge.size.height * 1.5));
      final base = positions.length;
      void vertex(double targetY, Color color, double opacity) {
        final lift = _smooth(((y - targetY) / shoulderHeight).clamp(0.0, 1.0));
        final spread = ui.lerpDouble(rootFeather, edge.sideFeather, lift)!;
        // 靠近底栏时沿弧长收色，升到摘要时按水平距离羽化，圆肩上方才不会拉出直边。
        final distance = ui.lerpDouble(column.sideDistance, toSide, lift)!;
        final side = _smooth((distance / spread).clamp(0.0, 1.0));
        positions.add(Offset(root.dx, ui.lerpDouble(y, targetY, growth)!));
        colors.add(color.withValues(alpha: opacity * side * growth));
        final at = positions.length - 1;
        if (base > 0 && at > base) {
          const rows = _fadeSteps + 3;
          indices.addAll([
            at - rows - 1,
            at - 1,
            at,
            at - rows - 1,
            at,
            at - rows,
          ]);
        }
      }

      vertex(y, container, 1);
      vertex(ui.lerpDouble(y, topFeather, .33)!, tint, 1);
      for (var i = _fadeSteps; i >= 0; i--) {
        final u = i / _fadeSteps;
        vertex(topFeather * u, surface, .98 * _smooth(u));
      }
    }
    final mesh = ui.Vertices(
      ui.VertexMode.triangles,
      positions,
      colors: colors,
      indices: indices,
    );
    canvas.drawVertices(mesh, BlendMode.src, Paint()..color = surface);
    mesh.dispose();
  }

  @override
  bool shouldRepaint(TopicFloatingScrubBackdrop old) =>
      old.edge != edge ||
      old.visibility != visibility ||
      old.feather != feather ||
      old.container != container ||
      old.surface != surface ||
      old.accent != accent;
}
