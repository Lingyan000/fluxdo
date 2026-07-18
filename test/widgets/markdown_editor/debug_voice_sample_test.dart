/// debug 语音合成:WAV 纯函数正确性 + 录音面板 debug 路径
/// (合成 → recorded 态 → 发送返回路径,不碰录音插件)。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/debug_voice_sample.dart';
import 'package:fluxdo/widgets/markdown_editor/voice_recorder_sheet.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.tempPath);
  final String tempPath;
  @override
  Future<String?> getTemporaryPath() async => tempPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('WAV 字节:RIFF 头/尺寸/PCM16 数据段自洽', () {
    final bytes = buildTestVoiceWav(
      duration: const Duration(seconds: 2),
      sampleRate: 16000,
    );
    const n = 2 * 16000;
    expect(bytes.length, 44 + n * 2);
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(bytes.sublist(36, 40)), 'data');
    final bd = ByteData.sublistView(bytes);
    expect(bd.getUint32(24, Endian.little), 16000, reason: '采样率');
    expect(bd.getUint16(22, Endian.little), 1, reason: '单声道');
    expect(bd.getUint32(40, Endian.little), n * 2, reason: 'data 长度');
    // 波形非静音(有效幅度)
    var maxAbs = 0;
    for (var i = 0; i < n; i++) {
      final v = bd.getInt16(44 + i * 2, Endian.little).abs();
      if (v > maxAbs) maxAbs = v;
    }
    expect(maxAbs, greaterThan(8000), reason: '非静音波形');
  });

  testWidgets('debug 按钮:合成 → recorded 态 → 发送返回文件路径',
      (tester) async {
    expect(kDebugMode, isTrue, reason: '测试环境即 debug');
    PathProviderPlatform.instance =
        _FakePathProvider(Directory.systemTemp.path);

    String? sent;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () async {
                sent = await showVoiceRecorderSheet(ctx);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('生成测试音频(debug)'), findsOneWidget);
    // runAsync:合成写文件是真实 IO
    await tester.runAsync(() async {
      await tester.tap(find.text('生成测试音频(debug)'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    expect(find.text('发送'), findsOneWidget, reason: '进入 recorded 态');
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(sent, isNotNull);
    expect(sent, contains('voice_debug_'));
  });
}
