import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/adapters/webview_request_codec.dart';
import 'package:fluxdo/services/network/adapters/webview_http_adapter.dart';

void main() {
  for (final base64 in [true, false]) {
    for (final size in [0, 1, 2, 3, 24575, 24576, 24577, 1048577]) {
      test('上传字节往返 base64=$base64 长度=$size', () async {
        final bytes = Uint8List.fromList(List.generate(size, (i) => i % 256));
        final messages = <Object>[];
        await WebViewRequestCodec.pipe(
          Stream.fromIterable([Uint8List(0), bytes, Uint8List(0)]),
          useBase64: base64,
          send: (payload) async {
            messages.add(payload);
          },
        );
        if (!base64) {
          expect(messages.expand((m) => m as Uint8List), orderedEquals(bytes));
          expect(
            messages.every((m) => (m as Uint8List).length <= 65536),
            isTrue,
          );
          return;
        }
        expect(messages.every((m) => m is String), isTrue);
        final process = await Process.start('node', []);
        final output = process.stdout.transform(utf8.decoder).join();
        final errors = process.stderr.transform(utf8.decoder).join();
        process.stdin.write('''
const state = {chunks: []};
for (const payload of ${jsonEncode(messages)}) {
  const message = JSON.parse(payload);
  switch (message.kind) {
    ${WebViewRequestCodec.receiverScript}
    default: throw new Error('Unexpected message');
  }
}
console.log(Buffer.concat(state.chunks).toString('base64'));
''');
        await process.stdin.close();
        expect(await process.exitCode, 0, reason: await errors);
        expect(base64Decode((await output).trim()), orderedEquals(bytes));
      });
    }
  }

  test('上传诊断保留响应头及字节数，不依赖结果回调', () async {
    final script = WebViewHttpAdapter.buildUploadDiagnosticsScript('upload-1');
    final result = await Process.run('node', [
      '-e',
      '''
      const window = {};
      $script
      uploadTrace('fetch_started', 1024);
      uploadTrace('response_headers', 422);
      uploadTrace('result_bridge_error');
      console.log(JSON.stringify(window.__fluxdoUploadDiagnostics['upload-1']));
    ''',
    ]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(jsonDecode(result.stdout.toString()), {
      'phase': 'result_bridge_error',
      'bodyBytes': 1024,
      'status': 422,
    });
  });

  test('传输中失败不重读流，保留原始异常', () async {
    var sends = 0;
    final error = StateError('模拟原生发送失败');
    await expectLater(
      WebViewRequestCodec.pipe(
        Stream.value(Uint8List(100000)),
        useBase64: true,
        send: (_) async {
          sends++;
          throw error;
        },
      ),
      throwsA(same(error)),
    );
    expect(sends, 1);
  });

  test('适配器上传接线复用能力查询并在读取流前选定协议', () {
    final source = File(
      'lib/services/network/adapters/webview_http_adapter.dart',
    ).readAsStringSync();
    final start = source.indexOf('Future<String?> _buildStreamedBodyScript(');
    final end = source.indexOf('Future<String?> _buildDirectBodyScript', start);
    final body = source.substring(start, end);
    expect(
      body.indexOf('_responseTransport.usesBase64()'),
      lessThan(body.indexOf('transferStarted = true')),
    );
    expect(body, contains('WebViewRequestCodec.pipe('));
    expect(source, contains(r'${WebViewRequestCodec.receiverScript}'));
    expect(
      body,
      contains("transferStarted ? 'transfer_failed' : 'bridge_fallback'"),
    );
  });
}
