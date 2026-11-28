import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../fixtures/metaverse/legacy_storage.dart';

import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_credential.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_host.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_permission.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_data_migration.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_installer.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/flutter_js_script_engine.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

class _Orders implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int status = 201;
  Object body = {
    'success': true,
    'data': {'orderNo': 'EX-1'},
  };
  void Function()? afterRequest;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? request,
    Future<void>? cancel,
  ) async {
    if (!options.uri.path.startsWith('/api/shop/orders') && !options.uri.path.startsWith('/api/shop/order-submissions')) {
      return ResponseBody.fromString('{"success":true,"data":{}}',200);
    }
    expect(options.headers['Authorization'], 'Bearer fixture');
    requests.add(options);
    afterRequest?.call();
    return ResponseBody.fromString(
      body is String ? body as String : jsonEncode(body),
      status,
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Delegate extends MetaversePluginHostDelegate {
  int account = 42;
  @override
  int currentAccountId() => account;
  @override
  String currentUsername() => 'tester';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _withSubmissionProbe(String script) {
  // 测试入口放在发行脚本的本地化闭包内，不向生产插件暴露提交管理器。
  const closureEnd = '})(fluxdo);';
  final end = script.lastIndexOf(closureEnd);
  expect(end, greaterThanOrEqualTo(0));
  expect(script.substring(end).trim(), closureEnd);
  return '${script.substring(0, end)}\n'
      '''fluxdo.on('fixture.order', async (ctx, args) => {
  try {
    const result = args.action === 'parallel'
      ? await Promise.all([ldStore.submission('submit', args.value), ldStore.submission('submit', args.value)])
      : await ldStore.submission(args.action, args.value);
    ctx.setData('result', result);
  } catch (error) { ctx.setData('failure', error.message); }
  ctx.setData('finished', true);
});
$closureEnd''';
}

void main() {
  final manifest = MetaversePluginManifest.parse(
    jsonDecode(File('test/fixtures/metaverse/ld-store/plugin.json').readAsStringSync()),
  );
  const intent = {
    'productId': 'example',
    'quantity': 2,
    'expectedAmount': 12.5,
  };

  group('士多脚本管理提交记录', () {
    late Directory root;
    late MetaversePluginStore store;
    late InMemorySecretStore secrets;
    late MetaversePluginHost host;
    late MetaversePluginNetwork network;
    late _Orders orders;
    late _Delegate delegate;
    final engines = <IsolateScriptEngine>[];
    Future<void> signIn(int id) async {
      host.shutdown();
      delegate.account = id;
      await store.writeCredential(
        manifest.id,
        'account',
        MetaverseCredential('fixture', accountId: id),
        revision: store.credentialRevision(manifest.id, 'account'),
        isActive: () => true,
      );
    }

    Future<Map> invoke(String action, [Object? value]) async {
      final surface = await host.open(kind: 'card');
      host.dispatchUserEvent(surface, 'fixture.order', {
        'action': action,
        'value': value,
      });
      for (var i = 0; i < 400 && surface.data['finished'] != true; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(surface.data['finished'], true);
      final result = Map.of(surface.data);
      host.close(surface);
      return result;
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      root = await Directory.systemTemp.createTemp('ld-store-orders-');
      secrets = InMemorySecretStore();
      store = MetaversePluginStore(
        preferences: await SharedPreferences.getInstance(),
        secretStore: secrets,
        rootDirectory: () async => root,
      );
      orders = _Orders();
      delegate = _Delegate();
      network = MetaversePluginNetwork(
        dio: Dio(BaseOptions(validateStatus: (_) => true))
          ..httpClientAdapter = orders,
        lookup: (_) async => [InternetAddress('198.18.0.6')],
      );
      await store.writeCode(manifest.id, (
        ui: File('test/fixtures/metaverse/ld-store/ui.rfwtxt').readAsStringSync(),
        script: _withSubmissionProbe(
          File('test/fixtures/metaverse/ld-store/main.js').readAsStringSync(),
        ),
      ));
      host = MetaversePluginHost(
        manifest: manifest,
        store: store,
        network: network,
        engineFactory: () async {
          final engine = await IsolateScriptEngine.spawn();
          engines.add(engine);
          return engine;
        },
        delegate: delegate,
      );
      await signIn(42);
    });
    tearDown(() async {
      host.shutdown();
      for (final engine in engines) {
        engine.dispose();
      }
      await Future.wait(engines.map((engine) => engine.terminated))
          .timeout(const Duration(seconds: 5));
      engines.clear();
      network.dispose();
      await root.delete(recursive: true);
    });

    test('并发点击只建一次，记录按账号隔离且只能归档原订单', () async {
      final result = (await invoke('parallel', intent))['result'] as List;
      expect(result[0], result[1]);
      expect(orders.requests, hasLength(1));
      expect(
        (await invoke('finish', 'other'))['failure'],
        'checkout_lookup_required',
      );
      await signIn(43);
      expect((await invoke('status'))['result'], {'state': 'idle'});
      await signIn(42);
      expect(((await invoke('status'))['result'] as Map)['orderNo'], 'EX-1');
      await invoke('finish', 'EX-1');
      await store.importLegacyStorage(manifest.id);
      expect((await invoke('status'))['result'], {'state': 'idle'});
      expect(orders.requests, hasLength(1));
    });

    test('响应丢失与冲突保留原提交号，明确不存在后才能重试', () async {
      orders.body = 'invalid';
      expect(
        ((await invoke('submit', intent))['result'] as Map)['state'],
        'pending',
      );
      final token = jsonDecode(
        orders.requests.single.data as String,
      )['submissionToken'];
      expect((await invoke('retry'))['failure'], 'checkout_lookup_required');
      for (final status in [503, 409, 401]) {
        orders.status = status;
        orders.body = {'success': false};
        expect(
          ((await invoke('recover'))['result'] as Map)['state'],
          'pending',
        );
      }
      expect(orders.requests.where((r) => r.method == 'POST'), hasLength(1));
      orders.status = 200;
      orders.body = {
        'success': true,
        'data': {'exists': false},
      };
      expect(((await invoke('recover'))['result'] as Map)['state'], 'missing');
      orders.status = 422;
      orders.body = {
        'success': false,
        'error': {'code': 'PURCHASE_LIMIT_EXCEEDED'},
      };
      expect(((await invoke('retry'))['result'] as Map)['state'], 'rejected');
      expect(
        jsonDecode(orders.requests.last.data as String)['submissionToken'],
        token,
      );
      expect((await invoke('status'))['result'], {'state': 'idle'});
    });

    test('记录损坏时保留现场，账号在请求期间变化后拒绝回写', () async {
      await store.updateStorage(manifest.id, '@forum-account:42:submission:42', {
        'invalid': true,
      });
      expect(
        (await invoke('submit', intent))['failure'],
        'checkout_record_invalid',
      );
      expect(orders.requests, isEmpty);
      await store.updateStorage(manifest.id, '@forum-account:42:submission:42', null);
      orders.afterRequest = () => delegate.account = 43;
      expect((await invoke('submit', intent))['failure'], 'forum_account_changed');
      final saved =
          (await store.readStorage(manifest.id))['@forum-account:42:submission:42'] as Map;
      expect(saved['state'], 'pending');
      expect(saved['orderNo'], isNull);
    });

    for (final misplaced in [false, true]) {
      test('旧版多账号记录按所属账号原号迁移，不重复导入，误分区=$misplaced', () async {
        String scope(int account) => sha256
            .convert(
              utf8.encode(
                jsonEncode([
                  'https://api2.ldspro.qzz.io/api/shop/orders',
                  'https://api2.ldspro.qzz.io/api/shop/order-submissions',
                  'linux.do:$account',
                  'LDC',
                ]),
              ),
            )
            .toString();
        final pending = {
          ...intent,
          'token': 'ord_${'a' * 32}',
          'state': 'pending',
        };
        await secrets.writeLegacyRecord(manifest.id, scope(42), jsonEncode(pending));
        await secrets.writeLegacyRecord(
          manifest.id,
          scope(43),
          jsonEncode({...pending, 'token': 'ord_${'b' * 32}'}),
        );
        await store.importLegacyStorage(manifest.id);
        if (misplaced) {
          final data = await store.readStorage(manifest.id);
          await store.writeStorage(manifest.id, {
            for (final entry in data.entries) '@forum-account:42:${entry.key}': entry.value,
          });
        }
        expect(
          ((await invoke('status'))['result'] as Map)['token'],
          pending['token'],
        );
        expect(orders.requests, isEmpty);
        var data = await store.readStorage(manifest.id);
        expect((data['legacyApi1Records'] as Map).keys, ['v1:${scope(43)}']);
        orders.status = 200;
        orders.body = {
          'success': true,
          'data': {
            'exists': true,
            'order': {'orderNo': 'EX-1'},
          },
        };
        await invoke('recover');
        expect(orders.requests.single.uri.path, endsWith('/${pending['token']}'));
        await invoke('finish', 'EX-1');
        await store.importLegacyStorage(manifest.id);
        expect((await invoke('status'))['result'], {'state': 'idle'});
        await signIn(43);
        expect(
          ((await invoke('status'))['result'] as Map)['token'],
          'ord_${'b' * 32}',
        );
        data = await store.readStorage(manifest.id);
        expect(data['legacyApi1Records'], isNull);
        expect(await secrets.readLegacyRecord(manifest.id, scope(42)), isNotNull);
      });
    }

    for (final misplaced in [false, true]) {
      test('迁移旧提交到所属账号并保留原提交号，误分区=$misplaced', () async {
        final prefix = misplaced ? '@forum-account:42:' : '';
        final pending = {...intent, 'state': 'pending', 'token': 'ord_${'b' * 32}'};
        await store.updateStorage(manifest.id, '${prefix}submission:43', pending);
        expect((await invoke('status'))['result'], {'state': 'idle'});
        await signIn(43);
        expect((await invoke('status'))['result'], pending);
        expect(orders.requests, isEmpty);
        final data = await store.readStorage(manifest.id);
        expect(data['@forum-account:43:submission:43'], pending);
        expect(data['${prefix}submission:43'], isNull);
        await signIn(42);
        expect((await invoke('status'))['result'], {'state': 'idle'});
      });
    }

    test('旧记录和现有记录冲突时不覆盖、不创建订单，保留两份记录', () async {
      final old = {...intent, 'state': 'pending', 'token': 'ord_${'a' * 32}'};
      final current = {...old, 'token': 'ord_${'b' * 32}'};
      await store.updateStorageEntries(manifest.id, {
        'submission:42': old,
        '@forum-account:42:submission:42': current,
      });
      final before = await store.readStorage(manifest.id);
      expect((await invoke('submit', intent))['failure'], 'checkout_record_conflict');
      expect(await store.readStorage(manifest.id), before);
      expect(orders.requests, isEmpty);
    });

    test('升级先整理旧分区，先登录另一账号也能恢复原订单', () async {
      final pending = {...intent, 'state': 'pending', 'token': 'ord_${'b' * 32}'};
      final data = <String, Object?>{'@forum-account:42:submission:43': pending};
      final migrated = await migrateMetaverseAccountPartitions(
        package: MetaversePluginPackage(manifest: manifest, source: 'file:${manifest.id}',
          code: await store.readCode(manifest.id)), data: data,
        engineFactory: createMetaverseScriptEngine);
      await store.writeStorage(manifest.id, migrated);
      await signIn(43);
      expect((await invoke('status'))['result'], pending);
      expect(orders.requests, isEmpty);
      expect(data, {'@forum-account:42:submission:43': pending});
    });

    test('身份权限关闭时不迁移，授权后同一实例可以恢复记录', () async {
      host.shutdown();
      host = MetaversePluginHost(manifest: manifest, store: store, network: network,
        delegate: delegate, blockedPermissions: {MetaversePluginPermission.identity},
        engineFactory: () async {
          final engine = await IsolateScriptEngine.spawn();
          engines.add(engine);
          return engine;
        });
      final before = {'submission:42': {...intent, 'state': 'pending', 'token': 'ord_${'a' * 32}'}};
      await store.writeStorage(manifest.id, before);
      await host.open(kind: 'card');
      await expectLater(host.call('storage.get', {'key': 'submission:42'}),
        throwsA(isA<MetaversePluginCallException>().having((e) => e.message,
          'message', 'permission_denied:identity')));
      expect(await store.readStorage(manifest.id), before);
      host.applyGrantedPermissions({});
      expect((await invoke('status'))['result'], before['submission:42']);
      expect(orders.requests, isEmpty);
    });

    test('开发隔离存储不会启动第二个迁移引擎抢占热更新连接', () async {
      host.shutdown();
      store = MetaversePluginStore(preferences: await SharedPreferences.getInstance(),
        secretStore: secrets, rootDirectory: () async => root, isolated: true);
      await store.writeCode(manifest.id, (
        ui: File('test/fixtures/metaverse/ld-store/ui.rfwtxt').readAsStringSync(),
        script: _withSubmissionProbe(File('test/fixtures/metaverse/ld-store/main.js').readAsStringSync()),
      ));
      var starts = 0;
      host = MetaversePluginHost(manifest: manifest, store: store, network: network,
        delegate: delegate, engineFactory: () async {
          expect(++starts, 1);
          final engine = await IsolateScriptEngine.spawn();
          engines.add(engine);
          return engine;
        });
      expect((await invoke('status'))['result'], {'state': 'idle'});
      expect(starts, 1);
      expect(await store.readStorage(manifest.id), isEmpty);
    });

    for (final mixed in [false, true]) {
      test('建单和恢复兼容订单号别名，驼峰优先=$mixed', () async {
        final order = {
          'order_no': mixed ? 'WRONG' : 'EX-1',
          if (mixed) 'orderNo': 'EX-1',
        };
        orders.body = {'success': true, 'data': order};
        expect(
          ((await invoke('submit', intent))['result'] as Map)['orderNo'],
          'EX-1',
        );
        await invoke('finish', 'EX-1');
        orders.status = 503;
        orders.body = {};
        await invoke('submit', intent);
        orders.status = 200;
        orders.body = {
          'success': true,
          'data': {'exists': true, 'order': order},
        };
        expect(((await invoke('recover'))['result'] as Map)['orderNo'], 'EX-1');
        expect(orders.requests.where((r) => r.method == 'POST'), hasLength(2));
      });
    }
  });
}
