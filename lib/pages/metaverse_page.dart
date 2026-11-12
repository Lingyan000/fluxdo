import 'package:app_icons/app_icons.dart';
import 'package:file_picker/file_picker.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../l10n/s.dart';
import '../modules/metaverse/core/metaverse_service.dart';
import '../modules/metaverse/metaverse_registry.dart';
import '../modules/metaverse/plugin/metaverse_plugin_installer.dart';
import '../modules/metaverse/plugin/providers/metaverse_plugin_providers.dart';
import '../modules/metaverse/plugin/ui/metaverse_plugin_dialogs.dart';
import '../services/toast_service.dart';

/// 元宇宙：官方服务与第三方插件服务的统一入口。
///
/// 页面本身不认识任何具体服务，只遍历 [metaverseServicesProvider]；新增官方
/// 服务或安装第三方插件都不需要改这里。
class MetaversePage extends ConsumerStatefulWidget {
  const MetaversePage({super.key});

  @override
  ConsumerState<MetaversePage> createState() => _MetaversePageState();
}

class _MetaversePageState extends ConsumerState<MetaversePage> {
  /// 正在开启/停用/授权的服务。
  final _processing = <String>{};
  bool _installing = false;

  ProviderContainer get _container =>
      ProviderScope.containerOf(context, listen: false);

  @override
  void initState() {
    super.initState();
    // 每次进入页面时刷新已开启服务的数据。
    final container = ProviderScope.containerOf(context, listen: false);
    for (final service in ref.read(metaverseServicesProvider)) {
      service.refresh(container, isActive: () => mounted);
    }
  }

  /// 串行化同一服务上的操作，并统一处理提示。
  Future<void> _run(
    MetaverseService service,
    Future<String?> Function() action,
  ) async {
    if (_processing.contains(service.id)) return;
    setState(() => _processing.add(service.id));
    try {
      final message = await action();
      if (message != null && mounted) ToastService.showSuccess(message);
    } catch (e) {
      if (mounted) {
        ToastService.showError(S.current.metaverse_authFailed(e.toString()));
      }
    } finally {
      if (mounted) setState(() => _processing.remove(service.id));
    }
  }

  Future<void> _enable(MetaverseService service) => _run(service, () async {
    final enabled = await service.enable(context, _container);
    return enabled ? service.enabledMessage() : null;
  });

  Future<void> _disable(MetaverseService service) => _run(service, () async {
    await service.disable(_container);
    return null;
  });

  Future<void> _reauthorize(MetaverseService service) =>
      _run(service, () async {
        final done = await service.reauthorize(context, _container);
        return done ? service.reauthorizedMessage() : null;
      });

  Future<void> _remove(MetaverseService service) => _run(service, () async {
    await service.remove(_container);
    return null;
  });

  Future<void> _installPlugin() async {
    if (_installing) return;
    setState(() => _installing = true);
    try {
      final installer = MetaversePluginInstaller(
        network: ref.read(metaversePluginNetworkProvider),
        reservedHosts: ref.read(metaversePluginStoreProvider).reservedHosts,
      );
      final bundled = await installer.bundledPackages(
        DefaultAssetBundle.of(context),
      );
      if (!mounted) return;
      final choice = await showMetaversePluginUrlDialog(context, bundled);
      if (choice == null || choice.url == '' || !mounted) return;
      final MetaversePluginPackage package;
      if (choice.bundled case final MetaversePluginPackage local) {
        package = local;
      } else if (choice.url case final String address) {
        package = await installer.fetch(address);
      } else {
        final result = await FilePicker.platform.pickFiles(
          withReadStream: true,
        );
        if (result == null) return;
        final stream = result.files.single.readStream;
        if (stream == null) {
          throw const MetaversePluginInstallException('无法读取插件文件');
        }
        package = await installer.importBundle(stream);
      }
      if (!mounted) return;
      final controller = ref.read(metaversePluginsProvider.notifier);
      final confirmed = await showMetaversePluginInstallSheet(
        context,
        package.manifest,
        isUpdate: controller.byId(package.manifest.id) != null,
      );
      if (!confirmed) return;
      await controller.install(package);
      if (mounted) {
        ToastService.showSuccess(
          S.current.metaverse_pluginInstalled(package.manifest.name),
        );
      }
    } catch (e) {
      if (mounted) {
        ToastService.showError(
          S.current.metaverse_pluginInstallFailed(e.toString()),
        );
      }
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final services = ref.watch(metaverseServicesProvider);
    final container = _container;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: Text(context.l10n.metaverse_title),
            centerTitle: false,
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                Padding(
                  padding: const EdgeInsets.only(bottom: 16, top: 8),
                  child: Text(
                    context.l10n.metaverse_myServices,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                for (final service in services)
                  ..._buildService(context, service, container),
                _buildAddServiceItem(theme),
                const SizedBox(height: 100), // 底部留白
              ]),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildService(
    BuildContext context,
    MetaverseService service,
    ProviderContainer container,
  ) {
    final isProcessing = _processing.contains(service.id);
    if (!service.isEnabled(container)) {
      return [
        _buildConnectCard(context, service, isProcessing),
        const SizedBox(height: 16),
      ];
    }
    final extras = service.buildExtras(context);
    return [
      KeyedSubtree(
        key: ValueKey('metaverse-service-${service.id}'),
        child: service.buildCard(
          context,
          MetaverseCardHost(
            isProcessing: isProcessing,
            onDisable: () => _disable(service),
            onReauthorize: () => _reauthorize(service),
            onRemove: service.canRemove ? () => _remove(service) : null,
          ),
        ),
      ),
      const SizedBox(height: 16),
      if (extras != null) ...[extras, const SizedBox(height: 16)],
    ];
  }

  /// 未开启状态：展示连接卡片。
  Widget _buildConnectCard(
    BuildContext context,
    MetaverseService service,
    bool isProcessing,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shape = RoundedSuperellipseBorder(
      borderRadius: context.shapes.borderRadius(24),
    );
    return Card(
      color: scheme.surfaceContainerHigh,
      shape: shape,
      child: InkWell(
        onTap: isProcessing ? null : () => _enable(service),
        customBorder: shape,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: ShapeDecoration(
                  color: service.useTertiaryTone
                      ? scheme.tertiaryContainer
                      : scheme.primaryContainer,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: context.shapes.borderRadius(16),
                  ),
                ),
                child: Icon(
                  service.icon,
                  size: 32,
                  color: service.useTertiaryTone
                      ? scheme.onTertiaryContainer
                      : scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      service.title(context),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      service.isThirdParty
                          ? '${context.l10n.metaverse_thirdParty} · '
                                '${service.description(context)}'
                          : service.description(context),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (isProcessing)
                const LoadingSpinner(size: 24)
              else ...[
                if (service.canRemove)
                  IconButton(
                    tooltip: context.l10n.common_remove,
                    icon: const Icon(Symbols.delete_rounded),
                    onPressed: () => _confirmRemove(service),
                  ),
                FilledButton(
                  onPressed: () => _enable(service),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(context.l10n.common_enable),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmRemove(MetaverseService service) async {
    final plugin = ref.read(metaversePluginsProvider.notifier).byId(service.id);
    if (plugin == null) return;
    if (await showMetaversePluginRemoveDialog(context, plugin.manifest)) {
      await _remove(service);
    }
  }

  /// 添加第三方服务的入口。
  Widget _buildAddServiceItem(ThemeData theme) {
    final shape = RoundedSuperellipseBorder(
      borderRadius: context.shapes.borderRadius(16),
    );
    return Card(
      color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.5),
      shape: shape,
      child: InkWell(
        onTap: _installing ? null : _installPlugin,
        customBorder: shape,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Center(
            child: Column(
              children: [
                if (_installing)
                  const LoadingSpinner(size: 32)
                else
                  Icon(
                    Symbols.add_rounded,
                    size: 32,
                    color: theme.colorScheme.outline,
                  ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.metaverse_addService,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  context.l10n.metaverse_addServiceDesc,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
