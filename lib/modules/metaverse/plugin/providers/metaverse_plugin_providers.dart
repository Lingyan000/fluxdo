import 'dart:io';
import 'dart:async';
import 'package:common_ui/common_ui.dart';
import '../../host/metaverse_forum_adapter.dart';
import '../../market/metaverse_update_store.dart';
import '../../host/metaverse_task_actions.dart';
import '../../host/metaverse_task_store.dart';
import '../../host/metaverse_task_dispatcher.dart';
import '../../../../services/background/background_notification_service.dart';
import '../../../../services/local_notification_service.dart';
import '../metaverse_forum_request.dart';
import '../../../../pages/topic_detail_page/topic_detail_page.dart';
import '../../../../pages/user_profile_page.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../../constants.dart';
import '../../../../l10n/s.dart';
import '../../../../services/log/log_writer.dart';
import '../../../../services/network/discourse_dio.dart';
import '../../../../providers/core_providers.dart';
import '../../../../providers/secret_store_provider.dart';
import '../../../../providers/theme_provider.dart';
import '../../../../providers/locale_provider.dart';
import '../../../../services/network/doh/network_settings_service.dart';
import '../../../../services/network/core/net_core_bindings.dart';
import '../../../../services/network/vpn_auto_toggle_service.dart';
import '../../../../utils/link_launcher.dart';
import '../metaverse_plugin_host.dart';
import '../metaverse_connect_capability.dart';
import '../metaverse_credential.dart';
import '../metaverse_plugin_installer.dart';
import '../metaverse_plugin_manifest.dart';
import '../metaverse_plugin_permission.dart';
import '../metaverse_plugin_capabilities.dart';
import '../metaverse_plugin_network.dart';
import '../metaverse_plugin_store.dart';
import '../metaverse_data_migration.dart';
import '../metaverse_approval_change.dart';
import '../metaverse_plugin_backup.dart';
import '../runtime/flutter_js_script_engine.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import '../ui/metaverse_plugin_dialogs.dart';
import '../ui/metaverse_plugin_page.dart';
import '../../../ldc_payment/ldc_payment_flow.dart';
import '../ui/metaverse_connect_confirmation.dart';
import '../ui/metaverse_confirmation_sheet.dart';
import '../ui/metaverse_permission_list.dart';

part 'metaverse_task_providers.dart';

/// 插件数据的根目录：每个插件一个子目录。
final metaversePluginDirectoryProvider = FutureProvider<Directory>((ref) async {
  final support = await getApplicationSupportDirectory();
  return Directory(p.join(support.path, 'metaverse_plugins'));
});

final metaversePluginBackupProvider = FutureProvider((ref) async => MetaversePluginBackup(
  await ref.watch(metaversePluginDirectoryProvider.future), reservedHosts: [Uri.parse(AppConstants.baseUrl).host]));
final metaversePendingRestoreProvider = FutureProvider((ref) async =>
  (await ref.watch(metaversePluginBackupProvider.future)).pending());

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
final metaverseForumBudgetProvider = Provider((ref) => MetaverseForumBudget());
final metaverseForumAdapterProvider = Provider((ref) => MetaverseForumAdapter(
  ref.watch(discourseServiceProvider), ref.watch(metaverseForumBudgetProvider)));

final metaversePluginHostsProvider = Provider<MetaversePluginHosts>((ref) {
  ref.watch(currentUserProvider.select((value) => value.value?.id));
  final hosts = MetaversePluginHosts(ref);
  ref.listen(localeProvider, (_, _) => hosts.notifyConfiguration('host.environmentChanged'));
  ref.onDispose(hosts.dispose);
  return hosts;
});

class MetaversePluginsController
    extends Notifier<List<InstalledMetaversePlugin>> {
  static const maxPlugins = 32;
  final _mutations = PluginOperationQueue();

  Set<MetaversePluginPermission> reviewPermissions(MetaversePluginPackage package) {
    final previous = byId(package.manifest.id);
    return InstalledMetaversePlugin.reviewPermissions(
      package.manifest,
      previous?.source == package.source && (previous?.publisherKey == null ||
        previous?.publisherKey == package.signature?.fingerprint || previous?.publisherKey == package.signature?.previousFingerprint) ? previous : null,
    );
  }

  Future<InstalledMetaversePlugin> install(MetaversePluginPackage package, {
    Map<MetaversePluginPermission, bool> choices = const {},
  }) => _mutations.run('index', () => _install(package, choices));
  /// 自动更新只发布仍在原来源、授权未变化且没有使用中界面的候选。
  Future<bool> installAutomatic(MetaversePluginPackage package,
      InstalledMetaversePlugin expected, bool Function() canApply) => _mutations.run('index', () async {
    bool valid() => identical(byId(expected.id), expected) && canApply() &&
        package.manifest.id == expected.id && package.source == expected.source &&
        package.manifest.runtimeSupported && package.manifest.canUpdateWithoutApproval(expected.manifest) &&
        (package.signature?.fingerprint == expected.publisherKey ||
          (expected.publisherKey != null && package.signature?.previousFingerprint == expected.publisherKey)) &&
        package.manifest.apiVersion == expected.manifest.apiVersion &&
        PluginVersion.parse(package.manifest.version).compareTo(PluginVersion.parse(expected.manifest.version)) > 0;
    if (!valid()) return false;
    final status = await _store.releaseStatus(expected.id);
    if ((status['rejected'] as List? ?? []).contains(MetaversePluginStore.revisionOf(package.code))) {
      throw const MetaversePluginCallException('update_rejected_version');
    }
    await _store.writeCode(expected.id, package.code);
    if (!valid()) return false;
    final next = InstalledMetaversePlugin(manifest: package.manifest, source: expected.source,
      publisherKey: package.signature?.fingerprint,
      installationId: InstalledMetaversePlugin.newInstallationId(),
      codeRevision: MetaversePluginStore.revisionOf(package.code), enabled: expected.enabled,
      suspendedReason: expected.suspendedReason, blockedPermissions: expected.blockedPermissions);
    final control = expected.manifest.tasks.isEmpty ? null : await ref.read(metaverseTaskStoreProvider.future);
    if (!valid()) return false;
    final hold = control?.holdForUpdate(expected.id);
    if (control != null && hold == null) return false;
    try {
      await _prepareRelease(expected, next, package);
      await _replace(next, publishGuard: () {
        if (!valid() || (control != null && !control.updateHeld(expected.id, hold!))) throw const PluginOperationCancelled();
      });
      await _store.settleRelease(next);
      await _store.pruneCode(next);
      await _pruneCredentials(expected.manifest, next.manifest);
      control?.applyPermissions(next);
      return true;
    } on PluginOperationCancelled { return false; }
    finally {
      try {
        final installed = byId(expected.id);
        if (installed != null) await _store.settleRelease(installed);
      } finally { if (hold != null) control!.releaseUpdate(expected.id, hold); }
    }
  });

  Future<void> setPermission(
    String id,
    MetaversePluginPermission permission,
    bool allowed,
  ) => _mutations.run('index', () async {
    final plugin = byId(id);
    if (plugin == null) throw ArgumentError.value(id, 'id');
    final blocked = plugin.manifest.applyPermissionChoices(
      plugin.blockedPermissions, {permission: allowed},
    );
    if (plugin.allows(permission) == allowed) return;
    await _replacePermissions(plugin, plugin.copyWith(blockedPermissions: blocked));
  });

  Future<void> restoreBackup(MetaversePluginPackage package, Map<String, dynamic> backup,
      Map<MetaversePluginPermission, bool> choices) => _mutations.run('index', () async {
    final old = MetaversePluginManifest.parse(backup['manifest'], reservedHosts: _store.reservedHosts, allowLegacyMetadata: true);
    if (package.manifest.id != old.id || package.source != backup['source'] ||
        PluginVersion.parse(package.manifest.version).compareTo(PluginVersion.parse(old.version)) < 0) {
      throw const MetaversePluginCallException('restore_source_mismatch');
    }
    final data = await migrateMetaverseData(package: package, fromVersion: old.dataVersion,
      data: (backup['data'] as Map).cast<String, Object?>(), engineFactory: ref.read(metaverseScriptEngineFactoryProvider));
    await _install(package, choices, restoreData: data,
      restorePreferences: (backup['preferences'] as Map? ?? const {}).cast<String, Object?>());
    MetaverseUpdateStore(await ref.read(metaversePluginDirectoryProvider.future)).setAllowed(byId(old.id)!, backup['autoUpdate'] != false);
    (await ref.read(metaversePluginBackupProvider.future)).remove(old.id);
    ref.invalidate(metaversePendingRestoreProvider);
  });
  Future<void> setEnabled(String id, {required bool enabled}) =>
      _mutations.run('index', () => _setEnabled(id, enabled: enabled));
  Future<void> grantRequested(InstalledMetaversePlugin reviewed, Set<MetaversePluginPermission> permissions,
      void Function() checkActive) => _mutations.run('index', () async {
    void check() {
      checkActive();
      if (!identical(byId(reviewed.id), reviewed) || !reviewed.enabled || reviewed.suspendedReason != null) {
        throw const PluginOperationCancelled();
      }
    }
    check();
    final blocked = reviewed.manifest.applyPermissionChoices(reviewed.blockedPermissions, {for (final p in permissions) p: true});
    await _replacePermissions(reviewed, reviewed.copyWith(blockedPermissions: blocked), grantGuard: check);
  });
  Future<void> saveToken(String id, String token, {bool Function()? isActive}) =>
      _mutations.run('index', () {
        if (isActive != null && !isActive()) throw const PluginOperationCancelled();
        return _saveToken(id, token);
      });
  Future<void> suspend(String id, String reason) =>
      _mutations.run('index', () => _suspend(id, reason));
  Future<void> resume(String id) => _mutations.run('index', () => _resume(id));
  Future<void> rollback(String id, {bool automatic = false, MetaversePluginManifest? expected, bool reviewed = false, Map<MetaversePluginPermission, bool> choices = const {}}) => _mutations.run('index', () async {
    final current = byId(id);
    if (current == null || (expected != null && !identical(expected, current.manifest))) return;
    final previous = await _store.previousRelease(current, probationOnly: automatic);
    if (previous == null) {
      if (automatic) await _suspend(id, 'plugin_start_failed');
      return;
    }
    ref.read(metaversePluginHostsProvider).shutdown(id);
    await _revokeTasks(current);
    // 回退版本不能重新取得新版本已删除的能力。
    final requiresReview = !previous.manifest.canUpdateWithoutApproval(current.manifest) || previous.publisherKey != current.publisherKey;
    if (requiresReview && !reviewed) {
      if (automatic) { await _suspend(id, 'rollback_review_required'); return; }
      throw const MetaversePluginCallException('rollback_review_required');
    }
    final restored = previous.copyWith(enabled: current.enabled && !requiresReview && !automatic,
      clearSuspended: true, blockedPermissions: previous.manifest.applyPermissionChoices(
        {...previous.blockedPermissions, ...current.blockedPermissions,
          if (requiresReview) ...previous.manifest.declaredPermissions.where((p) => p.manageable)}, choices));
    final control = _usesTaskControl(current) ? await ref.read(metaverseTaskStoreProvider.future) : null;
    final hold = control?.holdForUpdate(id);
    if (control != null && hold == null) throw const MetaversePluginCallException('update_busy');
    try {
      await _store.prepareRollback(current, restored);
      await _pruneCredentials(current.manifest, restored.manifest);
      await _replace(restored, publishGuard: () {
        if (control != null && !control.updateHeld(id, hold!)) throw const PluginOperationCancelled();
      });
    } finally {
      try { await _store.settleRelease(byId(id)!); }
      finally { if (hold != null) control!.releaseUpdate(id, hold); }
    }
    await _store.finishRollback(restored, 'rollback');
    await _pruneCredentials(current.manifest, restored.manifest);
  });
  Future<void> reloadHost(String id) => _mutations.run('index', () async {
    final plugin = byId(id);
    if (plugin != null) await _replace(plugin.copyWith());
  });
  Future<void> remove(String id) => _mutations.run('index', () => _remove(id));
  Future<void> resetData(String id) => _mutations.run('index', () => _resetData(id));
  Future<void> signOutAll() => _mutations.run('index', _signOutAll);


  @override
  List<InstalledMetaversePlugin> build() => _store.loadIndex();

  MetaversePluginStore get _store => ref.read(metaversePluginStoreProvider);

  InstalledMetaversePlugin? byId(String id) {
    for (final plugin in state) {
      if (plugin.id == id) return plugin;
    }
    return null;
  }

  /// 安装一个插件，或在用户确认后更新同源插件并保留其启用状态。
  ///
  /// 从别的地址装来的同 id 清单视为另一个插件：已有的本地数据与凭证一并清除，
  /// 避免新清单继承旧插件的授权。
  Future<InstalledMetaversePlugin> _install(
    MetaversePluginPackage package,
    Map<MetaversePluginPermission, bool> choices, {
    Map<String, Object?>? restoreData, Map<String, Object?>? restorePreferences,
  }) async {
    final manifest = package.manifest;
    if (!manifest.runtimeSupported) {
      throw MetaversePluginInstallException(
        S.current.metaverse_pluginApiUpgradeRequired,
      );
    }
    final previous = byId(manifest.id);
    if (previous == null && state.length >= maxPlugins) {
      throw const MetaversePluginInstallException('已达到插件数量上限');
    }
    final changedSource = previous != null && (previous.source != package.source ||
      (previous.publisherKey != null && package.signature?.fingerprint != previous.publisherKey &&
        package.signature?.previousFingerprint != previous.publisherKey));
    final blocked = manifest.applyPermissionChoices(
      restoreData == null ? reviewPermissions(package) : InstalledMetaversePlugin.reviewPermissions(manifest, null), choices);
    final changedPermissions =
        previous != null && !manifest.sameApprovalAs(previous.manifest);
    if (previous != null) {
      ref.read(metaversePluginHostsProvider).shutdown(manifest.id);
    }
    if (!changedSource && previous?.manifest.apiVersion == 1 && manifest.apiVersion == 2) {
      await _store.importLegacyStorage(manifest.id);
    }
    await _store.writeCode(manifest.id, package.code);
    final next = InstalledMetaversePlugin(
      manifest: manifest,
      publisherKey: package.signature?.fingerprint,
      installationId: InstalledMetaversePlugin.newInstallationId(),
      source: package.source,
      codeRevision: MetaversePluginStore.revisionOf(package.code),
      enabled: restoreData == null && !changedSource && (previous?.enabled ?? false),
      blockedPermissions: blocked,
    );
    final control = previous != null && _usesTaskControl(previous)
        ? await ref.read(metaverseTaskStoreProvider.future) : null;
    final hold = control?.holdForUpdate(manifest.id);
    if (control != null && hold == null) throw const MetaversePluginCallException('update_busy');
    try {
      if (restoreData != null || changedSource || previous == null) {
        await _store.prepareRelease(previous, next, restoreData ?? {}, reset: true,
          preferences: {for (final field in manifest.preferences)
            if (field.accepts(restorePreferences?[field.key])) field.key: restorePreferences![field.key]});
      } else {
        await _prepareRelease(previous, next, package);
      }
      void guard() {
        if (control != null && !control.updateHeld(manifest.id, hold!)) {
          throw const MetaversePluginCallException('update_busy');
        }
      }
      if (previous != null && !changedSource && changedPermissions) await _pruneCredentials(previous.manifest, manifest);
      if (previous != null && previous.allows(MetaversePluginPermission.serviceAccount) != next.allows(MetaversePluginPermission.serviceAccount)) {
        await _store.deleteToken(manifest.id);
      }
      await _replace(next, publishGuard: guard);
      await _store.settleRelease(next);
      if (previous != null && (changedSource || changedPermissions || restoreData != null)) {
        await _revokeTasks(previous);
      }
      control?.applyPermissions(next);
    } finally {
      try {
        final installed = byId(manifest.id);
        if (installed != null) await _store.settleRelease(installed);
      } finally { if (hold != null) control!.releaseUpdate(manifest.id, hold); }
    }
    if (previous != null && !changedSource) await _pruneCredentials(previous.manifest, manifest);
    await _store.pruneCode(next);
    return byId(manifest.id)!;
  }

  Future<void> _prepareRelease(InstalledMetaversePlugin previous, InstalledMetaversePlugin next,
      MetaversePluginPackage package) async {
    await _store.settleRelease(previous);
    final data = await migrateMetaverseData(package: package, fromVersion: previous.manifest.dataVersion,
      data: await _store.readStorage(previous.id), engineFactory: ref.read(metaverseScriptEngineFactoryProvider));
    await _store.prepareRelease(previous, next, data);
  }

  Future<void> _pruneCredentials(MetaversePluginManifest old, MetaversePluginManifest next) async {
    if (old.auth.type != next.auth.type || old.auth.header != next.auth.header || old.auth.scheme != next.auth.scheme ||
        (old.auth.canAttachCredential && !next.canUpdateWithoutApproval(old)) ||
        !old.capabilities.connectCallbacks.toSet().containsAll(next.capabilities.connectCallbacks)) {
      await _store.deleteToken(next.id);
      return;
    }
    for (final entry in old.capabilities.credentials.entries) {
      final spec = next.capabilities.credentials[entry.key];
      if (spec == null || !spec.isWithin(entry.value)) await _store.removeCredential(next.id, entry.key);
    }
  }

  Future<void> _setEnabled(String id, {required bool enabled}) async {
    final plugin = byId(id);
    if (plugin == null) return;
    if (enabled && plugin.suspendedReason == 'rollback_review_required') throw const MetaversePluginCallException('rollback_review_required');
    if (!enabled) {
      // 停用即撤销授权：凭证不留在设备上。
      ref.read(metaversePluginHostsProvider).shutdown(id);
      await _revokeTasks(plugin);
      await _store.deleteToken(id);
    }
    await _replace(plugin.copyWith(enabled: enabled));
  }

  Future<void> _saveToken(String id, String token) async {
    if (byId(id)?.manifest.auth.type != MetaversePluginAuthType.token) {
      throw StateError('只有声明手填凭证的已安装插件可以保存此类凭证');
    }
    if (token.isEmpty) {
      await _store.deleteToken(id);
      return;
    }
    if (!byId(id)!.allows(MetaversePluginPermission.serviceAccount)) {
      throw const MetaversePluginCallException('permission_denied:serviceAccount');
    }
    await _store.writeToken(id, token);
  }

  /// 脚本长时间无响应：挂起并停掉实例，等用户显式恢复。
  Future<void> _suspend(String id, String reason) async {
    final plugin = byId(id);
    if (plugin == null) return;
    ref.read(metaversePluginHostsProvider).shutdown(id);
    await _revokeTasks(plugin);
    await _replace(plugin.copyWith(suspendedReason: reason));
  }

  Future<void> _resume(String id) async {
    final plugin = byId(id);
    if (plugin == null || plugin.suspendedReason == null) return;
    if (plugin.suspendedReason == 'rollback_review_required') throw const MetaversePluginCallException('rollback_review_required');
    await _replace(plugin.copyWith(clearSuspended: true));
  }

  Future<void> _remove(String id) async {
    final plugin = byId(id);
    if (plugin == null) return;
    ref.read(metaversePluginHostsProvider).shutdown(id);
    await _revokeTasks(plugin);
    await _store.deleteFiles(id);
    await _store.clearLegacyRecords(id);
    await _store.deleteToken(id);
    await LogWriter.instance.clearPlugin(id);
    await _replace(plugin, remove: true);
  }

  Future<void> _resetData(String id) async {
    final plugin = byId(id);
    if (plugin == null) return;
    ref.read(metaversePluginHostsProvider).shutdown(id);
    await _revokeTasks(plugin);
    await _store.resetData(id);
    await _store.clearReleaseHistory(id);
    await _replace(plugin.copyWith(enabled: false, clearSuspended: true));
  }

  /// 退出登录：停掉所有插件并清除凭证（本地数据保留）。
  Future<void> _signOutAll() async {
    ref.read(metaversePluginHostsProvider).shutdownAll();
    for (final plugin in [...state]) {
      await _revokeTasks(plugin);
      await _store.deleteToken(plugin.id);
      if (plugin.enabled) {
        await _replace(plugin.copyWith(enabled: false, clearSuspended: true));
      }
    }
  }

  Future<void> _revokeTasks(InstalledMetaversePlugin plugin) async {
    if (!_usesTaskControl(plugin)) return;
    final control = await ref.read(metaverseTaskStoreProvider.future);
    final dismissed = control.notificationIds(plugin.id);
    control.revoke(plugin.id);
    await _dismissTaskNotifications(dismissed);
  }

  Future<void> _replacePermissions(
    InstalledMetaversePlugin previous,
    InstalledMetaversePlugin next, {void Function()? grantGuard}
  ) async {
    const account = MetaversePluginPermission.serviceAccount;
    if (previous.blockedPermissions.contains(account) && next.allows(account)) {
      await _store.deleteToken(next.id);
    }
    final control = _usesTaskControl(next)
        ? await ref.read(metaverseTaskStoreProvider.future)
        : null;
    // 后台只接受索引和租约中策略一致的任务。先撤销旧租约，再公布新索引。
    grantGuard?.call();
    final dismissed = control?.applyPermissions(next) ?? const <int>[];
    try {
      await _replace(next, grantGuard: grantGuard);
    } catch (_) {
      control?.applyPermissions(previous);
      rethrow;
    } finally {
      await _dismissTaskNotifications(dismissed);
    }
    // 如果安全存储暂不可用，访问仍然被禁止，再次开启前也要完成清理。
    if (previous.allows(account) && !next.allows(account)) {
      await _store.deleteToken(next.id);
    }
  }

  Future<void> _replace(
    InstalledMetaversePlugin plugin, {
    bool remove = false,
    void Function()? grantGuard,
    void Function()? publishGuard,
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
    publishGuard?.call();
    await _store.saveIndex(next);
    try { publishGuard?.call(); }
    catch (_) { await _store.saveIndex(state); rethrow; }
    if (grantGuard != null) {
      try {
        grantGuard();
      } catch (_) {
        await _store.saveIndex(state);
        rethrow;
      }
      ref.read(metaversePluginHostsProvider).applyGrant(plugin);
      state = next;
      return;
    }
    // 持久化期间旧页面仍可能打开实例。公布新策略前统一收回它的授权。
    if (ref.read(metaversePluginHostsProvider.exists)) {
      ref.read(metaversePluginHostsProvider).shutdown(plugin.id);
    }
    state = next;
  }
}

/// 插件运行实例的持有者。
///
/// 是普通对象而不是 Notifier：实例的创建发生在 widget build 里，不能在那时
/// 改 provider 状态；界面也不需要随实例的创建/销毁重建。
class MetaversePluginHosts with WidgetsBindingObserver {
  MetaversePluginHosts(this._ref) { WidgetsBinding.instance.addObserver(this); }

  @override
  void didChangeLocales(List<Locale>? locales) => notifyConfiguration('host.environmentChanged');
  void dispose() { WidgetsBinding.instance.removeObserver(this); shutdownAll(); }
  final Ref _ref;
  final _hosts = <String, MetaversePluginHost>{};
  void notifyConfiguration(String event, {String? pluginId}) {
    for (final host in _hosts.values.where((h) => pluginId == null || h.id == pluginId)) { host.notifyConfiguration(event); }
  }

  /// 取（必要时创建）某个插件的运行实例。
  MetaversePluginHost hostFor(InstalledMetaversePlugin requested) {
    final plugin = _ref.read(metaversePluginsProvider.notifier).byId(requested.id);
    if (plugin == null || !plugin.enabled || plugin.suspendedReason != null) {
      throw const PluginOperationCancelled();
    }
    final existing = _hosts[plugin.id];
    if (existing != null &&
        identical(existing.manifest, plugin.manifest) &&
        identical(existing.blockedPermissions, plugin.blockedPermissions)) {
      return existing;
    }
    // 清单在本次运行中被更新过：丢掉旧实例，按新清单重建。
    existing?.retire();
    return _hosts[plugin.id] = newHost(plugin);
  }

  MetaversePluginHost newHost(InstalledMetaversePlugin plugin, {bool worker = false}) => MetaversePluginHost(
      manifest: plugin.manifest,
      blockedPermissions: plugin.blockedPermissions,
      store: _ref.read(metaversePluginStoreProvider),
      codeLoader: plugin.codeRevision == null ? null : () => _ref.read(metaversePluginStoreProvider).readCodeRevision(plugin.id, plugin.codeRevision!),
      network: _ref.read(metaversePluginNetworkProvider),
      dohNetwork: _ref.read(_pluginDohNetworkProvider),
      canSuggestDoh: () => !NetworkSettingsService.instance.current.dohEnabled,
      engineFactory: _ref.read(metaverseScriptEngineFactoryProvider),
      delegate: _HostDelegate(_ref, plugin.manifest, worker: worker),
    );

  bool isInUse(String id) => _hosts[id]?.hasUpdateBlocker ?? false;
  bool closeForUpdate(String id) {
    if (_hosts[id]?.hasPendingInteraction == true) return false;
    shutdown(id);
    return true;
  }

  void notifyTaskUpdated(String id) => _hosts[id]?.notifyTaskUpdated();
  void applyGrant(InstalledMetaversePlugin plugin) => _hosts[plugin.id]?.applyGrantedPermissions(plugin.blockedPermissions);

  void shutdown(String pluginId) => _hosts.remove(pluginId)?.retire();

  void refreshVisibleCards() {
    for (final host in _hosts.values) { host.refreshVisibleCards(); }
  }

  void shutdownAll() {
    for (final host in _hosts.values) {
      host.retire();
    }
    _hosts.clear();
  }
}

class _HostDelegate extends MetaversePluginHostDelegate {
  @override
  Map<String, Object?> environment() => {
    'locale': (_ref.read(localeProvider) ?? WidgetsBinding.instance.platformDispatcher.locale).toLanguageTag(),
    'platform': Platform.operatingSystem,
    'timeZoneOffsetMinutes': DateTime.now().timeZoneOffset.inMinutes,
  };
  _HostDelegate(this._ref, this._manifest, {this.developmentStore, this.developmentActive, this.developmentNavigate, this.developmentSuspended, this.worker = false});
  final bool worker;
  final MetaversePluginStore? developmentStore;
  final bool Function()? developmentActive;
  final void Function(BuildContext, String, Map<String, Object?>)? developmentNavigate;
  final void Function(String)? developmentSuspended;

  final Ref _ref;
  final MetaversePluginManifest _manifest;
  int _generation = 0;

  @override
  Future<void> prepareStart() async {
    if (developmentStore != null) return;
    final plugin = _ref.read(metaversePluginsProvider.notifier).byId(_manifest.id);
    if (plugin == null || !identical(plugin.manifest, _manifest)) throw const PluginOperationCancelled();
    await _ref.read(metaversePluginStoreProvider).settleRelease(plugin);
  }

  @override
  void onHealthy() {
    if (developmentStore != null || worker) return;
    final plugin = _ref.read(metaversePluginsProvider.notifier).byId(_manifest.id);
    if (plugin != null && identical(plugin.manifest, _manifest)) {
      unawaited(_ref.read(metaversePluginStoreProvider).markHealthy(plugin.id, plugin.codeRevision)
        .catchError((Object error) => debugPrint('插件运行确认失败：$error')));
    }
  }

  @override
  void onStartFailed() {
    if (developmentStore != null || worker) return;
    unawaited(_ref.read(metaversePluginsProvider.notifier).rollback(_manifest.id,
      automatic: true, expected: _manifest).catchError((Object error) => debugPrint('插件版本恢复失败：$error')));
  }

  @override
  void onShutdown() => _generation++;

  @override
  Future<bool> requestPermissions(BuildContext context, Set<MetaversePluginPermission> missing, {required void Function() checkActive}) async {
    if (worker) return false;
    final controller = _ref.read(metaversePluginsProvider.notifier);
    final reviewed = developmentStore == null ? controller.byId(_manifest.id) : null;
    if (developmentStore == null && !identical(reviewed?.manifest, _manifest)) return false;
    final approved = await showMetaversePermissionRequest(context, _manifest, missing);
    if (!approved) return false;
    // 确认弹层出栈后，可见性由页面在下一帧更新，随后允许原点击继续读取。
    await WidgetsBinding.instance.endOfFrame;
    checkActive();
    if (reviewed != null) await controller.grantRequested(reviewed, missing, checkActive);
    return true;
  }

  @override
  bool dismissModal(BuildContext context, String page) =>
      MetaversePluginPage.dismissModal(context, _manifest.id, page);

  @override
  Future<bool> confirmBackground(BuildContext context, String id) => showMetaverseConfirmation(context, _manifest.name, {
    'title': context.l10n.metaverse_backgroundTasks,
    'message': '${_manifest.tasks.firstWhere((task) => task.id == id).title}\n${context.l10n.metaverse_backgroundTaskNote}',
    'confirmLabel': context.l10n.common_enable,
  });

  @override
  Future<bool> confirmNotifications(BuildContext context) => showMetaverseConfirmation(context, _manifest.name, {
    'title': context.l10n.metaverse_pluginNotifications, 'message': context.l10n.metaverse_pluginNotificationsNote,
    'confirmLabel': context.l10n.common_enable,
  });

  @override
  Future<Object?> taskOperation(String method, Map<String, Object?> params, {required void Function() checkActive}) async {
    if (developmentStore != null) throw const MetaversePluginCallException('task_development_preview_only');
    final account = currentAccountId();
    if (account == null) throw const MetaversePluginCallException('forum_auth_required');
    final control = await _ref.read(metaverseTaskStoreProvider.future);
    checkActive();
    return MetaverseTaskActions(control, _manifest, account, checkActive: () {
      checkActive();
      if (!_accountActive(account)) throw const MetaversePluginCallException('task_cancelled');
    }, changed: () async {
      if (!worker) await _ref.read(metaverseTaskDriverProvider)?.changed();
    }).call(method, params);
  }

  @override
  Future<Object?> readForum(MetaverseForumRequest request, {required void Function() checkActive}) =>
      _ref.read(metaverseForumAdapterProvider).read(_manifest.id, request, checkActive: checkActive);

  @override
  Future<void> openForum(BuildContext context, MetaverseForumDestination destination) async {
    unawaited(Navigator.of(context).push<void>(InteractionPageRoute(builder: (_) =>
      destination.username != null
          ? UserProfilePage(username: destination.username!)
          : TopicDetailPage(topicId: destination.topicId!, scrollToPostNumber: destination.postNumber),
    )));
  }

  @override
  String? currentUsername() => _ref.read(currentUserProvider).value?.username;

  @override
  int? currentAccountId() => _ref.read(currentUserProvider).value?.id;

  bool _accountActive(int id) =>
      _ref.mounted &&
      currentAccountId() == id &&
      (developmentActive?.call() ?? (_ref
              .read(metaversePluginsProvider.notifier)
              .byId(_manifest.id)
              ?.enabled ==
          true));

  @override
  Future<bool> confirm(BuildContext context, Map<String, Object?> options) =>
      showMetaverseConfirmation(context, _manifest.name, options);

  @override
  Future<String?> authorizeConnect(BuildContext context, Uri authorization) async {
    final generation = _generation;
    final account = _ref.read(currentUserProvider).value;
    if (account == null) throw StateError(S.current.metaverse_nativeLoginRequired);
    final callback = MetaverseConnectCapability.callback(
      _manifest,
      authorization,
    );
    if (!await showMetaverseConnectConfirmation(
      context,
      _manifest,
      account.username,
      callback: callback,
    )) {
      return null;
    }
    bool active() => context.mounted &&
        generation == _generation &&
        _accountActive(account.id);
    if (!active()) throw const PluginOperationCancelled();
    final client = DiscourseDio.create(
      enableNetworkLog: false,
      enableRetry: false,
      enableCfChallenge: false,
    );
    try {
      return await MetaverseConnectCapability(client).authorize(
        _manifest,
        authorization,
        isActive: active,
      );
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<bool> requestCredential(BuildContext context, String name) async {
    final spec = _manifest.capabilities.credentials[name];
    if (spec == null) {
      throw const MetaversePluginCallException('credential_not_declared');
    }
    final generation = _generation;
    final accountId = currentAccountId();
    final MetaversePluginStore store = developmentStore ?? _ref.read(metaversePluginStoreProvider);
    final revision = store.credentialRevision(_manifest.id, name);
    final secret = await showMetaversePluginTokenDialog(
      context,
      _manifest,
      label: spec.label,
      hosts: spec.scopes.map((scope) => scope.origin.host).toSet().toList(),
    );
    if (secret == null || secret.isEmpty) return false;
    final credential = MetaverseCredential.parse({
      'secret': secret,
      'accountId': accountId,
    });
    if (credential == null) {
      throw const MetaversePluginCallException('credential_invalid');
    }
    await store.writeCredential(
      _manifest.id,
      name,
      credential,
      revision: revision,
      isActive: () => context.mounted &&
          generation == _generation &&
          currentAccountId() == accountId,
    );
    return true;
  }

  @override
  Future<Object?> requestPayment(
    BuildContext context, {
    required MetaversePaymentProvider provider,
    required Uri url,
    required String reference,
    required Object amount,
  }) async {
    final generation = _generation;
    final account = _ref.read(currentUserProvider).value;
    if (account == null) throw StateError(S.current.metaverse_nativeLoginRequired);
    Future<void> checkSession() async {
      if (!context.mounted ||
          generation != _generation ||
          !_accountActive(account.id)) {
        throw const PluginOperationCancelled();
      }
    }
    return switch (provider) {
      MetaversePaymentProvider.linuxDoCredit => requestLdcPayment(
        context,
        url: url,
        reference: reference,
        amount: amount,
        accountId: account.id,
        username: account.username,
        secretStore: _ref.read(secretStoreProvider),
        preferences: _ref.read(sharedPreferencesProvider),
        checkSession: checkSession,
      ),
    };
  }

  @override
  Future<bool> requestAuth(
    BuildContext context,
    MetaversePluginManifest manifest,
  ) async {
    final generation = _generation;
    final store = _ref.read(metaversePluginStoreProvider);
    final revision = store.tokenRevision(manifest.id);
    bool active() => context.mounted && generation == _generation &&
        store.tokenRevision(manifest.id) == revision;
    final token = await showMetaversePluginTokenDialog(context, manifest);
    if (token == null || token.isEmpty || !active()) return false;
    await _ref
        .read(metaversePluginsProvider.notifier)
        .saveToken(manifest.id, token, isActive: active);
    return true;
  }

  @override
  void openPage(
    BuildContext context,
    MetaversePluginManifest manifest,
    String page,
    Map<String, Object?> params,
  ) {
    if (developmentNavigate != null) {
      developmentNavigate!(context, page, params);
    } else {
      MetaversePluginPage.open(context, manifest.id, page, params: params);
    }
  }

  @override
  Future<void> openUrl(BuildContext context, Uri url) =>
      launchExternalLink(context, url.toString());

  @override
  Future<void> openWebSession(BuildContext context, Uri url) =>
      launchExternalLink(context, url.toString(), preferSessionBrowser: true);

  @override
  Future<void> openBrowser(BuildContext context, Uri url, LinkOpenMode mode) =>
      launchExternalLink(context, url.toString(), mode: mode);

  @override
  void toast(String message, String type) =>
      showMetaversePluginToast(_manifest.name, message, type);

  @override
  void onSuspended(String pluginId, String reason) {
    // 工作引擎回收和退避由持久化调度器负责，不能用过期索引改写前台安装记录。
    if (worker) return;
    if (developmentSuspended != null) {
      developmentSuspended!(reason);
    } else {
      onStartFailed();
    }
  }
}

/// 开发实例复用正式能力代理，存储、导航和存活条件由会话提供。
MetaversePluginHost createDevelopmentPluginHost(Ref ref, {
  required MetaversePluginManifest manifest,
  Set<MetaversePluginPermission> blockedPermissions = const {},
  required MetaversePluginStore store,
  required MetaverseScriptEngineFactory engineFactory,
  required Future<MetaversePluginCode> Function() codeLoader,
  required bool Function() active,
  required void Function(BuildContext, String, Map<String, Object?>) navigate,
  required void Function(String) suspended,
}) => MetaversePluginHost(
  manifest: manifest, store: store, blockedPermissions: blockedPermissions,
  network: ref.read(metaversePluginNetworkProvider),
  engineFactory: engineFactory, codeLoader: codeLoader,
  delegate: _HostDelegate(ref, manifest, developmentStore: store,
    developmentActive: active, developmentNavigate: navigate, developmentSuspended: suspended),
);
