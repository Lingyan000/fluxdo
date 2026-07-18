/// 媒体压缩策略层:码率预算/三档递降(脚本 1:1)+ ffmpeg 腿参数与
/// Duration 解析。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/media_transcoder/ffmpeg_process_transcoder.dart';
import 'package:fluxdo/services/media_transcoder/media_compressor.dart';
import 'package:fluxdo/services/media_transcoder/media_transcoder.dart';

void main() {
  group('码率预算(脚本同款)', () {
    test('音频:60s 文件预算充裕 → 三档递降且钳 12k..96k', () {
      final tiers = audioProfilesFor(const Duration(seconds: 60));
      // budget = (4MB-96KB)*8/60 ≈ 546k → 0.72 档钳到 96k
      expect(tiers[0].audioBitrate, 96000);
      expect(tiers[1].audioBitrate, 96000, reason: '0.45 档 245k 仍触顶');
      expect(tiers[2].audioBitrate, 96000, reason: '0.28 档 152k 仍触顶');
      // 超长音频(1 小时):预算 9.1k → 全档触底 12k
      final long = audioProfilesFor(const Duration(hours: 1));
      expect(long.every((t) => t.audioBitrate == 12000), isTrue);
    });

    test('视频四档:HEVC 优先两档 + H264 兜底两档,码率递降', () {
      final tiers = videoProfilesFor(const Duration(minutes: 5));
      expect(tiers.map((t) => t.codec).toList(),
          ['hevc', 'hevc', 'h264', 'h264']);
      expect(tiers[0].audioBitrate, 24000);
      expect(tiers[0].videoBitrate, greaterThan(tiers[1].videoBitrate));
      expect(tiers[1].videoBitrate, tiers[2].videoBitrate,
          reason: '同 0.66 折扣,仅 codec 不同');
      expect(tiers[3].videoBitrate, greaterThanOrEqualTo(12000));
    });

    test('短视频预算高 → HEVC 720p 起步;HEVC 分辨率阈值放宽', () {
      final tiers = videoProfilesFor(const Duration(seconds: 30));
      expect(tiers[0].audioBitrate, 32000);
      expect(tiers[0].codec, 'hevc');
      expect(tiers[0].height, 720);
      expect(tiers[0].fps, 30);
      // 第二档 hevc ≈ 0.66*1.06M ≈ 700k:除 0.65 折算 >900k → 仍 720p;
      // 同码率的 h264 档(第三档)只到 480p —— 阈值放宽生效
      expect(tiers[1].height, 720);
      expect(tiers[2].height, 480);
    });
  });

  group('ffmpeg 腿', () {
    test('Duration 解析:HH:MM:SS.cc', () {
      expect(
        FfmpegProcessTranscoder.parseFfmpegDuration(
            '  Duration: 00:01:23.45, start: 0.0'),
        const Duration(minutes: 1, seconds: 23, milliseconds: 450),
      );
      expect(
        FfmpegProcessTranscoder.parseFfmpegDuration('Duration: N/A'),
        isNull,
      );
    });

    test('音频参数(脚本 audio 分支同款)', () {
      final args = FfmpegProcessTranscoder.buildArgs(const TranscodeSpec(
        input: 'in.mp3',
        output: 'out.m4a',
        audioOnly: true,
        audioBitrate: 32000,
        audioSampleRate: 16000,
        audioChannels: 1,
      ));
      expect(args, containsAllInOrder(['-vn', '-c:a', 'aac', '-b:a', '32000']));
      expect(args, containsAllInOrder(['-ac', '1', '-ar', '16000']));
      expect(args, containsAllInOrder(['-movflags', '+faststart']));
      expect(args.last, 'out.m4a');
      expect(args, isNot(contains('-c:v')));
    });

    test('HEVC 参数:libx265 + hvc1 tag(Safari 兼容关键)', () {
      final args = FfmpegProcessTranscoder.buildArgs(const TranscodeSpec(
        input: 'in.mov',
        output: 'out.mp4',
        audioBitrate: 24000,
        videoBitrate: 80000,
        videoCodec: 'hevc',
        maxHeight: 360,
      ));
      expect(args, containsAllInOrder(['-c:v', 'libx265', '-preset', 'veryfast']));
      expect(args, containsAllInOrder(['-tag:v', 'hvc1']));
      expect(args, isNot(contains('libx264')));
    });

    test('视频参数(x264 + 缩放 + 帧率 + maxrate)', () {
      final args = FfmpegProcessTranscoder.buildArgs(const TranscodeSpec(
        input: 'in.mov',
        output: 'out.mp4',
        audioBitrate: 24000,
        videoBitrate: 80000,
        maxHeight: 360,
        fps: 18,
      ));
      expect(args, containsAllInOrder(['-c:v', 'libx264', '-preset', 'veryfast']));
      expect(args, containsAllInOrder(['-vf', 'scale=-2:360', '-r', '18']));
      expect(
        args,
        containsAllInOrder(
            ['-b:v', '80000', '-maxrate', '80000', '-bufsize', '160000']),
      );
      expect(args, containsAllInOrder(['-progress', 'pipe:1', '-nostats']));
    });
  });
}
