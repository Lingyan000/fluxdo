import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/raw_cookie_writer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.fluxdo/raw_cookie');
  final writer = RawCookieWriter.forTesting();
  tearDown(() {
    writer.invalidateReads();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test('并发计数与枚举共用原生读取，完成后重新读取', () async {
    var reads = 0;
    final released = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getAllCookieInfos');
          reads++;
          await released.future;
          return [
            {'name': '_t', 'value': 'token', 'domain': 'linux.do', 'path': '/'},
          ];
        });
    final first = writer.getAllCookieInfos('https://linux.do');
    final second = writer.countCookiesByName('https://linux.do', '_t');
    await Future<void>.delayed(Duration.zero);
    expect(reads, 1);
    released.complete();
    expect((await first).length, 1);
    expect(await second, 1);
    await writer.getAllCookieInfos('https://linux.do');
    expect(reads, 2);
  });
  test('写入后不会复用写入前仍未返回的快照', () async {
    final old = Completer<Object?>();
    var reads = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'setRawCookie') return true;
          reads++;
          if (reads == 1) return old.future;
          return [
            {'name': '_t', 'value': 'new', 'domain': 'linux.do', 'path': '/'},
          ];
        });
    final stale = writer.getAllCookieInfos('https://linux.do');
    await writer.setRawCookie('https://linux.do', '_t=new; Path=/');
    expect(
      (await writer.getAllCookieInfos('https://linux.do')).single.value,
      'new',
    );
    old.complete([
      {'name': '_t', 'value': 'old', 'domain': 'linux.do', 'path': '/'},
    ]);
    await stale;
    expect(reads, 2);
  });
}
