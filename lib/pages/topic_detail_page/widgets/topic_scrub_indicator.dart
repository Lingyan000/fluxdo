import 'dart:math' as math;

import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/s.dart';
import '../../../utils/time_utils.dart';
import '../../../widgets/common/emoji_text.dart';
import '../controllers/topic_position_info.dart';
import 'topic_bottom_bar.dart';
import 'topic_scrub_mapping.dart';

/// 拖动时，正文在楼层预览和轨道周围逐渐淡入主题表面色。
class TopicScrubIndicator extends StatelessWidget {
  const TopicScrubIndicator({
    super.key,
    required this.visibility,
    required this.barRect,
    required this.railLeft,
    required this.tracker,
    required this.pointerY,
    required this.date,
    required this.excerptIndex,
    required this.excerpt,
  });

  final Animation<double> visibility;
  final Rect barRect;
  final double railLeft;
  final TopicScrubTracker tracker;
  final double pointerY;
  final DateTime? date;
  final int excerptIndex;
  final TopicPositionInfo? excerpt;

  static const double _railHeight = 28;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = context.emphasis.selected;
    final screen = MediaQuery.sizeOf(context);
    final railY = barRect.top + TopicProgressLine.handleHeight / 2;
    // 旋屏或窗口缩小时，手势取消之前的旧轨道可能已经离开视口。
    if (!barRect.overlaps(Offset.zero & screen) || railY > screen.height) {
      return const SizedBox.shrink();
    }
    final bottom = math.min(
      screen.height,
      barRect.bottom +
          MediaQuery.viewPaddingOf(context).bottom +
          TopicBottomBarMetrics.floatingMargin,
    );
    final belowRail = bottom - railY;
    final roomAbove = math.max(0.0, railY - MediaQuery.paddingOf(context).top);
    final feather = math.min(100.0, roomAbove * .22);
    final gap = math.min(
      (railY - pointerY + 28).clamp(24.0, 92.0),
      roomAbove * .35,
    );
    final infoWidth = math.min(400.0, tracker.surfaceWidth);
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.reduceMotionOf(context);

    return Positioned(
      left: barRect.left,
      width: barRect.width,
      bottom: screen.height - bottom,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: visibility,
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              Positioned.fill(
                child: RepaintBoundary(
                  child: _ScrubBackdrop(
                    surface: scheme.surface,
                    accent: accent,
                    feather: feather,
                    belowRail: belowRail,
                    fadeLeft: barRect.left > 1,
                    fadeRight: barRect.right < screen.width - 1,
                    atBottom: bottom >= screen.height - 1,
                  ),
                ),
              ),
              // 楼号在轨道上方保持稳定，上移换档时预览让开指尖。
              Padding(
                padding: EdgeInsets.only(top: feather, bottom: belowRail + gap),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: math.max(0, roomAbove - feather - gap),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: SizedBox(
                      width: infoWidth,
                      child: Material(
                        type: MaterialType.transparency,
                        child: _buildReadout(
                          context,
                          theme,
                          accent,
                          reduceMotion,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: railLeft - barRect.left - _railHeight / 2,
                width: tracker.surfaceWidth + _railHeight,
                bottom: belowRail - _railHeight / 2,
                height: _railHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLowest,
                    borderRadius: context.shapes.borderRadius(
                      UiShapes.fullThreshold,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: scheme.shadow.withValues(alpha: .15),
                        blurRadius: 13,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: CustomPaint(
                    painter: _RailPainter(
                      fill: tracker.thumbX,
                      accent: accent,
                      surface: scheme.surfaceContainerLowest,
                      track: Color.alphaBlend(
                        accent.withValues(alpha: .11),
                        scheme.surfaceContainerHigh,
                      ),
                      radius: context.shapes.radius(UiShapes.fullThreshold),
                      rate: tracker.scale == TopicScrubScale.whole
                          ? null
                          : tracker.floorsPerPixel,
                      origin: tracker.rulerOrigin,
                      total: tracker.totalCount,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReadout(
    BuildContext context,
    ThemeData theme,
    Color accent,
    bool reduceMotion,
  ) {
    final scheme = theme.colorScheme;
    final secondary = scheme.onSurfaceVariant;
    final bodyStyle = theme.textTheme.bodySmall!.copyWith(
      color: secondary,
      height: 1.35,
    );
    final lineHeight =
        MediaQuery.textScalerOf(context).scale(bodyStyle.fontSize!) *
        bodyStyle.height!;
    final l10n = context.l10n;
    final hasScales = tracker.scales.length > 1;
    final info = excerpt;
    final username = info?.username;
    final text = info?.excerpt;
    const digits = [FontFeature.tabularFigures()];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 预留两行，停止拖动后淡入该楼摘要，快速划过时不会叠出多段文字。
        SizedBox(
          height: lineHeight * 2,
          child: AnimatedSwitcher(
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 120),
            layoutBuilder: (current, _) =>
                Align(alignment: Alignment.bottomLeft, child: current),
            child: username == null && text == null
                ? const SizedBox.shrink()
                : Text.rich(
                    key: ValueKey(excerptIndex),
                    TextSpan(
                      children: [
                        if (username != null)
                          TextSpan(
                            text: text == null ? username : '$username  ',
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        if (text != null)
                          ...EmojiText.buildEmojiSpans(
                            context,
                            text,
                            bodyStyle,
                            inline: true,
                          ),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: bodyStyle,
                  ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              flex: 2,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: tracker.index.toString(),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w700,
                        fontFeatures: digits,
                      ),
                    ),
                    TextSpan(
                      text: ' / ${tracker.totalCount}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: secondary,
                        fontFeatures: digits,
                      ),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (hasScales) ...[
              const SizedBox(width: 8),
              Flexible(child: _buildScaleLabel(context, accent, reduceMotion)),
            ],
          ],
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                date == null ? '' : TimeUtils.formatSmartDate(date),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: secondary,
                  fontFeatures: digits,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (hasScales)
              Flexible(
                flex: 2,
                child: Text(
                  tracker.scale == TopicScrubScale.single
                      ? l10n.topic_scrubStepHint
                      : l10n.topic_scrubLiftHint,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: secondary,
                  ),
                  textAlign: TextAlign.end,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildScaleLabel(
    BuildContext context,
    Color accent,
    bool reduceMotion,
  ) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final label = switch (tracker.scale) {
      TopicScrubScale.whole => l10n.topic_scrubWhole,
      TopicScrubScale.nearby => l10n.topic_scrubNearby,
      TopicScrubScale.single => l10n.topic_scrubSingle,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          accent.withValues(alpha: .10),
          theme.colorScheme.surface,
        ),
        borderRadius: context.shapes.borderRadius(UiShapes.fullThreshold),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 2,
                children: [
                  for (final level in tracker.scales.reversed)
                    AnimatedContainer(
                      duration: reduceMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 100),
                      width: level == tracker.scale ? 10 : 3,
                      height: 3,
                      decoration: ShapeDecoration(
                        shape: const StadiumBorder(),
                        color: level == tracker.scale
                            ? accent
                            : accent.withValues(alpha: .35),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 上端从文章颜色过渡到近乎实色的读数区，轨道下方重新透出底栏。
class _ScrubBackdrop extends StatelessWidget {
  const _ScrubBackdrop({
    required this.surface,
    required this.accent,
    required this.feather,
    required this.belowRail,
    required this.fadeLeft,
    required this.fadeRight,
    required this.atBottom,
  });

  final Color surface;
  final Color accent;
  final double feather;
  final double belowRail;
  final bool fadeLeft;
  final bool fadeRight;
  final bool atBottom;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        if (height <= 0) return const SizedBox.shrink();
        final rail = (1 - belowRail / height).clamp(0.0, 1.0);
        final top = (feather / height).clamp(0.0, rail);
        final clear = surface.withValues(alpha: 0);
        final field = DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                clear,
                surface.withValues(alpha: .20),
                surface.withValues(alpha: .74),
                surface.withValues(alpha: .98),
                Color.alphaBlend(accent.withValues(alpha: .10), surface),
                surface.withValues(alpha: .83),
                surface.withValues(alpha: atBottom ? .44 : 0),
              ],
              stops: [
                0,
                top * .42,
                top * .77,
                top,
                rail,
                rail + (1 - rail) * .54,
                1,
              ],
            ),
          ),
        );
        if (!fadeLeft && !fadeRight) return field;
        // 悬浮底栏与分栏内缘横向收淡，渐变停在当前帖子栏内。
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) {
            final edge = math.min(.18, 32 / bounds.width);
            return LinearGradient(
              colors: [
                fadeLeft ? clear : surface,
                surface,
                surface,
                fadeRight ? clear : surface,
              ],
              stops: [0, edge, 1 - edge, 1],
            ).createShader(bounds);
          },
          child: field,
        );
      },
    );
  }
}

class _RailPainter extends CustomPainter {
  const _RailPainter({
    required this.fill,
    required this.accent,
    required this.surface,
    required this.track,
    required this.radius,
    required this.rate,
    required this.origin,
    required this.total,
  });

  final double fill;
  final Color accent;
  final Color surface;
  final Color track;
  final Radius radius;
  final double? rate;
  final double origin;
  final int total;

  @override
  void paint(Canvas canvas, Size size) {
    final rail = (Offset.zero & size).deflate(4);
    final center = size.height / 2;
    final width = size.width - size.height;
    final thumb = center + fill;
    final paint = Paint()..color = track;
    canvas.drawRRect(RRect.fromRectAndRadius(rail, radius), paint);
    final filled = Rect.fromLTRB(
      rail.left,
      rail.top,
      thumb + rail.height / 2,
      rail.bottom,
    );
    final fillPaint = Paint()
      ..shader = LinearGradient(
        colors: [Color.lerp(accent, surface, .16)!, accent],
      ).createShader(rail);
    canvas.drawRRect(RRect.fromRectAndRadius(filled, radius), fillPaint);

    final units = rate;
    if (units == null) {
      for (var quarter = 1; quarter <= 3; quarter++) {
        final x = center + width * quarter / 4;
        paint.color = (x < thumb ? surface : accent).withValues(alpha: .48);
        canvas.drawCircle(Offset(x, center), 1.6, paint);
      }
    } else {
      final step = math.max(1, (units * 10).ceil());
      final first = (math.max(1.0, origin) / step).ceil() * step;
      final last = math.min(total.toDouble(), origin + width * units);
      paint.strokeWidth = 1.3;
      paint.strokeCap = StrokeCap.round;
      for (var floor = first; floor <= last; floor += step) {
        final x = center + (floor - origin) / units;
        final half = (floor ~/ step) % 5 == 0 ? 4.0 : 2.0;
        paint.color = (x < thumb ? surface : accent).withValues(alpha: .68);
        canvas.drawLine(
          Offset(x, center - half),
          Offset(x, center + half),
          paint,
        );
      }
    }
    canvas.drawCircle(
      Offset(thumb, center),
      rail.height / 2 - 2,
      paint..color = surface,
    );
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.fill != fill ||
      old.accent != accent ||
      old.surface != surface ||
      old.track != track ||
      old.radius != radius ||
      old.rate != rate ||
      old.origin != origin ||
      old.total != total;
}
