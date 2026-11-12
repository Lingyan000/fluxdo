import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/s.dart';
import '../../../../utils/link_launcher.dart';
import '../../../../utils/dialog_utils.dart';
import '../providers/metaverse_plugin_providers.dart';
import 'metaverse_plugin_surface_view.dart';

/// 插件声明的一个独立页面。
///
/// 页面外壳（标题栏、返回）由宿主提供，插件只负责内容：导航行为和应用其它
/// 页面一致，插件出问题时也总能返回。
class MetaversePluginPage extends ConsumerWidget {
  const MetaversePluginPage({
    super.key,
    required this.pluginId,
    required this.page,
    this.params = const {},
    this.modal = false,
  });

  final String pluginId;
  final String page;
  final bool modal;
  final Map<String, Object?> params;

  static Future<void> open(
    BuildContext context,
    String pluginId,
    String page, {
    Map<String, Object?> params = const {},
  }) async {
    final plugin = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(metaversePluginsProvider.notifier).byId(pluginId);
    if (plugin?.manifest.page(page)?.modal == true) {
      final content = MetaversePluginPage(
        pluginId: pluginId,
        page: page,
        params: params,
        modal: true,
      );
      if (MediaQuery.sizeOf(context).width >= 600) {
        await showAppDialog<void>(
          context: context,
          builder: (_) => Dialog(
            clipBehavior: Clip.antiAlias,
            child: SizedBox(width: 560, height: 640, child: content),
          ),
        );
      } else {
        await showAppBottomSheet<void>(
          context: context,
          useRootNavigator: true,
          useSafeArea: true,
          isScrollControlled: true,
          clipBehavior: Clip.antiAlias,
          builder: (_) =>
              FractionallySizedBox(heightFactor: .88, child: content),
        );
      }
      return;
    }
    await Navigator.of(context).push<void>(
      InteractionPageRoute(
        builder: (_) =>
            MetaversePluginPage(pluginId: pluginId, page: page, params: params),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final plugin = ref.watch(
      metaversePluginsProvider.select((plugins) {
        for (final item in plugins) {
          if (item.id == pluginId) return item;
        }
        return null;
      }),
    );
    final spec = plugin?.manifest.page(page);
    // 由帖内链接打开时带着原始地址，给用户留一条"用浏览器打开"的退路。
    final sourceUrl = params['url'];

    final Widget body;
    if (plugin == null || spec == null || !plugin.enabled) {
      body = MetaversePluginErrorView(message: '$pluginId/$page');
    } else if (plugin.suspendedReason case final String reason) {
      body = MetaversePluginErrorView(message: reason);
    } else {
      final host = ref.read(metaversePluginHostsProvider).hostFor(plugin);
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ValueListenableBuilder<String?>(
            valueListenable: host.dnsRetryHost,
            builder: (context, name, _) => name == null
                ? const SizedBox.shrink()
                : OutlinedButton(
                    onPressed: () => host.enableDohForFailedHost(name),
                    child: Text(context.l10n.metaverse_pluginUseDoh(name)),
                  ),
          ),
          MetaversePluginSurfaceView(
            host: host,
            kind: MetaversePluginSurfaceKind.page,
            page: page,
            params: params,
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: modal ? const CloseButton() : null,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              spec?.title ?? plugin?.manifest.name ?? pluginId,
              style: theme.textTheme.titleMedium,
            ),
            if (plugin != null)
              Text(
                '${plugin.manifest.name} · ${context.l10n.metaverse_thirdParty}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          if (sourceUrl is String)
            IconButton(
              tooltip: context.l10n.metaverse_pluginOpen,
              icon: const Icon(Symbols.open_in_new_rounded),
              onPressed: () => launchExternalLink(context, sourceUrl),
            ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: body,
        ),
      ),
    );
  }
}
