import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../../l10n/s.dart';
import '../../../../pages/app_logs_page.dart';
import '../../../../services/toast_service.dart';
import '../../../../utils/dialog_utils.dart';
import '../../developer/metaverse_developer_page.dart';
import '../../market/metaverse_update_page.dart';
import '../../market/metaverse_update_provider.dart';
import '../../market/metaverse_market_provider.dart';
import '../providers/metaverse_plugin_providers.dart';
import 'metaverse_plugin_dialogs.dart';
import 'metaverse_restore_page.dart';
import 'metaverse_plugin_tile.dart';
import 'metaverse_permission_list.dart';
import '../metaverse_plugin_permission.dart';
import '../../../../utils/time_utils.dart';
import '../metaverse_plugin_store.dart';
import '../metaverse_approval_change.dart';
import '../../../../widgets/common/app_bottom_sheet.dart';

class MetaversePluginManagementPage extends ConsumerWidget {
  const MetaversePluginManagementPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = ref.watch(metaversePluginsProvider);
    final pendingRestore = ref.watch(metaversePendingRestoreProvider).value ?? const [];
    final reports = ref.watch(metaverseUpdatesProvider).value?.reports ?? const {};
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.metaverse_pluginManage),
        actions: [
          if (pendingRestore.isNotEmpty) TextButton.icon(
            icon: const Icon(Symbols.restore_rounded), label: Text(context.l10n.metaverse_restorePlugins),
            onPressed: () => Navigator.of(context).push(InteractionPageRoute(builder: (_) => const MetaverseRestorePage())),
          ),
          SwipeDismissiblePopupMenuButton<VoidCallback>(
            onSelected: (action) => action(),
            itemBuilder: (context) => [
              PopupMenuItem(value: () => Navigator.of(context).push(InteractionPageRoute(builder: (_) => const MetaverseUpdatePage())),
                child: Text(context.l10n.metaverse_autoUpdates)),
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
                    name: plugin.manifest.localizedName(context.l10n.localeName),
                    icon: plugin.manifest.icon,
                    metadata: '${plugin.manifest.author} · ${plugin.manifest.version}${switch (reports[plugin.id]?['status']) {
                      'ready' => ' · ${context.l10n.metaverse_updateReady}',
                      'review' => ' · ${context.l10n.metaverse_updateReview}',
                      'failed' => ' · ${context.l10n.metaverse_updateFailed}',
                      'withdrawn' => ' · ${context.l10n.metaverse_updateWithdrawn}',
                      _ => '',
                    }}',
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
        setState(() {
          _size = ref
              .read(metaversePluginStoreProvider)
              .localBytes(widget.pluginId);
        });
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

  Future<void> _preference(InstalledMetaversePlugin plugin, String key, Object value) => _run(() async {
    final current = ref.read(metaversePluginsProvider.notifier).byId(plugin.id);
    if (!identical(current, plugin)) return;
    await ref.read(metaversePluginStoreProvider).setPreference(plugin.manifest, key, value);
    ref.read(metaversePluginHostsProvider).notifyConfiguration('preferences.changed', pluginId: plugin.id);
  });

  @override
  Widget build(BuildContext context) {
    final installed = ref.watch(metaversePluginsProvider);
    final matches = installed.where((plugin) => plugin.id == widget.pluginId);
    final plugin = matches.firstOrNull;
    final driver = plugin != null && (plugin.manifest.tasks.isNotEmpty || plugin.manifest.capabilities.notifications)
        ? ref.watch(metaverseTaskDriverProvider) : null;
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(plugin?.manifest.localizedName(context.l10n.localeName) ?? l.metaverse_pluginManage),
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
                  plugin.manifest.localizedDescription(context.l10n.localeName),
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                if (plugin.manifest.preferences.isNotEmpty) FutureBuilder<Map<String, Object?>>(
                  future: ref.read(metaversePluginStoreProvider).preferences(plugin.manifest),
                  builder: (context, snapshot) {
                    final values = snapshot.data;
                    if (values == null) return const SizedBox.shrink();
                    return Padding(padding: const EdgeInsets.only(top: 16), child: SegmentedCardGroup(children: [
                      for (final field in plugin.manifest.preferences)
                        if (field.type == 'toggle') M3eSwitchListTile(title: Text(plugin.manifest.text('preferences.${field.key}.title', field.title, context.l10n.localeName)), value: values[field.key] as bool,
                          onChanged: _busy ? null : (value) => _preference(plugin, field.key, value))
                        else ListTile(title: Text(plugin.manifest.text('preferences.${field.key}.title', field.title, context.l10n.localeName)), subtitle: Text(plugin.manifest.text('preferences.${field.key}.options.${values[field.key]}', field.options[values[field.key]] ?? '${values[field.key]}', context.l10n.localeName)),
                          trailing: const Icon(Symbols.chevron_right_rounded), onTap: _busy ? null : () async {
                            final Object? value;
                            if (field.type == 'choice') {
                              value = await AppBottomSheet.show<String>(context: context, title: plugin.manifest.text('preferences.${field.key}.title', field.title, context.l10n.localeName), builder: (ctx) => SingleChildScrollView(
                                child: SegmentedCardGroup(children: [for (final option in field.options.entries)
                                  ListTile(title: Text(plugin.manifest.text('preferences.${field.key}.options.${option.key}', option.value, context.l10n.localeName)), selected: values[field.key] == option.key,
                                    onTap: () => Navigator.pop(ctx, option.key))])));
                            } else {
                              value = await showAppDialog<String>(context: context, builder: (_) => _PreferenceInput(title: plugin.manifest.text('preferences.${field.key}.title', field.title, context.l10n.localeName), value: values[field.key] as String));
                            }
                            if (value != null && mounted) await _preference(plugin, field.key, value);
                          }),
                    ]));
                  }),
                const SizedBox(height: 16),
                FutureBuilder<Map<String, dynamic>>(
                  future: ref.read(metaversePluginStoreProvider).releaseStatus(plugin.id),
                  builder: (context, snapshot) => Column(children: [
                    if (snapshot.data?['reason'] == 'rollback') Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(l.metaverse_rolledBack)),
                    if (snapshot.data?['previous'] != null) ListTile(
                      leading: const Icon(Symbols.restore_rounded), title: Text(l.metaverse_rollback),
                      onTap: _busy ? null : () async {
                        final confirmed = await showAppDialog<bool>(context: context, builder: (ctx) => AlertDialog(
                          title: Text(l.metaverse_rollback), content: Text(l.metaverse_rollbackNote), actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.common_cancel)),
                            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.common_confirm)),
                          ]));
                        if (confirmed != true || !mounted) return;
                        final previous = await ref.read(metaversePluginStoreProvider).previousRelease(plugin);
                        if (previous == null || !context.mounted) return;
                        Map<MetaversePluginPermission, bool> choices = {};
                        if (!previous.manifest.canUpdateWithoutApproval(plugin.manifest) || previous.publisherKey != plugin.publisherKey) {
                          final selected = await showMetaversePluginInstallSheet(context, previous.manifest,
                            isUpdate: true, previous: plugin, confirmLabel: l.metaverse_rollback,
                            reviewNote: previous.publisherKey == null ? l.metaverse_publisherUnsigned : '${l.metaverse_publisherKey}\n${previous.publisherKey}',
                            initialBlocked: {...previous.blockedPermissions, ...plugin.blockedPermissions,
                              ...previous.manifest.declaredPermissions.where((p) => p.manageable)});
                          if (selected == null || !mounted) return;
                          choices = selected;
                        }
                        await _run(() => ref.read(metaversePluginsProvider.notifier).rollback(plugin.id,
                          expected: plugin.manifest, reviewed: true, choices: choices));
                      }),
                  ]),
                ),
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
                    if (plugin.publisherKey != null) ListTile(title: Text(l.metaverse_publisherKey), subtitle: SelectableText(plugin.publisherKey!)),
                    Consumer(builder: (context, ref, _) {
                      final updates = ref.watch(metaverseUpdatesProvider).value;
                      final supported = ref.watch(metaverseMarketProvider).sources.any((s) => s.enabled && s.id == plugin.source);
                      return M3eSwitchListTile(title: Text(l.metaverse_updateParticipation),
                        subtitle: !supported ? Text(l.metaverse_updateNoSource) : null,
                        value: supported && (updates?.allows(plugin) ?? true),
                        onChanged: _busy || !supported || updates == null ? null : (value) => _run(() =>
                          ref.read(metaverseUpdatesProvider.notifier).setAllowed(plugin, value)));
                    }),
                    if (ref.watch(metaverseUpdatesProvider).value?.reports[plugin.id]?['status'] case final String status)
                      if (status == 'ready' || status == 'review' || status == 'failed') ListTile(
                        title: Text(l.metaverse_updateView),
                        subtitle: Text(status == 'ready' ? l.metaverse_updateReady : status == 'review' ? l.metaverse_updateReview : l.metaverse_updateFailed),
                        trailing: const Icon(Symbols.chevron_right_rounded),
                        onTap: () => Navigator.of(context).push(InteractionPageRoute(builder: (_) => const MetaverseUpdatePage())),
                      ),
                    ListTile(
                      leading: const Icon(Symbols.shield_rounded),
                      title: Text(l.metaverse_permissionSettings),
                      trailing: const Icon(Symbols.chevron_right_rounded),
                      onTap: () => Navigator.of(context).push(InteractionPageRoute(
                        builder: (_) => MetaversePluginPermissionsPage(pluginId: plugin.id),
                      )),
                    ),
                    ListTile(
                      leading: const Icon(Symbols.receipt_long_rounded),
                      title: Text(l.metaverse_pluginLogs),
                      trailing: const Icon(Symbols.chevron_right_rounded),
                      onTap: () => Navigator.of(context).push(
                        InteractionPageRoute(
                          builder: (_) => AppLogsPage(
                            pluginId: plugin.id,
                            pluginName: plugin.manifest.localizedName(context.l10n.localeName),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                if (driver != null && driver.account != null && plugin.enabled)
                  ValueListenableBuilder<Map<String, int>>(
                    valueListenable: driver.badges,
                    builder: (context, _, _) {
                      final jobs = driver.control.tasks(driver.account!, plugin.id);
                      if (jobs.isEmpty) return const SizedBox.shrink();
                      return Padding(padding: const EdgeInsets.only(bottom: 24), child: SegmentedCardGroup(children: [
                        for (final job in jobs) ListTile(
                          title: Text(plugin.manifest.tasks.where((spec) => spec.id == job['id']).firstOrNull?.title ?? job['id']),
                          subtitle: Text([
                            switch (job['error']) {
                              'forum_auth_required' => l.metaverse_taskAuth,
                              'forum_rate_limited' || 'forum_forbidden' => l.metaverse_taskLimited,
                              final String _ => l.metaverse_taskRetrying,
                              _ => job['background'] == true ? l.metaverse_taskWaiting : l.metaverse_foregroundTasks,
                            },
                            '${l.metaverse_taskLastSuccess}: ${job['lastSuccessAt'] is int ? TimeUtils.formatDetailTime(DateTime.fromMillisecondsSinceEpoch(job['lastSuccessAt'] as int)) : l.metaverse_updateNotChecked}',
                            '${l.metaverse_taskNext}: ${TimeUtils.formatDetailTime(DateTime.fromMillisecondsSinceEpoch(job['nextAt'] as int))}',
                          ].join('\n')),
                          trailing: IconButton(icon: const Icon(Symbols.stop_rounded), tooltip: l.metaverse_stopTask,
                            onPressed: _busy ? null : () => _run(() => driver.stopTask(plugin.id, job['id']))),
                        ),
                      ]));
                    },
                  ),
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
                      onTap: _busy ? null : () => _reset(plugin.manifest.localizedName(context.l10n.localeName)),
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

class _PreferenceInput extends StatefulWidget {
  const _PreferenceInput({required this.title, required this.value});
  final String title, value;
  @override
  State<_PreferenceInput> createState() => _PreferenceInputState();
}
class _PreferenceInputState extends State<_PreferenceInput> {
  late final controller = TextEditingController(text: widget.value);
  @override
  void dispose() { controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AlertDialog(title: Text(widget.title),
    content: TextField(controller: controller, maxLength: 512, autofocus: true), actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l10n.common_cancel)),
      FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(context.l10n.common_confirm)),
    ]);
}

class MetaversePluginPermissionsPage extends ConsumerStatefulWidget {
  const MetaversePluginPermissionsPage({super.key, required this.pluginId});
  final String pluginId;

  @override
  ConsumerState<MetaversePluginPermissionsPage> createState() => _PluginPermissionsState();
}

class _PluginPermissionsState extends ConsumerState<MetaversePluginPermissionsPage> {
  bool _saving = false;

  Future<void> _change(MetaversePluginPermission permission, bool allowed) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await ref.read(metaversePluginsProvider.notifier).setPermission(widget.pluginId, permission, allowed);
    } catch (_) {
      if (mounted) ToastService.showError(context.l10n.metaverse_permissionSaveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final plugin = ref.watch(metaversePluginsProvider).where((p) => p.id == widget.pluginId).firstOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.metaverse_permissionSettings)),
      body: plugin == null
          ? AppEmptyState(icon: const Icon(Symbols.extension_rounded), title: context.l10n.metaverse_marketEmpty)
          : ListView(padding: const EdgeInsets.all(16), children: [
              Text(plugin.manifest.localizedName(context.l10n.localeName), style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              MetaversePermissionList(manifest: plugin.manifest, blocked: plugin.blockedPermissions,
                busy: _saving, onChanged: _change),
            ]),
    );
  }
}
