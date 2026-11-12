import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../../constants.dart';
import '../../../../l10n/s.dart';
import '../../../../services/ldc_oauth_service.dart';
import '../../../../services/ldc_payment_service.dart';
import '../../../../services/network/exceptions/oauth_exception.dart';
import '../../../../utils/dialog_utils.dart';
import '../../../../providers/core_providers.dart';
import '../../../../providers/secret_store_provider.dart';
import '../../../../providers/theme_provider.dart';
import '../../../../services/network/doh/network_settings_service.dart';
import '../../../../services/network/core/net_core_bindings.dart';
import '../../../../services/network/vpn_auto_toggle_service.dart';
import '../../../../utils/link_launcher.dart';
import '../metaverse_plugin_host.dart';
import '../metaverse_connect_login.dart';
import '../metaverse_payment.dart';
import '../metaverse_checkout_types.dart';
import '../metaverse_plugin_installer.dart';
import '../metaverse_plugin_manifest.dart';
import '../metaverse_plugin_network.dart';
import '../metaverse_plugin_store.dart';
import '../runtime/flutter_js_script_engine.dart';
import '../runtime/metaverse_script_engine.dart';
import '../ui/metaverse_plugin_dialogs.dart';
import '../ui/metaverse_plugin_page.dart';
import '../ui/metaverse_payment_sheet.dart';

/// 插件数据的根目录：每个插件一个子目录。
final metaversePluginDirectoryProvider = FutureProvider<Directory>((ref) async {
  final support = await getApplicationSupportDirectory();
  return Directory(p.join(support.path, 'metaverse_plugins'));
});

final metaversePluginStoreProvider = Provider<MetaversePluginStore>((ref) {
  return MetaversePluginStore(
    preferences: ref.watch(sharedPreferencesProvider),
    secretStore: ref.watch(secretStoreProvider),
    rootDirectory: () => ref.read(metaversePluginDirectoryProvider.future),
    // 站点自己的域名不能作为插件的网络目标或链接接管对象。
    reservedHosts: [Uri.parse(AppConstants.baseUrl).host],
  );
});

final metaversePluginNetworkProvider = Provider<MetaversePluginNetwork>(
  (ref) => _createPluginNetwork(ref, localDoh: false),
);
final _pluginDohNetworkProvider = Provider<MetaversePluginNetwork>(
  (ref) => _createPluginNetwork(ref, localDoh: true),
);

MetaversePluginNetwork _createPluginNetwork(Ref ref, {required bool localDoh}) {
  final network = MetaversePluginNetwork(
    diagnosticNetwork: () =>
        'VPN=${VpnAutoToggleService.instance.vpnActive} '
        'DNS=${localDoh
            ? 'plugin-DoH'
            : NetworkSettingsService.instance.current.dohEnabled
            ? 'DoH'
            : 'system'}',
    useNetworkCore: () =>
        NetworkSettingsService.instance.coreService.isRunning &&
        NetCoreBindings.instance.supportsPluginRequests,
    lookup: (host) async {
      final settings = NetworkSettingsService.instance;
      if (localDoh) {
        final addresses = await settings.resolver.resolveAll(host);
        return [
          ...addresses.where((a) => a.type == InternetAddressType.IPv4),
          ...addresses.where((a) => a.type == InternetAddressType.IPv6),
        ];
      }
      return settings.current.dohEnabled
          ? settings.resolver.resolveAll(host)
          : InternetAddress.lookup(host);
    },
  );
  ref.onDispose(network.dispose);
  return network;
}

/// 脚本引擎工厂。测试用假引擎覆盖它，就不必加载原生库。
final metaverseScriptEngineFactoryProvider =
    Provider<MetaverseScriptEngineFactory>(
      (ref) => createMetaverseScriptEngine,
    );

/// 已安装的第三方插件（不含运行实例）。
final metaversePluginsProvider =
    NotifierProvider<
      MetaversePluginsController,
      List<InstalledMetaversePlugin>
    >(MetaversePluginsController.new);

/// 插件运行实例：按需启动脚本引擎，界面全部关闭后自动释放。
final metaversePluginHostsProvider = Provider<MetaversePluginHosts>((ref) {
  final hosts = MetaversePluginHosts(ref);
  ref.onDispose(hosts.shutdownAll);
  return hosts;
});

class MetaversePluginsController
    extends Notifier<List<InstalledMetaversePlugin>> {
  static const maxPlugins = 32;

  @override
  List<InstalledMetaversePlugin> build() => _store.loadIndex();

  MetaversePluginStore get _store => ref.read(metaversePluginStoreProvider);

  InstalledMetaversePlugin? byId(String id) {
    for (final plugin in state) {
      if (plugin.id == id) return plugin;
    }
    return null;
  }

  /// 安装（或按同一清单地址更新）一个插件。安装后默认未开启。
  ///
  /// 从别的地址装来的同 id 清单视为另一个插件：已有的本地数据与凭证一并清除，
  /// 避免新清单继承旧插件的授权。
  Future<InstalledMetaversePlugin> install(
    MetaversePluginPackage package,
  ) async {
    final manifest = package.manifest;
    final previous = byId(manifest.id);
    if (previous == null && state.length >= maxPlugins) {
      throw const MetaversePluginInstallException('已达到插件数量上限');
    }
    final changedSource = previous != null && previous.source != package.source;
    final changedPermissions =
        previous != null && !manifest.sameApprovalAs(previous.manifest);
    if (previous != null) {
      ref.read(metaversePluginHostsProvider).shutdown(manifest.id);
    }
    if (changedSource || changedPermissions) {
      await _store.deleteToken(manifest.id);
      if (changedSource) {
        await _store.clearStorage(manifest.id);
        await _store.clearOrders(manifest.id);
      }
    }
    await _store.writeCode(manifest.id, package.code);
    if (changedSource || changedPermissions) {
      await _replace(
        InstalledMetaversePlugin(manifest: manifest, source: package.source),
      );
    } else {
      // 同一来源的重复安装：保留开关状态（这些权限用户已经确认过）。
      await _replace(
        InstalledMetaversePlugin(
          manifest: manifest,
          source: package.source,
          enabled: previous?.enabled ?? false,
        ),
      );
    }
    return byId(manifest.id)!;
  }

  Future<void> setEnabled(String id, {required bool enabled}) async {
    final plugin = byId(id);
    if (plugin == null) return;
    if (!enabled) {
      // 停用即撤销授权：凭证不留在设备上。
      await _store.deleteToken(id);
      ref.read(metaversePluginHostsProvider).shutdown(id);
    }
    await _replace(plugin.copyWith(enabled: enabled));
  }

  Future<void> saveToken(String id, String token) async {
    if (byId(id)?.manifest.auth.type != MetaversePluginAuthType.token) {
      throw StateError('只有声明手填凭证的已安装插件可以保存此类凭证');
    }
    if (token.isEmpty) {
      await _store.deleteToken(id);
      return;
    }
    await _store.writeToken(id, token);
  }

  /// 脚本长时间无响应：挂起并停掉实例，等用户显式恢复。
  Future<void> suspend(String id, String reason) async {
    final plugin = byId(id);
    if (plugin == null) return;
    ref.read(metaversePluginHostsProvider).shutdown(id);
    await _replace(plugin.copyWith(suspendedReason: reason));
  }

  Future<void> resume(String id) async {
    final plugin = byId(id);
    if (plugin == null || plugin.suspendedReason == null) return;
    await _replace(plugin.copyWith(clearSuspended: true));
  }

  Future<void> remove(String id) async {
    final plugin = byId(id);
    if (plugin == null) return;
    ref.read(metaversePluginHostsProvider).shutdown(id);
    await _store.deleteFiles(id);
    await _store.clearOrders(id);
    await _store.deleteToken(id);
    await _replace(plugin, remove: true);
  }

  /// 退出登录：停掉所有插件并清除凭证（本地数据保留）。
  Future<void> signOutAll() async {
    ref.read(metaversePluginHostsProvider).shutdownAll();
    for (final plugin in [...state]) {
      await _store.deleteToken(plugin.id);
      if (plugin.enabled) {
        await _replace(plugin.copyWith(enabled: false, clearSuspended: true));
      }
    }
  }

  Future<void> _replace(
    InstalledMetaversePlugin plugin, {
    bool remove = false,
  }) async {
    final next = [...state];
    final index = next.indexWhere((item) => item.id == plugin.id);
    if (remove) {
      if (index >= 0) next.removeAt(index);
    } else if (index >= 0) {
      next[index] = plugin;
    } else {
      next.add(plugin);
    }
    state = next;
    await _store.saveIndex(next);
  }
}

/// 插件运行实例的持有者。
///
/// 是普通对象而不是 Notifier：实例的创建发生在 widget build 里，不能在那时
/// 改 provider 状态；界面也不需要随实例的创建/销毁重建。
class MetaversePluginHosts {
  MetaversePluginHosts(this._ref);

  final Ref _ref;
  final _hosts = <String, MetaversePluginHost>{};

  /// 取（必要时创建）某个插件的运行实例。
  MetaversePluginHost hostFor(InstalledMetaversePlugin plugin) {
    final existing = _hosts[plugin.id];
    if (existing != null && identical(existing.manifest, plugin.manifest)) {
      return existing;
    }
    // 清单在本次运行中被更新过：丢掉旧实例，按新清单重建。
    existing?.shutdown();
    return _hosts[plugin.id] = MetaversePluginHost(
      manifest: plugin.manifest,
      store: _ref.read(metaversePluginStoreProvider),
      network: _ref.read(metaversePluginNetworkProvider),
      dohNetwork: _ref.read(_pluginDohNetworkProvider),
      canSuggestDoh: () => !NetworkSettingsService.instance.current.dohEnabled,
      engineFactory: _ref.read(metaverseScriptEngineFactoryProvider),
      delegate: _HostDelegate(_ref, plugin.manifest),
    );
  }

  void shutdown(String pluginId) => _hosts.remove(pluginId)?.shutdown();

  void shutdownAll() {
    for (final host in _hosts.values) {
      host.shutdown();
    }
    _hosts.clear();
  }
}

class _HostDelegate extends MetaversePluginHostDelegate {
  _HostDelegate(this._ref, this._manifest);

  final Ref _ref;
  final MetaversePluginManifest _manifest;

  @override
  String? currentUsername() => _ref.read(currentUserProvider).value?.username;

  @override
  int? currentAccountId() => _ref.read(currentUserProvider).value?.id;

  bool _accountActive(int id) =>
      _ref.mounted &&
      currentAccountId() == id &&
      _ref
              .read(metaversePluginsProvider.notifier)
              .byId(_manifest.id)
              ?.enabled ==
          true;

  @override
  Future<bool> confirmOrder(
    BuildContext context,
    MetaverseCheckoutGrant grant,
    MetaverseOrderIntent intent,
  ) => showMetaverseOrderConfirmation(context, grant, intent);

  @override
  Future<bool> requestAuth(
    BuildContext context,
    MetaversePluginManifest manifest,
  ) async {
    if (manifest.auth.connect != null) {
      final account = _ref.read(currentUserProvider).value;
      if (account == null) {
        throw StateError(S.current.metaverse_nativeLoginRequired);
      }
      if (!await showMetaverseConnectConfirmation(
        context,
        manifest,
        account.username,
      )) {
        return false;
      }
      if (!context.mounted || !_accountActive(account.id)) return false;
      final login = MetaverseConnectLogin(
        _ref.read(metaversePluginNetworkProvider),
      );
      try {
        final session = await login.authorize(
          manifest,
          accountId: account.id,
          active: () => context.mounted && _accountActive(account.id),
        );
        if (!context.mounted || !_accountActive(account.id)) return false;
        await _ref
            .read(metaversePluginStoreProvider)
            .writeServiceSession(manifest.id, session);
        return true;
      } finally {
        login.dispose();
      }
    }
    final token = await showMetaversePluginTokenDialog(context, manifest);
    if (token == null || token.isEmpty) return false;
    await _ref
        .read(metaversePluginsProvider.notifier)
        .saveToken(manifest.id, token);
    return true;
  }

  @override
  Future<Object?> payOrder(
    BuildContext context,
    String orderNo, {
    bool cancel = false,
  }) async {
    final account = _ref.read(currentUserProvider).value;
    if (account == null) {
      throw StateError(S.current.metaverse_nativeLoginRequired);
    }
    final store = _ref.read(metaversePluginStoreProvider);
    return store.withOrderLock(_manifest.id, () async {
      final credit = LdcPaymentService();
      final payment = MetaversePayment(
        _manifest,
        store,
        _ref.read(metaversePluginNetworkProvider),
        credit,
        accountId: account.id,
        isActive: () => context.mounted && _accountActive(account.id),
      );
      try {
        await payment.checkSession();
        if (cancel) {
          if (!context.mounted) return null;
          final confirmed = await showAppDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(ctx.l10n.metaverse_nativeCancelOrder),
              content: Text(orderNo),
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
          if (confirmed != true) return null;
          await payment.request(orderNo, 'cancel');
          return {'state': 'cancelled'};
        }
        final oauth = LdcOAuthService();
        var needsPassword = false;
        try {
          final user = await oauth.getUserInfo(
            expectedUsername: account.username,
          );
          needsPassword = user?.isPayKey != true;
        } on OAuthExpiredException {
          if (!context.mounted ||
              !_accountActive(account.id) ||
              !await oauth.authorize(context)) {
            return null;
          }
          final user = await oauth.getUserInfo(
            expectedUsername: account.username,
          );
          needsPassword = user?.isPayKey != true;
        }
        await payment.checkSession();
        if (!context.mounted) return null;
        return await showMetaversePaymentSheet(
          context,
          payment: payment,
          orderNo: orderNo,
          username: account.username,
          needsPassword: needsPassword,
        );
      } finally {
        credit.dispose();
      }
    });
  }

  @override
  void openPage(
    BuildContext context,
    MetaversePluginManifest manifest,
    String page,
    Map<String, Object?> params,
  ) {
    MetaversePluginPage.open(context, manifest.id, page, params: params);
  }

  @override
  Future<void> openUrl(BuildContext context, Uri url) =>
      launchExternalLink(context, url.toString());

  @override
  Future<void> openWebSession(BuildContext context, Uri url) =>
      launchExternalLink(context, url.toString(), preferSessionBrowser: true);

  @override
  void toast(String message, String type) =>
      showMetaversePluginToast(_manifest.name, message, type);

  @override
  void onSuspended(String pluginId, String reason) {
    _ref.read(metaversePluginsProvider.notifier).suspend(pluginId, reason);
  }
}
