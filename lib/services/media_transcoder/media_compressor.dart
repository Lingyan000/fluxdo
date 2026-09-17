/// 基于站点预算的媒体压缩：保留源尺寸、使用实测体积反馈，最多三次转码。
library;

import 'dart:io';
import 'dart:math' as math;

import 'media_transcoder.dart';

/// 为封装开销留余量，小上限按比例保留，避免预算变负。
int mediaTargetBytes(int maxBytes) {
  if (maxBytes <= 0) throw ArgumentError.value(maxBytes, 'maxBytes');
  return math.max(
    1,
    (maxBytes * 0.95).floor() - math.min(96 * 1024, maxBytes ~/ 100),
  );
}

/// 录屏优先分辨率并限制帧率，体积优先使用HEVC（失败回退H.264）。
enum MediaCompressionMode { compatible, screen, efficient }

/// 取消意图贯穿准备、探测及重试间隙，不只取消当前原生编码器。
class MediaCompressionCancellation {
  bool cancelled = false;
  void cancel() => cancelled = true;
}

/// 压缩结果。
class CompressResult {
  const CompressResult.ok(this.path) : cancelled = false, error = null;
  const CompressResult.cancelled()
    : path = null,
      cancelled = true,
      error = null;
  const CompressResult.failed(this.error) : path = null, cancelled = false;

  final String? path;
  final bool cancelled;
  final String? error;

  bool get isOk => path != null;
}

/// 把 [inputPath] 压缩到站点附件上限内。[isAudio] = 走音频档(纯音频文件);
/// [onStatus] 回报"快速压缩 42%…"式进展;取消由调用方直接调
/// [MediaTranscoder.cancel](本函数感知后返回 cancelled)。
Future<CompressResult> compressMediaToFit(
  MediaTranscoder transcoder,
  String inputPath, {
  required bool isAudio,
  required String outputDir,
  required int maxBytes,
  MediaCompressionCancellation? cancellation,
  bool voice = false,
  MediaCompressionMode mode = MediaCompressionMode.compatible,
  void Function(String status)? onStatus,
}) async {
  try {
    if (cancellation?.cancelled == true) {
      return const CompressResult.cancelled();
    }
    final notReady = await transcoder.ensureReady(onStatus: onStatus);
    if (cancellation?.cancelled == true) {
      return const CompressResult.cancelled();
    }
    if (notReady != null) return CompressResult.failed(notReady);

    final info = await transcoder.probe(inputPath);
    if (cancellation?.cancelled == true) {
      return const CompressResult.cancelled();
    }
    if (info == null) {
      return const CompressResult.failed('无法读取媒体信息(文件可能损坏)');
    }
    // 纯音频文件走音频档(即使调用方按扩展名误判也纠正)
    final audioOnly = isAudio || !info.hasVideo;
    final stamp = DateTime.now().millisecondsSinceEpoch;

    final sourceBytes = await File(inputPath).length();
    if (sourceBytes > 0 && sourceBytes < maxBytes) {
      return CompressResult.ok(inputPath);
    }
    if (info.duration <= Duration.zero) {
      return const CompressResult.failed('媒体时长无效');
    }
    final target = mediaTargetBytes(maxBytes);
    var totalBitrate = (target * 8 / (info.duration.inMilliseconds / 1000))
        .floor();
    final minimum = audioOnly ? (voice ? 12000 : 32000) : 56000;
    if (totalBitrate < minimum) {
      return const CompressResult.failed('时长过长，当前站点大小限制无法保留可用质量，请缩短媒体');
    }
    Object? lastError;
    var useHevc = mode == MediaCompressionMode.efficient;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (cancellation?.cancelled == true) {
        return const CompressResult.cancelled();
      }
      final audioBitrate = audioOnly
          ? totalBitrate.clamp(voice ? 12000 : 32000, voice ? 64000 : 192000)
          : (totalBitrate * 0.12).round().clamp(24000, 128000);
      final videoBitrate = math.max(32000, totalBitrate - audioBitrate);
      final effectiveBitrate =
          (videoBitrate *
                  (mode == MediaCompressionMode.screen
                      ? 1.8
                      : useHevc
                      ? 1.35
                      : 1))
              .round();
      final desiredHeight = effectiveBitrate >= 2500000
          ? 1080
          : effectiveBitrate >= 900000
          ? 720
          : effectiveBitrate >= 350000
          ? 480
          : 360;
      final sourceHeight = info.height;
      final height = sourceHeight == null || sourceHeight < 2
          ? null
          : (math.min(desiredHeight, sourceHeight) ~/ 2) * 2;
      final out =
          '$outputDir${Platform.pathSeparator}compress_${stamp}_$attempt.${audioOnly ? 'm4a' : 'mp4'}';
      final spec = TranscodeSpec(
        input: inputPath,
        output: out,
        audioOnly: audioOnly,
        audioBitrate: audioBitrate,
        audioSampleRate: math.min(
          info.audioSampleRate ?? 44100,
          voice ? 16000 : 44100,
        ),
        audioChannels: voice ? 1 : math.min(info.audioChannels ?? 2, 2),
        videoBitrate: audioOnly ? null : videoBitrate,
        videoCodec: useHevc ? 'hevc' : 'h264',
        maxHeight: height,
        // 未探测源帧率时不传目标帧率，避免把低帧率素材升帧。
        fps: info.fps != null && info.fps!.isFinite && info.fps! >= 1
            ? math.min(
                info.fps!.floor(),
                mode == MediaCompressionMode.screen
                    ? 15
                    : videoBitrate < 350000
                    ? 18
                    : 30,
              )
            : null,
      );
      onStatus?.call('压缩媒体（${attempt + 1}/3）…');
      try {
        if (!await transcoder.transcode(spec)) {
          await _deleteOutput(out);
          return const CompressResult.cancelled();
        }
        if (cancellation?.cancelled == true) {
          await _deleteOutput(out);
          return const CompressResult.cancelled();
        }
        final size = await File(out).length();
        final outputInfo = await transcoder.probe(out);
        if (cancellation?.cancelled == true) {
          await _deleteOutput(out);
          return const CompressResult.cancelled();
        }
        final durationTolerance = math.max(
          1000,
          info.duration.inMilliseconds * 0.05,
        );
        if (size == 0 ||
            outputInfo == null ||
            outputInfo.duration <= Duration.zero ||
            (outputInfo.duration.inMilliseconds - info.duration.inMilliseconds)
                    .abs() >
                durationTolerance ||
            (!audioOnly && !outputInfo.hasVideo) ||
            (info.hasAudio == true && outputInfo.hasAudio == false)) {
          await _deleteOutput(out);
          return const CompressResult.failed('压缩产物无效或时长异常，已停止上传');
        }
        if (size < maxBytes && size < sourceBytes) {
          onStatus?.call('压缩完成 ${(size / 1048576).toStringAsFixed(1)} MiB');
          return CompressResult.ok(out);
        }
        // 实测结果修正总预算，最多下降一半且至少下降10%；每轮重读原片。
        totalBitrate = (totalBitrate * (target / size * 0.95).clamp(0.5, 0.9))
            .floor();
        await _deleteOutput(out);
        if (totalBitrate < minimum) break;
      } catch (error) {
        lastError = error;
        await _deleteOutput(out);
        // HEVC不被硬件支持时只退一次兼容编码；不重复相同失败。
        if (useHevc && !audioOnly) {
          useHevc = false;
          continue;
        }
        break;
      }
    }
    return CompressResult.failed(
      lastError == null ? '压缩后仍超过站点限制，请缩短媒体后重试' : '压缩失败：$lastError',
    );
  } catch (error) {
    return cancellation?.cancelled == true
        ? const CompressResult.cancelled()
        : CompressResult.failed('准备压缩失败：$error');
  }
}

Future<void> _deleteOutput(String path) async {
  try {
    await File(path).delete();
  } catch (_) {}
}
