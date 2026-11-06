import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/auth_session.dart';
import 'package:fluxdo/services/network/adapters/webview_http_adapter.dart';
import 'package:fluxdo/services/network/webview/shared_browser_resource.dart';
import 'package:fluxdo/services/network/webview/site_webview_runtime.dart';

class _Runtime implements SiteWebViewRuntime {
  _Runtime() {
    controller = _Controller(this);
    pool = SharedBrowserResource(
      create: () async {
        creations++;
        return SiteWebView()..controller = controller;
      },
      destroy: (_) async {},
    );
  }
  late final _Controller controller;
  late final SharedBrowserResource<SiteWebView> pool;
  final callbacks = <String, void Function(String)>{};
  final started = <String>[];
  final aborted = <String>[];
  final _interrupted = Completer<void>();
  int creations = 0;
  int _id = 0;
  @override
  Future<void> get interrupted => _interrupted.future;
  @override
  String nextRequestId() => 'test_${++_id}';
  @override
  Future<BrowserResourceLease<SiteWebView>> acquire({
    bool exclusive = false,
    Future<void>? cancelled,
  }) => pool.acquire(exclusive: exclusive, cancelled: cancelled);
  @override
  void registerResponse(String id, void Function(String) callback) {
    callbacks[id] = callback;
  }

  @override
  void removeResponse(String id) => callbacks.remove(id);
  void respond(String id, String body) => callbacks[id]?.call(
    jsonEncode({
      'ok': true,
      'status': 200,
      'body': body,
      'headers': <String, String>{},
    }),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Controller implements InAppWebViewController {
  _Controller(this.runtime);
  final _Runtime runtime;
  final channels = <String, _Channel>{};
  _Channel? _newChannel;

  @override
  Future<WebMessageChannel?> createWebMessageChannel() async =>
      _newChannel = _Channel();

  @override
  Future<void> postWebMessage({
    required WebMessage message,
    WebUri? targetOrigin,
  }) async {
    final id = (message.data as String).split(':').last;
    final channel = _newChannel!;
    channels[id] = channel;
    channel.port1.send({'kind': 'ready', 'requestId': id});
  }

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    final request = RegExp(r'const requestId = "(test_\d+)"')
        .firstMatch(source);
    if (request != null) {
      final id = request.group(1)!;
      runtime.started.add(id);
      channels[id]?.port1.send({
        'kind': 'headers',
        'status': 200,
        'headers': <String, String>{},
      });
    }
    final abort = RegExp(r'__fluxdoAbortFetch\("(test_\d+)"\)')
        .firstMatch(source);
    if (abort != null) runtime.aborted.add(abort.group(1)!);
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Port implements WebMessagePort {
  WebMessageCallback? callback;
  @override
  Future<void> setWebMessageCallback(WebMessageCallback? onMessage) async {
    callback = onMessage;
  }

  void send(Map<String, Object> data) =>
      callback?.call(WebMessage(data: jsonEncode(data)));
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Channel implements WebMessageChannel {
  @override
  final _Port port1 = _Port();
  @override
  final _Port port2 = _Port();
  @override
  void dispose() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> tick() => Future<void>.delayed(Duration.zero);
RequestOptions request() => RequestOptions(path: 'https://example.com/data');

void main() {
  late _Runtime runtime;
  late WebViewHttpAdapter first;
  late WebViewHttpAdapter second;
  setUp(() {
    runtime = _Runtime();
    first = WebViewHttpAdapter(runtime: runtime);
    second = WebViewHttpAdapter(runtime: runtime);
  });
  tearDown(() async {
    first.close(force: true);
    second.close(force: true);
    runtime.pool.invalidate();
    await tick();
  });

  test('多个适配器共享实例，乱序响应按全局请求 ID 正确分发', () async {
    final a = first.fetch(request(), null, null);
    final b = second.fetch(request(), null, null);
    await tick();
    expect(runtime.creations, 1);
    expect(runtime.started, ['test_1', 'test_2']);
    runtime.respond('test_2', 'second');
    runtime.respond('test_1', 'first');
    expect(await utf8.decodeStream((await a).stream), 'first');
    expect(await utf8.decodeStream((await b).stream), 'second');
    expect(runtime.callbacks, isEmpty);
    expect(runtime.pool.activeCount, 0);
  });

  test('强制关闭只取消自己的请求，不中断另一个适配器', () async {
    final a = first.fetch(request(), null, null);
    final aError = expectLater(a, throwsA(isA<DioException>()));
    final b = second.fetch(request(), null, null);
    await tick();
    first.close(force: true);
    await aError;
    expect(runtime.pool.activeCount, 1);
    expect(runtime.aborted, contains('test_1'));
    expect(runtime.aborted, isNot(contains('test_2')));
    runtime.respond('test_2', 'survived');
    expect(await utf8.decodeStream((await b).stream), 'survived');
  });

  test('正常关闭允许在途请求结束，并拒绝新请求', () async {
    final response = first.fetch(request(), null, null);
    await tick();
    first.close();
    await expectLater(first.fetch(request(), null, null), throwsStateError);
    runtime.respond('test_1', 'finished');
    expect(await utf8.decodeStream((await response).stream), 'finished');
  });

  test('账号会话变更取消所有旧请求并清除响应路由', () async {
    final a = first.fetch(request(), null, null);
    final b = second.fetch(request(), null, null);
    final errors = Future.wait([
      expectLater(a, throwsA(isA<DioException>())),
      expectLater(b, throwsA(isA<DioException>())),
    ]);
    await tick();
    AuthSession().advance();
    await errors;
    expect(runtime.callbacks, isEmpty);
    expect(runtime.pool.activeCount, 0);
    runtime.respond('test_1', '迟到的旧会话响应');
  });

  test('独占任务等待 HTTP 清理完成，后续请求使用同一个实例', () async {
    final response = first.fetch(request(), null, null);
    await tick();
    var exclusiveStarted = false;
    final exclusive = runtime.acquire(exclusive: true).then((lease) {
      exclusiveStarted = true;
      return lease;
    });
    final next = second.fetch(request(), null, null);
    await tick();
    expect(exclusiveStarted, isFalse);
    expect(runtime.started, ['test_1']);
    runtime.respond('test_1', 'done');
    await response;
    final lease = await exclusive;
    expect(runtime.aborted, contains('test_1'));
    expect(runtime.started, ['test_1']);
    lease.release();
    await tick();
    runtime.respond('test_2', 'next');
    await next;
    expect(runtime.creations, 1);
  });

  test('排队期间强制关闭，不执行迟到的请求', () async {
    final lease = await runtime.acquire(exclusive: true);
    final response = first.fetch(request(), null, null);
    final error = expectLater(response, throwsStateError);
    first.close(force: true);
    await error;
    lease.release();
    await tick();
    expect(runtime.started, isEmpty);
  });

  test('二进制响应头返回后仍持有租约，数据接收完成才允许切页', () async {
    final response = await first.fetch(
      request()..responseType = ResponseType.stream,
      null,
      null,
    );
    var exclusiveStarted = false;
    final exclusive = runtime.acquire(exclusive: true).then((lease) {
      exclusiveStarted = true;
      return lease;
    });
    final body = response.stream.toList();
    await tick();
    expect(exclusiveStarted, isFalse);
    expect(runtime.pool.activeCount, 1);
    final port = runtime.controller.channels['test_1']!.port1;
    port.send({
      'kind': 'chunk',
      'encoding': 'base64',
      'data': base64Encode([1, 2, 3]),
    });
    port.send({'kind': 'complete'});
    expect((await body).expand((bytes) => bytes).toList(), [1, 2, 3]);
    (await exclusive).release();
    expect(runtime.aborted, contains('test_1'));
  });

  test('关闭流所属适配器释放租约，其他适配器仍能使用实例', () async {
    final response = await first.fetch(
      request()..responseType = ResponseType.stream,
      null,
      null,
    );
    final streamError = expectLater(
      response.stream.drain<void>(),
      throwsA(isA<DioException>()),
    );
    first.close(force: true);
    await streamError;
    await tick();
    expect(runtime.pool.activeCount, 0);
    final next = second.fetch(request(), null, null);
    await tick();
    runtime.respond('test_2', 'ok');
    await next;
    expect(runtime.creations, 1);
  });
}
