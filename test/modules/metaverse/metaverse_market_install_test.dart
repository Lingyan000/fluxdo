import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_installer.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory directory;
  late MetaversePluginStore store;
  late MetaversePluginInstaller installer;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('plugin-market-test-');
    store = MetaversePluginStore(
      preferences: await SharedPreferences.getInstance(),
      secretStore: InMemorySecretStore(),
      rootDirectory: () async => directory,
    );
    installer = MetaversePluginInstaller(network: MetaversePluginNetwork());
  });
  tearDown(() async => directory.delete(recursive: true));

  test('市场包校验摘要且保留稳定来源', () async {
    final manifest = jsonDecode(
      File('plugins/ld-store/plugin.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final bytes = utf8.encode(
      jsonEncode({
        'manifest': manifest,
        'files': {
          'main.js': File('plugins/ld-store/main.js').readAsStringSync(),
          'ui.rfwtxt': File('plugins/ld-store/ui.rfwtxt').readAsStringSync(),
        },
      }),
    );
    const source = 'https://example.org/index.json';
    final package = await installer.importBundle(
      Stream.value(bytes),
      source: source,
      expectedDigest: sha256.convert(bytes).toString(),
    );
    expect(package.source, source);
    expect(package.manifest.apiVersion, 1);
    await expectLater(
      installer.importBundle(
        Stream.value([...bytes, 32]),
        source: source,
        expectedDigest: sha256.convert(bytes).toString(),
      ),
      throwsA(isA<MetaversePluginInstallException>()),
    );
  });

  test('新代码未提交索引时继续读取完整旧版本', () async {
    final manifest = MetaversePluginManifest.parse(
      jsonDecode(File('plugins/ld-store/plugin.json').readAsStringSync()),
    );
    const first = (ui: 'old ui', script: 'old script');
    const second = (ui: 'new ui', script: 'new script');
    await store.writeCode(manifest.id, first);
    final old = InstalledMetaversePlugin(
      manifest: manifest,
      source: 'test',
      codeRevision: MetaversePluginStore.revisionOf(first),
    );
    await store.saveIndex([old]);
    await store.writeCode(manifest.id, second);
    expect(await store.readCode(manifest.id), first);
    await store.saveIndex([
      InstalledMetaversePlugin(
        manifest: manifest,
        source: 'test',
        codeRevision: MetaversePluginStore.revisionOf(second),
      ),
    ]);
    expect(await store.readCode(manifest.id), second);
  });

  test('多个并发键写入不会覆盖，单插件重置保留其他插件数据和代码', () async {
    await Future.wait([
      for (var i = 0; i < 20; i++)
        store.updateStorage('example.one', 'key$i', i),
    ]);
    expect((await store.readStorage('example.one')).length, 20);
    await store.updateStorage('example.two', 'value', 2);
    await store.writeCode('example.one', (ui: 'ui', script: 'script'));
    await store.writeToken('example.one', 'fixture');
    await store.resetData('example.one');
    expect(await store.readStorage('example.one'), isEmpty);
    expect(await store.readToken('example.one'), isNull);
    expect(await store.readStorage('example.two'), {'value': 2});
    expect(await store.readCode('example.one'), (ui: 'ui', script: 'script'));
  });

  test('重置后到达的旧订单响应无法重建已删除记录', () async {
    var active = true;
    await store.writeOrder('example.one', 'account', 'pending');
    active = false;
    await store.resetData('example.one');
    await expectLater(
      store.writeOrder(
        'example.one',
        'account',
        'created',
        isActive: () => active,
      ),
      throwsA(isA<PluginOperationCancelled>()),
    );
    expect(await store.readOrder('example.one', 'account'), isNull);
    active = true;
    final queued = store.writeOrder(
      'example.one',
      'account',
      'stale',
      isActive: () => active,
    );
    active = false;
    await expectLater(queued, throwsA(isA<PluginOperationCancelled>()));
    expect(await store.readOrder('example.one', 'account'), isNull);
  });
}
