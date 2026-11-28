import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_approval_change.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_data_migration.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_host.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_permission.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_installer.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/flutter_js_script_engine.dart';

import 'metaverse_auto_update_test.dart' show updateManifest;
import 'metaverse_navigation_forum_test.dart' show Engine, Delegate;

Map<String, dynamic> scoped({
  String defaultScope = 'account',
  List<String> scopes = const ['shared', 'account'],
}) => {
  ...updateManifest('1.0.0'),
  'storage': {'default': defaultScope, 'scopes': scopes},
  'requiredFeatures': ['storageScopes'],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('扩展页面需要显式能力且仍保留总量上限', () {
    final raw = updateManifest('1.0.0');
    raw['pages'] = List.generate(
      17,
      (i) => {'id': 'page$i', 'title': 'Page $i', 'widget': 'Home'},
    );
    expect(
      () => MetaversePluginManifest.parse(raw),
      throwsA(isA<MetaverseManifestException>()),
    );
    raw['requiredFeatures'] = ['extendedPages'];
    expect(MetaversePluginManifest.parse(raw).pages.length, 17);
    raw['pages'] = List.generate(
      33,
      (i) => {'id': 'page$i', 'title': 'Page $i', 'widget': 'Home'},
    );
    expect(
      () => MetaversePluginManifest.parse(raw),
      throwsA(isA<MetaverseManifestException>()),
    );
  });
  test('版本迁移逐分区执行，不能用作用域读取另一区数据', () async {
    final raw = scoped()..['dataVersion'] = 2;
    (raw['requiredFeatures'] as List).add('dataMigrations');
    MetaversePluginPackage package(String script) => MetaversePluginPackage(
      manifest: MetaversePluginManifest.parse(raw),
      source: 'file',
      code: (ui: '', script: script),
    );
    final data = <String, Object?>{
      '@shared:value': 1,
      '@forum-account:1:value': 2,
      '@forum-account:2:value': 3,
    };
    final result = await migrateMetaverseData(
      package: package('''fluxdo.on('storage.migrate',async(ctx,args)=>{
      const value=await ctx.api.storage.get('value',{scope:args.scope});await ctx.api.storage.set('value',value+10,{scope:args.scope});
    });'''),
      fromVersion: 1,
      data: data,
      engineFactory: createMetaverseScriptEngine,
    );
    expect(result, {
      '@shared:value': 11,
      '@forum-account:1:value': 12,
      '@forum-account:2:value': 13,
    });
    await expectLater(
      migrateMetaverseData(
        package: package(
          "fluxdo.on('storage.migrate',async ctx=>{await ctx.api.storage.get('value',{scope:'account'});});",
        ),
        fromVersion: 1,
        data: data,
        engineFactory: createMetaverseScriptEngine,
      ),
      throwsA(anything),
    );
    expect(data['@shared:value'], 1);
  });
  test('存储作用域独立于通知和任务，账号范围必须声明身份', () {
    final raw = scoped();
    final manifest = MetaversePluginManifest.parse(raw);
    expect(manifest.accountScoped, isTrue);
    expect(manifest.defaultStorageScope, 'account');
    (raw['permissions'] as Map)['notifications'] = true;
    (raw['requiredFeatures'] as List).add('localNotifications');
    expect(
      MetaversePluginManifest.parse(raw).storageScopes,
      manifest.storageScopes,
    );
    final shared = scoped(defaultScope: 'shared', scopes: ['shared']);
    (shared['permissions'] as Map)['notifications'] = true;
    (shared['requiredFeatures'] as List).add('localNotifications');
    expect(MetaversePluginManifest.parse(shared).accountScoped, isFalse);
    (raw['permissions'] as Map)['identity'] = false;
    expect(
      () => MetaversePluginManifest.parse(raw),
      throwsA(isA<MetaverseManifestException>()),
    );
    expect(
      () => MetaversePluginManifest.parse(scoped(scopes: ['shared'])),
      throwsA(isA<MetaverseManifestException>()),
    );
  });

  test('新增可读范围或改变默认分区必须审阅；旧账号分区不会变成共享数据', () {
    final old = MetaversePluginManifest.parse(updateManifest('1.0.0'));
    final shared = MetaversePluginManifest.parse(
      scoped(defaultScope: 'shared', scopes: ['shared']),
    );
    final both = MetaversePluginManifest.parse(scoped());
    expect(shared.canUpdateWithoutApproval(old), isTrue);
    expect(both.expandedApprovalFrom(shared), contains('storage'));
    final data = {
      'categories': [1],
      '@forum-account:2:orders': [42],
    };
    expect(
      prepareMetaverseStorageScopes(previous: old, next: shared, data: data),
      {
        '@shared:categories': [1],
        '@forum-account:2:orders': [42],
      },
    );
    expect(
      prepareMetaverseStorageScopes(previous: old, next: both, data: data),
      data,
    );
    expect(
      () => prepareMetaverseStorageScopes(
        previous: shared,
        next: old,
        data: data,
      ),
      throwsA(isA<MetaversePluginCallException>()),
    );
  });

  test('两个账号共享分类但隔离订单，撤销身份后只允许共享区', () async {
    final root = await Directory.systemTemp.createTemp(
      'plugin-storage-scopes-',
    );
    SharedPreferences.setMockInitialValues({});
    final store = MetaversePluginStore(
      preferences: await SharedPreferences.getInstance(),
      secretStore: InMemorySecretStore(),
      rootDirectory: () async => root,
    );
    final network = MetaversePluginNetwork();
    final manifest = MetaversePluginManifest.parse(scoped());
    await store.writeCode(manifest.id, (
      ui: 'import fluxdo; widget Card = Label(text: "test"); widget Home = Gap();',
      script: '',
    ));
    final hosts = <MetaversePluginHost>[];
    Future<MetaversePluginHost> open(
      Delegate delegate, {
      bool blocked = false,
    }) async {
      final host = MetaversePluginHost(
        manifest: manifest,
        store: store,
        network: network,
        engineFactory: () async => Engine(),
        delegate: delegate,
        blockedPermissions: {if (blocked) MetaversePluginPermission.identity},
      );
      hosts.add(host);
      await host.open(kind: 'card');
      return host;
    }

    try {
      final first = Delegate()..account = 1;
      final a = await open(first);
      await a.call('storage.set', {
        'key': 'orders',
        'value': [11],
      });
      await a.call('storage.set', {
        'key': 'categories',
        'value': [7],
        'scope': 'shared',
      });
      final b = await open(Delegate()..account = 2);
      expect(await b.call('storage.get', {'key': 'orders'}), isNull);
      expect(
        await b.call('storage.get', {'key': 'categories', 'scope': 'shared'}),
        [7],
      );
      await b.call('storage.setMany', {
        'entries': {
          'orders': [22],
          'draft': 'mine',
        },
      });
      expect(await a.call('storage.get', {'key': 'orders'}), [11]);
      expect(
        await b.call('storage.compareAndSet', {
          'key': 'orders',
          'expected': [11],
          'value': [],
        }),
        false,
      );
      final denied = await open(Delegate()..account = 2, blocked: true);
      await expectLater(
        denied.call('storage.get', {'key': 'orders'}),
        throwsA(isA<MetaversePluginCallException>()),
      );
      expect(
        await denied.call('storage.get', {
          'key': 'categories',
          'scope': 'shared',
        }),
        [7],
      );
      first.account = 2;
      await expectLater(
        a.call('storage.set', {'key': 'orders', 'value': []}),
        throwsA(isA<MetaversePluginCallException>()),
      );
      await expectLater(
        b.call('storage.get', {'key': 'orders', 'scope': 'other'}),
        throwsA(isA<MetaversePluginCallException>()),
      );
    } finally {
      for (final host in hosts) {
        host.shutdown();
      }
      network.dispose();
      await root.delete(recursive: true);
    }
  });
}
