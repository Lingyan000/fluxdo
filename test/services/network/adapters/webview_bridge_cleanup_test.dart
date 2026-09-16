import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/adapters/webview_http_adapter.dart';

class _Port implements WebMessagePort {
  int closes = 0;
  @override
  Future<void> close() async {
    closes++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Channel implements WebMessageChannel {
  @override
  final _Port port1 = _Port();
  @override
  final _Port port2 = _Port();
  int disposals = 0;
  @override
  void dispose() {
    disposals++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('响应头监听前发生错误不会产生未处理异常，原 await 仍能收到错误', () async {
    final channel = _Channel();
    final bridge = WebViewBinaryResponseBridge(
      requestOptions: RequestOptions(path: '/image'),
      channel: channel,
      onCancel: () async {},
    );
    final error = StateError('建桥失败');
    bridge.completeError(error);
    await Future<void>.delayed(Duration.zero);
    await expectLater(bridge.headersCompleter.future, throwsA(same(error)));
    await expectLater(bridge.stream.drain<void>(), throwsA(same(error)));
    await bridge.done;
    expect(channel.disposals, 1);
    expect(channel.port1.closes, 1);
    expect(channel.port2.closes, 1);
    bridge.completeError(error);
    bridge.complete();
    expect(channel.disposals, 1);
  });

  test('流取消主动结束桥，不依赖页面错误回调清理', () async {
    final channel = _Channel();
    var aborted = 0;
    final bridge = WebViewBinaryResponseBridge(
      requestOptions: RequestOptions(path: '/image'),
      channel: channel,
      onCancel: () async {
        aborted++;
      },
    );
    final subscription = bridge.stream.listen((_) {});
    await subscription.cancel();
    await bridge.done;
    expect(aborted, 1);
    expect(channel.disposals, 1);
    expect(channel.port1.closes, 1);
    expect(channel.port2.closes, 1);
  });
}
