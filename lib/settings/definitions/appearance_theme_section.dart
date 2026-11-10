part of 'appearance_defs.dart';

// ══════════════════════════════════════════════════════════════════
// 主题区块：实时预览、主题画廊、跟随当前主题的子选项
// ══════════════════════════════════════════════════════════════════

/// 画廊卡片的缩略图配色（与 AppearanceWarmup 预热同源）。
ColorScheme _galleryScheme(
  ThemeSpec spec,
  ThemeState state,
  Brightness brightness,
) => ThemePreviewCache.schemeOf(
  spec: spec,
  brightness: brightness,
  accentId: state.accentFor(spec),
  seed: state.effectiveSeedColor,
  variant: state.schemeVariant,
  black: state.blackEnabled,
);

/// 主题显示名：生成式主题走 l10n，其余取主题自带的本地化名。
String _themeName(BuildContext context, ThemeSpec spec) {
  final l10n = context.l10n;
  return switch (spec.id) {
    ThemeRegistry.materialId => l10n.appearance_themeMaterial,
    ThemeRegistry.minimalId => l10n.appearance_themeMinimal,
    _ => localizedName(spec.name, Localizations.localeOf(context), spec.id),
  };
}

String _groupName(BuildContext context, ThemeGroup group) {
  final l10n = context.l10n;
  return switch (group) {
    ThemeGroup.generated => l10n.appearance_themeGroupGenerated,
    ThemeGroup.classic => l10n.appearance_themeGroupClassic,
    ThemeGroup.reading => l10n.appearance_themeGroupReading,
    ThemeGroup.terminal => l10n.appearance_themeGroupTerminal,
    ThemeGroup.custom => l10n.appearance_themeGroupCustom,
    ThemeGroup.festival => '',
  };
}

/// 当前主题的实时预览：一张缩略首页，主题切换时随 ThemeData 一起过渡。
class _ThemeLivePreview extends StatelessWidget {
  const _ThemeLivePreview();

  static const double _phoneWidth = 150;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shapes = context.shapes;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20),
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: scheme.surfaceContainer,
        shape: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(28),
        ),
      ),
      child: SizedBox(
        width: _phoneWidth,
        child: AspectRatio(
          aspectRatio: 9 / 17,
          child: _MiniScreen(
            scheme: scheme,
            shapes: shapes,
            cornerRadius: 22,
          ),
        ),
      ),
    );
  }
}

/// 缩略首页：带圆角外框的 [_MiniHomePainter]。
class _MiniScreen extends StatelessWidget {
  const _MiniScreen({
    required this.scheme,
    required this.shapes,
    required this.cornerRadius,
  });

  final ColorScheme scheme;

  /// 缩略图内元素的圆角风格（外框是设备轮廓，不随风格变化）。
  final UiShapes shapes;
  final double cornerRadius;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(cornerRadius);
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: ShapeDecoration(
        shape: RoundedSuperellipseBorder(
          borderRadius: radius,
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: ClipRSuperellipse(
        borderRadius: radius,
        child: CustomPaint(
          painter: _MiniHomePainter(scheme, shapes),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// 首页草图：顶栏、分类标签、话题卡、悬浮按钮、底栏，全部用 [scheme]
/// 的 role 上色，几何按画布尺寸等比缩放，圆角按 [shapes] 风格换算。
class _MiniHomePainter extends CustomPainter {
  _MiniHomePainter(this.scheme, this.shapes);

  final ColorScheme scheme;
  final UiShapes shapes;

  /// 缩略图里的普通圆角：按设计值 16 处的缩放比例等比换算。
  double _corner(double r) => r * shapes.resolve(16) / 16;

  /// 缩略图里的胶囊：封顶风格下收成小圆角，否则保持胶囊。
  double _pill(double r) => shapes.max == null ? r : r * 0.15;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final paint = Paint();
    void rrect(Rect r, double radius, Color color) {
      paint.color = color;
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, Radius.circular(radius)),
        paint,
      );
    }

    paint.color = scheme.surface;
    canvas.drawRect(Offset.zero & size, paint);

    final pad = w * 0.07;
    final line = h * 0.016;

    // 顶栏：标题 + 搜索按钮
    rrect(
      Rect.fromLTWH(pad, h * 0.06, w * 0.34, line * 1.3),
      _pill(line),
      scheme.onSurface,
    );
    paint.color = scheme.surfaceContainerHigh;
    canvas.drawCircle(Offset(w - pad - h * 0.018, h * 0.067), h * 0.022, paint);

    // 分类标签：首个选中
    var x = pad;
    for (var i = 0; i < 3; i++) {
      final tw = w * (i == 0 ? 0.2 : 0.15);
      rrect(
        Rect.fromLTWH(x, h * 0.115, tw, h * 0.036),
        _pill(h * 0.018),
        i == 0 ? scheme.secondaryContainer : scheme.surfaceContainerHigh,
      );
      x += tw + w * 0.025;
    }

    // 话题卡
    final navTop = h * 0.89;
    final cardH = h * 0.15;
    final gap = h * 0.018;
    var y = h * 0.18;
    var index = 0;
    while (y + cardH <= navTop - gap) {
      final card = Rect.fromLTWH(pad, y, w - pad * 2, cardH);
      rrect(card, _corner(w * 0.05), scheme.surfaceContainerLow);
      final cx = card.left + w * 0.05;
      paint.color = scheme.primaryContainer;
      canvas.drawCircle(
        Offset(cx + h * 0.02, card.top + cardH * 0.3),
        h * 0.02,
        paint,
      );
      final textLeft = cx + h * 0.05;
      rrect(
        Rect.fromLTWH(textLeft, card.top + cardH * 0.22, card.width * 0.5, line),
        line / 2,
        scheme.onSurface,
      );
      rrect(
        Rect.fromLTWH(cx, card.top + cardH * 0.55, card.width * 0.78, line * 0.8),
        line / 2,
        scheme.onSurfaceVariant.withValues(alpha: 0.45),
      );
      rrect(
        Rect.fromLTWH(cx, card.top + cardH * 0.74, card.width * 0.46, line * 0.8),
        line / 2,
        scheme.onSurfaceVariant.withValues(alpha: 0.45),
      );
      // 首张卡带未读标记
      if (index == 0) {
        paint.color = scheme.primary;
        canvas.drawCircle(
          Offset(card.right - w * 0.06, card.top + cardH * 0.3),
          h * 0.011,
          paint,
        );
      }
      y += cardH + gap;
      index++;
    }

    // 悬浮按钮
    final fab = w * 0.17;
    rrect(
      Rect.fromLTWH(w - pad - fab, navTop - fab - gap, fab, fab),
      _corner(fab * 0.3),
      scheme.primaryContainer,
    );
    final plus = fab * 0.32;
    final fc = Offset(w - pad - fab / 2, navTop - gap - fab / 2);
    rrect(
      Rect.fromCenter(center: fc, width: plus, height: plus * 0.2),
      plus * 0.1,
      scheme.onPrimaryContainer,
    );
    rrect(
      Rect.fromCenter(center: fc, width: plus * 0.2, height: plus),
      plus * 0.1,
      scheme.onPrimaryContainer,
    );

    // 底栏：首项选中
    paint.color = scheme.surfaceContainer;
    canvas.drawRect(Rect.fromLTWH(0, navTop, w, h - navTop), paint);
    const items = 4;
    final cell = w / items;
    final cy = navTop + (h - navTop) * 0.45;
    for (var i = 0; i < items; i++) {
      final center = Offset(cell * (i + 0.5), cy);
      if (i == 0) {
        rrect(
          Rect.fromCenter(center: center, width: cell * 0.62, height: h * 0.04),
          _pill(h * 0.02),
          scheme.secondaryContainer,
        );
      }
      rrect(
        Rect.fromCenter(center: center, width: h * 0.022, height: h * 0.022),
        h * 0.006,
        i == 0
            ? scheme.onSecondaryContainer
            : scheme.onSurfaceVariant.withValues(alpha: 0.7),
      );
    }
  }

  @override
  bool shouldRepaint(_MiniHomePainter oldDelegate) =>
      oldDelegate.scheme != scheme || oldDelegate.shapes != shapes;
}

/// 主题画廊：按分组列出全部主题，同族主题合并成一张卡。
class _ThemeGallery extends ConsumerWidget {
  const _ThemeGallery();

  static const _groups = [
    ThemeGroup.generated,
    ThemeGroup.classic,
    ThemeGroup.reading,
    ThemeGroup.terminal,
    ThemeGroup.custom,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeState = ref.watch(themeProvider);
    final current = themeState.themeSpec;
    final brightness = Theme.of(context).brightness;
    final textTheme = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    // 每个族取一张代表卡：当前主题所在族用当前主题，其余取族内第一个
    final cardsByGroup = <ThemeGroup, List<ThemeSpec>>{};
    final seenFamilies = <String>{};
    for (final spec in ThemeRegistry.all) {
      if (!seenFamilies.add(spec.familyId)) continue;
      final shown = spec.familyId == current.familyId ? current : spec;
      cardsByGroup.putIfAbsent(spec.group, () => []).add(shown);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final columns = math.max(3, (maxWidth / 112).floor());
        const spacing = 12.0;
        final itemWidth = (maxWidth - (columns - 1) * spacing) / columns;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final group in _groups)
              // 「我的主题」即使为空也显示：承载新建与导入入口
              if (cardsByGroup[group] != null ||
                  group == ThemeGroup.custom) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _groupName(context, group),
                          style: textTheme.titleSmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (group == ThemeGroup.custom)
                        TextButton.icon(
                          onPressed: () =>
                              _importThemeFromClipboard(context, ref),
                          icon: const Icon(Symbols.content_paste_rounded),
                          label: Text(
                            context.l10n.appearance_customThemeImport,
                          ),
                        ),
                    ],
                  ),
                ),
                Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    for (final spec in cardsByGroup[group] ?? const [])
                      _ThemeCard(
                        width: itemWidth,
                        name: _themeName(context, spec),
                        scheme: _galleryScheme(spec, themeState, brightness),
                        shapes: (themeState.shapeOverride ?? spec.shape).shapes,
                        selected: spec.familyId == current.familyId,
                        onTap: () {
                          if (spec.familyId == current.familyId) return;
                          ref.read(themeProvider.notifier).setThemeId(spec.id);
                        },
                        onMore: () => _showThemeActions(context, ref, spec),
                      ),
                    if (group == ThemeGroup.custom)
                      _NewThemeCard(width: itemWidth),
                  ],
                ),
                const SizedBox(height: 8),
              ],
          ],
        );
      },
    );
  }
}

class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.width,
    required this.name,
    required this.scheme,
    required this.shapes,
    required this.selected,
    required this.onTap,
    this.onMore,
  });

  final double width;
  final String name;
  final ColorScheme scheme;
  final UiShapes shapes;
  final bool selected;
  final VoidCallback onTap;

  /// 长按 / 右键：主题操作菜单
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return SizedBox(
      width: width,
      child: Semantics(
        button: true,
        selected: selected,
        label: name,
        child: GestureDetector(
          onTap: onTap,
          onLongPress: onMore,
          onSecondaryTap: onMore,
          behavior: HitTestBehavior.opaque,
          child: Column(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.all(3),
                decoration: ShapeDecoration(
                  shape: RoundedSuperellipseBorder(
                    borderRadius: context.shapes.borderRadius(21),
                    side: BorderSide(
                      color: selected ? cs.primary : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                ),
                child: Stack(
                  children: [
                    AspectRatio(
                      aspectRatio: 9 / 14,
                      child: _MiniScreen(
                        scheme: scheme,
                        shapes: shapes,
                        cornerRadius: 18,
                      ),
                    ),
                    if (selected)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: cs.primary,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Symbols.check_rounded,
                            size: 14,
                            color: cs.onPrimary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelMedium?.copyWith(
                  color: selected ? cs.primary : cs.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w600 : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 跟随当前主题的子选项：生成式主题显示原有的色板与配色风格，
/// 固定配色主题显示族内变体与主题自带强调色。
class _ThemeOptionsSection extends ConsumerWidget {
  const _ThemeOptionsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = ref.watch(themeProvider.select((s) => s.themeSpec));
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topLeft,
        children: [...previous, ?current],
      ),
      child: spec.isGenerated
          ? const _ThemeColorSection(key: ValueKey('generated'))
          : _FixedThemeOptions(key: ValueKey(spec.familyId)),
    );
  }
}

class _FixedThemeOptions extends ConsumerWidget {
  const _FixedThemeOptions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeState = ref.watch(themeProvider);
    final spec = themeState.themeSpec;
    final family = ThemeRegistry.familyOf(spec);
    final selection = themeState.accentFor(spec);
    final brightness = Theme.of(context).brightness;
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context);
    final notifier = ref.read(themeProvider.notifier);
    final customAccent = (selection?.startsWith('#') ?? false)
        ? ThemeSpecColor.tryParse(selection)
        : null;
    final selectedId = customAccent != null
        ? null
        : spec.accentOf(selection).id;

    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        text,
        style: textTheme.titleSmall?.copyWith(color: cs.onSurfaceVariant),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (family.length > 1) ...[
          label(context.l10n.appearance_themeVariant),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final variant in family)
                ChoiceChip(
                  label: Text(
                    localizedName(variant.variantName, locale, variant.id),
                  ),
                  selected: variant.id == spec.id,
                  onSelected: (_) => notifier.setThemeId(variant.id),
                ),
            ],
          ),
          const SizedBox(height: 24),
        ],
        label(context.l10n.appearance_themeAccent),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final accent in spec.accents)
              _AccentDot(
                color: accent.of(brightness),
                tooltip: localizedName(accent.name, locale, accent.id),
                selected: accent.id == selectedId,
                onTap: () => notifier.setThemeAccent(spec.familyId, accent.id),
              ),
            if (customAccent != null)
              _AccentDot(
                color: customAccent,
                tooltip: context.l10n.appearance_themeCustomAccent,
                selected: true,
                onTap: () {},
              ),
            if (spec.allowCustomAccent)
              Tooltip(
                message: context.l10n.appearance_themeCustomAccent,
                child: IconButton.filledTonal(
                  onPressed: () async {
                    final color = await _showSeedColorPicker(context, ref);
                    if (color == null) return;
                    await notifier.setThemeAccent(
                      spec.familyId,
                      ThemeSpecColor.format(color),
                    );
                  },
                  icon: Icon(Symbols.add_rounded, color: cs.primary),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _AccentDot extends StatelessWidget {
  const _AccentDot({
    required this.color,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final onColor = ColorContrast.onFilled(
      color,
      bg: const Color(0xFFFFFFFF),
      fg: const Color(0xFF000000),
    );
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        selected: selected,
        label: tooltip,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 44,
            height: 44,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? cs.onSurface : Colors.transparent,
                width: 2,
              ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: selected
                  ? Icon(Symbols.check_rounded, size: 20, color: onColor)
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// 圆角风格选择：跟随主题 + 三档预设，每档一张小样。
class _ShapeSelector extends ConsumerWidget {
  const _ShapeSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeState = ref.watch(themeProvider);
    final override = themeState.shapeOverride;
    final themePreset = themeState.themeSpec.shape;
    final l10n = context.l10n;
    String presetName(ShapePreset p) => switch (p) {
      ShapePreset.standard => l10n.appearance_shapeStandard,
      ShapePreset.compact => l10n.appearance_shapeCompact,
      ShapePreset.sharp => l10n.appearance_shapeSharp,
    };
    final choices = <(ShapePreset?, String, ShapePreset)>[
      (null, l10n.appearance_shapeFollow, themePreset),
      for (final p in ShapePreset.values) (p, presetName(p), p),
    ];
    return Row(
      children: [
        for (var i = 0; i < choices.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(
            child: _ShapeChoiceCard(
              label: choices[i].$2,
              caption: choices[i].$1 == null ? presetName(themePreset) : null,
              shapes: choices[i].$3.shapes,
              selected: choices[i].$1 == override,
              onTap: () => ref
                  .read(themeProvider.notifier)
                  .setShapeOverride(choices[i].$1),
            ),
          ),
        ],
      ],
    );
  }
}

class _ShapeChoiceCard extends StatelessWidget {
  const _ShapeChoiceCard({
    required this.label,
    required this.caption,
    required this.shapes,
    required this.selected,
    required this.onTap,
  });

  final String label;

  /// 「跟随主题」下显示主题推荐的那一档
  final String? caption;
  final UiShapes shapes;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
          decoration: ShapeDecoration(
            color: selected
                ? cs.secondaryContainer
                : cs.surfaceContainerHigh,
            shape: RoundedSuperellipseBorder(
              borderRadius: context.shapes.borderRadius(16),
              side: BorderSide(
                color: selected ? cs.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Column(
            children: [
              // 小样：一张卡片 + 一个胶囊按钮
              Container(
                height: 34,
                padding: const EdgeInsets.all(6),
                alignment: Alignment.bottomRight,
                decoration: ShapeDecoration(
                  color: cs.surface,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: shapes.borderRadius(12),
                  ),
                ),
                child: Container(
                  width: 22,
                  height: 10,
                  decoration: ShapeDecoration(
                    color: cs.primary,
                    shape: RoundedSuperellipseBorder(
                      borderRadius: shapes.borderRadius(9999),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelMedium?.copyWith(
                  color: selected ? cs.onSecondaryContainer : cs.onSurface,
                ),
              ),
              if (caption != null)
                Text(
                  caption!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 节日主题生效时的横幅：节日表情 + 生效时段 +「本次关闭」。
class _FestivalBanner extends ConsumerWidget {
  const _FestivalBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final occurrence = ref.watch(themeProvider.select((s) => s.activeFestival));
    if (occurrence == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final cs = Theme.of(context).colorScheme;
    final festival = occurrence.festival;
    final name = localizedName(
      festival.name,
      Localizations.localeOf(context),
      festival.id,
    );
    final until = MaterialLocalizations.of(
      context,
    ).formatShortMonthDay(occurrence.end);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        decoration: ShapeDecoration(
          color: cs.primaryContainer,
          shape: RoundedSuperellipseBorder(
            borderRadius: context.shapes.borderRadius(20),
          ),
        ),
        child: Row(
          children: [
            EmojiText(
              ':${festival.emoji}:',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.appearance_festivalActive(name, until),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onPrimaryContainer,
                ),
              ),
            ),
            TextButton(
              onPressed: () =>
                  ref.read(themeProvider.notifier).skipCurrentFestival(),
              child: Text(l10n.appearance_festivalSkip),
            ),
          ],
        ),
      ),
    );
  }
}
