import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../../l10n/s.dart';
import '../../../../pages/app_logs_page.dart';
import '../../../../services/toast_service.dart';
import '../../../../utils/dialog_utils.dart';
import '../../developer/metaverse_developer_page.dart';
import '../providers/metaverse_plugin_providers.dart';
import 'metaverse_plugin_dialogs.dart';
import 'metaverse_plugin_tile.dart';

class MetaversePluginManagementPage extends ConsumerWidget {
  const MetaversePluginManagementPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = ref.watch(metaversePluginsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.metaverse_pluginManage),
        actions: [
          SwipeDismissiblePopupMenuButton<VoidCallback>(
            onSelected: (action) => action(),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: () => Navigator.of(context).push(
                  InteractionPageRoute(
                    builder: (_) => const MetaverseDeveloperPage(),
                  ),
                ),
                child: Text(context.l10n.metaverse_developerCenter),
              ),
            ],
          ),
        ],
      ),
      body: installed.isEmpty
          ? AppEmptyState(
              icon: const Icon(Symbols.extension_rounded),
              title: context.l10n.metaverse_marketEmpty,
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: installed.length,
              itemBuilder: (context, index) {
                final plugin = installed[index];
                return SegmentedCardItem(
                  index: index,
                  count: installed.length,
                  gap: 3,
                  color: PageBackgroundScope.contentColor(
                    context,
                    Theme.of(context).colorScheme.surfaceContainerLow,
                  ),
                  child: MetaversePluginTile(
                    name: plugin.manifest.name,
                    icon: plugin.manifest.icon,
                    metadata:
                        '${plugin.manifest.author} · ${plugin.manifest.version}',
                    trailing: const Icon(Symbols.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      InteractionPageRoute(
                        builder: (_) =>
                            MetaversePluginSettingsPage(pluginId: plugin.id),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class MetaversePluginSettingsPage extends ConsumerStatefulWidget {
  const MetaversePluginSettingsPage({super.key, required this.pluginId});
  final String pluginId;

  @override
  ConsumerState<MetaversePluginSettingsPage> createState() =>
      _PluginSettingsState();
}

class _PluginSettingsState extends ConsumerState<MetaversePluginSettingsPage> {
  bool _busy = false;
  late Future<int> _size;

  @override
  void initState() {
    super.initState();
    _size = ref.read(metaversePluginStoreProvider).localBytes(widget.pluginId);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) {
        setState(
          () => _size = ref
              .read(metaversePluginStoreProvider)
              .localBytes(widget.pluginId),
        );
      }
    } catch (error) {
      if (mounted) ToastService.showError('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset(String name) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.metaverse_resetPluginData),
        content: Text(
          dialogContext.l10n.metaverse_resetPluginDataConfirm(name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(dialogContext.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(dialogContext.l10n.common_confirm),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run(
        () => ref
            .read(metaversePluginsProvider.notifier)
            .resetData(widget.pluginId),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final installed = ref.watch(metaversePluginsProvider);
    final matches = installed.where((plugin) => plugin.id == widget.pluginId);
    final plugin = matches.firstOrNull;
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(plugin?.manifest.name ?? l.metaverse_pluginManage),
      ),
      body: plugin == null
          ? AppEmptyState(
              icon: const Icon(Symbols.extension_rounded),
              title: l.metaverse_marketEmpty,
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  plugin.manifest.description,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 16),
                SegmentedCardGroup(
                  color: PageBackgroundScope.contentColor(
                    context,
                    Theme.of(context).colorScheme.surfaceContainerLow,
                  ),
                  children: [
                    M3eSwitchListTile(
                      title: Text(l.common_enable),
                      value: plugin.enabled,
                      onChanged: _busy
                          ? null
                          : (value) => _run(
                              () => ref
                                  .read(metaversePluginsProvider.notifier)
                                  .setEnabled(plugin.id, enabled: value),
                            ),
                    ),
                    ListTile(
                      title: Text(
                        l.metaverse_pluginAuthor(
                          plugin.manifest.author,
                          plugin.manifest.version,
                        ),
                      ),
                    ),
                    ListTile(
                      title: Text(l.metaverse_pluginSource),
                      subtitle: SelectableText(plugin.source),
                    ),
                    ListTile(
                      leading: const Icon(Symbols.shield_rounded),
                      title: Text(l.metaverse_marketPermissions),
                      trailing: const Icon(Symbols.chevron_right_rounded),
                      onTap: () =>
                          showMetaversePluginDetails(context, plugin.manifest),
                    ),
                    ListTile(
                      leading: const Icon(Symbols.receipt_long_rounded),
                      title: Text(l.metaverse_pluginLogs),
                      trailing: const Icon(Symbols.chevron_right_rounded),
                      onTap: () => Navigator.of(context).push(
                        InteractionPageRoute(
                          builder: (_) => AppLogsPage(
                            pluginId: plugin.id,
                            pluginName: plugin.manifest.name,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                SegmentedCardGroup(
                  color: PageBackgroundScope.contentColor(
                    context,
                    Theme.of(context).colorScheme.surfaceContainerLow,
                  ),
                  children: [
                    FutureBuilder<int>(
                      future: _size,
                      builder: (context, snapshot) => ListTile(
                        leading: const Icon(Symbols.storage_rounded),
                        title: Text(l.metaverse_pluginData),
                        subtitle: snapshot.hasData
                            ? Text(
                                l.metaverse_pluginStorageSize(
                                  '${(snapshot.data! / 1024).toStringAsFixed(1)} KiB',
                                ),
                              )
                            : null,
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Symbols.restart_alt_rounded),
                      title: Text(l.metaverse_resetPluginData),
                      onTap: _busy ? null : () => _reset(plugin.manifest.name),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                SegmentedCardGroup(
                  children: [
                    ListTile(
                      leading: const Icon(Symbols.delete_rounded),
                      title: Text(l.common_remove),
                      onTap: _busy
                          ? null
                          : () async {
                              if (await showMetaversePluginRemoveDialog(
                                    context,
                                    plugin.manifest,
                                  ) &&
                                  mounted) {
                                await _run(
                                  () => ref
                                      .read(metaversePluginsProvider.notifier)
                                      .remove(plugin.id),
                                );
                              }
                            },
                    ),
                  ],
                ),
                if (_busy) const LinearProgressIndicator(),
              ],
            ),
    );
  }
}
