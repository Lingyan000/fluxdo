import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/adapters/webview_operation_guard.dart';
import 'package:fluxdo/services/network/adapters/webview_request_codec.dart';

void main() {
  test('发送卡住时取消会停止传输并取消上游订阅，迟到结果不再发送', () async {
    final cancel = Completer<void>();
    final pending = Completer<void>();
    var cancelled = false;
    var sends = 0;
    final stream = StreamController<Uint8List>(
      onCancel: () {
        cancelled = true;
      },
    );
    final error = StateError('取消');
    final guard = WebViewOperationGuard(
      timeout: const Duration(seconds: 2),
      timeoutError: TimeoutException('超时'),
      cancel: cancel.future,
      cancelError: error,
    );
    final result = WebViewRequestCodec.pipe(
      stream.stream,
      useBase64: true,
      guard: guard,
      send: (_) {
        sends++;
        return pending.future;
      },
    );
    final check = expectLater(result, throwsA(same(error)));
    stream.add(Uint8List(100000));
    await Future<void>.delayed(Duration.zero);
    cancel.complete();
    await check;
    expect(cancelled, isTrue);
    pending.complete();
    await Future<void>.delayed(Duration.zero);
    expect(sends, 1);
    guard.dispose();
    await stream.close();
  });

  test('原生发送永不返回也受整体截止时间限制', () async {
    final timeout = TimeoutException('截止');
    final guard = WebViewOperationGuard(
      timeout: const Duration(milliseconds: 20),
      timeoutError: timeout,
      cancelError: StateError('取消'),
    );
    await expectLater(
      WebViewRequestCodec.pipe(
        Stream.value(Uint8List(3)),
        useBase64: true,
        guard: guard,
        send: (_) => Completer<void>().future,
      ),
      throwsA(same(timeout)),
    );
    guard.dispose();
  });

  test('上游没有下一块时取消也能打断等待', () async {
    final cancel = Completer<void>();
    final stream = StreamController<Uint8List>();
    final guard = WebViewOperationGuard(
      timeout: const Duration(seconds: 2),
      timeoutError: TimeoutException('截止'),
      cancel: cancel.future,
      cancelError: StateError('取消'),
    );
    final check = expectLater(
      WebViewRequestCodec.pipe(
        stream.stream,
        useBase64: false,
        guard: guard,
        send: (_) async {},
      ),
      throwsStateError,
    );
    cancel.complete();
    await check;
    guard.dispose();
    await stream.close();
  });

  test('页面报告传输失败立即停止，后续操作不执行', () async {
    final guard = WebViewOperationGuard(
      timeout: const Duration(seconds: 2),
      timeoutError: TimeoutException('截止'),
      cancelError: StateError('取消'),
    );
    var ran = false;
    guard.stop(StateError('页面拒绝块'));
    await expectLater(
      guard.run(() async {
        ran = true;
      }),
      throwsStateError,
    );
    expect(ran, isFalse);
    guard.dispose();
  });

  test('生产页面清理脚本释放块并关闭端口，迟到消息不再写入', () async {
    final source = File(
      'lib/services/network/adapters/webview_http_adapter.dart',
    ).readAsStringSync();
    final start = source.indexOf(
      'window.__fluxdoDiscardRequestBody = function',
    );
    final end = source.indexOf('          function ensureState', start);
    final process = await Process.start('node', []);
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    process.stdin.write('''
const window = {__fluxdoRequestBodyTransfers: new Map()};
let closed = 0;
const state = {chunks: [new Uint8Array(100)], body: new Blob(['data']), port: {close() {closed++;}}};
window.__fluxdoRequestBodyTransfers.set('x', state);
${source.substring(start, end)}
window.__fluxdoDiscardRequestBody('x');
window.__fluxdoDiscardRequestBody('x');
if (closed !== 1 || state.chunks.length || state.body !== null || !state.discarded || window.__fluxdoRequestBodyTransfers.size) process.exit(1);
''');
    await process.stdin.close();
    expect(await process.exitCode, 0, reason: await err);
    await out;
    expect(source, contains('if (state.discarded) return;'));
  });
}
