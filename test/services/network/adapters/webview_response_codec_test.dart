import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/adapters/webview_response_codec.dart';

/// 运行生产代码生成的 JS，而非另写一份编码器，验证真实发送格式。
Future<Map<String, dynamic>> runSender({
  required bool useBase64,
  required List<List<int>> buffers,
  bool rejectTransfer = false,
}) async {
  final script =
      '''
const requestId = 'response-test';
const messages = [];
let transferAttempts = 0;
const responsePort = {
  postMessage(payload, transfer) {
    if (transfer) {
      transferAttempts++;
      if ($rejectTransfer) throw new Error('不支持转移');
    }
    if ($useBase64 && typeof payload !== 'string') {
      throw new Error('Android 原生桥禁止接收 ArrayBuffer');
    }
    messages.push(typeof payload === 'string'
      ? JSON.parse(payload)
      : {kind: 'binary', data: Array.from(new Uint8Array(payload))});
  }
};
${WebViewResponseCodec.buildSenderScript(useBase64: useBase64)}
for (const bytes of ${jsonEncode(buffers)}) {
  sendBuffer(Uint8Array.from(bytes).buffer);
}
console.log(JSON.stringify({messages, transferAttempts}));
''';
  // 使用 stdin，避免大图回归数据超过操作系统命令行长度限制。
  final process = await Process.start('node', const []);
  final stdoutFuture = process.stdout.transform(utf8.decoder).join();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  process.stdin.write(script);
  await process.stdin.close();
  final exitCode = await process.exitCode;
  final output = await stdoutFuture;
  final errors = await stderrFuture;
  expect(exitCode, 0, reason: errors);
  return jsonDecode(output) as Map<String, dynamic>;
}

void main() {
  group('WebView 下载响应兼容策略', () {
    for (final supported in [true, false]) {
      test('Android 能力为 $supported 时选择对应编码并缓存', () async {
        var calls = 0;
        final transport = WebViewResponseTransport(
          isAndroid: true,
          supportsArrayBuffer: () async {
            calls++;
            return supported;
          },
        );
        final useBase64 = await transport.usesBase64();
        expect(useBase64, !supported);
        expect(await transport.usesBase64(), !supported);
        expect(calls, 1);
        final sent = await runSender(
          useBase64: useBase64,
          buffers: [
            [0, 128, 255],
          ],
        );
        final message = (sent['messages'] as List).single as Map;
        expect(message['kind'], supported ? 'binary' : 'chunk');
      });
    }

    test('非 Android 不调用原生能力查询', () async {
      final transport = WebViewResponseTransport(
        isAndroid: false,
        supportsArrayBuffer: () => throw StateError('不应查询'),
      );
      expect(await transport.usesBase64(), isFalse);
    });

    test('并发图片共享同一个未完成的能力查询', () async {
      var calls = 0;
      final capability = Completer<bool>();
      final transport = WebViewResponseTransport(
        isAndroid: true,
        supportsArrayBuffer: () {
          calls++;
          return capability.future;
        },
      );
      final first = transport.usesBase64();
      final second = transport.usesBase64();
      expect(identical(first, second), isTrue);
      capability.complete(true);
      expect(await Future.wait([first, second]), [false, false]);
      expect(calls, 1);
    });

    for (final synchronous in [true, false]) {
      test('能力查询异常安全降级并缓存（同步=$synchronous）', () async {
        var calls = 0;
        final transport = WebViewResponseTransport(
          isAndroid: true,
          supportsArrayBuffer: () {
            calls++;
            if (synchronous) throw StateError('查询失败');
            return Future<bool>.error(StateError('查询失败'));
          },
        );
        expect(await transport.usesBase64(), isTrue);
        expect(await transport.usesBase64(), isTrue);
        expect(calls, 1);
      });
    }

    test('能力查询超时后不等待或切回危险的传输方式', () async {
      final capability = Completer<bool>();
      final transport = WebViewResponseTransport(
        isAndroid: true,
        supportsArrayBuffer: () => capability.future,
        queryTimeout: Duration.zero,
      );
      expect(await transport.usesBase64(), isTrue);
      capability.complete(true);
      expect(await transport.usesBase64(), isTrue);
    });

    test('新适配器的策略实例重新查询，旧实例降级不污染新实例', () async {
      final failed = WebViewResponseTransport(
        isAndroid: true,
        supportsArrayBuffer: () => Future<bool>.error(StateError('查询失败')),
      );
      final supported = WebViewResponseTransport(
        isAndroid: true,
        supportsArrayBuffer: () async => true,
      );
      expect(await failed.usesBase64(), isTrue);
      expect(await supported.usesBase64(), isFalse);
    });
  });

  group('真实 JS 发送器与 Dart 接收器往返', () {
    for (final length in [
      0,
      1,
      2,
      3,
      256,
      WebViewResponseCodec.chunkSize - 1,
      WebViewResponseCodec.chunkSize,
      WebViewResponseCodec.chunkSize + 1,
      1024 * 1024 + 7,
    ]) {
      test('字符串降级 $length 字节保持完整且消息有界', () async {
        final original = List<int>.generate(length, (i) => i % 256);
        final result = await runSender(useBase64: true, buffers: [original]);
        final messages = result['messages'] as List;
        final restored = BytesBuilder(copy: false);
        for (final value in messages) {
          final message = value as Map;
          expect(message['kind'], 'chunk');
          expect(message['requestId'], 'response-test');
          final bytes = WebViewResponseCodec.decodeChunk(message)!;
          expect(
            bytes.length,
            lessThanOrEqualTo(WebViewResponseCodec.chunkSize),
          );
          expect((message['data'] as String).length, lessThanOrEqualTo(32768));
          restored.add(bytes);
        }
        expect(restored.takeBytes(), orderedEquals(original));
        expect(result['transferAttempts'], 0);
        expect(
          messages.length,
          (length / WebViewResponseCodec.chunkSize).ceil(),
        );
      });
    }

    test('多个网络块按序拼接，空块不发送', () async {
      final result = await runSender(
        useBase64: true,
        buffers: [
          [],
          [0, 255],
          [],
          [128],
          [1, 2, 3],
          [],
        ],
      );
      final messages = result['messages'] as List;
      expect(messages, hasLength(3));
      expect(
        messages.expand((m) => WebViewResponseCodec.decodeChunk(m as Map)!),
        orderedEquals([0, 255, 128, 1, 2, 3]),
      );
    });

    for (final rejectTransfer in [false, true]) {
      test('支持二进制时保持转移失败回退（$rejectTransfer）', () async {
        final result = await runSender(
          useBase64: false,
          buffers: [
            [],
            [0, 128, 255],
          ],
          rejectTransfer: rejectTransfer,
        );
        expect(result['messages'], [
          {
            'kind': 'binary',
            'data': [0, 128, 255],
          },
        ]);
        expect(result['transferAttempts'], 1);
      });
    }
  });

  group('响应协议校验', () {
    test('控制消息仍由原响应桥处理', () {
      for (final kind in ['ready', 'headers', 'complete', 'error']) {
        expect(WebViewResponseCodec.decodeChunk({'kind': kind}), isNull);
      }
    });

    test('损坏的数据块报错而不是静默截断图片', () {
      for (final message in [
        {'kind': 'chunk', 'encoding': 'unknown', 'data': 'AA=='},
        {'kind': 'chunk', 'encoding': 'base64', 'data': 42},
        {'kind': 'chunk', 'encoding': 'base64', 'data': '!invalid!'},
        {
          'kind': 'chunk',
          'encoding': 'base64',
          'data': base64Encode(Uint8List(WebViewResponseCodec.chunkSize + 1)),
        },
      ]) {
        expect(
          () => WebViewResponseCodec.decodeChunk(message),
          throwsFormatException,
        );
      }
    });
  });
}
