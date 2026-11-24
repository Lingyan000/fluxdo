import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/s.dart';
import '../../../providers/font_provider.dart';
import '../../../providers/theme_provider.dart';
import '../../../services/fonts/font_catalog.dart';
import '../../../services/fonts/font_download_service.dart';
import '../../../theme/theme_spec.dart';
import '../../../widgets/common/app_bottom_sheet.dart';
import '../../../widgets/common/paper_texture.dart';
import '../reader_preferences.dart';

/// 弹出纯净阅读排版设置面板（通过 [AppBottomSheet.show] 统一弹框外壳，
/// 关闭背景模糊便于即时观察后方正文排版变化）。
Future<void> showReaderTypesettingSheet(BuildContext context) {
  return AppBottomSheet.show<void>(
    context: context,
    title: context.l10n.reader_typesetting,
    showCloseButton: false,
    showDragHandle: true,
    blur: false,
    contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
    actions: [
      Consumer(
        builder: (context, ref, _) => TextButton(
          key: const ValueKey('reader_typesetting_reset'),
          onPressed: ref.read(readerPreferencesProvider.notifier).reset,
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          child: Text(context.l10n.reader_resetTypesetting),
        ),
      ),
    ],
    builder: (_) => const _ReaderTypesettingSheet(),
  );
}

class _ReaderTypesettingSheet extends ConsumerWidget {
  const _ReaderTypesettingSheet();

  static const _groupPadding = EdgeInsets.symmetric(
    horizontal: 10,
    vertical: 8,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final locale = Localizations.localeOf(context);
    final prefs = ref.watch(readerPreferencesProvider);
    final notifier = ref.read(readerPreferencesProvider.notifier);
    final fontService = ref.watch(fontDownloadProvider);
    final bodyFonts = FontCatalog.ofSlot(FontSlot.body);
    final isDark = theme.brightness == Brightness.dark;

    return SingleChildScrollView(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 字号（纯离散档位，界面高亮与实际字号严格一致）
            _SettingRow(
              label: l10n.reader_fontSize,
              child: M3eButtonGroup<double>(
                selected: prefs.fontSize,
                itemPadding: _groupPadding,
                onSelected: notifier.setFontSize,
                items: [
                  for (final stop in ReaderPreferences.fontSizeStops)
                    M3eButtonGroupItem(
                      value: stop,
                      label: Text(
                        '${stop.round()}',
                        key: ValueKey('reader_font_size_${stop.round()}'),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // 行距
            _SettingRow(
              label: l10n.reader_lineSpacing,
              child: M3eButtonGroup<ReaderLineSpacing>(
                selected: prefs.lineSpacing,
                itemPadding: _groupPadding,
                onSelected: notifier.setLineSpacing,
                items: [
                  M3eButtonGroupItem(
                    value: ReaderLineSpacing.compact,
                    label: Text(
                      l10n.reader_spacingCompact,
                      key: const ValueKey('reader_spacing_compact'),
                    ),
                  ),
                  M3eButtonGroupItem(
                    value: ReaderLineSpacing.normal,
                    label: Text(
                      l10n.reader_spacingNormal,
                      key: const ValueKey('reader_spacing_normal'),
                    ),
                  ),
                  M3eButtonGroupItem(
                    value: ReaderLineSpacing.relaxed,
                    label: Text(
                      l10n.reader_spacingRelaxed,
                      key: const ValueKey('reader_spacing_relaxed'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // 字重
            _SettingRow(
              label: l10n.reader_fontWeight,
              child: M3eButtonGroup<ReaderFontWeight>(
                selected: prefs.fontWeight,
                itemPadding: _groupPadding,
                onSelected: notifier.setFontWeight,
                items: [
                  M3eButtonGroupItem(
                    value: ReaderFontWeight.normal,
                    label: Text(
                      l10n.reader_weightNormal,
                      key: const ValueKey('reader_weight_normal'),
                    ),
                  ),
                  M3eButtonGroupItem(
                    value: ReaderFontWeight.medium,
                    label: Text(
                      l10n.reader_weightMedium,
                      key: const ValueKey('reader_weight_medium'),
                    ),
                  ),
                  M3eButtonGroupItem(
                    value: ReaderFontWeight.semiBold,
                    label: Text(
                      l10n.reader_weightSemiBold,
                      key: const ValueKey('reader_weight_semibold'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // 字体：直接复用应用内置 FontCatalog + FontDownloadService 体系
            _SettingRow(
              label: l10n.reader_fontFamily,
              child: M3eButtonGroup<String>(
                selected: prefs.fontChoice,
                scrollable: bodyFonts.isNotEmpty,
                itemPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                onSelected: (choice) async {
                  notifier.setFontChoice(choice);
                  final entry = FontCatalog.byId(choice);
                  if (entry == null) return;
                  final themeNotifier = ref.read(themeProvider.notifier);
                  if (fontService.stateOf(entry) is FontInstalled) {
                    await themeNotifier.ensureFontLoaded(entry.id);
                  } else {
                    unawaited(
                      fontService.install(entry).then((_) async {
                        if (fontService.stateOf(entry) is FontInstalled) {
                          await themeNotifier.ensureFontLoaded(entry.id);
                        }
                      }),
                    );
                  }
                },
                items: [
                  M3eButtonGroupItem(
                    value: FontChoice.follow,
                    label: Text(
                      l10n.appearance_fontFollowTheme,
                      key: const ValueKey('reader_font_follow'),
                    ),
                  ),
                  M3eButtonGroupItem(
                    value: FontChoice.system,
                    label: Text(
                      l10n.appearance_fontSystem,
                      key: const ValueKey('reader_font_system'),
                    ),
                  ),
                  for (final entry in bodyFonts)
                    _buildCatalogFontItem(
                      entry: entry,
                      locale: locale,
                      installState: fontService.stateOf(entry),
                    ),
                ],
              ),
            ),
            if (_buildFontDownloadStatus(
                  context: context,
                  fontChoice: prefs.fontChoice,
                  locale: locale,
                  fontService: fontService,
                )
                case final statusWidget?) ...[
              const SizedBox(height: 8),
              statusWidget,
            ],
            const SizedBox(height: 14),

            // 亮色纸张底色（深色模式下固定跟随深色主题）
            _SettingRow(
              label: l10n.reader_paperBackground,
              child: isDark
                  ? Text(
                      l10n.reader_paperDarkHint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: _PaperSwatch(
                            key: const ValueKey('reader_paper_followTheme'),
                            paperTheme: ReaderPaperTheme.followTheme,
                            label: l10n.reader_paperDefault,
                            selected:
                                prefs.paperTheme ==
                                ReaderPaperTheme.followTheme,
                            onTap: () => notifier.setPaperTheme(
                              ReaderPaperTheme.followTheme,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _PaperSwatch(
                            key: const ValueKey('reader_paper_paper'),
                            paperTheme: ReaderPaperTheme.paper,
                            label: l10n.reader_paperWarm,
                            selected:
                                prefs.paperTheme == ReaderPaperTheme.paper,
                            onTap: () =>
                                notifier.setPaperTheme(ReaderPaperTheme.paper),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _PaperSwatch(
                            key: const ValueKey('reader_paper_green'),
                            paperTheme: ReaderPaperTheme.green,
                            label: l10n.reader_paperGreen,
                            selected:
                                prefs.paperTheme == ReaderPaperTheme.green,
                            onTap: () =>
                                notifier.setPaperTheme(ReaderPaperTheme.green),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  M3eButtonGroupItem<String> _buildCatalogFontItem({
    required FontEntry entry,
    required Locale locale,
    required FontInstallState installState,
  }) {
    final name = localizedName(entry.name, locale, entry.id);
    // 按钮文案始终保持固定，图标槽位定宽 15×15，避免下载进度变化引起按钮组左右抖动。
    final Widget? statusIcon = switch (installState) {
      FontInstalled() => null,
      FontDownloading(:final progress) => SizedBox.square(
        dimension: 15,
        child: LoadingSpinner(size: 14, progress: progress),
      ),
      FontQueued() || FontVerifying() => const SizedBox.square(
        dimension: 15,
        child: LoadingSpinner(size: 14),
      ),
      FontNotInstalled() || FontFailed() => const SizedBox.square(
        dimension: 15,
        child: Icon(Symbols.download_rounded, size: 15),
      ),
    };

    return M3eButtonGroupItem(
      value: entry.id,
      icon: statusIcon,
      label: Text(
        name,
        key: ValueKey('reader_font_${entry.id}'),
      ),
    );
  }

  Widget? _buildFontDownloadStatus({
    required BuildContext context,
    required String fontChoice,
    required Locale locale,
    required FontDownloadService fontService,
  }) {
    final entry = FontCatalog.byId(fontChoice);
    if (entry == null) return null;
    final state = fontService.stateOf(entry);
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final name = localizedName(entry.name, locale, entry.id);

    final (String text, double? progress, bool isError) = switch (state) {
      FontQueued() => ('$name · ${l10n.appearance_fontQueued}', null, false),
      FontDownloading(:final progress) => (
        '$name · ${l10n.appearance_fontDownloading((progress * 100).floor().toString())}',
        progress,
        false,
      ),
      FontVerifying() => (
        '$name · ${l10n.appearance_fontVerifying}',
        null,
        false,
      ),
      FontFailed(:final reason) when reason != FontFailure.cancelled => (
        '$name · ${l10n.appearance_fontNetworkError}',
        0.0,
        true,
      ),
      _ => ('', null, false),
    };
    if (text.isEmpty) return null;

    return Padding(
      padding: const EdgeInsets.only(left: 78),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            text,
            style: theme.textTheme.labelSmall?.copyWith(
              color: isError
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (!isError) ...[
            const SizedBox(height: 6),
            M3eLinearProgress(value: progress),
          ],
        ],
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 68,
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: child),
      ],
    );
  }
}

class _PaperSwatch extends StatelessWidget {
  const _PaperSwatch({
    super.key,
    required this.paperTheme,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final ReaderPaperTheme paperTheme;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedAccent = context.emphasis.selected;
    final previewColor = ReaderPalette.previewColorOf(
      paperTheme,
      theme.colorScheme,
    );
    final swatchInk = switch (paperTheme) {
      ReaderPaperTheme.paper => const Color(0xFF2E261C),
      ReaderPaperTheme.green => const Color(0xFF223024),
      ReaderPaperTheme.followTheme => theme.colorScheme.onSurface,
    };

    Widget swatchBody = Container(
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: paperTheme == ReaderPaperTheme.paper ? null : previewColor,
        borderRadius: context.shapes.borderRadius(10),
        border: Border.all(
          color: selected
              ? selectedAccent
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
          width: selected ? 1.6 : 1.0,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected) ...[
            Icon(
              Symbols.check_rounded,
              size: 15,
              color: selectedAccent,
            ),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: swatchInk,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );

    if (paperTheme == ReaderPaperTheme.paper) {
      swatchBody = ClipRRect(
        borderRadius: context.shapes.borderRadius(10),
        child: Stack(
          children: [
            Positioned.fill(child: PaperBackground(color: previewColor)),
            swatchBody,
          ],
        ),
      );
    }

    return M3eElasticPress(
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: context.shapes.borderRadius(10),
          onTap: onTap,
          child: swatchBody,
        ),
      ),
    );
  }
}
