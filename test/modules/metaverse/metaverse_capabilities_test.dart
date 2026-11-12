import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_connect_capability.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_credential_manager.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_host.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/flutter_js_script_engine.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _manifest() => {
  'schema': 9,
  'apiVersion': 2,
  'id': 'example.service',
  'version': '1.0.0',
  'name': '通用服务',
  'author': '测试',
  'ui': 'ui.rfwtxt',
  'script': 'main.js',
  'card': {'widget': 'Card'},
  'permissions': {
    'network': ['service.example'],
    'connect': ['https://service.example/oauth/callback'],
    'credentials': {
      'account': {
        'requests': [
          {
            'origin': 'https://service.example',
            'pathPrefix': '/v2',
            'methods': ['GET', 'POST'],
          },
        ],
      },
    },
    'payments': ['linuxDoCredit'],
  },
};

class _Service implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  Completer<void>? hold;
  final entered = Completer<void>();
  bool wrongState = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    if (options.uri.host == 'connect.linux.do') {
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': [
            'https://service.example/oauth/callback?code=code&state=${wrongState ? 'wrong' : 'expected'}',
          ],
        },
      );
    }
    if (!entered.isCompleted) entered.complete();
    await hold?.future;
    return ResponseBody.fromString(
      jsonEncode({
        'access': {'value': 'opaque-fixture-secret'},
      }),
      200,
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Delegate extends MetaversePluginHostDelegate {
  @override
  int? currentAccountId() => 7;
  @override
  String? currentUsername() => 'tester';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> main() async {
  String? engineUnavailable;
  try {
    (await IsolateScriptEngine.spawn()).dispose();
  } on MetaverseScriptException catch (error) {
    engineUnavailable = '脚本引擎原生库不可用: $error';
  }
  late Directory directory;
  late MetaversePluginStore store;
  late _Service adapter;
  late MetaversePluginNetwork network;
  late MetaversePluginManifest manifest;
  late MetaverseCredentialManager manager;
  final request = {
    'name': 'account',
    'request': {'url': 'https://service.example/session', 'method': 'POST'},
    'tokenPath': ['access', 'value'],
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('plugin-capabilities-');
    store = MetaversePluginStore(
      preferences: await SharedPreferences.getInstance(),
      secretStore: InMemorySecretStore(),
      rootDirectory: () async => directory,
    );
    adapter = _Service();
    network = MetaversePluginNetwork(
      dio: Dio()..httpClientAdapter = adapter,
      lookup: (_) async => [InternetAddress('1.1.1.1')],
    );
    manifest = MetaversePluginManifest.parse(_manifest());
    manager = MetaverseCredentialManager(manifest, store, network);
  });
  tearDown(() async {
    network.dispose();
    await directory.delete(recursive: true);
  });

  test('API 2 插件从真实脚本入口捕获凭证并按声明发送请求', () async {
    await store.writeCode(manifest.id, (
      ui: 'import fluxdo; widget Card = Label(text: "Example");',
      script: '''fluxdo.on('card.load', async (ctx) => {
        try {
          const capture = await ctx.api.credentials.capture('account',
            {url: 'https://service.example/session', method: 'POST', body: {code: 'fixture'}},
            {tokenPath: ['access', 'value']});
          const response = await ctx.api.fetch('https://service.example/v2/tasks', {credential: 'account'});
          const pkce = await ctx.api.crypto.pkce();
          const uuid = await ctx.api.crypto.uuid();
          ctx.setData('done', {capture: capture, status: response.status, pkce: pkce, uuid: uuid});
        } catch (error) { ctx.setData('error', error.message); }
      });''',
    ));
    final host = MetaversePluginHost(
      manifest: manifest,
      store: store,
      network: network,
      engineFactory: createMetaverseScriptEngine,
      delegate: _Delegate(),
    );
    addTearDown(host.shutdown);
    final surface = await host.open(kind: 'card');
    for (
      var i = 0;
      i < 400 && surface.data['done'] == null && surface.data['error'] == null;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(surface.data['error'], isNull);
    final done = surface.data['done'] as Map;
    expect(done['status'], 200);
    expect(jsonEncode(done), isNot(contains('opaque-fixture-secret')));
    expect((done['pkce'] as Map)['method'], 'S256');
    expect(done['uuid'], matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(
      adapter.requests.last.headers['Authorization'],
      'Bearer opaque-fixture-secret',
    );
  }, skip: engineUnavailable);

  test('凭证捕获适配任意 JSON 结构，返回状态且绑定插件和账号', () async {
    final result = await manager.capture(
      request,
      accountId: 7,
      isActive: () => true,
    );
    expect(jsonEncode(result), isNot(contains('opaque-fixture-secret')));
    expect((await manager.status('account', 7))['authorized'], isTrue);
    expect((await manager.status('account', 8))['authorized'], isFalse);
    expect(await store.readCredential('example.other', 'account'), isNull);
    final secret = (await manager.read('account', 7))!.secret;
    await network.fetch(
      manifest,
      request: {
        'url': 'https://service.example/v2/tasks',
        'method': 'POST',
        'credential': 'account',
        'body': '{}',
      },
      authToken: secret,
    );
    expect(
      adapter.requests.last.headers['Authorization'],
      'Bearer opaque-fixture-secret',
    );
  });

  for (final target in [
    'https://service.example/v20/tasks',
    'https://service.example/private',
    'https://service.example/v2%2f..%2fprivate',
    'https://service.example/v2/../private',
  ]) {
    test('凭证拒绝范围外或歧义路径 $target', () async {
      await expectLater(
        network.fetch(
          manifest,
          request: {'url': target, 'credential': 'account'},
          authToken: 'fixture',
        ),
        throwsA(isA<MetaversePluginCallException>()),
      );
      expect(adapter.requests, isEmpty);
    });
  }
  test('声明变化按能力比较，显示名称和顺序不扩大授权', () {
    final changed = jsonDecode(jsonEncode(_manifest())) as Map<String, dynamic>;
    final permissions = changed['permissions'] as Map;
    final credential = (permissions['credentials'] as Map)['account'] as Map;
    credential['label'] = '新文案';
    ((credential['requests'] as List).single as Map)['methods'] = [
      'POST',
      'GET',
    ];
    expect(
      manifest.sameApprovalAs(MetaversePluginManifest.parse(changed)),
      isTrue,
    );
    ((credential['requests'] as List).single as Map)['methods'] = [
      'GET',
      'POST',
      'DELETE',
    ];
    expect(
      manifest.sameApprovalAs(MetaversePluginManifest.parse(changed)),
      isFalse,
    );
  });
  for (final reset in [false, true]) {
    test('撤销或重置后迟到的凭证交换不能重新授权 reset=$reset', () async {
      adapter.hold = Completer<void>();
      final pending = manager.capture(
        request,
        accountId: 7,
        isActive: () => true,
      );
      final rejected = expectLater(
        pending,
        throwsA(isA<PluginOperationCancelled>()),
      );
      await adapter.entered.future;
      if (reset) {
        await store.resetData(manifest.id);
      } else {
        await store.removeCredential(manifest.id, 'account');
      }
      adapter.hold!.complete();
      await rejected;
      expect((await manager.status('account', 7))['authorized'], isFalse);
    });
  }
  test('公共 Connect 返回业务回调且不请求业务服务，校验 state 和回调范围', () async {
    final connect = MetaverseConnectCapability(
      Dio()..httpClientAdapter = adapter,
    );
    final url = Uri.https('connect.linux.do', '/oauth2/authorize', {
      'redirect_uri': 'https://service.example/oauth/callback',
      'state': 'expected',
    });
    expect(
      await connect.authorize(manifest, url, isActive: () => true),
      contains('code=code'),
    );
    expect(
      adapter.requests.every(
        (request) => request.uri.host == 'connect.linux.do',
      ),
      isTrue,
    );
    adapter.wrongState = true;
    await expectLater(
      connect.authorize(manifest, url, isActive: () => true),
      throwsA(isA<MetaversePluginCallException>()),
    );
    expect(
      () => MetaverseConnectCapability.callback(
        manifest,
        url.replace(
          queryParameters: {'redirect_uri': 'https://service.example/other'},
        ),
      ),
      throwsA(isA<MetaversePluginCallException>()),
    );
  });
}
