import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

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
          customIconBuilder: plugin.manifest.requiredFeatures.contains('navigationBadge')
              ? (_, ref) => _badgeIcon(ref, plugin, page.id, navigation.icon) : null,
          customSelectedIconBuilder: plugin.manifest.requiredFeatures.contains('navigationBadge')
              ? (_, ref) => _badgeIcon(ref, plugin, page.id, navigation.icon) : null,
          label: (context) => plugin.manifest.text('pages.${page.id}.navigation.label', navigation.label, context.l10n.localeName),
          description: (context) =>
              plugin.enabled &&
                  plugin.suspendedReason == null &&
                  plugin.manifest.runtimeSupported
              ? plugin.manifest.localizedName(context.l10n.localeName)
              : '${plugin.manifest.localizedName(context.l10n.localeName)} · ${context.l10n.metaverse_navigationUnavailable}',
          available:
              plugin.enabled &&
              plugin.suspendedReason == null &&
              plugin.manifest.runtimeSupported,
          requiresLogin: plugin.manifest.accountScoped,
          lazy: true,
          pageBuilder: (_, active) => MetaversePluginPage(
            pluginId: plugin.id,
            page: page.id,
            workspace: true,
          ),
        ),
];

Widget _badgeIcon(WidgetRef ref, InstalledMetaversePlugin plugin, String page, String? name) {
  final driver = ref.watch(metaverseTaskDriverProvider);
  final icon = Icon(metaversePluginIcon(name ?? plugin.manifest.icon));
  if (driver == null) return icon;
  return ValueListenableBuilder<Map<String, int>>(valueListenable: driver.badges, child: icon,
    builder: (_, counts, child) {
      final count = counts[pluginNavigationId(plugin.id, page)] ?? 0;
      return Badge.count(count: count, isLabelVisible: count > 0, child: child);
    });
}
