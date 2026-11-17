import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/s.dart';
import '../modules/metaverse/plugin/metaverse_plugin_store.dart';
import '../modules/metaverse/plugin/providers/metaverse_plugin_providers.dart';
import '../modules/metaverse/plugin/ui/metaverse_plugin_page.dart';
import '../modules/metaverse/plugin/ui/metaverse_widget_library.dart';
import 'nav_entry.dart';
import 'nav_entry_registry.dart';

/// 导航只消费已安装插件的静态清单，不启动运行时，也不执行插件代码。
final navEntriesProvider = Provider<List<NavEntry>>(
  (ref) => [
    ...NavEntryRegistry.buildAll(),
    ...pluginNavigationEntries(ref.watch(metaversePluginsProvider)),
  ],
);

List<NavEntry> pluginNavigationEntries(
  Iterable<InstalledMetaversePlugin> plugins,
) => [
  for (final plugin in plugins)
    for (final page in plugin.manifest.pages)
      if (page.navigation case final navigation?)
        NavEntry(
          id: pluginNavigationId(plugin.id, page.id),
          kind: NavEntryKind.page,
          iconData: metaversePluginIcon(
            navigation.icon ?? plugin.manifest.icon,
          ),
          selectedIconData: metaversePluginIcon(
            navigation.icon ?? plugin.manifest.icon,
          ),
          label: (_) => navigation.label,
          description: (context) =>
              plugin.enabled &&
                  plugin.suspendedReason == null &&
                  plugin.manifest.runtimeSupported
              ? plugin.manifest.name
              : '${plugin.manifest.name} · ${context.l10n.metaverse_navigationUnavailable}',
          available:
              plugin.enabled &&
              plugin.suspendedReason == null &&
              plugin.manifest.runtimeSupported,
          requiresLogin: plugin.manifest.capabilities.forum.isNotEmpty,
          lazy: true,
          pageBuilder: (_, active) => MetaversePluginPage(
            pluginId: plugin.id,
            page: page.id,
            workspace: true,
          ),
        ),
];
