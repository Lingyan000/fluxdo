import 'dart:math' as math;

import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/s.dart';
import '../../../utils/time_utils.dart';
import '../../../widgets/common/emoji_text.dart';
import '../controllers/topic_position_info.dart';
import 'topic_bottom_bar.dart';
import 'topic_progress_track.dart';
import 'topic_scrub_mapping.dart';

/// 拖动时，正文在楼层预览和轨道周围逐渐淡入主题表面色。
class TopicScrubIndicator extends StatelessWidget {
  const TopicScrubIndicator({
    super.key,
    required this.visibility,
    required this.thumbTravel,
    required this.barRect,
    required this.insets,
    required this.floating,
    required this.progressAt,
    required this.markerIndex,
    required this.tracker,
    required this.pointer,
    required this.date,
    required this.excerptIndex,
    required this.excerpt,
  });

  final Animation<double> visibility;
  final Animation<double> thumbTravel;
  final Rect barRect;
  final EdgeInsets insets;
  final bool floating;
  final double Function(double expansion) progressAt;
  final int? markerIndex;
  final TopicScrubTracker tracker;
  final Offset pointer;
  final DateTime? date;
  final int excerptIndex;
  final TopicPositionInfo? excerpt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = context.emphasis.selected;
    final screen = MediaQuery.sizeOf(context);
    final style = floating
        ? TopicProgressSurface.floating
        : TopicProgressSurface.docked;
    final restY =
        barRect.top + TopicProgressLine.centerFromBarTop(floating, true);
    final railY = floating ? barRect.top - style.openThickness / 2 - 5 : restY;
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
    final sideFeather = floating ? math.min(48.0, barRect.width * .10) : 0.0;
    final available = floating
        ? math.max(0.0, barRect.width - 2 * sideFeather - 24)
        : barRect.width;
    final infoWidth = math.min(
      400.0,
      math.min(available, tracker.surfaceWidth),
    );
    // 宽轨两端的手指碰不到中间的读数，只有接近读数时才需要把它抬高。
    final outside = (pointer.dx - barRect.center.dx).abs() - infoWidth / 2;
    final proximity = floating
        ? 1 - (outside / sideFeather).clamp(0.0, 1.0)
        : 1.0;
    final lift = (railY - pointer.dy + 4).clamp(0.0, 68.0);
    final gap = math.min(24 + lift * proximity, roomAbove * .35);
    final readoutRoom = math.max(0.0, roomAbove - gap);
    final feather = math.min(232.0, readoutRoom * (floating ? .28 : .36));
    // 悬浮底栏的渐变覆盖轨道与读数之间的整段距离，收在操作行上沿。
    final fieldBottom = floating ? math.max(0.0, bottom - restY) : 0.0;
    final paintHeight = style.openThickness + 6;
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.reduceMotionOf(context);

    return Positioned(
      left: barRect.left,
      width: barRect.width,
      bottom: screen.height - bottom,
      child: IgnorePointer(
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            Positioned(
              top: 0,
              bottom: fieldBottom,
              left: 0,
              right: 0,
              child: FadeTransition(
                opacity: visibility,
                child: RepaintBoundary(
                  child: _ScrubBackdrop(
                    surface: scheme.surface,
                    accent: accent,
                    feather: feather,
                    belowRail: belowRail - fieldBottom,
                    floating: floating,
                    leftFeather: floating
                        ? insets.left * 1.5
                        : (barRect.left > 1 ? 32 : 0),
                    rightFeather: floating
                        ? insets.right * 1.5
                        : (barRect.right < screen.width - 1 ? 32 : 0),
                    atBottom: bottom >= screen.height - 1,
                  ),
                ),
              ),
            ),
            // 上移换档时，楼号和摘要给指尖留出空间。
            Padding(
              padding: EdgeInsets.only(top: feather, bottom: belowRail + gap),
              child: FadeTransition(
                opacity: visibility,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: readoutRoom - feather),
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
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: bottom - restY - paintHeight / 2,
              height: paintHeight,
              child: AnimatedBuilder(
                animation: visibility,
                builder: (context, _) {
                  final t = TopicProgressTrack.curve.transform(
                    visibility.value,
                  );
                  final marker = markerIndex;
                  return Transform.translate(
                    offset: Offset(0, (railY - restY) * t),
                    child: TopicProgressTrack(
                      surface: style,
                      thumbTravel: reduceMotion
                          ? kAlwaysDismissedAnimation
                          : thumbTravel,
                      expansion: t,
                      progress: progressAt(t),
                      startInset: insets.left,
                      endInset: insets.right,
                      lastRead: marker == null
                          ? null
                          : TopicProgressTrack.fraction(
                              marker,
                              tracker.totalCount,
                            ),
                      ruler: tracker.scale == TopicScrubScale.whole
                          ? null
                          : (
                              rate: tracker.floorsPerPixel,
                              origin: tracker.rulerOrigin,
                              total: tracker.totalCount,
                            ),
                    ),
                  );
                },
              ),
            ),
          ],
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
    required this.floating,
    required this.leftFeather,
    required this.rightFeather,
    required this.atBottom,
  });

  final Color surface;
  final Color accent;
  final double feather;
  final double belowRail;
  final bool floating;
  final double leftFeather, rightFeather;
  final bool atBottom;

  // 对三次平滑插值等距采样，使图片和读数区两端的透明度变化都逐渐放缓。
  static final _fade = List.generate(11, (i) {
    final x = i / 10;
    return (stop: x, opacity: .98 * x * x * (3 - 2 * x));
  }, growable: false);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        if (height <= 0) return const SizedBox.shrink();
        final rail = (1 - belowRail / height).clamp(0.0, 1.0);
        final top = (feather / height).clamp(0.0, rail);
        return TopicProgressGradient(
          axis: Axis.horizontal,
          startFeather: leftFeather,
          endFeather: rightFeather,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              for (final sample in _fade)
                surface.withValues(alpha: sample.opacity),
              floating
                  ? TopicProgressGradient.tintOf(context)
                  : Color.alphaBlend(accent.withValues(alpha: .10), surface),
              surface.withValues(alpha: floating ? .46 : .83),
              surface.withValues(alpha: !floating && atBottom ? .44 : 0),
            ],
            stops: [
              for (final sample in _fade) top * sample.stop,
              rail,
              rail + (1 - rail) * .54,
              1,
            ],
          ),
        );
      },
    );
  }
}
