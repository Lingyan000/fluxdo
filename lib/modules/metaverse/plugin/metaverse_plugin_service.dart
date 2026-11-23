import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart' show PluginOperationCancelled;

import '../core/metaverse_link_rule.dart';
import '../core/metaverse_service.dart';
import '../../../l10n/s.dart';
import 'providers/metaverse_plugin_providers.dart';
import 'metaverse_plugin_host.dart';
import 'metaverse_plugin_manifest.dart';
import 'metaverse_plugin_permission.dart';
import 'metaverse_plugin_store.dart';
import 'ui/metaverse_plugin_dialogs.dart';
import 'ui/metaverse_plugin_management_page.dart';
import 'ui/metaverse_plugin_page.dart';
import 'ui/metaverse_plugin_surface_view.dart';
import 'ui/metaverse_widget_library.dart';

/// 第三方插件在元宇宙里的服务实现。
///
/// 开关状态、凭证由插件索引与系统安全存储持有，卡片和页面由插件声明的界面
/// 渲染；这里只负责把两者接到 [MetaverseService] 这套宿主接口上。
class MetaversePluginService extends MetaverseService {
  const MetaversePluginService(this.plugin);

  final InstalledMetaversePlugin plugin;

  MetaversePluginManifest get manifest => plugin.manifest;

  @override
  String get id => manifest.id;

  @override
  bool get isThirdParty => true;

  @override
  String title(BuildContext context) => manifest.localizedName(context.l10n.localeName);

  @override
  String description(BuildContext context) {
    if (plugin.suspendedReason != null) {
      return context.l10n.metaverse_pluginSuspended;
    }
    final author = manifest.author;
    final version = manifest.version;
    return context.l10n.metaverse_pluginAuthor(author, version);
  }

  @override
  IconData get icon => metaversePluginIcon(manifest.icon);

  @override
  bool get useTertiaryTone => true;

  @override
  bool isEnabled(ProviderContainer container) => plugin.enabled;

  @override
  bool get canRemove => true;

  @override
  List<MetaverseLinkRule> get linkRules =>
      plugin.suspendedReason != null || !manifest.runtimeSupported || !plugin.allows(MetaversePluginPermission.links)
          ? const [] : manifest.links;

  @override
  Future<bool> enable(BuildContext context, ProviderContainer container) async {
    final controller = container.read(metaversePluginsProvider.notifier);
    if (manifest.auth.required && plugin.allows(MetaversePluginPermission.serviceAccount) &&
        !await _ensureAuth(context, container)) {
      return false;
    }
    await controller.resume(id);
    await controller.setEnabled(id, enabled: true);
    return true;
  }

  @override
  Future<void> disable(ProviderContainer container) =>
      container.read(metaversePluginsProvider.notifier).setEnabled(id, enabled: false);

  @override
  Future<bool> reauthorize(
    BuildContext context,
    ProviderContainer container,
  ) async {
    if (!manifest.auth.required || !plugin.allows(MetaversePluginPermission.serviceAccount)) return false;
    return _ensureAuth(context, container);
  }

  @override
  Future<void> remove(ProviderContainer container) =>
      container.read(metaversePluginsProvider.notifier).remove(id);

  @override
  Future<void> openPage(
    BuildContext context,
    String page,
    Map<String, Object?> params,
  ) => MetaversePluginPage.open(context, id, page, params: params);

  @override
  Widget buildCard(BuildContext context, MetaverseCardHost host) =>
      MetaversePluginCard(service: this, host: host);

  @override
  String enabledMessage() => S.current.metaverse_pluginEnabled(manifest.localizedName(S.current.localeName));

  @override
  String reauthorizedMessage() =>
      S.current.metaverse_pluginReauthorized(manifest.localizedName(S.current.localeName));

  Future<bool> _ensureAuth(
    BuildContext context,
    ProviderContainer container,
  ) async {
    final controller = container.read(metaversePluginsProvider.notifier);
    final installed = controller.byId(id);
    if (installed == null || installed.source != plugin.source ||
        !installed.manifest.auth.required ||
        !installed.allows(MetaversePluginPermission.serviceAccount)) {
      return false;
    }
    final store = container.read(metaversePluginStoreProvider);
    final revision = store.tokenRevision(id);
    bool active() => context.mounted && identical(controller.byId(id), installed) &&
        store.tokenRevision(id) == revision;
    final token = await showMetaversePluginTokenDialog(context, installed.manifest);
    if (token == null || token.isEmpty || !active()) return false;
    try {
      await controller.saveToken(id, token, isActive: active);
      return true;
    } on PluginOperationCancelled {
      return false;
    }
  }
}

/// 插件卡片：外壳（图标、名称、菜单）由宿主画，内容由插件声明。
class MetaversePluginCard extends ConsumerWidget {
  const MetaversePluginCard({
    super.key,
    required this.service,
    required this.host,
  });

  final MetaversePluginService service;
  final MetaverseCardHost host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final manifest = service.manifest;
    final plugin = ref
        .watch(metaversePluginsProvider)
        .where((item) => item.id == service.id).firstOrNull;
    if (plugin == null || !plugin.enabled) return const SizedBox.shrink();

    return IgnorePointer(
      ignoring: host.isProcessing,
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: PageBackgroundScope.contentColor(
          context,
          theme.colorScheme.surfaceContainerLow,
        ),
        shape: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(24),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: RoundedSuperellipseBorder(
            borderRadius: context.shapes.borderRadius(24),
          ),
          onTap: manifest.cardPage != null &&
                  plugin.suspendedReason == null &&
                  manifest.runtimeSupported
              ? () => MetaversePluginPage.open(
                    context, manifest.id, manifest.cardPage!,
                  )
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(context, ref, plugin, manifest),
              if (!plugin.manifest.runtimeSupported)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Text(
                    context.l10n.metaverse_pluginApiUpgradeRequired,
                    style: theme.textTheme.bodyMedium,
                  ),
                )
              else if (plugin.suspendedReason != null)
                _suspended(context, ref, plugin)
              else
                _content(
                  context,
                  ref.watch(metaversePluginHostsProvider).hostFor(plugin),
                  manifest,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(
    BuildContext context,
    WidgetRef ref,
    InstalledMetaversePlugin plugin,
    MetaversePluginManifest manifest,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: ShapeDecoration(
              color: theme.colorScheme.secondaryContainer.withValues(alpha: .6),
              shape: RoundedSuperellipseBorder(
                borderRadius: context.shapes.borderRadius(12),
              ),
            ),
            child: Icon(
              metaversePluginIcon(manifest.icon),
              size: 22,
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  manifest.localizedName(context.l10n.localeName),
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  manifest.homepage == null
                      ? manifest.author
                      : Uri.parse(manifest.homepage!).host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          _menu(context, ref, manifest),
        ],
      ),
    );
  }

  Widget _menu(
    BuildContext context,
    WidgetRef ref,
    MetaversePluginManifest manifest,
  ) {
    return SwipeDismissiblePopupMenuButton<String>(
      tooltip: context.l10n.common_more,
      shape: RoundedSuperellipseBorder(
        borderRadius: context.shapes.borderRadius(12),
      ),
      onSelected: (value) async {
        switch (value) {
          case 'manage':
            await Navigator.of(context).push(InteractionPageRoute(
              builder: (_) => MetaversePluginSettingsPage(pluginId: manifest.id),
            ));
          case 'permissions':
            await Navigator.of(context).push(InteractionPageRoute(
              builder: (_) => MetaversePluginPermissionsPage(pluginId: manifest.id),
            ));
          case 'reauthorize':
            host.onReauthorize();
          case 'disable':
            host.onDisable();
          case 'remove':
            if (await showMetaversePluginRemoveDialog(context, manifest)) {
              host.onRemove?.call();
            }
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'manage', child: Text(context.l10n.metaverse_pluginManage)),
        PopupMenuItem(
          value: 'permissions',
          child: Text(context.l10n.metaverse_permissionSettings),
        ),
        if (manifest.auth.required && service.plugin.allows(MetaversePluginPermission.serviceAccount))
          PopupMenuItem(
            value: 'reauthorize',
            child: Text(context.l10n.common_reAuth),
          ),
        PopupMenuItem(
          value: 'disable',
          child: Text(context.l10n.metaverse_pluginDisable),
        ),
        PopupMenuItem(
          value: 'remove',
          child: Text(context.l10n.common_remove),
        ),
      ],
      child: const Padding(
        padding: EdgeInsets.all(8),
        child: Icon(Symbols.more_vert_rounded),
      ),
    );
  }

  Widget _suspended(
    BuildContext context,
    WidgetRef ref,
    InstalledMetaversePlugin plugin,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Symbols.warning_rounded,
                size: 18,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.l10n.metaverse_pluginSuspended,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            plugin.suspendedReason ?? '',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: () =>
                ref.read(metaversePluginsProvider.notifier).resume(plugin.id),
            child: Text(context.l10n.metaverse_pluginResume),
          ),
        ],
      ),
    );
  }

  Widget _content(
    BuildContext context,
    MetaversePluginHost pluginHost,
    MetaversePluginManifest manifest,
  ) {
    final card = manifest.cardWidget;
    if (card == null) {
      // 没有声明卡片的插件：只列出页面入口。
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Column(
          children: [
            for (final page in manifest.pages)
              ListTile(
                dense: true,
                title: Text(manifest.pageTitle(page, context.l10n.localeName)),
                trailing: const Icon(Symbols.chevron_right_rounded),
                onTap: () => MetaversePluginPage.open(
                  context,
                  manifest.id,
                  page.id,
                ),
              ),
          ],
        ),
      );
    }
    // 插件自己决定卡片多高，但给个上限，避免一个膨胀的界面把整页顶走。
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        // 外壳负责圆角；内容边界只按滚动视口裁切，避免削掉末行文字。
        child: SingleChildScrollView(
          child: MetaversePluginSurfaceView(
            host: pluginHost,
            kind: MetaversePluginSurfaceKind.card,
          ),
        ),
      ),
    );
  }
}
