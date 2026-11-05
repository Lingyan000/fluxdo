import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/image_cache_write_queue.dart';

void main() {
  test('大文件等待独占时小文件不能持续插队造成饥饿', () async {
    final queue = ImageCacheWriteQueue(maxCount: 2, maxBytes: 8);
    final first = Completer<void>();
    final second = Completer<void>();
    final large = Completer<void>();
    await queue.schedule('a', Uint8List(1), () => first.future);
    await queue.schedule('b', Uint8List(1), () => second.future);
    final order = <String>[];
    final largeWrite = queue.schedule('large', Uint8List(9), () {
      order.add('large');
      return large.future;
    });
    final smallWrite = queue.schedule('small', Uint8List(1), () async {
      order.add('small');
    });
    first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(order, isEmpty);
    second.complete();
    await Future<void>.delayed(Duration.zero);
    expect(order, ['large']);
    large.complete();
    await Future.wait([largeWrite, smallWrite]);
    expect(order, ['large', 'small']);
    await queue.finishWhere((_) => true);
  });
  test('解码可先取得同一份字节，写入数量达到上限后背压', () async {
    final queue = ImageCacheWriteQueue(maxCount: 2, maxBytes: 8);
    final first = Completer<void>();
    final second = Completer<void>();
    final third = Completer<void>();
    final bytes = Uint8List(2);
    await queue.schedule('a', bytes, () => first.future);
    expect(identical(queue['a']!.bytes, bytes), isTrue);
    await queue.schedule('b', Uint8List(2), () => second.future);
    var started = false;
    final waiting = queue.schedule('c', Uint8List(2), () {
      started = true;
      return third.future;
    });
    await Future<void>.delayed(Duration.zero);
    expect(started, isFalse);
    first.complete();
    await waiting;
    expect(started, isTrue);
    expect(queue['a'], isNull);
    second.complete();
    third.complete();
    await queue.finishWhere((_) => true);
  });

  test('按字节限额背压，不仅限制任务数', () async {
    final queue = ImageCacheWriteQueue(maxCount: 3, maxBytes: 8);
    final first = Completer<void>();
    final second = Completer<void>();
    await queue.schedule('a', Uint8List(6), () => first.future);
    var started = false;
    final waiting = queue.schedule('b', Uint8List(3), () {
      started = true;
      return second.future;
    });
    await Future<void>.delayed(Duration.zero);
    expect(started, isFalse);
    first.complete();
    await waiting;
    expect(started, isTrue);
    second.complete();
    await queue.finishWhere((_) => true);
  });

  test('超大文件独占且等待落盘，不作为超预算后台任务返回', () async {
    final queue = ImageCacheWriteQueue(maxBytes: 8);
    final large = Completer<void>();
    var returned = false;
    final writing = queue
        .schedule('large', Uint8List(9), () => large.future)
        .then((_) => returned = true);
    var smallStarted = false;
    final small = queue.schedule('small', Uint8List(1), () async {
      smallStarted = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(returned, isFalse);
    expect(smallStarted, isFalse);
    large.complete();
    await Future.wait([writing, small]);
    expect(returned, isTrue);
    expect(smallStarted, isTrue);
    await queue.finishWhere((_) => true);
  });

  test('写入失败释放预算且没有后台未处理异常', () async {
    final queue = ImageCacheWriteQueue(maxCount: 1);
    final failure = Completer<void>();
    await queue.schedule('bad', Uint8List(2), () => failure.future);
    final result = queue['bad']!.completed;
    final next = queue.schedule('next', Uint8List(2), () async {});
    failure.completeError(StateError('disk full'));
    expect(await result, isFalse);
    await next;
    await queue.finishWhere((_) => true);
    expect(queue['bad'], isNull);
  });

  test('清理期间失效的等待任务不会重新落盘', () async {
    final queue = ImageCacheWriteQueue(maxCount: 1);
    final gate = Completer<void>();
    await queue.schedule('a', Uint8List(1), () => gate.future);
    var current = true;
    var wrote = false;
    final waiting = queue.schedule('b', Uint8List(1), () async {
      wrote = true;
    }, isCurrent: () => current);
    current = false;
    gate.complete();
    await waiting;
    expect(wrote, isFalse);
    expect(queue['b'], isNull);
  });
}
