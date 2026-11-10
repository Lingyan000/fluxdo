import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/raw_cookie_writer.dart';
import 'package:fluxdo/services/network/cookie/session_cookie_sentinel.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';

import '../../../support/cookie_sync_fakes.dart';

void main() {
  testWidgets('原生读取超时释放同名锁，后续清理可恢复且不执行误删除', (tester) async {
    const channel = MethodChannel('com.fluxdo/raw_cookie');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final sentinel = SessionCookieSentinel.instance;
    final writer = RawCookieWriter.forTesting();
    sentinel.resetForTest();
    sentinel.replaceDependenciesForTest(writer: writer, jar: MemoryJar());
    final stale = Completer<Object?>();
    var reads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expectSync(call.method, 'getAllCookieInfos', reason: '读取失败不能误判为空再写入/删除');
      if (++reads == 1) return stale.future;
      return [
        {'name': '_t', 'value': 'old', 'domain': 'linux.do', 'path': '/'},
      ];
    });
    addTearDown(() async {
      await sentinel.drain();
      sentinel.resetForTest();
      sentinel.replaceDependenciesForTest(
        writer: RawCookieWriter.instance,
        jar: CookieJarService(),
      );
      messenger.setMockMethodCallHandler(channel, null);
    });
    final first = sentinel.sweep(origin, '_t', force: true);
    await tester.pump();
    final queued = sentinel.sweep(origin, '_t', force: true);
    await tester.pump();
    expect(reads, 1);
    await tester.pump(const Duration(seconds: 5));
    final failed = await first;
    expect(failed.status, SweepStatus.failed);
    expect(failed.elapsed, const Duration(seconds: 5));
    expect((await queued).status, SweepStatus.noop);
    expect(reads, 2);
    stale.complete([]);
    await tester.pump();
    expect(
      (await sentinel.sweep(origin, '_t', force: true)).status,
      SweepStatus.noop,
    );
  });
}
