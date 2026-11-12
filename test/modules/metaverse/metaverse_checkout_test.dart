import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_checkout.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_checkout_types.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_service_session.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/metaverse_plugin_runtime.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Orders extends MetaversePluginNetwork {
  final calls = <String>[];
  Map<String, Object?> response = {
    'status': 201,
    'body': '{"success":true,"data":{"orderNo":"EX-1","paymentUrl":"https://example.com/unused"}}',
  };
  @override
  Future<Map<String, Object?>> orderRequest(
    MetaversePluginManifest manifest,
    MetaverseServiceSession session,
    String submissionToken, {
    MetaverseOrderIntent? create,
    required Future<void> Function() checkSession,
  }) async {
    await checkSession();
    calls.add('${create == null ? 'GET' : 'POST'} $submissionToken');
    return response;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MetaverseCheckout flow;
  late MetaversePluginStore store;
  late MetaversePluginManifest manifest;
  late _Orders api;
  final intent = MetaverseOrderIntent.parse({
    'productId': 'p-1',
    'quantity': 2,
    'expectedAmount': 4.25,
  })!;
  Future<void> signIn(String subject) => store.writeServiceSession(
    manifest.id,
    MetaverseServiceSession(
      'fixture-$subject',
      checkout: MetaverseCheckoutGrant(
        manifest.auth.checkout!,
        subject: subject,
        unit: 'LDC',
      ),
    ),
  );
  bool active() => true;
  Future<bool> accept(_, _) async => true;
  setUp(() async {
    manifest = MetaversePluginManifest.parse(
      jsonDecode(File('plugins/ld-store/plugin.json').readAsStringSync()),
    );
    SharedPreferences.setMockInitialValues({});
    store = MetaversePluginStore(
      preferences: await SharedPreferences.getInstance(),
      secretStore: InMemorySecretStore(),
      rootDirectory: () async => throw UnimplementedError(),
    );
    api = _Orders();
    addTearDown(api.dispose);
    flow = MetaverseCheckout(manifest, store, api);
  });

  test('读会话不等于建单授权；切账号不能沿用已打开的确认框', () async {
    await store.writeServiceSession(
      manifest.id,
      MetaverseServiceSession(
        'read-only',
        queryUrls: manifest.auth.queries.values,
      ),
    );
    await expectLater(
      flow.submit(intent, accept, active, retry: false),
      throwsA(isA<MetaversePluginCallException>()),
    );
    await signIn('alice');
    await expectLater(
      flow.submit(
        intent,
        (_, _) async {
          await signIn('bob');
          return true;
        },
        active,
        retry: false,
      ),
      throwsA(isA<MetaversePluginCallException>()),
    );
    expect(api.calls, isEmpty);
    expect(await flow.status(active), {'state': 'idle'});
  });

  test('并发确认只产生一个提交；已建订单按账号隔离且不能以未知订单号结束', () async {
    await signIn('alice');
    final entered = Completer<void>(), release = Completer<bool>();
    final action = flow.submit(
      intent,
      (_, _) {
        entered.complete();
        return release.future;
      },
      active,
      retry: false,
    );
    await entered.future;
    await expectLater(
      flow.submit(intent, accept, active, retry: false),
      throwsStateError,
    );
    release.complete(true);
    final order = await action;
    expect(order['orderNo'], 'EX-1');
    expect(order.keys, isNot(contains('paymentUrl')));
    expect(order.keys, isNot(contains('token')));
    expect(
      await flow.submit(
        intent,
        (_, _) => fail('已有订单不能重复确认'),
        active,
        retry: false,
      ),
      order,
    );
    await expectLater(
      flow.finish('other', active),
      throwsA(isA<MetaversePluginCallException>()),
    );
    await signIn('bob');
    expect(await flow.status(active), {'state': 'idle'});
    await signIn('alice');
    expect(await flow.status(active), order);
    await flow.finish('EX-1', active);
    expect(await flow.status(active), {'state': 'idle'});
    expect(api.calls, hasLength(1));
  });

  test('无法解析的成功回应、服务错误和冲突保留记录，只有明确未找到才允许原号重试', () async {
    await signIn('alice');
    api.response = {'status': 201, 'body': 'invalid'};
    final first = await flow.submit(intent, accept, active, retry: false);
    expect(first['state'], 'pending');
    await expectLater(
      flow.submit(null, accept, active, retry: true),
      throwsA(isA<MetaversePluginCallException>()),
    );
    for (final http in [503, 409, 401]) {
      api.response = {'status': http, 'body': '{"success":false}'};
      expect((await flow.recover(active))['state'], 'pending');
    }
    expect(api.calls.where((v) => v.startsWith('POST')), hasLength(1));
    api.response = {
      'status': 200,
      'body': '{"success":true,"data":{"exists":false}}',
    };
    expect((await flow.recover(active))['state'], 'missing');
    api.response = {
      'status': 422,
      'body': '{"success":false,"error":{"code":"PURCHASE_LIMIT_EXCEEDED"}}',
    };
    expect(
      (await flow.submit(null, accept, active, retry: true))['state'],
      'rejected',
    );
    expect((await flow.status(active))['state'], 'idle');
    expect(api.calls.map((v) => v.split(' ').last).toSet(), hasLength(1));
  });
}
