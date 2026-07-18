/// debug 专用:合成一段可播放的测试"语音"(扫频正弦 + 每秒节拍,
/// 纯 Dart 产 WAV),不经录音插件、不要麦克风权限 —— 用于跑通语音
/// 消息全链路(上传/.xz 改名/[wrap=voice] 标签/语音条渲染)。
///
/// release 下无入口(调用方 kDebugMode 守卫,tree-shake 掉)。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 合成 PCM16 mono WAV 字节(RIFF/fmt/data)。纯函数,可单测。
///
/// 波形:220→880Hz 线性扫频 + 每秒开头 80ms 的 1.2kHz 节拍音 ——
/// 听感明确不似静音,试听/播放进度一耳朵可辨。
Uint8List buildTestVoiceWav({
  Duration duration = const Duration(seconds: 8),
  int sampleRate = 16000,
}) {
  final n = duration.inMilliseconds * sampleRate ~/ 1000;
  final data = ByteData(44 + n * 2);

  void writeAscii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  // RIFF 头
  writeAscii(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  writeAscii(8, 'WAVE');
  // fmt 块(PCM16 mono)
  writeAscii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little); // PCM
  data.setUint16(22, 1, Endian.little); // mono
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little); // byte rate
  data.setUint16(32, 2, Endian.little); // block align
  data.setUint16(34, 16, Endian.little); // bits
  // data 块
  writeAscii(36, 'data');
  data.setUint32(40, n * 2, Endian.little);

  final totalSec = math.max(0.001, duration.inMilliseconds / 1000);
  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    final freq = 220 + 660 * (t / totalSec);
    var v = 0.35 * math.sin(2 * math.pi * freq * t);
    if ((t % 1.0) < 0.08) {
      v += 0.4 * math.sin(2 * math.pi * 1200 * t);
    }
    data.setInt16(
      44 + i * 2,
      (v.clamp(-1.0, 1.0) * 32767).round(),
      Endian.little,
    );
  }
  return data.buffer.asUint8List();
}

/// 合成并写入临时目录,返回 wav 文件路径。
Future<String> synthesizeTestVoiceWav({
  Duration duration = const Duration(seconds: 8),
}) async {
  final dir = await getTemporaryDirectory();
  final path = p.join(
    dir.path,
    'voice_debug_${DateTime.now().millisecondsSinceEpoch}.wav',
  );
  await File(path).writeAsBytes(buildTestVoiceWav(duration: duration));
  return path;
}
