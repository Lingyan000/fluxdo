/// 媒体转码平台抽象(音视频压缩到站点 4MB 上限的执行层)。
///
/// 三条实现腿(安装包零/近零增量,见 [[voice-media-upload-pipeline]]):
/// - iOS/macOS:AVAssetReader/Writer(系统框架,H264 videotoolbox 硬编);
/// - Android:media3 Transformer(Java 库 ~1-2MB,底层系统 MediaCodec);
/// - Windows/Linux:进程 ffmpeg(Windows 首用时从 npmmirror 镜像下载
///   缓存;Linux 用系统 ffmpeg)—— 见 ffmpeg_process_transcoder.dart。
///
/// 单任务模型:同一时刻只允许一个转码任务(压缩是用户前台等待的模态
/// 流程);progress 轮询,cancel 中断。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import 'ffmpeg_process_transcoder.dart';

/// 媒体探测结果。
class MediaProbeInfo {
  const MediaProbeInfo({
    required this.duration,
    required this.hasVideo,
    this.width,
    this.height,
  });

  final Duration duration;
  final bool hasVideo;
  final int? width;
  final int? height;
}

/// 一次转码的完整参数(码率单位 bps)。
class TranscodeSpec {
  const TranscodeSpec({
    required this.input,
    required this.output,
    required this.audioBitrate,
    this.audioOnly = false,
    this.videoBitrate,
    this.videoCodec = 'h264',
    this.maxHeight,
    this.fps,
    this.audioSampleRate = 44100,
    this.audioChannels = 2,
  });

  final String input;

  /// 目标文件路径(audio-only 用 `.m4a`,视频用 `.mp4` —— AAC/H264 均
  /// 走 MP4 容器,双端播放兼容面最大)。
  final String output;

  /// 只转音频(输入为纯音频文件,或显式丢弃视频轨)。
  final bool audioOnly;

  final int audioBitrate;
  final int? videoBitrate;

  /// 视频编码器:'h264'(默认,兼容面最大)/ 'hevc'(同码率画质
  /// +30~50%;Safari/Chrome 新版可播,Firefox 部分平台不行 —— 编码
  /// 失败由策略层回退 H264)。
  final String videoCodec;

  /// 视频缩放目标高(宽按比例,偶数对齐);null 保持原尺寸。
  final int? maxHeight;

  /// 目标帧率(仅 ffmpeg/Apple 腿支持;media3 不降帧,码率主导)。
  final int? fps;

  final int audioSampleRate;
  final int audioChannels;

  Map<String, Object?> toChannelMap() => {
        'input': input,
        'output': output,
        'audioOnly': audioOnly,
        'audioBitrate': audioBitrate,
        'videoBitrate': videoBitrate,
        'videoCodec': videoCodec,
        'maxHeight': maxHeight,
        'fps': fps,
        'audioSampleRate': audioSampleRate,
        'audioChannels': audioChannels,
      };
}

abstract class MediaTranscoder {
  /// 当前平台的转码器;null = 平台不支持(web)。桌面 ffmpeg 腿的
  /// 可用性(Windows 未下载/Linux 未安装)由 [ensureReady] 惰性解决。
  static MediaTranscoder? forCurrentPlatform() {
    if (kIsWeb) return null;
    if (Platform.isIOS || Platform.isMacOS || Platform.isAndroid) {
      return _ChannelTranscoder.instance;
    }
    if (Platform.isWindows || Platform.isLinux) {
      return FfmpegProcessTranscoder.instance;
    }
    return null;
  }

  /// 转码前的环境准备(Windows:下载 ffmpeg;Linux:检测系统 ffmpeg;
  /// 移动端恒 ready)。[onStatus] 回报准备进展(如下载百分比)。
  /// 返回 null = 就绪;非 null = 不可用原因(人话,直接展示)。
  Future<String?> ensureReady({void Function(String status)? onStatus}) async =>
      null;

  Future<MediaProbeInfo?> probe(String path);

  /// 执行转码。true = 完成;false = 被 [cancel] 中断。失败抛异常。
  Future<bool> transcode(TranscodeSpec spec);

  /// 当前任务进度 0..1(无任务返回 0)。
  Future<double> progress();

  Future<void> cancel();
}

/// iOS/macOS/Android:MethodChannel 到原生实现。
class _ChannelTranscoder extends MediaTranscoder {
  _ChannelTranscoder._();
  static final instance = _ChannelTranscoder._();

  static const _ch = MethodChannel('com.fluxdo/media_transcode');

  @override
  Future<MediaProbeInfo?> probe(String path) async {
    final res = await _ch.invokeMapMethod<String, Object?>('probe', path);
    if (res == null) return null;
    final ms = res['durationMs'] as int?;
    if (ms == null || ms <= 0) return null;
    return MediaProbeInfo(
      duration: Duration(milliseconds: ms),
      hasVideo: res['hasVideo'] as bool? ?? false,
      width: res['width'] as int?,
      height: res['height'] as int?,
    );
  }

  @override
  Future<bool> transcode(TranscodeSpec spec) async {
    final res =
        await _ch.invokeMethod<bool>('transcode', spec.toChannelMap());
    return res ?? false;
  }

  @override
  Future<double> progress() async =>
      await _ch.invokeMethod<double>('progress') ?? 0;

  @override
  Future<void> cancel() => _ch.invokeMethod('cancel');
}
