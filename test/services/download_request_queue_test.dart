import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/download_request_queue.dart';

void main() {
  test('取消排队任务不会占槽或释放其他任务的槽', () async {
    final queue = DownloadRequestQueue(1);
    await queue.acquire('active', DownloadPriority.normal);
    final cancelled = Completer<void>();
    final waiting = queue.acquire(
      'gone',
      DownloadPriority.high,
      cancelled: cancelled.future,
    );
    final check = expectLater(waiting, throwsA(isA<DownloadQueueCancelled>()));
    cancelled.complete();
    await check;
    var started = false;
    final next = queue
        .acquire('next', DownloadPriority.normal)
        .then((_) => started = true);
    await Future<void>.delayed(Duration.zero);
    expect(started, isFalse);
    queue.release();
    await next;
    queue.release();
    expect(queue.release, throwsStateError);
  });

  test('首绘早于下载入队时仍可取得保留槽', () async {
    final q = DownloadRequestQueue(2, reservedHighSlots: 1);
    await q.acquire('background', DownloadPriority.normal);
    final release = q.retainForeground('visible');
    await q.acquire('visible', DownloadPriority.normal);
    release();
    release(); // 释放幂等
    q.release();
    q.release();
  });

  test('同 URL 多视图最后一个释放后才降低优先级', () async {
    final q = DownloadRequestQueue(2, reservedHighSlots: 1);
    await q.acquire('a', DownloadPriority.high);
    await q.acquire('b', DownloadPriority.high);
    final first = q.retainForeground('shared');
    final second = q.retainForeground('shared');
    var started = false;
    final waiting = q
        .acquire('shared', DownloadPriority.normal)
        .then((_) => started = true);
    first();
    q.release();
    await waiting;
    expect(started, isTrue);
    second();
    q.release();
    q.release();
  });

  test('已离开的视图不占保留槽，主动高优请求不会被降级', () async {
    final q = DownloadRequestQueue(2, reservedHighSlots: 1);
    await q.acquire('a', DownloadPriority.high);
    await q.acquire('b', DownloadPriority.high);
    final release = q.retainForeground('gone');
    var started = false;
    final waiting = q
        .acquire('gone', DownloadPriority.normal)
        .then((_) => started = true);
    release();
    q.release();
    await Future<void>.delayed(Duration.zero);
    expect(started, isFalse);
    final stop = q.retainForeground('save');
    stop();
    await q.acquire('save', DownloadPriority.high);
    q.release();
    q.release();
    await waiting;
    q.release();
  });
  test('下层下载一直不完成时市场仍获得保留槽', () async {
    final q = DownloadRequestQueue(3, reservedHighSlots: 1);
    await q.acquire('lower1', DownloadPriority.normal);
    await q.acquire('lower2', DownloadPriority.normal);
    var lowerStarted = false;
    final lower = q
        .acquire('lower3', DownloadPriority.normal)
        .then((_) => lowerStarted = true);
    await q.acquire('market', DownloadPriority.high);
    expect(lowerStarted, isFalse);
    q.release();
    await Future<void>.delayed(Duration.zero);
    expect(lowerStarted, isFalse);
    q.release();
    await lower;
    expect(lowerStarted, isTrue);
    q.release();
    q.release();
    expect(q.release, throwsStateError);
  });
  test('提权已有后台排队URL无需等下层释放且保持FIFO', () async {
    final q = DownloadRequestQueue(3, reservedHighSlots: 1);
    await q.acquire('a', DownloadPriority.normal);
    await q.acquire('b', DownloadPriority.normal);
    final order = <String>[];
    final c = q
        .acquire('c', DownloadPriority.normal)
        .then((_) => order.add('c'));
    final d = q
        .acquire('d', DownloadPriority.normal)
        .then((_) => order.add('d'));
    q.bump('d');
    q.bump('d');
    await d;
    expect(order, ['d']);
    q.release();
    q.release();
    await c;
    expect(order, ['d', 'c']);
    q.release();
    q.release();
  });
  test('普通通道不预留槽，高优释放时先行', () async {
    final q = DownloadRequestQueue(1);
    await q.acquire('a', DownloadPriority.normal);
    final order = <String>[];
    final low = q
        .acquire('b', DownloadPriority.normal)
        .then((_) => order.add('b'));
    final high = q
        .acquire('c', DownloadPriority.high)
        .then((_) => order.add('c'));
    q.release();
    await high;
    q.release();
    await low;
    expect(order, ['c', 'b']);
    q.release();
  });

  test('共享池按组轮转，后来的头像不排在整批表情之后', () async {
    final q = DownloadRequestQueue(2, groupLimits: {'emoji': 2, 'avatar': 1});
    await q.acquire('e1', DownloadPriority.normal, group: 'emoji');
    await q.acquire('e2', DownloadPriority.normal, group: 'emoji');
    final order = <String>[];
    final e3 = q
        .acquire('e3', DownloadPriority.normal, group: 'emoji')
        .then((_) => order.add('e3'));
    final e4 = q
        .acquire('e4', DownloadPriority.normal, group: 'emoji')
        .then((_) => order.add('e4'));
    final avatar = q
        .acquire('a', DownloadPriority.normal, group: 'avatar')
        .then((_) => order.add('a'));
    q.release(group: 'emoji');
    await avatar.timeout(const Duration(seconds: 1));
    expect(order, ['a']);
    q.release(group: 'emoji');
    await e3;
    q.release(group: 'avatar');
    await e4;
    expect(order, ['a', 'e3', 'e4']);
    q.release(group: 'emoji');
    q.release(group: 'emoji');
  });

  test('高优组达到组内上限不会挡住其他组，也不能越过上限', () async {
    final q = DownloadRequestQueue(3, groupLimits: {'emoji': 3, 'avatar': 1});
    await q.acquire('a1', DownloadPriority.high, group: 'avatar');
    var nextAvatarStarted = false;
    final a2 = q
        .acquire('a2', DownloadPriority.high, group: 'avatar')
        .then((_) => nextAvatarStarted = true);
    await q.acquire('e1', DownloadPriority.normal, group: 'emoji');
    await q.acquire('e2', DownloadPriority.normal, group: 'emoji');
    expect(nextAvatarStarted, isFalse);
    expect(() => q.release(group: 'unknown'), throwsStateError);
    q.release(group: 'avatar');
    await a2;
    expect(nextAvatarStarted, isTrue);
    q.release(group: 'avatar');
    q.release(group: 'emoji');
    q.release(group: 'emoji');
  });

  test('分组等待取消后不占配额，错误组名不会进入队列', () async {
    final q = DownloadRequestQueue(2, groupLimits: {'avatar': 1});
    expect(
      () => q.acquire('bad', DownloadPriority.normal, group: 'missing'),
      throwsArgumentError,
    );
    await q.acquire('a1', DownloadPriority.normal, group: 'avatar');
    final cancel = Completer<void>();
    final gone = q.acquire(
      'gone',
      DownloadPriority.normal,
      group: 'avatar',
      cancelled: cancel.future,
    );
    final check = expectLater(gone, throwsA(isA<DownloadQueueCancelled>()));
    cancel.complete();
    await check;
    final next = q.acquire('a2', DownloadPriority.normal, group: 'avatar');
    q.release(group: 'avatar');
    await next;
    q.release(group: 'avatar');
    expect(() => q.release(group: 'avatar'), throwsStateError);
  });
  test('三个组同时排队按轮次取得名额，不只在前两个组之间交替', () async {
    final q = DownloadRequestQueue(1, groupLimits: {'a': 1, 'b': 1, 'c': 1});
    await q.acquire('first', DownloadPriority.normal, group: 'a');
    final order = <String>[];
    final pending = <String, Future<void>>{};
    for (final group in ['a', 'b', 'c']) {
      for (var i = 1; i <= 2; i++) {
        final name = '$group$i';
        pending[name] = q
            .acquire(name, DownloadPriority.normal, group: group)
            .then((_) => order.add(name));
      }
    }
    var currentGroup = 'a';
    for (final name in ['b1', 'c1', 'a1', 'b2', 'c2', 'a2']) {
      q.release(group: currentGroup);
      await pending[name]!.timeout(const Duration(seconds: 1));
      currentGroup = name[0];
    }
    q.release(group: currentGroup);
    expect(order, ['b1', 'c1', 'a1', 'b2', 'c2', 'a2']);
  });
}
