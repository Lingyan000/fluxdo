import 'dart:typed_data';

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../services/toast_service.dart';
import '../../../utils/dialog_utils.dart';
import '../../../utils/link_launcher.dart';
import '../../../widgets/common/image_placeholder.dart';
import '../plugin/providers/metaverse_plugin_providers.dart';
import '../plugin/ui/metaverse_plugin_dialogs.dart';
import '../plugin/ui/metaverse_plugin_management_page.dart';
import '../plugin/ui/metaverse_plugin_tile.dart';
import '../plugin/ui/metaverse_widget_library.dart';
import 'metaverse_market_catalog.dart';
import 'metaverse_market_provider.dart';

class MetaverseMarketPage extends ConsumerStatefulWidget {
  const MetaverseMarketPage({super.key});
  @override
  ConsumerState<MetaverseMarketPage> createState() => _MarketPageState();
}

class _MarketPageState extends ConsumerState<MetaverseMarketPage>
    with AutomaticKeepAliveClientMixin {
  String _query = '';
  final _searchController = TextEditingController();
  String? _category;
  bool _updatesOnly = false;
  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final market = ref.watch(metaverseMarketProvider);
    final installed = {
      for (final plugin in ref.watch(metaversePluginsProvider))
        plugin.id: plugin,
    };
    final l = context.l10n;
    bool hasUpdate(MetaverseMarketEntry entry) {
      final plugin = installed[entry.id];
      return plugin != null &&
          plugin.source == entry.source.id &&
          entry.newerThan(plugin.manifest.version);
    }

    final query = _query.trim().toLowerCase();
    final entries = market.entries
        .where(
          (entry) =>
              (_category == null || entry.categories.contains(_category)) &&
              (!_updatesOnly || hasUpdate(entry)) &&
              '${entry.name} ${entry.summary} ${entry.author} ${entry.id}'
                  .toLowerCase()
                  .contains(query),
        )
        .toList();
    final categories = {
      for (final entry in market.entries) ...entry.categories,
    }.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: InputFieldShell(
                  radius: 24,
                  child: TextField(
                    controller: _searchController,
                    textAlignVertical: TextAlignVertical.center,
                    textInputAction: TextInputAction.search,
                    style: Theme.of(context).textTheme.bodyLarge,
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      hintText: l.metaverse_marketSearch,
                      prefixIcon: const Icon(Symbols.search_rounded),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: l.common_clear,
                              icon: const Icon(Symbols.close_rounded),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _query = '');
                              },
                            ),
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Symbols.source_rounded),
                tooltip: l.metaverse_marketSources,
                onPressed: () => Navigator.of(context).push(
                  InteractionPageRoute(
                    builder: (_) => const MetaverseMarketSourcesPage(),
                  ),
                ),
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            spacing: 8,
            children: [
              FilterChip(
                label: Text(l.metaverse_marketUpdates),
                selected: _updatesOnly,
                onSelected: (value) => setState(() => _updatesOnly = value),
              ),
              for (final category in categories)
                ChoiceChip(
                  label: Text(category),
                  selected: _category == category,
                  onSelected: (value) =>
                      setState(() => _category = value ? category : null),
                ),
            ],
          ),
        ),
        if (market.refreshing) const LinearProgressIndicator(),
        if (market.errors.isNotEmpty)
          ListTile(
            leading: const Icon(Symbols.cloud_off_rounded),
            title: Text(
              market.entries.isEmpty
                  ? l.metaverse_marketRefreshFailed
                  : l.metaverse_marketCached,
            ),
            trailing: IconButton(
              tooltip: l.common_retry,
              icon: const Icon(Symbols.refresh_rounded),
              onPressed: market.refreshing
                  ? null
                  : () => ref
                        .read(metaverseMarketProvider.notifier)
                        .refresh(force: true),
            ),
          ),
        Expanded(
          child: M3eRefreshIndicator(
            onRefresh: () =>
                ref.read(metaverseMarketProvider.notifier).refresh(force: true),
            child: entries.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 48),
                        child: AppEmptyState(
                          icon: const Icon(Symbols.extension_rounded),
                          title: l.metaverse_marketEmpty,
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return SegmentedCardItem(
                        index: index,
                        count: entries.length,
                        gap: 3,
                        color: PageBackgroundScope.contentColor(
                          context,
                          Theme.of(context).colorScheme.surfaceContainerLow,
                        ),
                        child: MetaversePluginTile(
                          name: entry.name,
                          icon: entry.icon,
                          description: entry.summary,
                          metadata: '${entry.author} · ${entry.version}',
                          trailing: hasUpdate(entry)
                              ? Tooltip(
                                  message: l.metaverse_marketUpdates,
                                  child: Icon(
                                    Symbols.update_rounded,
                                    color: context.emphasis.accent,
                                  ),
                                )
                              : installed.containsKey(entry.id)
                              ? Tooltip(
                                  message: l.metaverse_marketInstalled,
                                  child: const Icon(
                                    Symbols.check_circle_rounded,
                                  ),
                                )
                              : const Icon(Symbols.chevron_right_rounded),
                          onTap: () => Navigator.of(context).push(
                            InteractionPageRoute(
                              builder: (_) =>
                                  MetaverseMarketDetailPage(entry: entry),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class MetaverseMarketDetailPage extends ConsumerStatefulWidget {
  const MetaverseMarketDetailPage({super.key, required this.entry});
  final MetaverseMarketEntry entry;
  @override
  ConsumerState<MetaverseMarketDetailPage> createState() =>
      _MarketDetailState();
}

class _MarketDetailState extends ConsumerState<MetaverseMarketDetailPage> {
  bool _installing = false;

  Future<void> _install() async {
    if (_installing) return;
    setState(() => _installing = true);
    try {
      final package = await ref
          .read(metaverseMarketProvider.notifier)
          .download(widget.entry);
      if (!mounted) return;
      final controller = ref.read(metaversePluginsProvider.notifier);
      final previous = controller.byId(package.manifest.id);
      if (previous != null && previous.source != package.source) {
        final approved = await showAppDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(ctx.l10n.metaverse_pluginSource),
            content: Text(
              ctx.l10n.metaverse_marketSourceChange(
                previous.source,
                package.source,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(ctx.l10n.common_cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(ctx.l10n.common_confirm),
              ),
            ],
          ),
        );
        if (approved != true || !mounted) return;
      }
      if (!await showMetaversePluginInstallSheet(
        context,
        package.manifest,
        isUpdate: previous != null,
      )) {
        return;
      }
      await controller.install(package);
      if (mounted) {
        ToastService.showSuccess(
          context.l10n.metaverse_pluginInstalled(package.manifest.name),
        );
      }
    } catch (error) {
      if (mounted) ToastService.showError('$error');
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final installed = ref
        .watch(metaversePluginsProvider)
        .where((p) => p.id == entry.id)
        .firstOrNull;
    final current =
        installed != null &&
        installed.source == entry.source.id &&
        !entry.newerThan(installed.manifest.version);
    final l = context.l10n;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(entry.name)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              Icon(
                metaversePluginIcon(entry.icon),
                size: 48,
                color: context.emphasis.accent,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.name, style: theme.textTheme.headlineSmall),
                    Text(
                      '${entry.author} · ${entry.version}',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(entry.summary, style: theme.textTheme.titleMedium),
          if (entry.screenshots.isNotEmpty) ...[
            const SizedBox(height: 20),
            SizedBox(
              height: 280,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: entry.screenshots.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (_, index) =>
                    _MarketScreenshot(url: entry.screenshots[index]),
              ),
            ),
          ],
          if (entry.description.isNotEmpty) ...[
            const SizedBox(height: 20),
            SelectableText(entry.description),
          ],
          const SizedBox(height: 20),
          SegmentedCardGroup(
            color: PageBackgroundScope.contentColor(
              context,
              theme.colorScheme.surfaceContainerLow,
            ),
            children: [
              ListTile(
                title: Text(l.metaverse_marketCompatibility),
                subtitle: Text('SDK ${entry.apiVersion}'),
              ),
              ListTile(
                title: Text(l.metaverse_pluginSource),
                subtitle: SelectableText(entry.source.url),
              ),
              ListTile(
                title: Text(l.metaverse_marketRepository),
                subtitle: Text(entry.repository),
                trailing: const Icon(Symbols.open_in_new_rounded),
                onTap: () => launchExternalLink(context, entry.repository),
              ),
            ],
          ),
          if (entry.changelog.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              l.metaverse_marketChangelog,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            SelectableText(entry.changelog),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _installing || !entry.compatible
                ? null
                : current
                ? () => Navigator.of(context).push(
                    InteractionPageRoute(
                      builder: (_) =>
                          MetaversePluginSettingsPage(pluginId: entry.id),
                    ),
                  )
                : _install,
            icon: _installing
                ? const LoadingSpinner(size: 18)
                : Icon(
                    current
                        ? Symbols.settings_rounded
                        : Symbols.download_rounded,
                  ),
            label: Text(
              current
                  ? l.metaverse_pluginManage
                  : installed == null
                  ? l.metaverse_marketInstall
                  : l.metaverse_marketUpdate,
            ),
          ),
        ),
      ),
    );
  }
}

final _screenshotProvider = FutureProvider.autoDispose
    .family<Uint8List, String>((ref, url) async {
      final response = await ref
          .read(metaversePluginNetworkProvider)
          .downloadResource(Uri.parse(url), maxBytes: 8 * 1024 * 1024);
      if (response.status != 200) throw StateError('HTTP ${response.status}');
      return response.bytes;
    });

class _MarketScreenshot extends ConsumerWidget {
  const _MarketScreenshot({required this.url});
  final String url;
  @override
  Widget build(BuildContext context, WidgetRef ref) => SizedBox(
    width: 180,
    child: ClipRRect(
      borderRadius: context.shapes.borderRadius(16),
      child: ref
          .watch(_screenshotProvider(url))
          .when(
            data: (bytes) => Image.memory(
              bytes,
              fit: BoxFit.contain,
              cacheWidth: 720,
              errorBuilder: (_, _, _) => ImagePlaceholder(
                onRetry: () => ref.invalidate(_screenshotProvider(url)),
              ),
            ),
            loading: () => const ImagePlaceholder(loading: true),
            error: (_, _) => ImagePlaceholder(
              onRetry: () => ref.invalidate(_screenshotProvider(url)),
            ),
          ),
    ),
  );
}

class MetaverseMarketSourcesPage extends ConsumerStatefulWidget {
  const MetaverseMarketSourcesPage({super.key});
  @override
  ConsumerState<MetaverseMarketSourcesPage> createState() =>
      _MarketSourcesState();
}

class _MarketSourcesState extends ConsumerState<MetaverseMarketSourcesPage> {
  final _input = TextEditingController();
  bool _busy = false;
  String? _inputError;
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
    } catch (error) {
      if (mounted) ToastService.showError('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addSource() async {
    if (_busy || _input.text.trim().isEmpty) return;
    try {
      MetaverseMarketSource.fromInput(_input.text);
    } on FormatException {
      setState(() => _inputError = context.l10n.metaverse_marketSourceInvalid);
      return;
    }
    FocusScope.of(context).unfocus();
    await _run(() async {
      await ref.read(metaverseMarketProvider.notifier).addSource(_input.text);
      if (mounted) _input.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final market = ref.watch(metaverseMarketProvider);
    final controller = ref.read(metaverseMarketProvider.notifier);
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l.metaverse_marketSources)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            l.metaverse_marketSourceHint,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 12),
          InputFieldShell(
            child: TextField(
              controller: _input,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              autocorrect: false,
              textAlignVertical: TextAlignVertical.center,
              style: Theme.of(context).textTheme.bodyMedium,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.all(16),
                hintText: 'https://github.com/owner/repo',
                prefixIcon: const Icon(Symbols.link_rounded),
              ),
              onChanged: (_) => setState(() => _inputError = null),
              onSubmitted: (_) => _addSource(),
            ),
          ),
          if (_inputError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _inputError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: _busy || _input.text.trim().isEmpty
                ? null
                : _addSource,
            icon: const Icon(Symbols.add_rounded),
            label: Text(l.metaverse_marketAddSource),
          ),
          if (_busy || market.refreshing) const LinearProgressIndicator(),
          const SizedBox(height: 24),
          SegmentedCardGroup(
            color: PageBackgroundScope.contentColor(
              context,
              Theme.of(context).colorScheme.surfaceContainerLow,
            ),
            children: [
              for (final source in market.sources)
                Column(
                  children: [
                    M3eSwitchListTile(
                      title: Text(
                        source.displayName,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      subtitle: Text(
                        source.url,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      value: source.enabled,
                      onChanged: _busy
                          ? null
                          : (value) => _run(
                              () => controller.setEnabled(source.id, value),
                            ),
                    ),
                    if (market.errors[source.id] case final error?)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          error,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton.icon(
                        onPressed: _busy
                            ? null
                            : () async {
                                final confirmed = await showAppDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: Text(
                                      ctx.l10n.metaverse_marketSourceRemove,
                                    ),
                                    content: Text(source.url),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: Text(ctx.l10n.common_cancel),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: Text(ctx.l10n.common_remove),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed == true && mounted) {
                                  await _run(
                                    () => controller.removeSource(source.id),
                                  );
                                }
                              },
                        icon: const Icon(Symbols.delete_rounded),
                        label: Text(l.common_remove),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}
