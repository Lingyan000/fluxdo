import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

import '../../widgets/content/discourse_image.dart';
import 'mini_app.dart';
import 'mini_app_artwork_palette.dart';

/// 在公共 SegmentedCardItem 的 Material 上绘制底色，保留水波纹和超椭圆裁切。
class MiniAppCardSurface extends StatefulWidget {
  const MiniAppCardSurface({
    super.key,
    required this.app,
    required this.child,
    this.prominent = false,
    this.watermark = true,
  });
  final MiniApp app;
  final Widget child;
  final bool prominent, watermark;

  @override
  State<MiniAppCardSurface> createState() => _MiniAppCardSurfaceState();
}

class _MiniAppCardSurfaceState extends State<MiniAppCardSurface> {
  (String, Brightness)? _key;
  Future<Color?>? _palette;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolvePalette();
  }

  @override
  void didUpdateWidget(MiniAppCardSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolvePalette();
  }

  void _resolvePalette() {
    final key = (widget.app.iconUrl, Theme.of(context).brightness);
    if (key == _key) return;
    _key = key;
    _palette = MiniAppArtworkPalette.resolve(key.$1, key.$2);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    final fallback = [
      colors.primary,
      colors.secondary,
      colors.tertiary,
    ][widget.app.id.codeUnits.fold<int>(0, (sum, unit) => sum + unit) % 3];
    return FutureBuilder<Color?>(
      key: ValueKey(_key),
      future: _palette,
      builder: (context, snapshot) {
        final seed = (snapshot.data ?? fallback).harmonizeWith(colors.primary);
        final hsl = HSLColor.fromColor(seed);
        final accent = hsl
            .withSaturation(hsl.saturation.clamp(.18, .62))
            .withLightness(dark ? .64 : .42)
            .toColor();
        final surface = colors.surfaceContainerLow;
        final strength = widget.prominent ? .32 : .22;
        return Stack(
          children: [
            Positioned.fill(
              child: TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: accent),
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                builder: (context, color, _) => Ink(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color.alphaBlend(
                          color!.withValues(
                            alpha: dark ? strength : strength * .65,
                          ),
                          surface,
                        ),
                        Color.alphaBlend(
                          color.withValues(alpha: dark ? .07 : .035),
                          surface,
                        ),
                        surface,
                      ],
                      stops: const [0, .58, 1],
                    ),
                  ),
                ),
              ),
            ),
            if (widget.watermark && widget.app.iconUrl.isNotEmpty)
              PositionedDirectional(
                top: -18,
                end: -26,
                width: 144,
                height: 144,
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: ShaderMask(
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (rect) => LinearGradient(
                        begin: Alignment.topRight,
                        end: Alignment.bottomLeft,
                        colors: [
                          Colors.white.withValues(alpha: dark ? .16 : .10),
                          Colors.transparent,
                        ],
                        stops: const [.05, .85],
                      ).createShader(rect),
                      child: DiscourseImage(
                        url: widget.app.iconUrl,
                        width: 144,
                        height: 144,
                        fit: BoxFit.cover,
                        placeholderBuilder: (_) => const SizedBox.shrink(),
                        errorBuilder: (_) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
            widget.child,
          ],
        );
      },
    );
  }
}
