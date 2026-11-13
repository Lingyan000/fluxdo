import 'dart:io';
import 'dart:convert';

import '../../fixtures/metaverse/legacy_storage.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/constants.dart';
import 'package:fluxdo/modules/metaverse/metaverse_link_router.dart';
import 'package:fluxdo/modules/metaverse/metaverse_registry.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_installer.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_host.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/providers/metaverse_plugin_providers.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/providers/secret_store_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

class _UnsupportedDelegate extends MetaversePluginHostDelegate {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Secrets implements SecretStore {
  @override
  Future<Map<String, String>> readScope(SecretScope scope) async => {
    for (final entry in values.entries)
      if (entry.key.startsWith(scope.storagePrefix)) entry.key: entry.value,
  };
  final values = <String, String>{};

  @override
  Future<String?> read(SecretKey key) async => values[key.storageKey];

  @override
  Future<void> write(SecretKey key, String value) async =>
      values[key.storageKey] = value;

  @override
  Future<void> delete(SecretKey key) async => values.remove(key.storageKey);

  @override
  Future<void> deleteScope(SecretScope scope) async =>
      values.removeWhere((key, _) => key.startsWith(scope.storagePrefix));

  @override
  Future<SecretStoreAvailability> checkAvailability() async =>
      SecretStoreAvailability.available;
}

Map<String, Object?> mapOf(Map<String, Object?> overrides) => {
  'schema': 1,
  'id': 'com.example.points',
  'name': '示例积分',
  'version': '1.0.0',
  'author': 'example',
  'ui': 'ui.rfwtxt',
  'script': 'main.js',
  'permissions': {
    'network': ['api.example.com'],
  },
  'auth': {
    'type': 'token',
    'hosts': ['api.example.com'],
  },
  'card': {'widget': 'Card'},
  'pages': [
    {'id': 'order', 'widget': 'OrderPage', 'title': '订单'},
  ],
  'links': [
    {'host': 'example.com', 'path': '/orders/:id', 'page': 'order'},
  ],
  ...overrides,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late ProviderContainer container;

  Future<MetaversePluginPackage> package(
    Map<String, Object?> overrides, {
    String source = 'https://example.com/plugin.json',
    String ui = 'import fluxdo; widget Card = Gap(); widget OrderPage = Gap();',
  }) async => MetaversePluginPackage(
    manifest: MetaversePluginManifest.parse(
      mapOf(overrides),
      reservedHosts: ['linux.do'],
    ),
    source: source,
    code: (ui: ui, script: "fluxdo.on('card.load', () => {});"),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('metaverse_registry_test');
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        secretStoreProvider.overrideWithValue(_Secrets()),
        metaversePluginDirectoryProvider.overrideWith((ref) async => root),
      ],
    );
    addTearDown(container.dispose);
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('安装后注册表里多出一个未开启的第三方服务', () async {
    final controller = container.read(metaversePluginsProvider.notifier);
    await controller.install(await package(const {}));

    final services = container.read(metaverseServicesProvider);
    // 官方服务在前，插件在后。
    expect(services, hasLength(3));
    expect(services.first.isThirdParty, isFalse);
    expect(services.last.isThirdParty, isTrue);
    expect(services.last.id, 'com.example.points');
    expect(services.last.isEnabled(container), isFalse);
    expect(services.last.canRemove, isTrue);
  });

  test('同源 API 升级导出旧记录，切换来源清空全部记录', () async {
    final controller = container.read(metaversePluginsProvider.notifier);
    final store = container.read(metaversePluginStoreProvider);
    final old = await package(const {});
    await controller.install(old);
    await container.read(secretStoreProvider).writeLegacyRecord(old.manifest.id, 'scope', 'pending-fixture');
    await container.read(secretStoreProvider).writeLegacyRecord('example.other', 'scope', 'other-fixture');
    final raw = Map<String, dynamic>.from(old.manifest.raw)
      ..remove('auth')
      ..['schema'] = 9
      ..['apiVersion'] = 2
      ..['version'] = '2.0.0';
    final next = MetaversePluginPackage(
      manifest: MetaversePluginManifest.parse(raw),
      source: old.source,
      code: old.code,
    );
    await controller.install(next);
    expect((await store.readStorage(old.manifest.id))['legacyApi1Records'],
      {'v1:scope': 'pending-fixture'});
    expect(await container.read(secretStoreProvider).readLegacyRecord(old.manifest.id, 'scope'), 'pending-fixture');
    await controller.install(MetaversePluginPackage(
      manifest: next.manifest,
      source: 'https://other.example/plugin.json',
      code: next.code,
    ));
    expect(await store.readStorage(old.manifest.id), isEmpty);
    expect(await container.read(secretStoreProvider).readLegacyRecord(old.manifest.id, 'scope'), isNull);
    expect(await container.read(secretStoreProvider).readLegacyRecord('example.other', 'scope'), 'other-fixture');
  });

  test('已安装旧业务插件保留管理数据，禁止启动并可同源升级', () async {
    final store = container.read(metaversePluginStoreProvider);
    final raw = jsonDecode(
      File('test/fixtures/metaverse/api1_shop.json').readAsStringSync(),
    );
    final old = MetaversePluginManifest.parse(raw, allowLegacyMetadata: true);
    const source = 'https://example.org/plugin.json';
    await store.saveIndex([
      InstalledMetaversePlugin(manifest: old, source: source, enabled: true),
    ]);
    await container.read(secretStoreProvider).writeLegacyRecord(
      old.id, 'scope', 'pending',
    );
    final controller = container.read(metaversePluginsProvider.notifier);
    expect(controller.byId(old.id)?.manifest.runtimeSupported, isFalse);
    expect(store.loadIndex().single.enabled, isTrue);
    final host = MetaversePluginHost(
      manifest: old,
      store: store,
      network: MetaversePluginNetwork(),
      engineFactory: () async => throw StateError('旧插件不得启动脚本引擎'),
      delegate: _UnsupportedDelegate(),
    );
    await expectLater(
      host.open(kind: 'card'),
      throwsA(isA<MetaversePluginCallException>().having(
        (error) => error.message, 'message', 'plugin_api_upgrade_required',
      )),
    );
    host.shutdown();
    final next = MetaversePluginManifest.parse(
      jsonDecode(File('test/fixtures/metaverse/ld-store/plugin.json').readAsStringSync()),
    );
    await controller.install(MetaversePluginPackage(
      manifest: next,
      source: source,
      code: (
        ui: File('test/fixtures/metaverse/ld-store/ui.rfwtxt').readAsStringSync(),
        script: File('test/fixtures/metaverse/ld-store/main.js').readAsStringSync(),
      ),
    ));
    expect(controller.byId(old.id)?.manifest.runtimeSupported, isTrue);
    expect(
      (await store.readStorage(old.id))['legacyApi1Records'],
      {'v1:scope': 'pending'},
    );
  });

  test('插件显式更新后才获得新回调权限', () async {
    final latest = MetaversePluginPackage(
      manifest: MetaversePluginManifest.parse(jsonDecode(File('test/fixtures/metaverse/ld-store/plugin.json').readAsStringSync())),
      source: 'https://example.org/ld-store.fluxplugin',
      code: (ui: File('test/fixtures/metaverse/ld-store/ui.rfwtxt').readAsStringSync(), script: File('test/fixtures/metaverse/ld-store/main.js').readAsStringSync()),
    );
    final oldJson =
        jsonDecode(jsonEncode(latest.manifest.raw)) as Map<String, dynamic>;
    oldJson['version'] = '1.6.0';
    (oldJson['permissions']['network'] as List).remove('api.ldspro.qzz.io');
    (oldJson['permissions']['connect'] as List).remove('https://api.ldspro.qzz.io/api/auth/callback');
    final controller = container.read(metaversePluginsProvider.notifier);
    await controller.install(
      MetaversePluginPackage(
        manifest: MetaversePluginManifest.parse(oldJson),
        source: latest.source,
        code: latest.code,
      ),
    );
    await controller.setEnabled(latest.manifest.id, enabled: true);

    final store = container.read(metaversePluginStoreProvider);
    expect(store.loadIndex().single.manifest.version, '1.6.0');
    expect(store.loadIndex().single.enabled, isTrue);
    expect(
      store.loadIndex().single.manifest.networkHosts,
      isNot(contains('api.ldspro.qzz.io')),
    );

    await controller.install(latest);
    final updated = store.loadIndex().single;
    expect(updated.manifest.version, latest.manifest.version);
    expect(updated.manifest.networkHosts, contains('api.ldspro.qzz.io'));
    expect(updated.enabled, isFalse);
    expect(await store.readCode(updated.id), latest.code);
    await controller.setEnabled(updated.id, enabled: true);
    expect(controller.byId(updated.id)!.enabled, isTrue);
  });

  for (final versions in [
    ('1.6.0', '1.6.1', true),
    ('1.6.1', '1.6.1', false),
    ('1.7.0', '1.6.1', false),
    ('1.6.1', '1.6.1-beta.1', false),
    ('1.6.1-beta.1', '1.6.1', true),
    ('1.6.1-beta.2', '1.6.1-beta.10', true),
    ('1.6.1-beta.10', '1.6.1-beta.2', false),
    ('1.6.1-beta', '1.6.1-beta.1', true),
    ('1.6.1+1', '1.6.1+2', false),
  ]) {
    test('插件版本判断 ${versions.$1} → ${versions.$2}', () {
      expect(PluginVersion.parse(versions.$2).compareTo(PluginVersion.parse(versions.$1)) > 0, versions.$3);
    });
  }

  test('未开启的插件不接管链接；开启后接管并按规则捕获参数', () async {
    final controller = container.read(metaversePluginsProvider.notifier);
    await controller.install(await package(const {}));

    final uri = Uri.parse('https://example.com/orders/42');
    expect(matchMetaverseLink(container, uri), isNull);

    await controller.setEnabled('com.example.points', enabled: true);
    final match = matchMetaverseLink(container, uri);
    expect(match, isNotNull);
    expect(match!.page, 'order');
    expect(match.params, {'id': '42'});
  });

  test('挂起的插件不接管链接，恢复后重新接管', () async {
    final controller = container.read(metaversePluginsProvider.notifier);
    await controller.install(await package(const {}));
    await controller.setEnabled('com.example.points', enabled: true);

    await controller.suspend('com.example.points', '脚本执行超时');
    expect(
      matchMetaverseLink(container, Uri.parse('https://example.com/orders/1')),
      isNull,
    );

    await controller.resume('com.example.points');
    expect(
      matchMetaverseLink(container, Uri.parse('https://example.com/orders/1')),
      isNotNull,
    );
  });

  test('停用即撤销凭证', () async {
    final controller = container.read(metaversePluginsProvider.notifier);
    await controller.install(await package(const {}));
    await controller.saveToken('com.example.points', 'secret');
    final store = container.read(metaversePluginStoreProvider);
    expect(await store.readToken('com.example.points'), 'secret');

    await controller.setEnabled('com.example.points', enabled: true);
    await controller.setEnabled('com.example.points', enabled: false);
    expect(await store.readToken('com.example.points'), isNull);
  });

  test('同一来源的重复安装保留开关；换来源视为另一个插件并清凭证与本地数据', () async {
    final controller = container.read(metaversePluginsProvider.notifier);
    final store = container.read(metaversePluginStoreProvider);
    await controller.install(await package(const {}));
    await controller.setEnabled('com.example.points', enabled: true);
    await controller.saveToken('com.example.points', 'secret');
    await store.writeStorage('com.example.points', {'k': 1});

    await controller.install(await package(const {'version': '1.1.0'}));
    expect(controller.byId('com.example.points')!.enabled, isTrue);
    expect(await store.readToken('com.example.points'), 'secret');

    await controller.install(
      await package(const {
        'version': '2.0.0',
      }, source: 'https://other.example.net/plugin.json'),
    );
    final plugin = controller.byId('com.example.points')!;
    expect(plugin.enabled, isFalse);
    expect(plugin.manifest.version, '2.0.0');
    expect(await store.readToken('com.example.points'), isNull);
    expect(await store.readStorage('com.example.points'), isEmpty);
  });

  test('内置来源不随版本变更，新增权限时重新启用且撤销旧凭证', () async {
    const source = 'asset:plugins/example/plugin.json';
    final controller = container.read(metaversePluginsProvider.notifier);
    final store = container.read(metaversePluginStoreProvider);
    final plugin = await controller.install(await package({}, source: source));
    await controller.setEnabled(plugin.id, enabled: true);
    await controller.saveToken(plugin.id, 'example');
    await container.read(secretStoreProvider).writeLegacyRecord(plugin.id, 'fixture-buyer-scope', 'last-submission');
    await controller.install(
      await package({'version': '1.1.0'}, source: source),
    );
    expect(controller.byId(plugin.id)?.enabled, true);
    expect(await store.readToken(plugin.id), 'example');
    expect(
      await container.read(secretStoreProvider).readLegacyRecord(plugin.id, 'fixture-buyer-scope'),
      'last-submission',
    );
    await controller.install(
      await package({
        'version': '1.2.0',
        'permissions': {
          'network': ['api.example.com'],
          'identity': true,
        },
      }, source: source),
    );
    expect(controller.byId(plugin.id)?.enabled, false);
    expect(await store.readToken(plugin.id), isNull);
    expect(
      await container.read(secretStoreProvider).readLegacyRecord(plugin.id, 'fixture-buyer-scope'),
      'last-submission',
    );
    await controller.install(
      await package({}, source: 'https://other.example.net/plugin.json'),
    );
    expect(await container.read(secretStoreProvider).readLegacyRecord(plugin.id, 'fixture-buyer-scope'), isNull);
  });

  test('移除插件后注册表恢复为只有官方服务', () async {
    final controller = container.read(metaversePluginsProvider.notifier);
    await controller.install(await package(const {}));
    await controller.remove('com.example.points');
    expect(container.read(metaverseServicesProvider), hasLength(2));
    expect(controller.byId('com.example.points'), isNull);
  });

  test('退出登录清空所有插件凭证', () async {
    final controller = container.read(metaversePluginsProvider.notifier);
    final store = container.read(metaversePluginStoreProvider);
    await controller.install(await package(const {}));
    await controller.saveToken('com.example.points', 'secret');

    await controller.signOutAll();
    expect(await store.readToken('com.example.points'), isNull);
    expect(controller.byId('com.example.points')!.enabled, isFalse);
  });

  test('已安装插件的清单在读取时重新校验，站点域名等规则收紧后会被丢弃', () async {
    final controller = container.read(metaversePluginsProvider.notifier);
    await controller.install(await package(const {}));
    // 模拟更严格的站点域名规则（如切换站点后）。
    final strict = MetaversePluginStore(
      preferences: await SharedPreferences.getInstance(),
      secretStore: _Secrets(),
      rootDirectory: () async => root,
      reservedHosts: ['example.com'],
    );
    expect(strict.loadIndex(), isEmpty);
  });

  test('插件声明的链接域名不能是站点自身', () {
    expect(
      () => MetaversePluginManifest.parse(
        mapOf(const <String, Object?>{}),
        reservedHosts: [Uri.parse(AppConstants.baseUrl).host],
      ),
      returnsNormally,
    );
    expect(
      () => MetaversePluginManifest.parse(
        mapOf(const <String, Object?>{
          'links': [
            {'host': 'linux.do', 'path': '/t/:id', 'page': 'order'},
          ],
        }),
        reservedHosts: [Uri.parse(AppConstants.baseUrl).host],
      ),
      throwsA(isA<MetaverseManifestException>()),
    );
  });
}
