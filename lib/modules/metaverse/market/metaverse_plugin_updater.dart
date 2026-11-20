import 'dart:async';
import 'dart:typed_data';

import '../plugin/metaverse_plugin_installer.dart';
import '../plugin/metaverse_plugin_store.dart';
import 'metaverse_market_catalog.dart';
import 'metaverse_market_provider.dart';
import 'metaverse_update_store.dart';

typedef MetaverseUpdateBundle = ({
  MetaversePluginPackage package,
  Uint8List bytes,
});

/// 调度器只准备已安装插件的同源新版本。后台不运行插件脚本、不修改安装索引。
class MetaversePluginUpdater {
  MetaversePluginUpdater({
    required this.store,
    required this.installed,
    required this.refresh,
    required this.download,
    required this.sourceEnabled,
  });
  final MetaverseUpdateStore store;
  final List<InstalledMetaversePlugin> Function() installed;
  final Future<MetaverseMarketState> Function() refresh;
  final Future<MetaverseUpdateBundle> Function(MetaverseMarketEntry) download;
  final bool Function(String source) sourceEnabled;

  bool eligible(InstalledMetaversePlugin plugin) =>
      store.snapshot().allows(plugin) && sourceEnabled(plugin.source);

  Future<void> check({
    bool force = false,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    if (!installed().any(eligible)) return;
    final token = store.begin(force: force);
    if (token == null) return;
    var failed = false, running = true;
    var retryAt = 0;
    bool active() => running && store.active(token);
    Future<void> run() async {
      final market = await refresh();
      if (!active()) return;
      failed = market.errors.isNotEmpty;
      retryAt = market.retryAt;
      for (final original in installed()) {
        if (!active()) return;
        if (!eligible(original)) continue;
        final entry = market.entries
            .where((e) => e.id == original.id && e.source.id == original.source)
            .firstOrNull;
        if (market.errors.containsKey(original.source)) {
          store.report(token, original, original.manifest.version, 'failed');
          continue;
        }
        if (entry == null || !entry.newerThan(original.manifest.version)) {
          store.report(token, original, original.manifest.version, 'current');
          continue;
        }
        if (!entry.compatible) {
          store.report(token, original, entry.version, 'incompatible');
          continue;
        }
        // 已准备的同一包无需重复下载，权限变化仍保持待审阅。
        final pending = store.pending(original.id);
        if (pending?.base == MetaverseUpdateStore.baseOf(original) &&
            pending?.digest == entry.sha256) {
          continue;
        }
        try {
          final result = await download(entry);
          if (!active()) return;
          final current = installed()
              .where((p) => p.id == original.id)
              .firstOrNull;
          if (current == null ||
              MetaverseUpdateStore.baseOf(current) !=
                  MetaverseUpdateStore.baseOf(original) ||
              !eligible(current)) {
            continue;
          }
          final status =
              result.package.manifest.sameApprovalAs(current.manifest) &&
                  result.package.manifest.apiVersion ==
                      current.manifest.apiVersion
              ? 'ready'
              : 'review';
          store.report(
            token,
            current,
            entry.version,
            status,
            bytes: result.bytes,
            digest: entry.sha256,
          );
          _log(current, status, version: entry.version);
        } catch (_) {
          if (!active()) return;
          failed = true;
          store.report(token, original, entry.version, 'failed');
          _log(original, 'download_failed', version: entry.version);
        }
      }
    }

    try {
      await run().timeout(timeout);
    } catch (_) {
      failed = true;
    } finally {
      running = false;
      store.finish(token, failed: failed, notBefore: retryAt);
    }
  }

  Future<void> apply({
    required MetaversePluginInstaller installer,
    required bool Function(String id) idle,
    required bool Function() available,
    required Future<bool> Function(
      MetaversePluginPackage,
      InstalledMetaversePlugin,
      bool Function(),
    )
    install,
  }) async {
    for (final plugin in installed()) {
      if (!available() || !store.snapshot().enabled) return;
      if (!eligible(plugin) || !idle(plugin.id)) continue;
      final candidate = store.pending(plugin.id);
      if (candidate == null) continue;
      if (candidate.base != MetaverseUpdateStore.baseOf(plugin)) {
        store.discard(plugin.id);
        continue;
      }
      bool allowed() =>
          available() &&
          idle(plugin.id) &&
          store.snapshot().enabled &&
          eligible(plugin) &&
          store.pending(plugin.id)?.digest == candidate.digest;
      try {
        final package = await installer.importBundle(
          Stream.value(candidate.bytes),
          source: plugin.source,
          expectedDigest: candidate.digest,
        );
        if (!allowed()) continue;
        if (!package.manifest.sameApprovalAs(plugin.manifest) ||
            package.manifest.apiVersion != plugin.manifest.apiVersion) {
          continue;
        }
        if (await install(package, plugin, allowed)) {
          final updated = installed()
              .where((p) => p.id == plugin.id)
              .firstOrNull;
          if (updated != null) {
            store.applied(updated);
            _log(updated, 'updated');
          }
        }
      } catch (_) {
        // 安装或校验失败保留旧版本，清掉候选让下一轮重新校验下载。
        store.discard(plugin.id, status: 'failed');
        _log(plugin, 'install_failed');
      }
    }
  }

  void _log(
    InstalledMetaversePlugin plugin,
    String result, {
    String? version,
  }) => store.queueEvent({
    'type': 'plugin',
    'level': result.endsWith('failed') ? 'warning' : 'info',
    'event': 'plugin_update',
    'emitter': 'framework',
    'pluginId': plugin.id,
    'pluginVersion': plugin.manifest.version,
    'targetVersion': version,
    'message': result,
  });
}
