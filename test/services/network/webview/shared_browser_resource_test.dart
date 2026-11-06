import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/webview/shared_browser_resource.dart';

Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  late SharedBrowserResource<int> pool;
  late int created;
  late List<int> destroyed;
  setUp(() {
    created = 0;
    destroyed = [];
    pool = SharedBrowserResource(
      create: () async => ++created,
      destroy: (value) async => destroyed.add(value),
    );
  });
  tearDown(() async {
    pool.invalidate();
    await tick();
  });

  test('并发申请只创建一次，释放一个租约不会影响另一个', () async {
    final leases = await Future.wait([pool.acquire(), pool.acquire()]);
    expect(created, 1);
    expect(leases.map((e) => e.value), [1, 1]);
    leases.first.release();
    leases.first.release();
    expect(pool.activeCount, 1);
    expect(destroyed, isEmpty);
    expect(leases.last.isCurrent, isTrue);
    leases.last.release();
    final reused = await pool.acquire();
    expect(created, 1);
    reused.release();
  });

  test('独占任务等待在途任务，后来的共享任务不能插队', () async {
    final first = await pool.acquire();
    var exclusiveGranted = false;
    var sharedGranted = false;
    final exclusive = pool.acquire(exclusive: true).then((lease) {
      exclusiveGranted = true;
      return lease;
    });
    final shared = pool.acquire().then((lease) {
      sharedGranted = true;
      return lease;
    });
    await tick();
    expect(exclusiveGranted, isFalse);
    first.release();
    final writer = await exclusive;
    expect(sharedGranted, isFalse);
    writer.release();
    (await shared).release();
    expect(created, 1);
  });

  test('取消排队任务不会阻塞后续共享任务', () async {
    final first = await pool.acquire();
    final cancel = Completer<void>();
    final waiting = pool.acquire(exclusive: true, cancelled: cancel.future);
    final failure = expectLater(waiting, throwsStateError);
    final next = pool.acquire();
    cancel.complete();
    await failure;
    (await next).release();
    first.release();
    expect(created, 1);
  });

  test('初始化失败不会毒化后续申请', () async {
    pool = SharedBrowserResource(
      create: () async {
        if (++created == 1) throw StateError('创建失败');
        return created;
      },
      destroy: (value) async => destroyed.add(value),
    );
    await expectLater(pool.acquire(), throwsStateError);
    final next = await pool.acquire();
    expect(next.value, 2);
    next.release();
  });

  test('会话变更使旧租约和排队任务失效，等待清理后才重建', () async {
    final first = await pool.acquire();
    final waiting = pool.acquire(exclusive: true);
    final failure = expectLater(waiting, throwsStateError);
    pool.invalidate();
    expect(first.isCurrent, isFalse);
    final next = pool.acquire();
    await tick();
    expect(created, 1);
    expect(destroyed, isEmpty);
    first.release();
    final fresh = await next;
    await failure;
    expect(fresh.value, 2);
    expect(destroyed, [1]);
    fresh.release();
  });

  test('创建期间失效不会把迟到实例交给新会话', () async {
    final creation = Completer<int>();
    pool = SharedBrowserResource(
      create: () async => ++created == 1 ? creation.future : created,
      destroy: (value) async => destroyed.add(value),
    );
    final old = pool.acquire();
    final failure = expectLater(old, throwsStateError);
    pool.invalidate();
    final next = pool.acquire();
    creation.complete(1);
    await failure;
    final fresh = await next;
    expect(fresh.value, 2);
    expect(destroyed, [1]);
    fresh.release();
  });

  test('排空等待原生析构结束，恢复前不创建实例', () async {
    final disposal = Completer<void>();
    pool = SharedBrowserResource(
      create: () async => ++created,
      destroy: (_) => disposal.future,
    );
    final first = await pool.acquire();
    var drained = false;
    final drain = pool.suspendAndDrain().then((_) => drained = true);
    final next = pool.acquire();
    first.release();
    await tick();
    expect(drained, isFalse);
    expect(created, 1);
    disposal.complete();
    await drain;
    expect(created, 1);
    pool.resume();
    (await next).release();
    expect(created, 2);
  });

  test('空闲后回收，下次按需重建', () async {
    pool = SharedBrowserResource(
      create: () async => ++created,
      destroy: (value) async => destroyed.add(value),
      idleTimeout: Duration.zero,
    );
    (await pool.acquire()).release();
    await tick();
    expect(destroyed, [1]);
    (await pool.acquire()).release();
    expect(created, 2);
  });

  test('原生析构失败时拒绝创建重叠实例', () async {
    pool = SharedBrowserResource(
      create: () async => ++created,
      destroy: (_) async => throw StateError('原生析构失败'),
    );
    final first = await pool.acquire();
    pool.invalidate();
    final next = pool.acquire();
    final failure = expectLater(next, throwsStateError);
    first.release();
    await failure;
    await expectLater(pool.acquire(), throwsStateError);
    expect(created, 1);
  });
}
