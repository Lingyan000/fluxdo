import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../providers/theme_provider.dart';
import '../../services/data_management/cache_size_service.dart';
import '../../services/fonts/font_catalog.dart';
import '../../services/fonts/font_download_service.dart';
import '../../services/fonts/font_sources.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';

/// MiSans 移出安装包后的升级引导。
class FontMigrationPrompt {
  FontMigrationPrompt._();

  static const String promptedKey = 'font_migration_prompted';
  static const String misansId = 'misans';

  /// 旧版选了内置 MiSans、升级后字体尚未下载时，主动弹框引导下载。
  /// 只弹一次；用户已改选其他字体或已下载时不弹。
  static Future<void> maybeShow(BuildContext context, WidgetRef ref) async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (prefs.getBool(promptedKey) ?? false) return;
    if (prefs.getString(ThemeNotifier.legacyFontFamilyKey) != 'miSans') return;
    final entry = FontCatalog.byId(misansId);
    if (entry == null) return;
    if (FontDownloadService.instance.isInstalled(entry) ||
        ref.read(themeProvider).bodyFont != misansId) {
      await prefs.setBool(promptedKey, true);
      return;
    }
    await prefs.setBool(promptedKey, true);
    if (!context.mounted) return;
    await showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _FontMigrationDialog(entry: entry),
    );
  }
}

class _FontMigrationDialog extends ConsumerStatefulWidget {
  const _FontMigrationDialog({required this.entry});

  final FontEntry entry;

  @override
  ConsumerState<_FontMigrationDialog> createState() =>
      _FontMigrationDialogState();
}

class _FontMigrationDialogState extends ConsumerState<_FontMigrationDialog> {
  final FontDownloadService _service = FontDownloadService.instance;
  StreamSubscription<FontEntry>? _installedSub;

  @override
  void initState() {
    super.initState();
    // 弹框关闭（转后台下载）后不取消订阅：完成时仍要提示一次，
    // take(1) 保证只触发一次
    final name = widget.entry.name['en'] ?? widget.entry.id;
    _installedSub = _service.onInstalled
        .where((e) => e.id == widget.entry.id)
        .take(1)
        .listen((_) {
          ToastService.showSuccess(S.current.appearance_fontReadyToast(name));
          if (mounted) Navigator.of(context, rootNavigator: true).pop();
        });
  }

  void _close() {
    Navigator.of(context, rootNavigator: true).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cs = Theme.of(context).colorScheme;
    final entry = widget.entry;
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final state = _service.stateOf(entry);
        final busy =
            state is FontQueued ||
            state is FontDownloading ||
            state is FontVerifying;
        final failed =
            state is FontFailed && state.reason != FontFailure.cancelled;
        return AlertDialog(
          title: Text(l10n.appearance_fontMigrationTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.appearance_fontMigrationBody(
                  CacheSizeService.formatSize(entry.size),
                ),
              ),
              if (busy) ...[
                const SizedBox(height: 20),
                LinearProgressIndicator(
                  value: state is FontDownloading ? state.progress : null,
                ),
                const SizedBox(height: 8),
                Text(
                  state is FontDownloading
                      ? l10n.appearance_fontDownloading(
                          (state.progress * 100).floor().toString(),
                        )
                      : state is FontVerifying
                      ? l10n.appearance_fontVerifying
                      : l10n.appearance_fontQueued,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (failed) ...[
                const SizedBox(height: 16),
                Text(
                  switch (state.reason) {
                    FontFailure.corrupted => l10n.appearance_fontCorrupted,
                    FontFailure.invalidSource =>
                      l10n.appearance_fontInvalidSource,
                    FontFailure.storage => l10n.appearance_fontStorageError,
                    _ => l10n.appearance_fontNetworkError,
                  },
                  style: TextStyle(color: cs.error),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(l10n.appearance_fontChangeSource),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButton<FontSourceKind>(
                        isExpanded: true,
                        value: _service.sourceKind,
                        items: [
                          for (final kind in FontSourceKind.values)
                            if (kind != FontSourceKind.custom ||
                                FontSource.isValidTemplate(
                                  _service.customTemplate,
                                ))
                              DropdownMenuItem(
                                value: kind,
                                child: Text(
                                  switch (kind) {
                                    FontSourceKind.auto =>
                                      l10n.appearance_fontSourceAuto,
                                    FontSourceKind.npmmirror =>
                                      l10n.appearance_fontSourceNpmmirror,
                                    FontSourceKind.fastly =>
                                      'jsDelivr (Fastly)',
                                    FontSourceKind.jsdelivr => 'jsDelivr',
                                    FontSourceKind.unpkg => 'unpkg',
                                    FontSourceKind.npmjs => 'npmjs.org',
                                    FontSourceKind.custom =>
                                      l10n.appearance_fontSourceCustom,
                                  },
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                        ],
                        onChanged: (kind) {
                          if (kind != null) _service.setSource(kind);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
          actions: [
            if (busy)
              TextButton(
                onPressed: _close,
                child: Text(l10n.appearance_fontMigrationBackground),
              )
            else ...[
              TextButton(
                onPressed: () {
                  final notifier = ref.read(themeProvider.notifier);
                  unawaited(_installedSub?.cancel());
                  _close();
                  unawaited(notifier.setBodyFont(FontChoice.system));
                },
                child: Text(l10n.appearance_fontMigrationLater),
              ),
              FilledButton(
                onPressed: () => unawaited(_service.install(entry)),
                child: Text(
                  failed
                      ? l10n.appearance_fontRetry
                      : l10n.appearance_fontDownload,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
