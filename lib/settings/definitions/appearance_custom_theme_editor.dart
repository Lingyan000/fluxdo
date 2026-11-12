part of 'appearance_defs.dart';

// ══════════════════════════════════════════════════════════════════
// 自定义主题：编辑器、画廊操作（新建 / 复制 / 编辑 / 导入导出 / 删除）
// ══════════════════════════════════════════════════════════════════

String _hueLabel(BuildContext context, AppHue hue) {
  final l10n = context.l10n;
  return switch (hue) {
    AppHue.red => l10n.appearance_hueRed,
    AppHue.orange => l10n.appearance_hueOrange,
    AppHue.yellow => l10n.appearance_hueYellow,
    AppHue.green => l10n.appearance_hueGreen,
    AppHue.cyan => l10n.appearance_hueCyan,
    AppHue.blue => l10n.appearance_hueBlue,
    AppHue.purple => l10n.appearance_huePurple,
    _ => hue.name,
  };
}

/// 以 [base] 为底稿打开编辑器（底稿未保存，编辑器里点保存才落盘）。
Future<void> _createThemeFrom(
  BuildContext context,
  WidgetRef ref,
  ThemeSpec base,
) {
  final state = ref.read(themeProvider);
  final resolved = ThemeResolver.resolve(
    spec: base,
    mode: ThemeMode.system,
    black: false,
    seed: state.effectiveSeedColor,
    variant: state.schemeVariant,
    accentId: state.accentFor(base),
  );
  final draft = CustomThemes.draftFrom(
    base,
    name: context.l10n.appearance_customThemeCopyName(
      _themeName(context, base),
    ),
    resolved: resolved,
  );
  return _openThemeEditor(context, draft);
}

Future<void> _openThemeEditor(BuildContext context, ThemeSpec spec) =>
    Navigator.of(context).push(
      InteractionPageRoute<void>(
        builder: (_) => _CustomThemeEditorPage(initial: spec),
      ),
    );

/// 从剪贴板导入主题代码。
Future<void> _importThemeFromClipboard(
  BuildContext context,
  WidgetRef ref,
) async {
  final l10n = context.l10n;
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final code = data?.text;
  if (code == null || code.trim().isEmpty) {
    ToastService.showError(l10n.appearance_customThemeImportFailed);
    return;
  }
  try {
    final spec = await ref.read(themeProvider.notifier).importCustomTheme(code);
    if (!context.mounted) return;
    ToastService.showSuccess(
      l10n.appearance_customThemeImported(_themeName(context, spec)),
    );
  } on FormatException {
    ToastService.showError(l10n.appearance_customThemeImportFailed);
  }
}

/// 主题卡的长按 / 右键操作。
Future<void> _showThemeActions(
  BuildContext context,
  WidgetRef ref,
  ThemeSpec spec,
) {
  final l10n = context.l10n;
  final isCustom = spec.group == ThemeGroup.custom;
  return showAppBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      void close() => Navigator.of(sheetContext).pop();
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isCustom)
              ListTile(
                leading: const Icon(Symbols.edit_rounded),
                title: Text(l10n.common_edit),
                onTap: () {
                  close();
                  _openThemeEditor(context, spec);
                },
              ),
            ListTile(
              leading: const Icon(Symbols.content_copy_rounded),
              title: Text(l10n.appearance_customThemeDuplicate),
              onTap: () {
                close();
                _createThemeFrom(context, ref, spec);
              },
            ),
            if (isCustom) ...[
              ListTile(
                leading: const Icon(Symbols.share_rounded),
                title: Text(l10n.appearance_customThemeCopyCode),
                onTap: () async {
                  close();
                  await Clipboard.setData(
                    ClipboardData(text: CustomThemes.export(spec)),
                  );
                  ToastService.showSuccess(
                    l10n.appearance_customThemeCodeCopied,
                  );
                },
              ),
              ListTile(
                leading: Icon(
                  Symbols.delete_rounded,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(l10n.common_delete),
                onTap: () async {
                  close();
                  final confirmed = await showAppDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      content: Text(
                        l10n.appearance_customThemeDeleteConfirm(
                          _themeName(context, spec),
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(false),
                          child: Text(l10n.common_cancel),
                        ),
                        FilledButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(true),
                          child: Text(l10n.common_delete),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await ref
                        .read(themeProvider.notifier)
                        .deleteCustomTheme(spec.id);
                  }
                },
              ),
            ],
          ],
        ),
      );
    },
  );
}

class _CustomThemeEditorPage extends ConsumerStatefulWidget {
  const _CustomThemeEditorPage({required this.initial});

  final ThemeSpec initial;

  @override
  ConsumerState<_CustomThemeEditorPage> createState() =>
      _CustomThemeEditorPageState();
}

class _CustomThemeEditorPageState
    extends ConsumerState<_CustomThemeEditorPage> {
  late ThemeSpec _spec = widget.initial;
  late final TextEditingController _name = TextEditingController(
    text: localizedName(widget.initial.name, const Locale('zh'), ''),
  );
  Brightness? _side;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _side ??= Theme.of(context).brightness;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Brightness get side => _side ?? Brightness.light;
  ThemePalette get _palette => _spec.paletteOf(side);

  void _setPalette(ThemePalette palette) => setState(() {
    _spec = side == Brightness.light
        ? _spec.copyWith(light: palette)
        : _spec.copyWith(dark: palette);
  });

  void _setStyle(ThemeStyle style) =>
      setState(() => _spec = _spec.copyWith(style: style));

  Future<void> _pick(Color current, void Function(Color) apply) async {
    final color = await _showSeedColorPicker(context, ref, initial: current);
    if (color != null && mounted) apply(color);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final spec = name.isEmpty
        ? _spec
        : _spec.copyWith(name: {'zh': name, 'en': name});
    final notifier = ref.read(themeProvider.notifier);
    await notifier.saveCustomTheme(spec);
    await notifier.setThemeId(spec.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final resolved = ThemeResolver.resolve(
      spec: _spec,
      mode: ThemeMode.system,
      black: false,
      seed: Colors.blue,
      variant: DynamicSchemeVariant.tonalSpot,
    );
    final scheme = side == Brightness.light ? resolved.light : resolved.dark;
    final palette = _palette;
    final style = _spec.style;

    Widget sectionTitle(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        text,
        style: textTheme.titleSmall?.copyWith(color: cs.onSurfaceVariant),
      ),
    );

    Widget colorRow(
      String label,
      Color color,
      void Function(Color) apply, {
      bool adjusted = false,
    }) => ListTile(
      leading: _ColorDot(color: color),
      title: Text(label),
      subtitle: Text(
        adjusted
            ? l10n.appearance_themeEditorAdjusted
            : ThemeSpecColor.format(color),
        style: adjusted ? TextStyle(color: cs.error) : null,
      ),
      trailing: const Icon(Symbols.chevron_right_rounded),
      onTap: () => _pick(color, apply),
    );

    // 界面风格的一项：标题 + 联排选项。选项取枚举的全部取值，文案用
    // 穷尽的 switch 给出，新增取值时编译器会要求补上
    Widget styleChoice<T>(
      String label,
      List<T> values,
      String Function(T value) name,
      T selected,
      ThemeStyle Function(T value) apply,
    ) => Padding(
      // 可横滑的按钮组四周自带 8 的留白，这里补到与其他分区同样的 16 边距
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(label, style: textTheme.bodyMedium),
          ),
          M3eButtonGroup<T>(
            scrollable: true,
            items: [
              for (final value in values)
                M3eButtonGroupItem(value: value, label: Text(name(value))),
            ],
            selected: selected,
            onSelected: (value) => _setStyle(apply(value)),
          ),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appearance_themeEditorTitle),
        actions: [
          TextButton(onPressed: _save, child: Text(l10n.common_save)),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: l10n.appearance_customThemeName,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: SizedBox(
              width: 140,
              child: AspectRatio(
                aspectRatio: 9 / 17,
                child: _MiniScreen(
                  scheme: scheme,
                  shapes: _spec.shape.shapes,
                  style: _spec.style,
                  cornerRadius: 20,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: M3eButtonGroup<Brightness>(
              items: [
                M3eButtonGroupItem(
                  value: Brightness.light,
                  icon: const Icon(Symbols.light_mode_rounded),
                  label: Text(l10n.appearance_modeLight),
                ),
                M3eButtonGroupItem(
                  value: Brightness.dark,
                  icon: const Icon(Symbols.dark_mode_rounded),
                  label: Text(l10n.appearance_modeDark),
                ),
              ],
              selected: side,
              onSelected: (value) => setState(() => _side = value),
            ),
          ),
          sectionTitle(l10n.appearance_themeEditorBase),
          colorRow(
            l10n.appearance_themeEditorBg,
            palette.bg,
            (c) => _setPalette(palette.copyWith(bg: c)),
          ),
          colorRow(
            l10n.appearance_themeEditorFg,
            palette.fg,
            (c) => _setPalette(palette.copyWith(fg: c)),
            adjusted: scheme.onSurface != palette.fg,
          ),
          colorRow(
            l10n.appearance_themeEditorFgMuted,
            palette.fgMuted,
            (c) => _setPalette(palette.copyWith(fgMuted: c)),
            adjusted: scheme.onSurfaceVariant != palette.fgMuted,
          ),
          colorRow(
            l10n.appearance_themeEditorBorder,
            palette.border,
            (c) => _setPalette(palette.copyWith(border: c)),
          ),
          sectionTitle(l10n.appearance_themeEditorHues),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final hue in AppHue.basics)
                  GestureDetector(
                    onTap: () => _pick(
                      palette.hues[hue]!,
                      (c) => _setPalette(
                        palette.copyWith(hues: {...palette.hues, hue: c}),
                      ),
                    ),
                    child: Column(
                      children: [
                        _ColorDot(color: palette.hues[hue]!, size: 36),
                        const SizedBox(height: 4),
                        Text(
                          _hueLabel(context, hue),
                          style: textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          sectionTitle(l10n.appearance_themeAccent),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              l10n.appearance_themeEditorAccentHint,
              style: textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final (i, accent) in _spec.accents.indexed)
                  GestureDetector(
                    onLongPress: _spec.accents.length <= 1
                        ? null
                        : () => setState(() {
                            _spec = _spec.copyWith(
                              accents: [..._spec.accents]..removeAt(i),
                            );
                          }),
                    child: _AccentDot(
                      color: accent.of(side),
                      tooltip: localizedName(
                        accent.name,
                        Localizations.localeOf(context),
                        accent.id,
                      ),
                      selected: false,
                      onTap: () => _pick(accent.of(side), (c) {
                        final updated = ThemeAccent(
                          id: accent.id,
                          name: accent.name,
                          light: side == Brightness.light ? c : accent.light,
                          dark: side == Brightness.dark ? c : accent.dark,
                        );
                        setState(() {
                          _spec = _spec.copyWith(
                            accents: [..._spec.accents]..[i] = updated,
                          );
                        });
                      }),
                    ),
                  ),
                IconButton.filledTonal(
                  onPressed: () => _pick(_spec.accents.first.of(side), (c) {
                    setState(() {
                      _spec = _spec.copyWith(
                        accents: [
                          ..._spec.accents,
                          ThemeAccent(
                            id: 'a${DateTime.now().microsecondsSinceEpoch}',
                            light: c,
                            dark: c,
                          ),
                        ],
                      );
                    });
                  }),
                  icon: Icon(Symbols.add_rounded, color: context.emphasis.accent),
                ),
              ],
            ),
          ),
          sectionTitle(l10n.appearance_shape),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: M3eButtonGroup<ShapePreset>(
              items: [
                M3eButtonGroupItem(
                  value: ShapePreset.standard,
                  label: Text(l10n.appearance_shapeStandard),
                ),
                M3eButtonGroupItem(
                  value: ShapePreset.compact,
                  label: Text(l10n.appearance_shapeCompact),
                ),
                M3eButtonGroupItem(
                  value: ShapePreset.sharp,
                  label: Text(l10n.appearance_shapeSharp),
                ),
              ],
              selected: _spec.shape,
              onSelected: (value) =>
                  setState(() => _spec = _spec.copyWith(shape: value)),
            ),
          ),
          sectionTitle(l10n.appearance_themeEditorStyle),
          styleChoice(
            l10n.appearance_styleSurfaces,
            SurfaceStyle.values,
            (v) => switch (v) {
              SurfaceStyle.filled => l10n.appearance_styleSurfacesFilled,
              SurfaceStyle.outlined => l10n.appearance_styleSurfacesOutlined,
              SurfaceStyle.flat => l10n.appearance_styleSurfacesFlat,
              SurfaceStyle.raised => l10n.appearance_styleSurfacesRaised,
            },
            style.surfaces,
            (v) => style.copyWith(surfaces: v),
          ),
          styleChoice(
            l10n.appearance_styleControls,
            ControlStyle.values,
            (v) => switch (v) {
              ControlStyle.accent => l10n.appearance_styleControlsAccent,
              ControlStyle.ink => l10n.appearance_styleControlsInk,
            },
            style.controls,
            (v) => style.copyWith(controls: v),
          ),
          styleChoice(
            l10n.appearance_styleNav,
            NavIndicatorStyle.values,
            (v) => switch (v) {
              NavIndicatorStyle.pill => l10n.appearance_styleNavPill,
              NavIndicatorStyle.bar => l10n.appearance_styleNavBar,
              NavIndicatorStyle.tint => l10n.appearance_styleNavTint,
            },
            style.navIndicator,
            (v) => style.copyWith(navIndicator: v),
          ),
          styleChoice(
            l10n.appearance_styleInputs,
            InputStyle.values,
            (v) => switch (v) {
              InputStyle.filled => l10n.appearance_styleInputsFilled,
              InputStyle.outlined => l10n.appearance_styleInputsOutlined,
              InputStyle.underline => l10n.appearance_styleInputsUnderline,
            },
            style.inputs,
            (v) => style.copyWith(inputs: v),
          ),
          styleChoice(
            l10n.appearance_styleQuote,
            QuoteStyle.values,
            (v) => switch (v) {
              QuoteStyle.card => l10n.appearance_styleQuoteCard,
              QuoteStyle.bar => l10n.appearance_styleQuoteBar,
            },
            style.quote,
            (v) => style.copyWith(quote: v),
          ),
          styleChoice(
            l10n.appearance_styleDataColors,
            DataColorStyle.values,
            (v) => switch (v) {
              DataColorStyle.vivid => l10n.appearance_styleDataColorsVivid,
              DataColorStyle.harmonized =>
                l10n.appearance_styleDataColorsHarmonized,
              DataColorStyle.muted => l10n.appearance_styleDataColorsMuted,
              DataColorStyle.mono => l10n.appearance_styleDataColorsMono,
            },
            style.dataColors,
            (v) => style.copyWith(dataColors: v),
          ),
          SwitchListTile(
            title: Text(l10n.appearance_styleShadows),
            value: style.shadows,
            onChanged: (v) => _setStyle(style.copyWith(shadows: v)),
          ),
          SwitchListTile(
            title: Text(l10n.appearance_styleTexture),
            value: style.texture == TextureStyle.paper,
            onChanged: (v) => _setStyle(
              style.copyWith(
                texture: v ? TextureStyle.paper : TextureStyle.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color, this.size = 32});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
  );
}

/// 画廊「我的主题」末尾的新建卡：以当前主题为底稿。
class _NewThemeCard extends ConsumerWidget {
  const _NewThemeCard({required this.width});

  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final label = context.l10n.appearance_customThemeNew;
    return SizedBox(
      width: width,
      child: Semantics(
        button: true,
        label: label,
        child: _AppearancePressSurface(
          shape: RoundedSuperellipseBorder(
            borderRadius: context.shapes.borderRadius(21),
          ),
          onTap: () =>
              _createThemeFrom(context, ref, ref.read(themeProvider).themeSpec),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(3),
                child: AspectRatio(
                  aspectRatio: 9 / 14,
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: cs.surfaceContainerHigh,
                      shape: RoundedSuperellipseBorder(
                        borderRadius: context.shapes.borderRadius(18),
                        side: BorderSide(color: cs.outlineVariant),
                      ),
                    ),
                    child: Icon(
                      Symbols.add_rounded,
                      color: context.emphasis.accent,
                      size: 32,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
