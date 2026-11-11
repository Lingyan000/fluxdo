part of 'appearance_defs.dart';

// ══════════════════════════════════════════════════════════════════
// 字体：正文 / 等宽两个槽位 + 下载源
// ══════════════════════════════════════════════════════════════════

String _fontName(BuildContext context, FontEntry entry) =>
    localizedName(entry.name, Localizations.localeOf(context), entry.id);

/// 字体安装状态的一行描述。
String _fontStatusText(
  BuildContext context,
  FontEntry entry,
  FontInstallState state,
) {
  final l10n = context.l10n;
  final size = CacheSizeService.formatSize(entry.size);
  return switch (state) {
    FontNotInstalled() => l10n.appearance_fontNotDownloaded(size),
    FontQueued() => l10n.appearance_fontQueued,
    FontDownloading(:final progress) => l10n.appearance_fontDownloading(
      (progress * 100).floor().toString(),
    ),
    FontVerifying() => l10n.appearance_fontVerifying,
    FontInstalled() => l10n.appearance_fontReady(size),
    FontFailed(reason: FontFailure.cancelled) =>
      l10n.appearance_fontNotDownloaded(size),
    FontFailed(:final reason) => _fontFailureText(context, reason),
  };
}

String _fontFailureText(BuildContext context, FontFailure reason) {
  final l10n = context.l10n;
  final pinned = FontDownloadService.instance.sourceKind != FontSourceKind.auto;
  return switch (reason) {
    FontFailure.network =>
      pinned
          ? l10n.appearance_fontPinnedSourceFailed
          : l10n.appearance_fontNetworkError,
    FontFailure.corrupted => l10n.appearance_fontCorrupted,
    FontFailure.invalidSource => l10n.appearance_fontInvalidSource,
    FontFailure.storage => l10n.appearance_fontStorageError,
    // 取消不算失败，由调用方按「未下载」展示
    FontFailure.cancelled => '',
  };
}

/// 一个字体槽位的选项列表。
class _FontSlotSection extends ConsumerWidget {
  const _FontSlotSection(this.slot);

  final FontSlot slot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final themeState = ref.watch(themeProvider);
    final service = ref.watch(fontDownloadProvider);
    final cs = Theme.of(context).colorScheme;
    final isBody = slot == FontSlot.body;
    final choice = isBody ? themeState.bodyFont : themeState.monoFont;
    final suggestion = FontCatalog.byId(
      isBody ? themeState.themeSpec.fontBody : themeState.themeSpec.fontMono,
    );
    final notifier = ref.read(themeProvider.notifier);
    Future<void> select(String value) =>
        isBody ? notifier.setBodyFont(value) : notifier.setMonoFont(value);

    return RadioGroup<String>(
      groupValue: choice,
      onChanged: (value) async {
        if (value == null) return;
        await select(value);
        final entry =
            FontCatalog.byId(value) ??
            (value == FontChoice.follow ? suggestion : null);
        // 选中未下载的字体：直接开始下载，完成后自动生效
        if (entry != null && service.stateOf(entry) is! FontInstalled) {
          unawaited(service.install(entry));
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              isBody ? l10n.appearance_fontBody : l10n.appearance_fontMono,
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          RadioListTile<String>(
            value: FontChoice.follow,
            title: Text(l10n.appearance_fontFollowTheme),
            subtitle: Text(
              suggestion == null
                  ? l10n.appearance_fontThemeNone
                  : l10n.appearance_fontThemeSuggests(
                      _fontName(context, suggestion),
                    ),
            ),
          ),
          RadioListTile<String>(
            value: FontChoice.system,
            title: Text(
              isBody
                  ? l10n.appearance_fontSystem
                  : l10n.appearance_fontMonoSystem,
            ),
          ),
          for (final entry in FontCatalog.ofSlot(slot))
            _FontEntryTile(entry: entry, service: service),
        ],
      ),
    );
  }
}

class _FontEntryTile extends StatelessWidget {
  const _FontEntryTile({required this.entry, required this.service});

  final FontEntry entry;
  final FontDownloadService service;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cs = Theme.of(context).colorScheme;
    final state = service.stateOf(entry);
    final failed = state is FontFailed && state.reason != FontFailure.cancelled;

    final Widget action = switch (state) {
      FontInstalled() => SwipeDismissiblePopupMenuButton<void>(
        icon: const Icon(Symbols.more_vert_rounded),
        itemBuilder: (_) => [
          PopupMenuItem(
            onTap: () => service.uninstall(entry),
            child: Text(l10n.appearance_fontDelete),
          ),
        ],
      ),
      FontQueued() || FontDownloading() || FontVerifying() => IconButton(
        tooltip: l10n.appearance_fontCancel,
        onPressed: state is FontVerifying ? null : () => service.cancel(entry),
        icon: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            value: state is FontDownloading ? state.progress : null,
          ),
        ),
      ),
      _ => IconButton(
        tooltip: failed
            ? l10n.appearance_fontRetry
            : l10n.appearance_fontDownload,
        onPressed: () => service.install(entry),
        icon: Icon(
          failed ? Symbols.refresh_rounded : Symbols.download_rounded,
          color: failed ? cs.error : context.emphasis.accent,
        ),
      ),
    };

    return RadioListTile<String>(
      value: entry.id,
      title: Text(
        _fontName(context, entry),
        // 已注册的字体用自身字形展示名字
        style: service.isRegistered(entry)
            ? TextStyle(fontFamily: entry.family)
            : null,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _fontStatusText(context, entry, state),
            style: failed ? TextStyle(color: cs.error) : null,
          ),
          if (service.isRegistered(entry))
            Text(
              entry.slot == FontSlot.mono
                  ? 'Aa 0123 != => {}'
                  : context.l10n.appearance_previewText,
              style: TextStyle(fontFamily: entry.family),
            ),
        ],
      ),
      secondary: action,
      controlAffinity: ListTileControlAffinity.leading,
    );
  }
}

String _fontSourceLabel(BuildContext context, FontSourceKind kind) {
  final l10n = context.l10n;
  return switch (kind) {
    FontSourceKind.auto => l10n.appearance_fontSourceAuto,
    FontSourceKind.npmmirror => l10n.appearance_fontSourceNpmmirror,
    FontSourceKind.fastly => 'jsDelivr (Fastly)',
    FontSourceKind.jsdelivr => 'jsDelivr',
    FontSourceKind.unpkg => 'unpkg',
    FontSourceKind.npmjs => 'npmjs.org',
    FontSourceKind.custom => l10n.appearance_fontSourceCustom,
  };
}

class _FontSourceTile extends ConsumerWidget {
  const _FontSourceTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(fontDownloadProvider);
    return ListTile(
      leading: Icon(
        Symbols.cloud_download_rounded,
        color: context.emphasis.accent,
      ),
      title: Text(context.l10n.appearance_fontSource),
      subtitle: Text(_fontSourceLabel(context, service.sourceKind)),
      trailing: const Icon(Symbols.chevron_right_rounded),
      onTap: () => showAppBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => const _FontSourceSheet(),
      ),
    );
  }
}

class _FontSourceSheet extends ConsumerStatefulWidget {
  const _FontSourceSheet();

  @override
  ConsumerState<_FontSourceSheet> createState() => _FontSourceSheetState();
}

class _FontSourceSheetState extends ConsumerState<_FontSourceSheet> {
  late final TextEditingController _template = TextEditingController(
    text: FontDownloadService.instance.customTemplate,
  );
  bool _testing = false;

  /// 示例模板（不翻译：URL 语法本身）。
  static const _templateExample =
      'https://mirror.example.com/npm/{pkg}@{ver}/{file}';

  @override
  void dispose() {
    _template.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    // 测速只取 1KB，用目录里任意一个字体即可
    final entry = FontCatalog.all.isEmpty ? null : FontCatalog.all.first;
    if (entry == null) return;
    setState(() => _testing = true);
    await ref.read(fontDownloadProvider).measureLatencies(entry);
    if (mounted) setState(() => _testing = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final service = ref.watch(fontDownloadProvider);
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    String? latencyText(FontSourceKind kind) {
      if (!service.latencies.containsKey(kind)) return null;
      final latency = service.latencies[kind];
      return latency == null
          ? l10n.appearance_fontSourceUnreachable
          : '${latency.inMilliseconds} ms';
    }

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.appearance_fontSource,
                        style: textTheme.titleLarge,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _testing ? null : _test,
                      icon: _testing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Symbols.speed_rounded),
                      label: Text(l10n.appearance_fontSourceTest),
                    ),
                  ],
                ),
              ),
              RadioGroup<FontSourceKind>(
                groupValue: service.sourceKind,
                onChanged: (kind) {
                  if (kind != null) service.setSource(kind);
                },
                child: Column(
                  children: [
                    for (final kind in FontSourceKind.values)
                      RadioListTile<FontSourceKind>(
                        value: kind,
                        title: Text(_fontSourceLabel(context, kind)),
                        secondary: switch (latencyText(kind)) {
                          final text? => Text(
                            text,
                            style: textTheme.labelMedium?.copyWith(
                              color: service.latencies[kind] == null
                                  ? cs.error
                                  : cs.onSurfaceVariant,
                            ),
                          ),
                          null => null,
                        },
                      ),
                  ],
                ),
              ),
              if (service.sourceKind == FontSourceKind.custom)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                  child: TextField(
                    controller: _template,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: l10n.appearance_fontSourceCustom,
                      helperText: l10n.appearance_fontSourceCustomHint,
                      helperMaxLines: 2,
                      hintText: _templateExample,
                      errorText:
                          _template.text.isEmpty ||
                              FontSource.isValidTemplate(_template.text)
                          ? null
                          : l10n.appearance_fontInvalidSource,
                    ),
                    onChanged: (value) {
                      setState(() {});
                      if (FontSource.isValidTemplate(value)) {
                        service.setSource(
                          FontSourceKind.custom,
                          customTemplate: value,
                        );
                      }
                    },
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
