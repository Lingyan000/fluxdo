import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_credential.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_event_stream.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_host.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_permission.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/flutter_js_script_engine.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('等待流式事件超时');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class Service implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final bodies = <StreamController<Uint8List>>[];
  int status = 200;
  String contentType = 'text/event-stream; charset=utf-8';
  int cancelled = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    late StreamController<Uint8List> controller;
    var closed = false;
    void stop() {
      if (!closed) {
        closed = true;
        cancelled++;
        unawaited(controller.close());
      }
    }

    controller = StreamController<Uint8List>(onCancel: stop);
    bodies.add(controller);
    unawaited(cancel?.then((_) => stop()));
    return ResponseBody(
      controller.stream,
      status,
      headers: {
        'content-type': [contentType],
        'location': ['https://other.example/events'],
        'retry-after': ['120'],
      },
    );
  }

  void event(int index, String value) =>
      bodies[index].add(Uint8List.fromList(utf8.encode(value)));
  @override
  void close({bool force = false}) {
    for (final controller in bodies) {
      unawaited(controller.close());
    }
  }
}

class Delegate extends MetaversePluginHostDelegate {
  int? account = 42;
  @override
  int? currentAccountId() => account;
  @override
  String? currentUsername() => 'fixture';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('SSE 分块 UTF-8、BOM、CR/LF、多行、注释、ID 与 retry', () async {
    final bytes = utf8.encode(
      '\uFEFF: heartbeat\r\n\r\nid: abc\revent: changed\rdata: 第一行\rdata: 第二行\r\rretry: 2000\nid:\ndata:\n\ndata: incomplete',
    );
    int? retry;
    final events = await decodePluginEventStream(
      Stream.fromIterable(bytes.map((b) => [b])),
      onRetry: (ms) => retry = ms,
    ).toList();
    expect(events.length, 2);
    expect(events[0].event, 'changed');
    expect(events[0].data, '第一行\n第二行');
    expect(events[0].lastEventId, 'abc');
    expect(events[1].lastEventId, '');
    expect(events[1].data, '');
    expect(retry, 2000);
  });
  test('无边界长行、超大帧和无效 UTF-8 会终止', () async {
    for (final bytes in [
      utf8.encode('data: ${'x' * 65536}'),
      [0xff],
    ]) {
      await expectLater(
        decodePluginEventStream(Stream.value(bytes)).toList(),
        throwsFormatException,
      );
    }
  });
  test('ID 含 NUL 忽略，未闭合帧不交付', () async {
    final events = await decodePluginEventStream(
      Stream.value(
        utf8.encode(
          'id: a\ndata: ok\n\nid: bad\u0000id\ndata: still\n\ndata: lost',
        ),
      ),
    ).toList();
    expect(events.map((e) => e.lastEventId), ['a', 'a']);
    expect(events.map((e) => e.data), ['ok', 'still']);
  });

  late Directory directory;
  late MetaversePluginStore store;
  late Service adapter;
  late MetaversePluginNetwork network;
  late MetaversePluginHost host;
  late Delegate delegate;
  late MetaversePluginManifest manifest;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('plugin-stream-');
    store = MetaversePluginStore(
      preferences: await SharedPreferences.getInstance(),
      secretStore: InMemorySecretStore(),
      rootDirectory: () async => directory,
    );
    adapter = Service();
    network = MetaversePluginNetwork(
      dio: Dio()..httpClientAdapter = adapter,
      lookup: (_) async => [InternetAddress('198.18.0.6')],
    );
    manifest = MetaversePluginManifest.parse({
      'schema': 12,
      'apiVersion': 2,
      'id': 'example.stream',
      'name': '事件示例',
      'version': '1.0.0',
      'author': '测试',
      'ui': 'ui.rfwtxt',
      'script': 'main.js',
      'card': {'widget': 'Card'},
      'requiredFeatures': ['eventStreams'],
      'permissions': {
        'network': ['service.example'],
        'credentials': {
          'account': {
            'requests': [
              {
                'origin': 'https://service.example',
                'pathPrefix': '/events',
                'methods': ['GET'],
              },
            ],
          },
        },
      },
    });
    await store.writeCredential(
      manifest.id,
      'account',
      const MetaverseCredential('test-secret', accountId: 42),
      isActive: () => true,
      revision: store.credentialRevision(manifest.id, 'account'),
    );
    delegate = Delegate();
    host = MetaversePluginHost(
      manifest: manifest,
      store: store,
      network: network,
      delegate: delegate,
      engineFactory: createMetaverseScriptEngine,
      codeLoader: () async => (
        ui: 'import fluxdo; widget Card = Label(text: "test");',
        script: """
        let events=[];
        fluxdo.on('stream.event', async(ctx, frame)=>{
          events.push(frame);ctx.setData('events',events);
          try {await ctx.api.navigate('page');} catch(error) {ctx.setData('blocked',true);}
        });
        fluxdo.on('stream.state', (ctx, state)=>ctx.setData('state',state));
      """,
      ),
    );
  });
  tearDown(() async {
    host.retire();
    network.dispose();
    await directory.delete(recursive: true);
  });
  Future<Object?> call(
    MetaversePluginSurface source,
    String method,
    Map<String, Object?> params,
  ) => PluginExecutionContext(
    pluginId: manifest.id,
    pluginVersion: manifest.version,
    runtimeId: host.runtimeId,
    surfaceId: source.id,
  ).run(() => host.call(method, params));
  Future<MetaversePluginSurface> open({
    String path = '/events',
    String? credential = 'account',
  }) async {
    final source = await host.open(kind: 'card');
    await call(source, 'streams.open', {
      'id': 'events',
      'url': 'https://service.example$path',
      'credential': credential,
    });
    return source;
  }

  test('网络传输持续读取直至取消', () async {
    final cancel = CancelToken();
    final events = <PluginServerEvent>[];
    Object? failure;
    final pending = network
        .consumeEvents(
          manifest,
          request: {'url': 'https://service.example/events'},
          authToken: null,
          cancel: cancel,
          checkActive: () {},
          onOpen: () async {},
          onEvent: (event) async {
            events.add(event);
          },
          onRetry: (_) {},
        )
        .catchError((Object e) {
          failure = e;
        });
    await until(() => adapter.requests.isNotEmpty);
    expect(failure, isNull);
    expect(adapter.bodies.first.isClosed, false, reason: '$failure');
    adapter.event(0, 'data: payload\n\n');
    await until(() => events.isNotEmpty || failure != null);
    expect(failure, isNull);
    expect(events.single.data, 'payload');
    cancel.cancel();
    await pending;
  });
  test('真实引擎逐帧交付，凭证由宿主注入，事件不能获得点击权限', () async {
    final source = await open();
    await until(() => adapter.requests.isNotEmpty);
    adapter.event(0, 'id: 1\nevent: changed\ndata: {"unread":2}\n\n');
    await until(() => source.data['blocked'] == true);
    expect((source.data['events'] as List).single['event'], 'changed');
    expect(
      adapter.requests.single.headers['Authorization'],
      'Bearer test-secret',
    );
    expect(adapter.requests.single.extra['pinnedAddresses'], ['198.18.0.6']);
    expect(adapter.requests.single.followRedirects, false);
    await call(source, 'streams.close', {'id': 'events'});
    await until(() => adapter.cancelled == 1);
  });
  test('隐藏暂停连接，恢复携带最后成功事件 ID，关闭不再重连', () async {
    final source = await open();
    await until(() => adapter.requests.length == 1);
    adapter.event(0, 'id: previous\ndata: hello\n\n');
    await until(() => source.data['blocked'] == true);
    host.setSurfaceForeground(source, false);
    await until(() => adapter.cancelled == 1);
    host.setSurfaceForeground(source, true);
    await until(() => adapter.requests.length == 2);
    expect(adapter.requests.last.headers['Last-Event-ID'], 'previous');
    host.close(source);
    await until(() => adapter.cancelled == 2);
  });
  test('撤销账号凭证立即取消正在接收的流', () async {
    final source = await open();
    await until(() => adapter.requests.isNotEmpty);
    await call(source, 'credentials.remove', {'name': 'account'});
    await until(() => adapter.cancelled == 1);
    expect(await store.readCredential(manifest.id, 'account'), isNull);
  });
  test('换账号的迟到帧不会交给旧页面，撤权回收立即关闭连接', () async {
    final source = await open();
    await until(() => adapter.requests.isNotEmpty);
    delegate.account = 99;
    adapter.event(0, 'data: private\n\n');
    await until(() => adapter.cancelled == 1);
    expect(source.data['events'], isNull);
    host.retire();
    await expectLater(
      call(source, 'streams.open', {
        'id': 'other',
        'url': 'https://service.example/events',
      }),
      throwsA(isA<PluginOperationCancelled>()),
    );
  });
  test('未授予账号权限、隐藏界面和全局脚本不能订阅', () async {
    host.retire();
    host = MetaversePluginHost(
      manifest: manifest,
      store: store,
      network: network,
      delegate: delegate,
      engineFactory: createMetaverseScriptEngine,
      blockedPermissions: {MetaversePluginPermission.serviceAccount},
      codeLoader: () async =>
          (ui: 'import fluxdo; widget Card = Label(text: "test");', script: ''),
    );
    final source = await host.open(kind: 'card');
    await expectLater(
      call(source, 'streams.open', {
        'id': 'e',
        'url': 'https://service.example/events',
        'credential': 'account',
      }),
      throwsA(isA<MetaversePluginCallException>()),
    );
    host.setSurfaceForeground(source, false);
    await expectLater(
      call(source, 'streams.open', {
        'id': 'e',
        'url': 'https://service.example/events',
      }),
      throwsA(isA<MetaversePluginCallException>()),
    );
    await expectLater(
      host.call('streams.open', {
        'id': 'e',
        'url': 'https://service.example/events',
      }),
      throwsA(isA<MetaversePluginCallException>()),
    );
    expect(adapter.requests, isEmpty);
  });
  for (final code in [204, 302, 401, 403, 429, 500]) {
    test('HTTP $code 不跟随跳转，鉴权失败终止，限流尊重 Retry-After', () async {
      adapter.status = code;
      final source = await open();
      await until(
        () => [
          'closed',
          'retrying',
        ].contains((source.data['state'] as Map?)?['state']),
      );
      final state = source.data['state'] as Map;
      expect(
        state['state'],
        code >= 500 || code == 429 ? 'retrying' : 'closed',
      );
      expect(state['status'], code);
      if (code == 429) expect(state['retryInMs'], greaterThanOrEqualTo(120000));
      expect(adapter.requests.length, 1);
    });
  }
  test('HTML 不当作事件、越过凭证路径不发请求', () async {
    adapter.contentType = 'text/html';
    final source = await open();
    await until(() => (source.data['state'] as Map?)?['state'] == 'closed');
    expect(
      (source.data['state'] as Map)['reason'],
      'stream_invalid_content_type',
    );
    await call(source, 'streams.close', {'id': 'events'});
    await call(source, 'streams.open', {
      'id': 'events',
      'url': 'https://service.example/private',
      'credential': 'account',
    });
    await until(
      () => (source.data['state'] as Map?)?['reason'] == 'stream_cancelled',
    );
    expect(adapter.requests.length, 1);
  });
  test('断线重连保留游标，服务端事件不带 ID 时继续使用原游标', () async {
    final source = await open();
    await until(() => adapter.requests.length == 1);
    adapter.event(0, 'id: retained\ndata: one\n\n');
    await until(() => source.data['blocked'] == true);
    await adapter.bodies[0].close();
    await until(() => adapter.requests.length == 2);
    expect(adapter.requests.last.headers['Last-Event-ID'], 'retained');
    adapter.event(1, 'data: two\n\n');
    await until(() => (source.data['events'] as List).length == 2);
    expect((source.data['events'] as List).last['lastEventId'], 'retained');
    await call(source, 'streams.close', {'id': 'events'});
  });
  test('慢处理器期间关闭，立即中止连接且不交付积压事件', () async {
    final source = await open();
    await until(() => adapter.requests.isNotEmpty);
    // 用独立连接管理器模拟业务异步处理，比固定 sleep 更稳定。
    final processing = Completer<void>(),
        entered = Completer<void>(),
        stopped = Completer<void>();
    var count = 0;
    final connection = MetaverseEventStream(
      id: 'slow',
      credential: null,
      budget: MetaverseStreamBudget(),
      connect: (cancel, lastId, onOpen, onEvent, onRetry) async {
        try {
          await onOpen();
          await onEvent(const PluginServerEvent('message', 'one', '1'));
          await onEvent(const PluginServerEvent('message', 'two', '2'));
        } finally {
          stopped.complete();
        }
      },
      emit: (name, args) async {
        if (name == 'stream.event') {
          count++;
          entered.complete();
          await processing.future;
        }
      },
    );
    connection.setActive(true);
    await entered.future;
    connection.close();
    await stopped.future.timeout(const Duration(seconds: 1));
    expect(count, 1);
    processing.complete();
    host.close(source);
  });
  test('未声明域名、内网目标与宿主保留请求头不会访问服务', () async {
    final source = await host.open(kind: 'card');
    var index = 0;
    for (final request in [
      {'url': 'https://other.example/events'},
      {'url': 'https://127.0.0.1/events'},
      {
        'url': 'https://service.example/events',
        'headers': {'Cookie': 'forged'},
      },
    ]) {
      final id = 'bad${index++}';
      await call(source, 'streams.open', {'id': id, ...request});
      await until(
        () =>
            (source.data['state'] as Map?)?['state'] == 'closed' &&
            (source.data['state'] as Map?)?['id'] == id,
      );
      await call(source, 'streams.close', {'id': id});
    }
    expect(adapter.requests, isEmpty);
  });
  test('连接预算按实例与全局计数，释放后可复用', () {
    final budget = MetaverseStreamBudget();
    expect(budget.acquire(), true);
    expect(budget.acquire(), true);
    expect(budget.acquire(), false);
    budget.release();
    expect(budget.acquire(), true);
    budget.release();
    budget.release();
  });
}
