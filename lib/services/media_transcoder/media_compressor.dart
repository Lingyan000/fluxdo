/// 媒体压缩策略层(社区「媒体上传」脚本 1:1 移植):
///
/// 码率预算 = (4MB − 96KB 余量) × 8 ÷ 时长秒;三档递降试压,任一档
/// 产物 < 4MB 即成功。音频档只降码率(AAC 单声道 16kHz);视频档同时
/// 降码率/分辨率/帧率(480p24 → 360p18 → 240p12)。
///
/// 执行层是 [MediaTranscoder] 的三条平台腿;本层纯 Dart,档位函数
/// 公开做单测。
library;

import 'dart:async' show unawaited;
import 'dart:io';
import 'dart:math' as math;

import 'media_transcoder.dart';

/// 站点上传体积上限(linux.do 4MB)。
const int kMaxMediaBytes = 4 * 1024 * 1024;

/// 压缩目标(留 96KB 容器/元数据余量,脚本同款)。
const int kTargetMediaBytes = kMaxMediaBytes - 96 * 1024;

/// 音频压缩档(码率系数递降)。
class AudioProfile {
  const AudioProfile(this.label, this.audioBitrate);
  final String label;
  final int audioBitrate;
}

/// 视频压缩档。
class VideoProfile {
  const VideoProfile(this.label, this.videoBitrate, this.audioBitrate,
      this.height, this.fps, this.codec);
  final String label;
  final int videoBitrate;
  final int audioBitrate;
  final int height;
  final int fps;

  /// 'hevc' / 'h264'。
  final String codec;
}

/// 音频三档(脚本 profiles factor 0.72/0.45/0.28,b:a 钳 12k..96k)。
List<AudioProfile> audioProfilesFor(Duration duration) {
  final seconds = math.max(1, duration.inMilliseconds / 1000);
  final budget = math.max(12000, (kTargetMediaBytes * 8 / seconds).floor());
  AudioProfile p(String label, double factor) => AudioProfile(
        label,
        (budget * factor).floor().clamp(12000, 96000),
      );
  return [
    p('快速压缩', 0.72),
    p('二次压缩', 0.45),
    p('极限压缩', 0.28),
  ];
}

/// 视频三档:码率预算递降,分辨率/帧率**按每档实际码率动态选**
/// (短视频预算高 → 720p,不再写死 480p 起步白白降清晰度)。
/// 折扣系数 0.92/0.66/0.42(原脚本 0.74 起步的 safety margin 过大,
/// 第一档直接丢 26% 码率;硬编/x264 的码率控制没那么不准,超了还有
/// 下一档兜底)。
List<VideoProfile> videoProfilesFor(Duration duration) {
  final seconds = math.max(1, duration.inMilliseconds / 1000);
  final budget = math.max(24000, (kTargetMediaBytes * 8 / seconds).floor());
  final audio = budget > 180000 ? 32000 : (budget > 80000 ? 24000 : 16000);

  // 码率 → 该码率下观感最优的分辨率/帧率档(bpp 经验值)。
  // HEVC 同码率效率高 ~40%,阈值放宽 35%(600k 即可上 720p)。
  (int, int) tierFor(int videoBps, {required bool hevc}) {
    final bps = hevc ? (videoBps / 0.65).round() : videoBps;
    if (bps > 900000) return (720, 30);
    if (bps > 350000) return (480, 24);
    if (bps > 140000) return (360, 18);
    return (240, 12);
  }

  VideoProfile p(String label, double factor, String codec) {
    final v = math.max(12000, ((budget - audio) * factor).floor());
    final (h, fps) = tierFor(v, hevc: codec == 'hevc');
    return VideoProfile(label, v, audio, h, fps, codec);
  }

  // HEVC 优先(画质档),编码器不可用由 compressMediaToFit 整体跳到
  // H264 档(不逐档重试浪费时间)
  return [
    p('快速压缩', 0.92, 'hevc'),
    p('二次压缩', 0.66, 'hevc'),
    p('兼容压缩', 0.66, 'h264'),
    p('极限压缩', 0.42, 'h264'),
  ];
}

/// 压缩结果。
class CompressResult {
  const CompressResult.ok(this.path)
      : cancelled = false,
        error = null;
  const CompressResult.cancelled()
      : path = null,
        cancelled = true,
        error = null;
  const CompressResult.failed(this.error)
      : path = null,
        cancelled = false;

  final String? path;
  final bool cancelled;
  final String? error;

  bool get isOk => path != null;
}

/// 把 [inputPath] 压缩到 4MB 内。[isAudio] = 走音频档(纯音频文件);
/// [onStatus] 回报"快速压缩 42%…"式进展;取消由调用方直接调
/// [MediaTranscoder.cancel](本函数感知后返回 cancelled)。
Future<CompressResult> compressMediaToFit(
  MediaTranscoder transcoder,
  String inputPath, {
  required bool isAudio,
  required String outputDir,
  void Function(String status)? onStatus,
}) async {
  final notReady = await transcoder.ensureReady(onStatus: onStatus);
  if (notReady != null) return CompressResult.failed(notReady);

  final info = await transcoder.probe(inputPath);
  if (info == null) {
    return const CompressResult.failed('无法读取媒体信息(文件可能损坏)');
  }
  // 纯音频文件走音频档(即使调用方按扩展名误判也纠正)
  final audioOnly = isAudio || !info.hasVideo;
  final stamp = DateTime.now().millisecondsSinceEpoch;

  final profiles = audioOnly
      ? [
          for (final p in audioProfilesFor(info.duration))
            (
              label: p.label,
              codec: 'aac',
              spec: (String out) => TranscodeSpec(
                    input: inputPath,
                    output: out,
                    audioOnly: true,
                    audioBitrate: p.audioBitrate,
                    audioSampleRate: 16000,
                    audioChannels: 1,
                  ),
              ext: 'm4a',
            ),
        ]
      : [
          for (final p in videoProfilesFor(info.duration))
            (
              label: p.label,
              codec: p.codec,
              spec: (String out) => TranscodeSpec(
                    input: inputPath,
                    output: out,
                    audioBitrate: p.audioBitrate,
                    videoBitrate: p.videoBitrate,
                    videoCodec: p.codec,
                    maxHeight: p.height,
                    fps: p.fps,
                  ),
              ext: 'mp4',
            ),
        ];

  Object? lastError;
  var hevcBroken = false; // 编码器不可用:跳过所有剩余 HEVC 档
  for (var i = 0; i < profiles.length; i++) {
    final tier = profiles[i];
    if (hevcBroken && tier.codec == 'hevc') continue;
    final out =
        '$outputDir${Platform.pathSeparator}compress_${stamp}_$i.${tier.ext}';
    onStatus?.call('${tier.label}…');
    try {
      final done = await transcoder.transcode(tier.spec(out));
      if (!done) {
        unawaited(File(out).delete().catchError((_) => File(out)));
        return const CompressResult.cancelled();
      }
      final size = await File(out).length();
      if (size < kMaxMediaBytes) {
        onStatus?.call('${tier.label}完成 ${(size / 1048576).toStringAsFixed(1)}MB');
        return CompressResult.ok(out);
      }
      onStatus?.call('结果 ${(size / 1048576).toStringAsFixed(1)}MB,继续压小…');
      unawaited(File(out).delete().catchError((_) => File(out)));
    } catch (e) {
      lastError = e;
      if (tier.codec == 'hevc') hevcBroken = true;
      unawaited(File(out).delete().catchError((_) => File(out)));
    }
  }
  return CompressResult.failed(
    lastError != null ? '压缩失败:$lastError' : '压缩后仍超过 4MB,请手动处理后再上传',
  );
}
