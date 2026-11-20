import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'topic_floating_bar_edge.dart';

/// 四种摆放位置共用端点、握柄和展开曲线，粗细随可用空间调整。
enum TopicProgressSurface {
  docked(2, 18, 0, 0),
  floating(TopicFloatingBarEdge.strokeWidth, 12, 0, 0),
  sidebar(3, 10, 17, 8),
  sheet(4, 13, 19, 10);

  const TopicProgressSurface(
    this.restThickness,
    this.openThickness,
    this.gripLength,
    this.gripThickness,
  );

  final double restThickness, openThickness, gripLength, gripThickness;
  bool get vertical => this == sidebar || this == sheet;
  double get openPaintHeight => openThickness + 6;

  /// 贴底细线占满分割线，展开时才逐渐让出系统边缘手势区。
  double insetAt(double openInset, double expansion) =>
      this == docked ? openInset * expansion : openInset;
}

/// 累加握柄沿轨道的实际位移；每次位移都会自行衰减，停住手指也能恢复原形。
class TopicThumbMotion {
  TopicThumbMotion(TickerProvider vsync)
    : _travel = AnimationController(
        vsync: vsync,
        lowerBound: -1,
        upperBound: 1,
        value: 0,
      );

  final AnimationController _travel;
  Animation<double> get travel => _travel.view;

  void moveBy(double delta) {
    if (delta == 0) return;
    // 连续快拖时约 28 个逻辑像素就能拉满；逐楼微调只留下很小的尾部。
    _travel.value = (_travel.value + delta / 28).clamp(-1.0, 1.0);
    _travel.animateTo(
      0,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
    );
  }

  void reset() => _travel.value = 0;
  void dispose() => _travel.dispose();
}

/// [startInset] 和 [endInset] 是展开时两端到握柄中心的距离。
class TopicProgressTrack extends StatelessWidget {
  const TopicProgressTrack({
    super.key,
    required this.surface,
    required this.progress,
    this.readingProgress,
    this.expansion = 0,
    this.startInset = 0,
    this.endInset = 0,
    this.thumbTravel = kAlwaysDismissedAnimation,
    this.lastRead,
    this.current,
    this.ruler,
    this.floatingEdge,
  });

  static const openDuration = Duration(milliseconds: 200);
  static const closeDuration = Duration(milliseconds: 160);
  static const curve = Curves.easeInOutCubic;

  final TopicProgressSurface surface;
  final double progress, expansion, startInset, endInset;

  /// 正文滚动只刷新绘制层，握柄和填充使用同一帧的读数。
  final Animation<double>? readingProgress;

  final Animation<double> thumbTravel;
  final double? lastRead, current;
  final TopicFloatingBarEdge? floatingEdge;

  /// 局部档位下，刻度按真实楼层间距铺开。
  final ({double origin, double rate, int total})? ruler;

  static double fraction(int index, int total) =>
      total > 1 ? ((index - 1) / (total - 1)).clamp(0.0, 1.0) : 1;

  static double readingFraction(int index, int total, double? floorsRead) =>
      floorsRead == null || total <= 0
      ? fraction(index, total)
      : (floorsRead / total).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final paint = CustomPaint(
      painter: _TrackPainter(
        this,
        Theme.of(context).colorScheme,
        context.emphasis.selected,
        context.shapes.radius(UiShapes.fullThreshold),
      ),
      child: const SizedBox.expand(),
    );
    return RepaintBoundary(
      child: surface.vertical
          ? RotatedBox(quarterTurns: 1, child: paint)
          : paint,
    );
  }
}

/// 渐变沿轨道铺开，两端按实际可用长度收淡。
class TopicProgressGradient extends StatelessWidget {
  const TopicProgressGradient({
    super.key,
    required this.axis,
    required this.gradient,
    required this.startFeather,
    required this.endFeather,
  });

  final Axis axis;
  final LinearGradient gradient;
  final double startFeather, endFeather;

  static Color tintOf(BuildContext context) => Color.alphaBlend(
    context.emphasis.selected.withValues(alpha: .14),
    Theme.of(context).colorScheme.surface,
  );

  @override
  Widget build(BuildContext context) {
    final field = DecoratedBox(decoration: BoxDecoration(gradient: gradient));
    if (startFeather == 0 && endFeather == 0) return field;
    final ink = Theme.of(context).colorScheme.surface.withValues(alpha: 1);
    final clear = ink.withValues(alpha: 0);
    final horizontal = axis == Axis.horizontal;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final extent = math.max(1.0, horizontal ? bounds.width : bounds.height);
        return LinearGradient(
          begin: horizontal ? Alignment.centerLeft : Alignment.topCenter,
          end: horizontal ? Alignment.centerRight : Alignment.bottomCenter,
          colors: [
            startFeather > 0 ? clear : ink,
            ink,
            ink,
            endFeather > 0 ? clear : ink,
          ],
          stops: [
            0,
            math.min(.5, startFeather / extent),
            1 - math.min(.5, endFeather / extent),
            1,
          ],
        ).createShader(bounds);
      },
      child: field,
    );
  }
}

class _TrackPainter extends CustomPainter {
  _TrackPainter(this.track, this.scheme, this.accent, this.radius)
    : super(
        repaint: track.readingProgress == null
            ? track.thumbTravel
            : Listenable.merge([track.thumbTravel, track.readingProgress]),
      );
  final TopicProgressTrack track;
  final ColorScheme scheme;
  final Color accent;
  final Radius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final style = track.surface;
    final t = track.expansion;
    final h = lerpDouble(style.restThickness, style.openThickness, t)!;
    final left = style.insetAt(track.startInset, t).clamp(0.0, size.width);
    final right = (size.width - style.insetAt(track.endInset, t)).clamp(
      left,
      size.width,
    );
    final width = right - left;
    if (width <= 0 || size.height <= 0) return;
    final y = size.height / 2;
    double xAt(double fraction) => left + width * fraction;
    final edge = t < 1 ? track.floatingEdge : null;
    Offset pointAt(double f) => edge == null
        ? Offset(xAt(f), y)
        : Offset.lerp(
            edge.at(f),
            Offset(xAt(f), style.openPaintHeight / 2),
            t,
          )!;
    final progress = track.readingProgress?.value ?? track.progress;
    final tip = pointAt(progress);
    final thumb = tip.dx;
    final paint = Paint();
    final paper = scheme.surfaceContainerLowest;
    RRect pill(double start, double end, double thickness) =>
        RRect.fromRectAndRadius(
          Rect.fromLTRB(start, y - thickness / 2, end, y + thickness / 2),
          radius,
        );
    final bed = pill(left - h / 2, right + h / 2, h);
    // 仅在贴底细线与拖动轨道交接期间补画两端，透明度跟随同一段展开动画。
    final dividerPaint = style == TopicProgressSurface.docked && t > 0 && t < 1
        ? Paint()
        : null;
    void drawSegment(RRect segment, double fraction, {bool divider = true}) {
      if (edge != null) {
        if (fraction == 0) {
          canvas.drawCircle(pointAt(0), segment.height / 2, paint);
          return;
        }
        final openY = style.openPaintHeight / 2;
        final path = edge.trace(
          fraction,
          t,
          Offset(left, openY),
          Offset(right, openY),
        );
        paint
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = segment.height;
        canvas.drawPath(path, paint);
        paint.style = PaintingStyle.fill;
        return;
      }
      if (dividerPaint != null && divider) {
        dividerPaint.color = paint.color.withValues(
          alpha: paint.color.a * (1 - t),
        );
        final end = size.width * fraction;
        final top = y - style.restThickness / 2;
        final leftWidth = math.min(bed.left, end);
        if (leftWidth > 0) {
          canvas.drawRect(
            Rect.fromLTWH(0, top, leftWidth, style.restThickness),
            dividerPaint,
          );
        }
        if (end > bed.right) {
          canvas.drawRect(
            Rect.fromLTWH(bed.right, top, end - bed.right, style.restThickness),
            dividerPaint,
          );
        }
      }
      canvas.drawRRect(segment, paint);
    }

    // 贴底的收起进度线可以铺到屏幕边缘，其他形态的圆头留在容器以内。
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final railColor = scheme.outlineVariant.withValues(
      alpha: style.vertical ? .8 : .55,
    );
    if (!style.vertical && t == 0) {
      if (progress <= 0 || progress >= 1) {
        paint.color = progress <= 0 ? railColor : accent;
      } else {
        // 两个色标落在同一位置，整条顶边只画一次，分界处也保持原来的线宽。
        final split = thumb / size.width;
        paint.shader = LinearGradient(
          colors: [accent, accent, railColor, railColor],
          stops: [0, split, split, 1],
        ).createShader(Offset.zero & size);
      }
      drawSegment(bed, 1);
      canvas.restore();
      return;
    }
    if (!style.vertical) {
      final rim = (style == TopicProgressSurface.floating ? 1.5 : 2.5) * t;
      paint.color = paper;
      drawSegment(bed.inflate(rim), 1, divider: false);
    }
    paint.color = Color.lerp(
      railColor,
      Color.alphaBlend(
        accent.withValues(alpha: .09),
        scheme.surfaceContainerHigh,
      ),
      t,
    )!;
    drawSegment(bed, 1);

    paint.color = accent;
    if (t > 0) {
      paint.shader = LinearGradient(
        colors: [Color.lerp(accent, paper, .16 * t)!, accent],
      ).createShader(bed.outerRect);
    }
    drawSegment(pill(left - h / 2, xAt(progress) + h / 2, h), progress);
    paint.shader = null;

    if (t > 0) {
      final ruler = track.ruler;
      if (ruler == null) {
        for (var i = 1; i < 4; i++) {
          final p = pointAt(i / 4);
          paint.color = (p.dx < thumb ? paper : accent).withValues(
            alpha: .48 * t,
          );
          canvas.drawCircle(p, 1.4 * t, paint);
        }
      } else {
        final step = math.max(1, (ruler.rate * 10).ceil());
        final first = (math.max(1.0, ruler.origin) / step).ceil() * step;
        final end = math.min(ruler.total, ruler.origin + width * ruler.rate);
        paint.strokeWidth = 1.25;
        paint.strokeCap = StrokeCap.round;
        for (var floor = first; floor <= end; floor += step) {
          final p = pointAt(
            ((floor - ruler.origin) / ruler.rate / width).clamp(0.0, 1.0),
          );
          final half = h * ((floor ~/ step) % 5 == 0 ? .28 : .14);
          paint.color = (p.dx < thumb ? paper : accent).withValues(
            alpha: .68 * t,
          );
          canvas.drawLine(p - Offset(0, half), p + Offset(0, half), paint);
        }
      }
    }
    if (style.vertical) {
      final last = track.lastRead;
      if (last != null) {
        final at = Offset(xAt(last), y);
        canvas.drawCircle(at, 4.25, paint..color = scheme.surface);
        canvas.drawCircle(at, 3, paint..color = accent);
      }
      final current = track.current;
      if (current != null && current != progress) {
        final at = Offset(xAt(current), y);
        canvas.drawCircle(at, 4.5, paint..color = accent);
        canvas.drawCircle(at, 2.75, paint..color = scheme.surface);
      }
    }
    final open = style.openThickness;
    final length = lerpDouble(
      style.gripLength,
      style.vertical ? open + 8 : open - 3,
      t,
    )!;
    final thickness = lerpDouble(
      style.gripThickness,
      style.vertical ? open + 3 : open - 3,
      t,
    )!;
    final half = math.min(length, size.width) / 2;
    final center = thumb.clamp(half, size.width - half);
    final stretch = axisStretch(track.thumbTravel.value * t, maxStretch: .5);
    final extra = length * stretch.amount;
    // 首末楼的圆头留在画布内，只有朝轨道内侧的尾部可以继续伸长。
    final start = math.max(
      math.max(0.0, pointAt(0).dx - half),
      center - half - extra * stretch.origin,
    );
    final end = math.min(
      math.min(size.width, pointAt(1).dx + half),
      center + half + extra * (1 - stretch.origin),
    );
    final grip = pill(start, end, thickness).shift(Offset(0, tip.dy - y));
    if (style.vertical) canvas.drawRRect(grip, paint..color = accent);
    canvas.drawRRect(
      style.vertical ? grip.deflate(1.75 * t) : grip,
      paint..color = Color.lerp(accent, paper, t)!,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TrackPainter old) =>
      track.surface != old.track.surface ||
      track.floatingEdge != old.track.floatingEdge ||
      track.progress != old.track.progress ||
      track.readingProgress != old.track.readingProgress ||
      track.expansion != old.track.expansion ||
      track.startInset != old.track.startInset ||
      track.endInset != old.track.endInset ||
      track.thumbTravel != old.track.thumbTravel ||
      track.lastRead != old.track.lastRead ||
      track.current != old.track.current ||
      track.ruler != old.track.ruler ||
      scheme != old.scheme ||
      accent != old.accent ||
      radius != old.radius;
}
