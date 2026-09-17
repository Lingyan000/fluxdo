import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/media_transcoder/media_compressor.dart';
import 'package:fluxdo/services/media_transcoder/media_transcoder.dart';

class FakeTranscoder extends MediaTranscoder {
  final specs = <TranscodeSpec>[];
  List<int> sizes = [12000, 8000];
  bool invalid = false;
  bool failProbe = false;
  MediaCompressionCancellation? cancelOnProbe;
  bool failHevc = false;
  double? sourceFps;
  int? channels;
  int? sampleRate;
  @override
  Future<MediaProbeInfo?> probe(String path) async {
    if (failProbe) throw StateError("probe failure");
    cancelOnProbe?.cancel();
    return MediaProbeInfo(
      duration: Duration(seconds: invalid && specs.isNotEmpty ? 0 : 2),
      hasVideo: true,
      fps: sourceFps,
      audioChannels: channels,
      audioSampleRate: sampleRate,
      width: 160,
      height: 240,
    );
  }

  @override
  Future<bool> transcode(TranscodeSpec spec) async {
    specs.add(spec);
    if (failHevc && spec.videoCodec == "hevc") throw StateError("unsupported");
    await File(spec.output).writeAsBytes(List.filled(sizes.removeAt(0), 0));
    return true;
  }

  @override
  Future<double> progress() async => 0;
  @override
  Future<void> cancel() async {}
}

void main() {
  late Directory dir;
  late File input;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('media-feedback');
    input = File('${dir.path}/input.mp4');
    await input.writeAsBytes(List.filled(30000, 0));
  });
  tearDown(() => dir.delete(recursive: true));
  test('体积反馈降码率且每次从原片重试，尺寸不放大', () async {
    final transcoder = FakeTranscoder()..sizes = [22000, 16000];
    final result = await compressMediaToFit(
      transcoder,
      input.path,
      isAudio: false,
      outputDir: dir.path,
      maxBytes: 20000,
    );
    expect(result.isOk, true);
    expect(transcoder.specs, hasLength(2));
    expect(
      transcoder.specs.last.videoBitrate!,
      lessThan(transcoder.specs.first.videoBitrate!),
    );
    expect(
      transcoder.specs.every(
        (s) =>
            s.input == input.path &&
            s.maxHeight == 240 &&
            s.fps == null &&
            s.videoCodec == 'h264',
      ),
      true,
    );
  });
  test('源视频低帧率、单声道和低采样率不会被提高', () async {
    final transcoder = FakeTranscoder()
      ..sourceFps = 12
      ..channels = 1
      ..sampleRate = 22050
      ..sizes = [8000];
    await compressMediaToFit(
      transcoder,
      input.path,
      isAudio: false,
      outputDir: dir.path,
      maxBytes: 20000,
    );
    expect(transcoder.specs.single.fps, 12);
    expect(transcoder.specs.single.audioChannels, 1);
    expect(transcoder.specs.single.audioSampleRate, 22050);
  });

  test('体积优先编码失败只回退一次H264', () async {
    final transcoder = FakeTranscoder()
      ..failHevc = true
      ..sizes = [8000];
    final result = await compressMediaToFit(
      transcoder,
      input.path,
      isAudio: false,
      outputDir: dir.path,
      maxBytes: 20000,
      mode: MediaCompressionMode.efficient,
    );
    expect(result.isOk, true);
    expect(transcoder.specs.map((s) => s.videoCodec), ['hevc', 'h264']);
  });

  test('录屏模式降低帧率预算而不升帧', () async {
    final transcoder = FakeTranscoder()
      ..sourceFps = 24
      ..sizes = [8000];
    await compressMediaToFit(
      transcoder,
      input.path,
      isAudio: false,
      outputDir: dir.path,
      maxBytes: 20000,
      mode: MediaCompressionMode.screen,
    );
    expect(transcoder.specs.single.fps, 15);
    expect(transcoder.specs.single.videoCodec, 'h264');
  });

  test('初始探测失败返回错误结果，不悬挂进度框', () async {
    final transcoder = FakeTranscoder()..failProbe = true;
    final result = await compressMediaToFit(
      transcoder,
      input.path,
      isAudio: false,
      outputDir: dir.path,
      maxBytes: 20000,
    );
    expect(result.error, contains('probe failure'));
    expect(transcoder.specs, isEmpty);
  });

  test('探测期间取消不会启动编码或上传', () async {
    final token = MediaCompressionCancellation();
    final transcoder = FakeTranscoder()..cancelOnProbe = token;
    final result = await compressMediaToFit(
      transcoder,
      input.path,
      isAudio: false,
      outputDir: dir.path,
      maxBytes: 20000,
      cancellation: token,
    );
    expect(result.cancelled, true);
    expect(transcoder.specs, isEmpty);
  });

  test('未超限不转码', () async {
    final transcoder = FakeTranscoder();
    final result = await compressMediaToFit(
      transcoder,
      input.path,
      isAudio: false,
      outputDir: dir.path,
      maxBytes: 40000,
    );
    expect(result.path, input.path);
    expect(transcoder.specs, isEmpty);
  });
  test('异常产物不上传', () async {
    final transcoder = FakeTranscoder()..invalid = true;
    final result = await compressMediaToFit(
      transcoder,
      input.path,
      isAudio: false,
      outputDir: dir.path,
      maxBytes: 20000,
    );
    expect(result.isOk, false);
  });
  test('语音和普通音频使用不同参数', () async {
    for (final voice in [true, false]) {
      final transcoder = FakeTranscoder()..sizes = [8000];
      await compressMediaToFit(
        transcoder,
        input.path,
        isAudio: true,
        voice: voice,
        outputDir: dir.path,
        maxBytes: 20000,
      );
      expect(transcoder.specs.single.audioSampleRate, voice ? 16000 : 44100);
      expect(transcoder.specs.single.audioChannels, voice ? 1 : 2);
    }
  });
}
