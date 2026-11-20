import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/s.dart';
import '../../../../services/toast_service.dart';
import '../../market/metaverse_market_provider.dart';
import '../metaverse_plugin_installer.dart';
import '../metaverse_plugin_manifest.dart';
import '../metaverse_plugin_store.dart';
import '../providers/metaverse_plugin_providers.dart';
import 'metaverse_plugin_dialogs.dart';

class MetaverseRestorePage extends ConsumerStatefulWidget {
  const MetaverseRestorePage({super.key});
  @override
  ConsumerState<MetaverseRestorePage> createState() => _RestoreState();
}

class _RestoreState extends ConsumerState<MetaverseRestorePage> {
  String? _busy;
  Future<void> _restore(Map<String, dynamic> item) async {
    final manifest = item['manifest'] as Map;
    setState(() => _busy = manifest['id'] as String);
    try {
      final controller = ref.read(metaversePluginsProvider.notifier);
      final installer = MetaversePluginInstaller(
        network: ref.read(metaversePluginNetworkProvider),
        reservedHosts: ref.read(metaversePluginStoreProvider).reservedHosts,
      );
      final source = item['source'] as String;
      final MetaversePluginPackage package;
      if (source.startsWith('file:')) {
        final file = await FilePicker.pickFile();
        if (file == null) return;
        package = await installer.importBundle(file.readAsByteStream());
      } else if (ref
          .read(metaverseMarketProvider)
          .sources
          .any((s) => s.enabled && s.id == source)) {
        await ref.read(metaverseMarketProvider.notifier).refresh(force: true);
        final entry = ref
            .read(metaverseMarketProvider)
            .entries
            .where(
              (e) =>
                  e.source.id == source &&
                  e.id == manifest['id'] &&
                  e.channel == 'stable' &&
                  e.compatible,
            )
            .firstOrNull;
        if (!mounted) return;
        if (entry == null)
          throw StateError(context.l10n.metaverse_restoreSourceRequired);
        package = await ref
            .read(metaverseMarketProvider.notifier)
            .download(entry);
      } else if (Uri.parse(source).path.endsWith('/plugin.json')) {
        package = await installer.fetch(source);
      } else {
        if (!mounted) return;
        throw StateError(context.l10n.metaverse_restoreSourceRequired);
      }
      if (!mounted) return;
      final choices = await showMetaversePluginInstallSheet(
        context,
        package.manifest,
        package: package,
        previous: InstalledMetaversePlugin(
          manifest: MetaversePluginManifest.parse(
            item['manifest'],
            allowLegacyMetadata: true,
          ),
          source: source,
          publisherKey: item['publisherKey'] as String?,
        ),
        isUpdate: controller.byId(package.manifest.id) != null,
        reviewNote: context.l10n.metaverse_restoreNote,
      );
      if (choices == null) return;
      await controller.restoreBackup(package, item, choices);
      if (mounted) ToastService.showSuccess(context.l10n.metaverse_restoreDone);
    } catch (error) {
      if (mounted)
        ToastService.showError(
          '${context.l10n.metaverse_restoreFailed}\n$error',
        );
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n.metaverse_restorePlugins)),
    body: ref
        .watch(metaversePendingRestoreProvider)
        .when(
          loading: () => const Center(child: LoadingSpinner()),
          error: (_, _) => AppEmptyState(
            icon: const Icon(Symbols.error_outline_rounded),
            title: context.l10n.metaverse_restoreFailed,
          ),
          data: (items) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(context.l10n.metaverse_restoreNote),
              const SizedBox(height: 16),
              if (items.isEmpty)
                AppEmptyState(
                  icon: const Icon(Symbols.restore_rounded),
                  title: context.l10n.metaverse_restoreEmpty,
                ),
              SegmentedCardGroup(
                children: [
                  for (final item in items)
                    ListTile(
                      title: Text(item['manifest']['name'] as String),
                      subtitle: Text(item['source'] as String),
                      leading: _busy == item['manifest']['id']
                          ? const LoadingSpinner(size: 24)
                          : const Icon(Symbols.restore_rounded),
                      onTap: _busy == null ? () => _restore(item) : null,
                      trailing: IconButton(
                        icon: const Icon(Symbols.close_rounded),
                        tooltip: context.l10n.common_remove,
                        onPressed: _busy != null
                            ? null
                            : () async {
                                (await ref.read(
                                  metaversePluginBackupProvider.future,
                                )).remove(item['manifest']['id'] as String);
                                ref.invalidate(metaversePendingRestoreProvider);
                              },
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
  );
}
