import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

void main() {
  test('重置等待正在写入的操作并拒绝旧代次排队写入', () async {
    final queue = PluginOperationQueue();
    final started = Completer<void>();
    final finish = Completer<void>();
    final values = <int>[];
    final first = queue.run('one', () async {
      started.complete();
      await finish.future;
      values.add(1);
    });
    await started.future;
    final stale = queue.run('one', () async => values.add(2));
    final rejected = expectLater(
      stale,
      throwsA(isA<PluginOperationCancelled>()),
    );
    final reset = queue.reset('one', () async => values.clear());
    final fresh = queue.run('one', () async => values.add(3));
    finish.complete();
    await Future.wait([first, rejected, reset, fresh]);
    expect(values, [3]);
  });

  test('插件之间独立执行且失败后可以继续写入', () async {
    final queue = PluginOperationQueue();
    final finish = Completer<void>();
    final first = queue.run('one', () => finish.future);
    expect(await queue.run('two', () async => 2), 2);
    await expectLater(
      queue.run('two', () async => throw StateError('failed')),
      throwsStateError,
    );
    expect(await queue.run('two', () async => 3), 3);
    finish.complete();
    await first;
  });
}
