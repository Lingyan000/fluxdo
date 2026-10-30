/// 媒体压缩策略层:码率预算/三档递降(脚本 1:1)+ ffmpeg 腿参数与
/// Duration 解析。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/media_transcoder/ffmpeg_process_transcoder.dart';
import 'package:fluxdo/services/media_transcoder/media_compressor.dart';
import 'package:fluxdo/services/media_transcoder/media_transcoder.dart';
import 'package:fluxdo/services/uploads/media_upload_limits.dart';

void main() {
  test('媒体使用站点附件上限，不再固定4MiB', () {
    expect(
      MediaUploadLimits.fromSettings({'max_attachment_size_kb': 20480}),
      20 * 1024 * 1024,
    );
    expect(
      MediaUploadLimits.fromSettings({'max_attachment_size_kb': '8192'}),
      8 * 1024 * 1024,
    );
    expect(MediaUploadLimits.fromSettings(null), isNull);
    expect(
      MediaUploadLimits.fromSettings({'max_attachment_size_kb': 0}),
      isNull,
    );
    expect(mediaTargetBytes(1024), inExclusiveRange(0, 1024));
  });

  group('ffmpeg 腿', () {
    test('Duration 解析:HH:MM:SS.cc', () {
      expect(
        FfmpegProcessTranscoder.parseFfmpegDuration(
          '  Duration: 00:01:23.45, start: 0.0',
        ),
        const Duration(minutes: 1, seconds: 23, milliseconds: 450),
      );
      expect(
        FfmpegProcessTranscoder.parseFfmpegDuration('Duration: N/A'),
        isNull,
      );
    });

    test('音频参数(脚本 audio 分支同款)', () {
      final args = FfmpegProcessTranscoder.buildArgs(
        const TranscodeSpec(
          input: 'in.mp3',
          output: 'out.m4a',
          audioOnly: true,
          audioBitrate: 32000,
          audioSampleRate: 16000,
          audioChannels: 1,
        ),
      );
      expect(args, containsAllInOrder(['-vn', '-c:a', 'aac', '-b:a', '32000']));
      expect(args, containsAllInOrder(['-ac', '1', '-ar', '16000']));
      expect(args, containsAllInOrder(['-movflags', '+faststart']));
      expect(args.last, 'out.m4a');
      expect(args, isNot(contains('-c:v')));
    });

    test('HEVC 参数:libx265 + hvc1 tag(Safari 兼容关键)', () {
      final args = FfmpegProcessTranscoder.buildArgs(
        const TranscodeSpec(
          input: 'in.mov',
          output: 'out.mp4',
          audioBitrate: 24000,
          videoBitrate: 80000,
          videoCodec: 'hevc',
          maxHeight: 360,
        ),
      );
      expect(
        args,
        containsAllInOrder(['-c:v', 'libx265', '-preset', 'veryfast']),
      );
      expect(args, containsAllInOrder(['-tag:v', 'hvc1']));
      expect(args, isNot(contains('libx264')));
    });

    test('视频参数(x264 + 缩放 + 帧率 + maxrate)', () {
      final args = FfmpegProcessTranscoder.buildArgs(
        const TranscodeSpec(
          input: 'in.mov',
          output: 'out.mp4',
          audioBitrate: 24000,
          videoBitrate: 80000,
          maxHeight: 360,
          fps: 18,
        ),
      );
      expect(
        args,
        containsAllInOrder(['-c:v', 'libx264', '-preset', 'veryfast']),
      );
      expect(args, containsAllInOrder(['-vf', 'scale=-2:360', '-r', '18']));
      expect(
        args,
        containsAllInOrder([
          '-b:v',
          '80000',
          '-maxrate',
          '80000',
          '-bufsize',
          '160000',
        ]),
      );
      expect(args, containsAllInOrder(['-progress', 'pipe:1', '-nostats']));
    });
  });
}
