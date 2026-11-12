import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_credential.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_host.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/flutter_js_script_engine.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

Future<void> main() async {
  String? unavailable;
  try {
    (await IsolateScriptEngine.spawn()).dispose();
  } on MetaverseScriptException catch (error) {
    unavailable = '脚本引擎原生库不可用 $error';
  }
  final manifest = MetaversePluginManifest.parse(
    jsonDecode(File('plugins/ld-store/plugin.json').readAsStringSync()),
  );
  const intent = {
    'productId': 'example',
    'quantity': 2,
    'expectedAmount': 12.5,
  };

  group('士多脚本管理提交记录', skip: unavailable, () {
    late Directory root;
    late MetaversePluginStore store;
    late MetaversePluginHost host;
    late MetaversePluginNetwork network;
    late _Orders orders;
    late _Delegate delegate;
    Future<void> signIn(int id) async {
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
      store = MetaversePluginStore(
        preferences: await SharedPreferences.getInstance(),
        secretStore: InMemorySecretStore(),
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
        ui: File('plugins/ld-store/ui.rfwtxt').readAsStringSync(),
        script: '''${File('plugins/ld-store/main.js').readAsStringSync()}
fluxdo.on('fixture.order', async (ctx, args) => {
  try {
    const result = args.action === 'parallel'
      ? await Promise.all([ldStore.submission('submit', args.value), ldStore.submission('submit', args.value)])
      : await ldStore.submission(args.action, args.value);
    ctx.setData('result', result);
  } catch (error) { ctx.setData('failure', error.message); }
  ctx.setData('finished', true);
});''',
      ));
      host = MetaversePluginHost(
        manifest: manifest,
        store: store,
        network: network,
        engineFactory: createMetaverseScriptEngine,
        delegate: delegate,
      );
      await signIn(42);
    });
    tearDown(() async {
      host.shutdown();
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
      await store.updateStorage(manifest.id, 'submission:42', {
        'invalid': true,
      });
      expect(
        (await invoke('submit', intent))['failure'],
        'checkout_record_invalid',
      );
      expect(orders.requests, isEmpty);
      await store.updateStorage(manifest.id, 'submission:42', null);
      orders.afterRequest = () => delegate.account = 43;
      expect((await invoke('submit', intent))['failure'], 'auth_required');
      final saved =
          (await store.readStorage(manifest.id))['submission:42'] as Map;
      expect(saved['state'], 'pending');
      expect(saved['orderNo'], isNull);
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
