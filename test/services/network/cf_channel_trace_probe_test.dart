import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/log/log_writer.dart';
import 'package:fluxdo/services/network/cf_channel_trace_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    await LogWriter.resetForTesting();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cf_trace_probe_test_');
    await LogWriter.initForTesting(tempDir);
  });

  tearDown(() async {
    await LogWriter.resetForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('parseTraceBody 正确解析 Cloudflare trace 键值对', () {
    const sample = '''
fl=123f45
h=linux.do
ip=203.0.113.42
ts=1730000000.123
visit_scheme=https
uag=Mozilla/5.0
colo=HKG
http=http/2
tls=TLSv1.3
sni=plaintext
warp=off
kex=X25519
''';
    final parsed = CfChannelTraceProbe.parseTraceBody(sample);
    expect(parsed['ip'], '203.0.113.42');
    expect(parsed['colo'], 'HKG');
    expect(parsed['http'], 'http/2');
    expect(parsed['tls'], 'TLSv1.3');
    expect(parsed['kex'], 'X25519');
    expect(parsed['warp'], 'off');
    expect(parsed['sni'], 'plaintext');
  });

  test('同出口与不同协议对照准确脱敏落盘，绝不泄露明文 IP', () async {
    const rawIp = '198.51.100.77';
    final probe = CfChannelTraceProbe.forTesting(
      coreFetcher: (_) async => const CfTraceRawResult(
        ok: true,
        statusCode: 200,
        body:
            'ip=$rawIp\ncolo=HKG\nhttp=http/2\ntls=TLSv1.3\nkex=X25519\nwarp=off\nsni=plaintext\n',
      ),
      webViewFetcher: (_) async => const CfTraceRawResult(
        ok: true,
        statusCode: 200,
        body:
            'ip=$rawIp\ncolo=HKG\nhttp=http/3\ntls=TLSv1.3\nkex=X25519MLKEM768\nwarp=off\nsni=plaintext\n',
      ),
    );

    final report = await probe.probeIfNeeded(
      triggerPath: '/latest.json',
      triggerStatusCode: 403,
    );
    expect(report, isNotNull);
    expect(report!.sameIp, isTrue);
    expect(report.sameColo, isTrue);
    expect(report.sameHttp, isFalse);
    expect(report.sameTls, isTrue);
    expect(report.sameKex, isFalse);
    expect(report.core.ipVersion, 'v4');
    expect(report.core.ipHash, isNotNull);
    expect(report.core.ipHash, equals(report.webview.ipHash));
    expect(jsonEncode(report.toJson()), isNot(contains(rawIp)));

    await LogWriter.instance.flushNow();
    final logText = await _readAllLogText(tempDir);
    expect(logText, contains('cf_channel_trace_compare'));
    expect(logText, contains('"sameIp":true'));
    expect(logText, contains('"sameHttp":false'));
    expect(logText, isNot(contains(rawIp)));
  });

  test('不同出口 IPv4/IPv6 与机房时准确标出 sameIp=false 且不记明文', () async {
    const ipA = '203.0.113.10';
    const ipB = '2001:db8::9';
    final probe = CfChannelTraceProbe.forTesting(
      coreFetcher: (_) async => const CfTraceRawResult(
        ok: true,
        statusCode: 200,
        body: 'ip=$ipA\ncolo=LAX\nhttp=http/2\ntls=TLSv1.3\nkex=X25519\n',
      ),
      webViewFetcher: (_) async => const CfTraceRawResult(
        ok: true,
        statusCode: 200,
        body: 'ip=$ipB\ncolo=SIN\nhttp=http/2\ntls=TLSv1.3\nkex=X25519\n',
      ),
    );

    final report = await probe.probeIfNeeded(
      triggerPath: '/',
      triggerStatusCode: 403,
    );
    expect(report, isNotNull);
    expect(report!.sameIp, isFalse);
    expect(report.sameColo, isFalse);
    expect(report.core.ipVersion, 'v4');
    expect(report.webview.ipVersion, 'v6');
    expect(report.core.ipHash, isNot(equals(report.webview.ipHash)));

    await LogWriter.instance.flushNow();
    final logText = await _readAllLogText(tempDir);
    expect(logText, isNot(contains(ipA)));
    expect(logText, isNot(contains(ipB)));
  });

  test('15 分钟冷却与单飞防并发生效', () async {
    var now = DateTime(2026, 11, 26, 10, 0, 0);
    var coreCalls = 0;
    var webViewCalls = 0;
    final gate = Completer<void>();

    final probe = CfChannelTraceProbe.forTesting(
      now: () => now,
      coreFetcher: (_) async {
        coreCalls++;
        await gate.future;
        return const CfTraceRawResult(
          ok: true,
          statusCode: 200,
          body: 'ip=198.51.100.1\ncolo=HKG\nhttp=http/2\ntls=TLSv1.3\n',
        );
      },
      webViewFetcher: (_) async {
        webViewCalls++;
        return const CfTraceRawResult(
          ok: true,
          statusCode: 200,
          body: 'ip=198.51.100.1\ncolo=HKG\nhttp=http/2\ntls=TLSv1.3\n',
        );
      },
    );

    final first = probe.probeIfNeeded(triggerPath: '/a');
    final concurrent = await probe.probeIfNeeded(triggerPath: '/b');
    expect(concurrent, isNull);
    gate.complete();
    expect(await first, isNotNull);
    expect(coreCalls, 1);
    expect(webViewCalls, 1);

    // 冷却期内不再触发
    now = now.add(const Duration(minutes: 14, seconds: 59));
    expect(await probe.probeIfNeeded(triggerPath: '/c'), isNull);
    expect(coreCalls, 1);

    // 超过 15 分钟冷却后允许再次触发
    now = now.add(const Duration(seconds: 2));
    expect(await probe.probeIfNeeded(triggerPath: '/d'), isNotNull);
    expect(coreCalls, 2);
    expect(webViewCalls, 2);
  });

  test('单边失败时静默产出部分对照报告，不抛异常', () async {
    final probe = CfChannelTraceProbe.forTesting(
      coreFetcher: (_) async => const CfTraceRawResult(
        ok: false,
        errorType: 'receiveTimeout',
      ),
      webViewFetcher: (_) async => const CfTraceRawResult(
        ok: true,
        statusCode: 200,
        body: 'ip=198.51.100.2\ncolo=HKG\nhttp=http/2\ntls=TLSv1.3\n',
      ),
    );

    final report = await probe.probeIfNeeded(triggerPath: '/latest.json');
    expect(report, isNotNull);
    expect(report!.core.ok, isFalse);
    expect(report.core.errorType, 'receiveTimeout');
    expect(report.webview.ok, isTrue);
    expect(report.sameIp, isNull);
    expect(report.sameColo, isNull);
  });
}

Future<String> _readAllLogText(Directory dir) async {
  final buffer = StringBuffer();
  await for (final entity in dir.list(recursive: true)) {
    if (entity is File) {
      buffer.writeln(await entity.readAsString());
    }
  }
  return buffer.toString();
}
