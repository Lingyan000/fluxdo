import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/s.dart';
import '../../../../pages/app_logs_page.dart';
import '../../../../services/toast_service.dart';
import '../../market/metaverse_update_page.dart';
import '../metaverse_plugin_store.dart';
import '../providers/metaverse_plugin_providers.dart';

class MetaversePluginStatus extends ConsumerWidget {
  const MetaversePluginStatus({super.key, required this.plugin, this.report});
  final InstalledMetaversePlugin plugin;
  final Map? report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    if (plugin.suspendedReason != null) {
      return Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            l.metaverse_suspendedStatus,
            style: Theme.of(context).textTheme.labelLarge
                ?.copyWith(color: Theme.of(context).colorScheme.error),
          ),
          TextButton.icon(
            icon: const Icon(Symbols.receipt_long_rounded, size: 18),
            label: Text(l.metaverse_pluginLogs),
            onPressed: () => Navigator.of(context).push(
              InteractionPageRoute(
                builder: (_) => AppLogsPage(
                  pluginId: plugin.id,
                  pluginName: plugin.manifest.localizedName(l.localeName),
                ),
              ),
            ),
          ),
          TextButton.icon(
            icon: const Icon(Symbols.play_arrow_rounded, size: 18),
            label: Text(l.metaverse_resumePlugin),
            onPressed: () async {
              try {
                await ref
                    .read(metaversePluginsProvider.notifier)
                    .resume(plugin.id);
              } catch (_) {
                if (context.mounted) {
                  ToastService.showError(l.metaverse_updateFailed);
                }
              }
            },
          ),
        ],
      );
    }
    final status = report?['source'] == plugin.source
        ? (report?['status'])
        : null;
    final label = switch (status) {
      'review' => l.metaverse_updateReview,
      'ready' => l.metaverse_updateReady,
      'failed' => l.metaverse_updateFailed,
      'withdrawn' => l.metaverse_updateWithdrawn,
      _ => null,
    };
    if (label != null) {
      return ActionChip(
        label: Text(label),
        avatar: const Icon(Symbols.system_update_rounded, size: 18),
        onPressed: () => Navigator.of(context).push(
          InteractionPageRoute(builder: (_) => const MetaverseUpdatePage()),
        ),
      );
    }
    final driver = plugin.manifest.tasks.isEmpty
        ? null
        : ref.watch(metaverseTaskDriverProvider);
    if (driver == null) return const SizedBox.shrink();
    return ValueListenableBuilder<Set<String>>(
      valueListenable: driver.runningPlugins,
      builder: (context, running, _) => running.contains(plugin.id)
          ? Text(
              l.metaverse_taskRunning,
              style: Theme.of(context).textTheme.labelMedium,
            )
          : const SizedBox.shrink(),
    );
  }
}
