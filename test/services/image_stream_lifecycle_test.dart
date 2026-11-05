import 'dart:async';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/image_stream_lifecycle.dart';
import 'package:fluxdo/utils/image_decode_gate.dart';

void main() {
  testWidgets('缓存监听不保活下载，两个真实消费者均离开后才取消', (tester) async {
    final cache = ManagedImageCache();
    final token = CancelToken();
    final stream = CancelableImageStreamCompleter(
      codec: Completer<ui.Codec>().future,
      scale: 1,
      cancellation: token,
    );
    final key = Object();
    cache.putIfAbsent(key, () => stream);
    final a = ImageStreamListener((_, _) {});
    final b = ImageStreamListener((_, _) {});
    stream.addListener(a);
    stream.addListener(b);
    stream.removeListener(a);
    await tester.pump(const Duration(milliseconds: 300));
    expect(token.isCancelled, isFalse);
    stream.removeListener(b);
    await tester.pump(const Duration(milliseconds: 200));
    stream.addListener(b);
    await tester.pump(const Duration(milliseconds: 100));
    expect(token.isCancelled, isFalse);
    stream.removeListener(b);
    await tester.pump(const Duration(milliseconds: 300));
    expect(token.isCancelled, isTrue);
    expect(cache.containsKey(key), isFalse);
  });

  test('解码字节预算让超大图独占且 FIFO 防止饿死', () async {
    final first = Completer<void>();
    final large = Completer<void>();
    final started = <String>[];
    final a = ImageDecodeGate.run(() async {
      started.add('a');
      await first.future;
    }, estimatedBytes: 24 << 20);
    final b = ImageDecodeGate.run(() async {
      started.add('b');
      await large.future;
    }, estimatedBytes: 40 << 20);
    final c = ImageDecodeGate.run(() async {
      started.add('c');
    }, estimatedBytes: 1 << 20);
    await Future<void>.delayed(Duration.zero);
    expect(started, ['a']);
    first.complete();
    await a;
    await Future<void>.delayed(Duration.zero);
    expect(started, ['a', 'b']);
    large.complete();
    await Future.wait([b, c]);
    expect(started, ['a', 'b', 'c']);
  });
}
