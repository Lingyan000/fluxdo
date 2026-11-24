import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/s.dart';
import '../../../widgets/common/paper_texture.dart';
import '../reader_preferences.dart';

/// 极简阅读页眉：常驻正文上方，展示当前标题与阅读进度百分比。
class ReaderRunningHeader extends StatelessWidget {
  const ReaderRunningHeader({
    super.key,
    required this.title,
    required this.progress,
    required this.palette,
    required this.visible,
  });

  final String title;
  final double progress;
  final ReaderPalette palette;
  final bool visible;

  static const double height = 34;

  static const _effectsDuration = Duration(milliseconds: 220);
  static final _effectsCurve = M3eMotion.defaultEffects.curveFor(
    _effectsDuration,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percent = (progress.clamp(0.0, 1.0) * 100).round();
    final reduced = _isReducedMotion(context);

    return IgnorePointer(
      child: AnimatedOpacity(
        duration: reduced ? Duration.zero : _effectsDuration,
        curve: _effectsCurve,
        opacity: visible ? 1.0 : 0.0,
        child: Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: palette.mutedInk.withValues(alpha: 0.78),
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.1,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '$percent%',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: palette.mutedInk.withValues(alpha: 0.78),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 轻触呼出的顶部浮层栏：使用平台自适应 [BackButton]、[TopBarIconScope] 与 [PageBackdrop]。
class ReaderTopBar extends StatelessWidget {
  const ReaderTopBar({
    super.key,
    required this.visible,
    required this.title,
    required this.subtitle,
    required this.palette,
    required this.onBack,
  });

  final bool visible;
  final String title;
  final String subtitle;
  final ReaderPalette palette;
  final VoidCallback onBack;

  static const _spatialDuration = Duration(milliseconds: 300);
  static const _effectsDuration = Duration(milliseconds: 200);
  static final _spatialCurve = M3eMotion.defaultSpatial.curveFor(
    _spatialDuration,
  );
  static final _effectsCurve = M3eMotion.defaultEffects.curveFor(
    _effectsDuration,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topPadding = MediaQuery.paddingOf(context).top;
    final reduced = _isReducedMotion(context);

    final barContent = TopBarIconScope(
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: palette.outline.withValues(alpha: 0.45),
              width: 0.5,
            ),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(4, topPadding + 4, 16, 8),
          child: Row(
            children: [
              BackButton(
                key: const ValueKey('reader_top_back'),
                onPressed: onBack,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: palette.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: palette.mutedInk,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final Widget surface;
    if (palette.isCustomLight) {
      surface = palette.usePaperTexture
          ? Stack(
              children: [
                Positioned.fill(
                  child: PaperBackground(color: palette.background),
                ),
                barContent,
              ],
            )
          : ColoredBox(color: palette.background, child: barContent);
    } else {
      surface = PageBackdrop(child: barContent);
    }

    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        duration: reduced ? Duration.zero : _spatialDuration,
        curve: _spatialCurve,
        offset: visible ? Offset.zero : const Offset(0, -1),
        child: AnimatedOpacity(
          duration: reduced ? Duration.zero : _effectsDuration,
          curve: _effectsCurve,
          opacity: visible ? 1.0 : 0.0,
          child: surface,
        ),
      ),
    );
  }
}

/// 轻触呼出的底部玻璃胶囊（有目录时为「目录 | 排版」，无目录时仅「排版」）。
class ReaderBottomCapsule extends StatelessWidget {
  const ReaderBottomCapsule({
    super.key,
    required this.visible,
    required this.showToc,
    required this.tocActive,
    required this.onTapToc,
    required this.onTapTypesetting,
  });

  final bool visible;
  final bool showToc;
  final bool tocActive;
  final VoidCallback onTapToc;
  final VoidCallback onTapTypesetting;

  static const _spatialDuration = Duration(milliseconds: 300);
  static const _effectsDuration = Duration(milliseconds: 200);
  static final _spatialCurve = M3eMotion.defaultSpatial.curveFor(
    _spatialDuration,
  );
  static final _effectsCurve = M3eMotion.defaultEffects.curveFor(
    _effectsDuration,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    final reduced = _isReducedMotion(context);

    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        duration: reduced ? Duration.zero : _spatialDuration,
        curve: _spatialCurve,
        offset: visible ? Offset.zero : const Offset(0, 1.4),
        child: AnimatedOpacity(
          duration: reduced ? Duration.zero : _effectsDuration,
          curve: _effectsCurve,
          opacity: visible ? 1.0 : 0.0,
          child: Padding(
            padding: EdgeInsets.only(bottom: bottomPadding + 16),
            child: Center(
              heightFactor: 1,
              child: GlassSurfaceFrame(
                radius: 26,
                recipe: GlassRecipe.navigation,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showToc) ...[
                        _CapsuleAction(
                          key: const ValueKey('reader_capsule_toc'),
                          icon: Symbols.toc_rounded,
                          label: l10n.reader_toc,
                          active: tocActive,
                          onTap: onTapToc,
                        ),
                        Container(
                          width: 1,
                          height: 20,
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.55,
                          ),
                        ),
                      ],
                      _CapsuleAction(
                        key: const ValueKey('reader_capsule_typesetting'),
                        icon: Symbols.text_fields_rounded,
                        label: l10n.reader_typesetting,
                        active: false,
                        onTap: onTapTypesetting,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CapsuleAction extends StatelessWidget {
  const _CapsuleAction({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor = active
        ? context.emphasis.selected
        : theme.colorScheme.onSurface;
    final textColor = active
        ? context.emphasis.selected
        : theme.colorScheme.onSurface;

    return M3eElasticPress(
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: context.shapes.borderRadius(999),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 19, color: iconColor),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: textColor,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

bool _isReducedMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context) ||
    MediaQuery.reduceMotionOf(context);
