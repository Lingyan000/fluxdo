part of 'appearance_defs.dart';

/// 主页面保留常用选择与预览，完整列表及管理操作进入对应设置页。
enum AppearanceSection {
  themes({'themeGallery'}),
  colors({'themeOptions'}),
  fonts({'fontBody', 'fontMono', 'fontSource'}),
  background({
    'customBackground',
    'm3eStyle',
    'glassEnabled',
    'glassEffectLevel',
    'dialogBlur',
  }),
  interface({'appIcon', 'emojiStyle', 'displayMode', 'topicCardStyle'}),
  festival({
    'festivalEnabled',
    'festivalGreeting',
    'festivalDecor',
    'festivalDebugPreview',
  });

  const AppearanceSection(this.settingIds);
  final Set<String> settingIds;

  String title(AppLocalizations l10n) => switch (this) {
    themes => l10n.appearance_themeLibrary,
    colors => l10n.appearance_colorSettings,
    fonts => l10n.appearance_font,
    background => l10n.appearance_backgroundEffects,
    interface => l10n.appearance_interface,
    festival => l10n.appearance_festival,
  };
}

AppearanceSection? appearanceSectionForSetting(String? id) {
  for (final section in AppearanceSection.values) {
    if (section.settingIds.contains(id)) return section;
  }
  return null;
}

/// 搜索和旧入口使用原有设置 id，进入收纳后的页面仍能准确定位。
class AppearanceSectionPage extends StatelessWidget {
  const AppearanceSectionPage({
    super.key,
    required this.section,
    this.highlightId,
  });

  final AppearanceSection section;
  final String? highlightId;

  @override
  Widget build(BuildContext context) => SettingsGroupPage(
    title: section.title(context.l10n),
    groupsBuilder: (context) => buildAppearanceSectionGroups(context, section),
    highlightId: highlightId,
    maxContentWidth: section == AppearanceSection.themes ? 960 : 720,
  );
}

void _openAppearanceSection(BuildContext context, AppearanceSection section) {
  Navigator.of(context).push(
    InteractionPageRoute(
      builder: (_) => AppearanceSectionPage(section: section),
    ),
  );
}

List<SettingsGroup> buildAppearanceSectionGroups(
  BuildContext context,
  AppearanceSection section,
) {
  final groups = buildAppearanceSearchGroups(context);
  return [
    if ({
      AppearanceSection.fonts,
      AppearanceSection.background,
      AppearanceSection.colors,
    }.contains(section))
      SettingsGroup(
        title: section == AppearanceSection.fonts
            ? context.l10n.appearance_fontPreview
            : context.l10n.appearance_theme,
        icon: Symbols.preview_rounded,
        wrapInCard: false,
        items: [
          CustomModel(
            id: 'appearancePreview',
            title: context.l10n.appearance_theme,
            builder: (context, ref) => const _ThemeLivePreview(),
          ),
        ],
      ),
    for (final group in groups)
      if (group.items.any((item) => section.settingIds.contains(item.id)))
        SettingsGroup(
          title: group.title,
          icon: group.icon,
          wrapInCard: group.wrapInCard,
          items: [
            for (final item in group.items)
              if (section.settingIds.contains(item.id)) item,
          ],
        ),
  ];
}

List<SettingsGroup> buildAppearanceGroups(BuildContext context) {
  final l10n = context.l10n;
  final items = {
    for (final group in buildAppearanceSearchGroups(context))
      for (final item in group.items) item.id: item,
  };
  ActionModel entry(
    AppearanceSection section,
    IconData icon, {
    String? Function(WidgetRef)? subtitle,
  }) => ActionModel(
    id: 'appearance_${section.name}',
    title: section.title(l10n),
    icon: icon,
    getDynamicSubtitle: subtitle,
    onTap: (context, ref) => _openAppearanceSection(context, section),
  );

  return [
    SettingsGroup(
      title: l10n.appearance_themeMode,
      icon: Symbols.brightness_6_rounded,
      wrapInCard: false,
      items: [items['themePreview']!, items['themeMode']!],
    ),
    SettingsGroup(
      title: l10n.appearance_theme,
      icon: Symbols.color_lens_rounded,
      wrapInCard: false,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _ThemeResetButton(),
          TextButton(
            onPressed: () =>
                _openAppearanceSection(context, AppearanceSection.themes),
            child: Text(l10n.appearance_themeLibrary),
          ),
        ],
      ),
      items: [
        CustomModel(
          id: 'themeQuickGallery',
          title: l10n.appearance_theme,
          builder: (context, ref) => const _ThemeQuickGallery(),
        ),
        CustomModel(
          id: 'themeOptions',
          title: l10n.appearance_themeAccent,
          builder: (context, ref) => const _CompactThemeOptions(),
        ),
      ],
    ),
    SettingsGroup(
      title: l10n.appearance_shape,
      icon: Symbols.rounded_corner_rounded,
      wrapInCard: false,
      items: [items['shapePreset']!],
    ),
    SettingsGroup(
      title: l10n.appearance_surfaceStyle,
      icon: Symbols.contrast_rounded,
      items: [
        items['black']!,
        entry(AppearanceSection.festival, Symbols.celebration_rounded),
      ],
    ),
    SettingsGroup(
      title: l10n.appearance_interface,
      icon: Symbols.tune_rounded,
      items: [
        entry(
          AppearanceSection.fonts,
          Symbols.font_download_rounded,
          subtitle: (ref) {
            final state = ref.watch(themeProvider);
            String name(String? id, String fallback) {
              final font = FontCatalog.byId(id);
              return font == null ? fallback : _fontName(context, font);
            }

            return '${name(state.effectiveBodyFontId, l10n.appearance_fontSystem)}'
                ' · ${name(state.effectiveMonoFontId, l10n.appearance_fontMonoSystem)}';
          },
        ),
        entry(
          AppearanceSection.background,
          Symbols.wallpaper_rounded,
          subtitle: (ref) => ref.watch(themeProvider).isTransparentActive
              ? l10n.appearance_styleTransparent
              : l10n.appearance_bgNone,
        ),
        entry(
          AppearanceSection.interface,
          Symbols.style_rounded,
          subtitle: (ref) =>
              '${l10n.appearance_emojiStyle} · ${l10n.topicCardStyle_title}',
        ),
      ],
    ),
  ];
}

/// 分组标题上的「重置」：只在主题外观偏离默认时出现，确认后恢复默认。
class _ThemeResetButton extends ConsumerWidget {
  const _ThemeResetButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDefault = ref.watch(
      themeProvider.select((s) => s.isThemeLookDefault),
    );
    final l10n = context.l10n;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      transitionBuilder: (child, animation) =>
          ScaleTransition(scale: animation, child: child),
      child: isDefault
          ? const SizedBox.shrink()
          : IconButton(
              tooltip: l10n.common_reset,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Symbols.restart_alt_rounded, size: 20),
              onPressed: () async {
                final confirmed = await showAppDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    content: Text(l10n.appearance_themeResetConfirm),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(false),
                        child: Text(l10n.common_cancel),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(dialogContext).pop(true),
                        child: Text(l10n.common_reset),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await ref.read(themeProvider.notifier).resetThemeLook();
                }
              },
            ),
    );
  }
}

class _ThemeQuickGallery extends ConsumerWidget {
  const _ThemeQuickGallery();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(themeProvider);
    final current = state.themeSpec;
    // 固定快捷槽位；当前主题名称及版本由顶部实时预览展示。
    // 族内切换口味只更新对应卡片的预览，不改变位置。
    final choices = <ThemeSpec>[];
    for (final id in [ThemeRegistry.materialId, 'catppuccin-mocha', 'nord']) {
      final spec = ThemeRegistry.byId(id);
      if (!choices.any((choice) => choice.familyId == spec.familyId)) {
        choices.add(spec.familyId == current.familyId ? current : spec);
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (state.activeFestival != null) const _FestivalBanner(),
        LayoutBuilder(
          builder: (context, constraints) {
            final width =
                (constraints.maxWidth - 12 * (choices.length - 1)) /
                choices.length;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final spec in choices)
                  _ThemeCard(
                    key: ValueKey('quick-theme-${spec.familyId}'),
                    width: width,
                    previewHeight: 56,
                    name: _themeName(context, spec),
                    scheme: _galleryScheme(
                      spec,
                      state,
                      Theme.of(context).brightness,
                    ),
                    shapes: (state.shapeOverride ?? spec.shape).shapes,
                    selected: spec.familyId == current.familyId,
                    onTap: () {
                      if (spec.id == current.id) return;
                      ref.read(themeProvider.notifier).setThemeId(spec.id);
                    },
                    onMore: () => _showThemeActions(context, ref, spec),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// 主页面保留当前强调色和少量快捷色，完整色板与配色风格小样仍在详情页。
class _CompactThemeOptions extends ConsumerWidget {
  const _CompactThemeOptions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(themeProvider);
    if (!state.themeSpec.isGenerated) return const _FixedThemeOptions();
    final l10n = context.l10n;
    final notifier = ref.read(themeProvider.notifier);
    final palettes = [...AppPalettes.builtins.take(4)];
    if (state.accentSource == AccentSource.palette &&
        !palettes.any((p) => p.id == state.paletteId)) {
      palettes.add(AppPalettes.byId(state.paletteId));
    }
    Color color(Color seed) => SeedColorScheme.from(
      seedColor: seed,
      variant: state.schemeVariant,
      brightness: Theme.of(context).brightness,
    ).primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.appearance_themeAccent,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            TextButton.icon(
              onPressed: () =>
                  _openAppearanceSection(context, AppearanceSection.colors),
              icon: const Icon(Symbols.palette_rounded, size: 18),
              label: Text(l10n.appearance_schemeVariant),
            ),
          ],
        ),
        const SizedBox(height: 4),
        _AccentPanel(
          children: [
            _AccentDot(
              color: color(state.dynamicPrimary ?? state.seedColor),
              tooltip: l10n.appearance_modeAuto,
              systemBadge: true,
              selected: state.accentSource == AccentSource.dynamic,
              onTap: notifier.selectDynamicColor,
            ),
            for (final palette in palettes)
              _AccentDot(
                color: color(palette.seedColor),
                tooltip: _paletteLabel(context, palette.id),
                selected:
                    state.accentSource == AccentSource.palette &&
                    state.paletteId == palette.id,
                onTap: () => notifier.selectPalette(palette.id),
              ),
            if (state.accentSource == AccentSource.custom)
              _AccentDot(
                color: color(state.seedColor),
                tooltip: l10n.appearance_themeCustomAccent,
                selected: true,
                onTap: () {},
                onEdit: () => _editCustomColor(context, ref, state.seedColor),
                onDelete: () => notifier.removeCustomColor(state.seedColor),
              ),
            _AccentAddButton(
              tooltip: l10n.appearance_themeCustomAccent,
              onTap: () => _addCustomColor(context, ref),
            ),
          ],
        ),
      ],
    );
  }
}

Future<void> _addCustomColor(BuildContext context, WidgetRef ref) async {
  final color = await _showSeedColorPicker(context, ref);
  if (color == null || !context.mounted) return;
  final notifier = ref.read(themeProvider.notifier);
  await notifier.addCustomColor(color);
  await notifier.selectCustomColor(color);
}

Future<void> _editCustomColor(
  BuildContext context,
  WidgetRef ref,
  Color from,
) async {
  final color = await _showSeedColorPicker(context, ref, initial: from);
  if (color == null || !context.mounted) return;
  await ref.read(themeProvider.notifier).replaceCustomColor(from, color);
}
