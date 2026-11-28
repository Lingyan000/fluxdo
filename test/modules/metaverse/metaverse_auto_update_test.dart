import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_market_catalog.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_market_provider.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_plugin_updater.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_update_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_installer.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_permission.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/providers/metaverse_plugin_providers.dart';
import 'package:fluxdo/providers/secret_store_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_update_provider.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_host.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_credential.dart';
import 'package:fluxdo/modules/metaverse/host/metaverse_task_store.dart';

import 'metaverse_navigation_forum_test.dart' show Engine, Delegate;

import 'package:fluxdo/services/storage/secret_store.dart';

const updateSource = MetaverseMarketSource('https://example.org/index.json');
Map<String, dynamic> updateManifest(String version, {bool expanded = false}) =>
    {
      'schema': 12,
      'apiVersion': 2,
      'id': 'example.updates',
      'name': '更新测试',
      'author': 'example',
      'version': version,
      'description': '测试定时更新',
      'ui': 'ui.rfwtxt',
      'script': 'main.js',
      'permissions': {
        'network': ['api.example.org', if (expanded) 'extra.example.org'],
        'identity': true,
      },
      'pages': [
        {'id': 'home', 'title': '首页', 'widget': 'Home'},
      ],
      'card': {'widget': 'Card'},
    };
MetaversePluginPackage updatePackage(
  String version, {
  bool expanded = false,
  String? source,
}) => MetaversePluginPackage(
  manifest: MetaversePluginManifest.parse(
    updateManifest(version, expanded: expanded),
  ),
  source: source ?? updateSource.id,
  code: (
    ui: 'import fluxdo; widget Card = Gap(); widget Home = Gap();',
    script: 'fluxdo.on("page.open", () => {}); // $version',
  ),
);
Uint8List updateBytes(MetaversePluginPackage package) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'manifest': package.manifest.raw,
      'files': {'main.js': package.code.script, 'ui.rfwtxt': package.code.ui},
    }),
  ),
);
MetaverseMarketEntry updateEntry(
  MetaversePluginPackage package, {
  String? digest,
  List<String> features = const [],
}) => MetaverseMarketEntry.parse({
  'id': package.manifest.id,
  'name': package.manifest.name,
  'version': package.manifest.version,
  'summary': '测试更新',
  'author': 'example',
  'apiVersion': 2,
  'requiredFeatures': features,
  'repository': 'https://example.org/repo',
  'packageUrl': 'https://example.org/update.fluxplugin',
  'sha256': digest ?? sha256.convert(updateBytes(package)).toString(),
}, MetaverseMarketSource(package.source));

class _NoAccount extends CurrentUserNotifier {
  @override
  Future<User?> build() async => null;
}

class _DriverMarket extends MetaverseMarketController {
  int requests = 0;
  @override
  MetaverseMarketState build() => MetaverseMarketState(
    sources: [updateSource],
    entries: [updateEntry(updatePackage('1.1.0'))],
  );
  @override
  Future<void> refresh({bool force = false}) async {
    requests++;
  }

  @override
  Future<MetaverseUpdateBundle> downloadBundle(
    MetaverseMarketEntry entry,
  ) async {
    final package = updatePackage(entry.version);
    return (package: package, bytes: updateBytes(package));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ProviderContainer container;
  late MetaversePluginsController controller;
  late MetaversePluginStore plugins;
  late MetaverseUpdateStore updates;
  late MetaversePluginInstaller installer;
  late DateTime clock;
  late MetaversePluginPackage latest;
  late List<MetaverseMarketEntry> entries;
  late Map<String, String> errors;
  late bool sourceEnabled;
  late int downloads, refreshes;
  Completer<void>? downloadGate;
  late MetaversePluginUpdater updater;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('plugin-auto-update-');
    clock = DateTime.utc(2026, 11, 20);
    updates = MetaverseUpdateStore(root, clock: () => clock);
    container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith(_NoAccount.new),
        metaverseUpdateStoreProvider.overrideWith((ref) async => updates),
        metaverseMarketProvider.overrideWith(_DriverMarket.new),
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        secretStoreProvider.overrideWithValue(InMemorySecretStore()),
        metaversePluginDirectoryProvider.overrideWith((ref) async => root),
      ],
    );
    controller = container.read(metaversePluginsProvider.notifier);
    plugins = container.read(metaversePluginStoreProvider);
    installer = MetaversePluginInstaller(network: MetaversePluginNetwork());
    await controller.install(updatePackage('1.0.0'));
    await controller.setEnabled('example.updates', enabled: true);
    latest = updatePackage('1.1.0');
    entries = [updateEntry(latest)];
    errors = {};
    sourceEnabled = true;
    downloads = 0;
    refreshes = 0;
    downloadGate = null;
    updater = MetaversePluginUpdater(
      store: updates,
      installed: () => container.read(metaversePluginsProvider),
      sourceEnabled: (source) => sourceEnabled && source == updateSource.id,
      refresh: () async {
        refreshes++;
        return MetaverseMarketState(
          sources: [updateSource],
          entries: entries,
          errors: errors,
        );
      },
      download: (entry) async {
        downloads++;
        await downloadGate?.future;
        final bytes = updateBytes(latest);
        final package = await installer.importBundle(
          Stream.value(bytes),
          source: entry.source.id,
          expectedDigest: entry.sha256,
        );
        return (package: package, bytes: bytes);
      },
    );
  });
  tearDown(() async {
    container.dispose();
    await root.delete(recursive: true);
  });
  Future<void> apply({bool idle = true, bool available = true}) =>
      updater.apply(
        installer: installer,
        idle: (_) => idle,
        available: () => available,
        install: controller.installAutomatic,
      );

  test('默认每天检查，准备和安装分离，启用状态与权限选择保持', () async {
    final old = controller.byId('example.updates')!;
    await plugins.updateStorage(old.id, 'draft', '保留');
    expect(old.allows(MetaversePluginPermission.identity), isFalse);
    await updater.check();
    expect(controller.byId(old.id)!.manifest.version, '1.0.0');
    expect(updates.snapshot().reports[old.id]!['status'], 'ready');
    expect(
      updates.snapshot().nextCheck,
      clock.add(const Duration(days: 1)).millisecondsSinceEpoch,
    );
    await apply();
    final next = controller.byId(old.id)!;
    expect(next.manifest.version, '1.1.0');
    expect(next.enabled, isTrue);
    expect(next.blockedPermissions, old.blockedPermissions);
    expect(await plugins.readStorage(old.id), {'draft': '保留'});
    expect(await plugins.readCode(old.id), latest.code);
    expect(updates.snapshot().reports[old.id]!['status'], 'updated');
    await updater.check();
    expect(refreshes, 2);
    clock = clock.add(const Duration(days: 1));
    await updater.check();
    expect(refreshes, 3);
  });
  test('后台或仍在使用的插件只准备候选，空闲后安装', () async {
    await updater.check();
    await apply(available: false);
    await apply(idle: false);
    expect(controller.byId('example.updates')!.manifest.version, '1.0.0');
    await apply();
    expect(controller.byId('example.updates')!.manifest.version, '1.1.0');
  });
  test('新增域名必须人工审阅，保留旧版本和候选', () async {
    latest = updatePackage('1.1.0', expanded: true);
    entries = [updateEntry(latest)];
    await updater.check();
    await apply();
    expect(updates.snapshot().reports['example.updates']!['status'], 'review');
    expect(controller.byId('example.updates')!.manifest.version, '1.0.0');
    await updater.check(force: true);
    expect(downloads, 1);
  });
  test('不兼容的新版本无需下载且提示升级宿主', () async {
    entries = [
      updateEntry(latest, features: ['unknownFutureFeature']),
    ];
    await updater.check();
    await apply();
    expect(downloads, 0);
    expect(
      updates.snapshot().reports['example.updates']!['status'],
      'incompatible',
    );
  });
  test('摘要错误保留原代码，失败后持久化退避，手动检查也遵守冷却', () async {
    entries = [updateEntry(latest, digest: 'a' * 64)];
    await updater.check();
    await apply();
    expect(updates.snapshot().failed, isTrue);
    expect(
      await plugins.readCode('example.updates'),
      updatePackage('1.0.0').code,
    );
    await updater.check(force: true);
    expect(downloads, 1);
    final reopened = MetaverseUpdateStore(root, clock: () => clock);
    expect(reopened.begin(force: true), isNull);
    clock = clock.add(const Duration(minutes: 15));
    entries = [updateEntry(latest)];
    await updater.check();
    expect(downloads, 2);
    expect(updates.snapshot().failed, isFalse);
  });
  test('过期市场缓存遇到错误不会安装旧候选条目', () async {
    errors[updateSource.id] = 'HTTP 503';
    await updater.check();
    expect(downloads, 0);
    expect(updates.snapshot().failed, isTrue);
  });
  test('关闭计划或单插件排除不会自动检查，手动检查不绕过安装关闭', () async {
    updates.setFrequency(MetaverseUpdateFrequency.disabled);
    await updater.check();
    expect(refreshes, 0);
    await updater.check(force: true);
    await apply();
    expect(controller.byId('example.updates')!.manifest.version, '1.0.0');
    updates.setAllowed(controller.byId('example.updates')!, false);
    await updater.check(force: true);
    expect(refreshes, 1);
    expect(updates.pending('example.updates'), isNull);
  });
  test('重复唤醒共用持久化租约，超时租约可以恢复', () async {
    final other = MetaverseUpdateStore(root, clock: () => clock);
    final token = updates.begin()!;
    expect(other.begin(), isNull);
    clock = clock.add(const Duration(minutes: 6));
    expect(updates.active(token), isFalse);
    expect(other.begin(), isNotNull);
  });
  test('下载期间关闭自动更新，迟到结果不再落入候选', () async {
    downloadGate = Completer<void>();
    final checking = updater.check();
    await Future<void>.delayed(Duration.zero);
    expect(downloads, 1);
    updates.setFrequency(MetaverseUpdateFrequency.disabled);
    downloadGate!.complete();
    await checking;
    await apply();
    expect(updates.pending('example.updates'), isNull);
    expect(controller.byId('example.updates')!.manifest.version, '1.0.0');
  });
  test('下载期间卸载插件不会重新安装或残留候选', () async {
    downloadGate = Completer<void>();
    final checking = updater.check();
    await Future<void>.delayed(Duration.zero);
    await controller.remove('example.updates');
    downloadGate!.complete();
    await checking;
    await apply();
    expect(controller.byId('example.updates'), isNull);
    expect(updates.pending('example.updates'), isNull);
  });
  test('停用市场源和跨源同 ID 条目不能触发更新', () async {
    sourceEnabled = false;
    await updater.check();
    expect(refreshes, 0);
    sourceEnabled = true;
    entries = [
      updateEntry(
        updatePackage('2.0.0', source: 'https://other.example/index.json'),
      ),
    ];
    await updater.check();
    expect(downloads, 0);
  });
  test('同版本与旧版本均不自动覆盖', () async {
    entries = [updateEntry(updatePackage('1.0.0'))];
    await updater.check();
    entries = [updateEntry(updatePackage('0.9.0'))];
    await updater.check(force: true);
    expect(downloads, 0);
  });
  for (final entry in {'ld-store': '2.9.3', 'activity-feed': '1.4.0'}.entries) {
    test('${entry.key} 开发版本改号须手动审阅，同源保留数据与关闭的权限', () async {
      Future<MetaversePluginPackage> readPackage(String path) =>
          installer.importBundle(File('test/fixtures/metaverse/$path.fluxplugin').openRead(),
            source: updateSource.id);
      final oldPackage = await readPackage('${entry.key}-${entry.value}');
      final nextPackage = await readPackage('release/${entry.key}-1.0.0');
      expect(nextPackage.signature!.fingerprint, oldPackage.signature!.fingerprint);
      expect(nextPackage.manifest.dataVersion, oldPackage.manifest.dataVersion);
      await controller.install(oldPackage, choices: {
        MetaversePluginPermission.identity: true,
        if (oldPackage.manifest.capabilities.credentials.isNotEmpty)
          MetaversePluginPermission.serviceAccount: true,
      });
      final id = oldPackage.manifest.id;
      await controller.setEnabled(id, enabled: true);
      final old = controller.byId(id)!;
      final data = <String, Object?>{
        '@shared:cache': ['cached'],
        '@forum-account:7:draft': '保留账号草稿',
        '@forum-account:8:draft': '其他账号保持隔离',
        if (entry.key == 'ld-store')
          '@forum-account:7:submission:7': {
            'token': 'ord_11111111111111111111111111111111',
            'productId': 'fixture-product', 'quantity': 1,
            'expectedAmount': 5.0, 'state': 'created',
            'orderNo': 'fixture-order',
          },
      };
      await plugins.updateStorageEntries(id, data);
      for (final name in old.manifest.capabilities.credentials.keys) {
        await plugins.writeCredential(id, name,
          const MetaverseCredential('test-only-secret', accountId: 7),
          isActive: () => true, revision: plugins.credentialRevision(id, name));
      }
      expect(await controller.installAutomatic(nextPackage, old, () => true), isFalse);
      expect(controller.byId(id), same(old));
      expect(await plugins.readStorage(id), data);
      final next = await controller.replaceReviewed(nextPackage, old, {});
      expect(next.manifest.version, '1.0.0');
      expect(next.source, old.source);
      expect(next.enabled, isTrue);
      expect(next.blockedPermissions, old.blockedPermissions);
      expect(next.allows(MetaversePluginPermission.background), isFalse);
      expect(next.allows(MetaversePluginPermission.notifications), isFalse);
      final stored = await plugins.readStorage(id);
      for (final item in data.entries) {
        expect(stored[item.key], item.value);
      }
      for (final name in old.manifest.capabilities.credentials.keys) {
        expect((await plugins.readCredential(id, name))?.secret, 'test-only-secret');
      }
      expect(await plugins.readCode(id), nextPackage.code);
    });
  }
  test('显式替换拒绝换源、换作者、数据降级和过期审阅；同版可重装', () async {
    final signed = await installer.importBundle(File('test/fixtures/metaverse/release/quick-notes-1.0.0.fluxplugin').openRead(), source: updateSource.id);
    final old = await controller.install(signed);
    await plugins.updateStorage(old.id, 'draft', 'keep');
    for (final bad in [
      MetaversePluginPackage(manifest: signed.manifest, source: 'https://other.example.org/index.json', code: signed.code, signature: signed.signature),
      MetaversePluginPackage(manifest: signed.manifest, source: signed.source, code: signed.code),
    ]) {
      await expectLater(controller.replaceReviewed(bad, old, {}), throwsA(anything));
      expect(controller.byId(old.id), same(old));
      expect((await plugins.readStorage(old.id))['draft'], 'keep');
    }
    final higher = MetaversePluginPackage(manifest: MetaversePluginManifest.parse({...signed.manifest.raw,
      'schema':12, 'dataVersion': signed.manifest.dataVersion + 1,
      'requiredFeatures': {...signed.manifest.requiredFeatures, 'dataMigrations'}.toList()}),
      source: signed.source, code: signed.code, signature: signed.signature);
    await plugins.saveIndex([InstalledMetaversePlugin(manifest: higher.manifest, source: old.source,
      publisherKey: old.publisherKey, codeRevision: old.codeRevision, installationId: old.installationId)]);
    container.invalidate(metaversePluginsProvider);
    controller = container.read(metaversePluginsProvider.notifier);
    final elevated = controller.byId(old.id)!;
    await expectLater(controller.replaceReviewed(signed, elevated, {}), throwsA(anything));
    expect(controller.byId(old.id), same(elevated));
    await controller.setEnabled(old.id, enabled: true);
    await expectLater(controller.replaceReviewed(higher, elevated, {}), throwsA(anything));
    final current = controller.byId(old.id)!;
    final reinstalled = await controller.replaceReviewed(higher, current, {});
    expect(reinstalled.enabled, isTrue);
    expect((await plugins.readStorage(old.id))['draft'], 'keep');
  });
  test('下载超时撤销写入资格，迟到结果丢弃', () async {
    downloadGate = Completer<void>();
    await updater.check(timeout: const Duration(milliseconds: 10));
    expect(updates.snapshot().failed, isTrue);
    downloadGate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(updates.pending('example.updates'), isNull);
  });
  test('准备后手动更新、换源或卸载会清理候选', () async {
    await updater.check();
    await controller.install(updatePackage('1.2.0'));
    updates.reconcile(container.read(metaversePluginsProvider));
    await apply();
    expect(updates.pending('example.updates'), isNull);
    expect(controller.byId('example.updates')!.manifest.version, '1.2.0');
  });
  test('候选准备后仍须确认原市场源启用', () async {
    await updater.check();
    sourceEnabled = false;
    await apply();
    expect(controller.byId('example.updates')!.manifest.version, '1.0.0');
  });
  test('原停用和挂起状态不被自动更新清除', () async {
    await controller.setEnabled('example.updates', enabled: false);
    await controller.suspend('example.updates', '测试挂起');
    await updater.check();
    await apply();
    final next = controller.byId('example.updates')!;
    expect(next.manifest.version, '1.1.0');
    expect(next.enabled, isFalse);
    expect(next.suspendedReason, '测试挂起');
  });
  test('安装持久化期间页面打开，恢复旧索引且保留可重试候选', () async {
    final expected = controller.byId('example.updates')!;
    var checks = 0;
    final accepted = await controller.installAutomatic(
      latest,
      expected,
      () => ++checks < 5,
    );
    expect(accepted, isFalse);
    expect(checks, 5);
    expect(controller.byId(expected.id), same(expected));
    expect(plugins.loadIndex().single.manifest.version, '1.0.0');
    expect(await plugins.readCode(expected.id), updatePackage('1.0.0').code);
  });
  test('每天的前台定时器自动触发检查和安装，恢复应用不会重复下载', () async {
    await container.read(metaverseUpdateStoreProvider.future);
    final driver = container.read(metaverseUpdateDriverProvider)!;
    final updated = Completer<void>();
    final subscription = container.listen(metaversePluginsProvider, (_, next) {
      if (next.single.manifest.version == '1.1.0' && !updated.isCompleted) {
        updated.complete();
      }
    });
    await updated.future.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(Duration.zero);
    await driver.check();
    expect(
      (container.read(
        metaverseMarketProvider.notifier,
      ) as _DriverMarket).requests,
      2,
    );
    subscription.close();
  });

  test('隐藏的打开页面仍阻止替换，关闭后才能自动更新', () async {
    final host = MetaversePluginHost(
      manifest: updatePackage('1.0.0').manifest,
      store: plugins,
      network: MetaversePluginNetwork(),
      engineFactory: () async => Engine(),
      delegate: Delegate(),
    );
    addTearDown(host.shutdown);
    final opening = host.open(kind: 'page', page: 'home');
    expect(host.hasUpdateBlocker, isTrue);
    final surface = await opening;
    host.setSurfaceForeground(surface, false);
    expect(host.hasUpdateBlocker, isTrue);
    host.close(surface);
    expect(host.hasUpdateBlocker, isFalse);
  });

  test('服务端冷却时间持久化并覆盖较短的本地退避', () {
    final token = updates.begin()!;
    updates.finish(
      token,
      failed: true,
      notBefore: clock.add(const Duration(hours: 1)).millisecondsSinceEpoch,
    );
    expect(updates.snapshot().nextCheck, updates.snapshot().retryAt);
    clock = clock.add(const Duration(minutes: 20));
    updates.setFrequency(MetaverseUpdateFrequency.disabled);
    updates.setFrequency(MetaverseUpdateFrequency.sixHours);
    expect(updates.begin(force: true), isNull);
    clock = clock.add(const Duration(minutes: 40));
    expect(updates.begin(force: true), isNotNull);
  });

  test('后台更新日志跨实例保留且只消费一次', () async {
    await updater.check();
    final worker = MetaverseUpdateStore(root, clock: () => clock);
    final events = worker.takeEvents();
    expect(events.single['event'], 'plugin_update');
    expect(events.single['pluginId'], 'example.updates');
    expect(events.single['emitter'], 'framework');
    expect(updates.takeEvents(), isEmpty);
  });

  test('更新与系统任务通过同一数据库互斥，进程退出后的锁会过期', () {
    final tasks = MetaverseTaskStore(root, clock: () => clock);
    tasks.transaction((s) {
      s['account'] = {'id': 1};
      s['epoch'] = 1;
      s['plugins'] = {
        'example.updates': {'source': updateSource.id},
      };
      s['jobs'] = {
        '1:example.updates:sync': {
          'plugin': 'example.updates',
          'account': 1,
          'id': 'sync',
          'background': true,
          'nextAt': 0,
          'intervalSeconds': 60,
        },
      };
    });
    final hold = tasks.holdForUpdate('example.updates')!;
    final other = MetaverseTaskStore(root, clock: () => clock);
    expect(other.claim(background: true), isNull);
    expect(other.holdForUpdate('example.updates'), isNull);
    tasks.releaseUpdate('example.updates', hold);
    final lease = other.claim(background: true)!;
    expect(tasks.holdForUpdate('example.updates'), isNull);
    other.finish(lease);
    final abandoned = tasks.holdForUpdate('example.updates')!;
    clock = clock.add(const Duration(seconds: 31));
    expect(tasks.updateHeld('example.updates', abandoned), isFalse);
    expect(other.holdForUpdate('example.updates'), isNotNull);
  });

  test('安装队列不使用过期的权限快照', () async {
    final expected = controller.byId('example.updates')!;
    await controller.setPermission(
      expected.id,
      MetaversePluginPermission.identity,
      true,
    );
    expect(
      await controller.installAutomatic(latest, expected, () => true),
      isFalse,
    );
    expect(controller.byId(expected.id)!.manifest.version, '1.0.0');
  });
  test('缓存包安装前复核撤回和网络状态，不能使用过期目录', () async {
    await updater.check();
    errors = {updateSource.id:'unavailable'};
    await apply();
    expect(controller.byId('example.updates')!.manifest.version,'1.0.0');
    errors = {};
    entries = [];
    await apply();
    expect(updates.pending('example.updates'),isNull);
    expect(controller.byId('example.updates')!.manifest.version,'1.0.0');
  });
  test('故障版本回退后只下载一次以确认摘要，后续检查跳过相同包', () async {
    await updater.check(); await apply();
    await controller.rollback('example.updates',automatic:true);
    await updater.check(force:true); await apply();
    expect(updates.snapshot().reports['example.updates']!['status'],'rejected');
    final count = downloads;
    await updater.check(force:true);
    expect(downloads,count);
    expect(controller.byId('example.updates')!.manifest.version,'1.0.0');
  });
  test('稳定渠道默认排除测试版本，明确选择后才准备候选', () async {
    latest=updatePackage('2.0.0-beta.1'); entries=[updateEntry(latest)];
    await updater.check();expect(updates.pending('example.updates'),isNull);
    updates.setPreview(true);await updater.check(force:true);
    expect(updates.pending('example.updates'),isNotNull);
    updates.setPreview(false);await apply();
    expect(controller.byId('example.updates')!.manifest.version,'1.0.0');
  });

}
