/// 进程 ffmpeg 转码腿(Windows / Linux)。
///
/// ffmpeg 二进制**随安装包分发**(windows/linux 的 CMakeLists 构建期
/// 下载打入,开发机缓存一次)—— 运行时零下载(终端用户网络不可控,
/// 曾试过运行时下载被否)。查找顺序:①主程序同目录随包版 → ②系统
/// PATH → ③不可用提示。pubspec 无任何 ffmpeg 依赖,移动端构建完全
/// 不感知(平台选择在各端原生构建系统里完成,不在 Dart 依赖层)。
///
/// 进度:`-progress pipe:1 -nostats` 输出 `out_time_ms=` 行 ÷ 总时长
/// (该字段实为微秒,ffmpeg 历史命名坑)。
/// probe:ffmpeg-static 不带 ffprobe —— 用 `ffmpeg -i` 的 stderr 解析
/// `Duration:` 行与 `Stream ... Video:` 行(经典兜底,格式多年稳定)。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'media_transcoder.dart';

class FfmpegProcessTranscoder extends MediaTranscoder {
  FfmpegProcessTranscoder._();
  static final instance = FfmpegProcessTranscoder._();

  String? _ffmpegPath;
  Process? _proc;
  double _progress = 0;
  Duration _total = Duration.zero;
  bool _cancelled = false;

  @override
  Future<String?> ensureReady({
    void Function(String status)? onStatus,
  }) async {
    if (_ffmpegPath != null) return null;
    // ① 随包分发:与主程序同目录(CMake install 到 bundle 根)
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final name = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    final bundled = File('$exeDir${Platform.pathSeparator}$name');
    if (await bundled.exists()) {
      _ffmpegPath = bundled.path;
      return null;
    }
    // ② 系统 PATH(用户自装的 ffmpeg)
    final probe = await Process.run(
      Platform.isWindows ? 'where' : 'which',
      ['ffmpeg'],
    );
    final found = (probe.stdout as String)
        .trim()
        .split(RegExp(r'[\r\n]+'))
        .first
        .trim();
    if (probe.exitCode == 0 && found.isNotEmpty) {
      _ffmpegPath = found;
      return null;
    }
    return Platform.isLinux
        ? '未检测到 ffmpeg,请安装(如 sudo apt install ffmpeg)后重试'
        : '安装包缺少 ffmpeg 组件,请重新安装应用';
  }

  @override
  Future<MediaProbeInfo?> probe(String path) async {
    final ffmpeg = _ffmpegPath;
    if (ffmpeg == null) return null;
    // `ffmpeg -i` 无输出目标必然非零退出,信息全在 stderr
    final res = await Process.run(ffmpeg, ['-hide_banner', '-i', path]);
    final err = res.stderr as String;
    final dur = parseFfmpegDuration(err);
    if (dur == null) return null;
    return MediaProbeInfo(
      duration: dur,
      hasVideo: RegExp(r'Stream #\d+:\d+.*: Video:').hasMatch(err),
    );
  }

  /// `Duration: 00:01:23.45` → Duration。公开做单测。
  static Duration? parseFfmpegDuration(String stderr) {
    final m = RegExp(r'Duration:\s*(\d+):(\d\d):(\d\d)\.(\d\d)')
        .firstMatch(stderr);
    if (m == null) return null;
    return Duration(
      hours: int.parse(m[1]!),
      minutes: int.parse(m[2]!),
      seconds: int.parse(m[3]!),
      milliseconds: int.parse(m[4]!) * 10,
    );
  }

  /// 组装 ffmpeg 参数(与社区脚本 profile 同款语义)。公开做单测。
  static List<String> buildArgs(TranscodeSpec spec) {
    final args = <String>['-y', '-hide_banner', '-i', spec.input];
    if (spec.audioOnly) {
      args.addAll(['-vn', '-c:a', 'aac', '-b:a', '${spec.audioBitrate}']);
      args.addAll(['-ac', '${spec.audioChannels}']);
      args.addAll(['-ar', '${spec.audioSampleRate}']);
    } else {
      args.addAll(['-map', '0:v:0', '-map', '0:a:0?']);
      // veryfast:x26x 速度/质量甜点(ultrafast 率失真最差,同码率
      // 明显更糊;桌面 CPU 扛得住)。HEVC 必须 -tag:v hvc1 ——
      // ffmpeg 默认写 hev1,Safari/AVFoundation 不认。
      if (spec.videoCodec == 'hevc') {
        args.addAll(['-c:v', 'libx265', '-preset', 'veryfast']);
        args.addAll(['-tag:v', 'hvc1']);
      } else {
        args.addAll(['-c:v', 'libx264', '-preset', 'veryfast']);
      }
      if (spec.maxHeight != null) {
        args.addAll(['-vf', 'scale=-2:${spec.maxHeight}']);
      }
      if (spec.fps != null) args.addAll(['-r', '${spec.fps}']);
      final v = spec.videoBitrate!;
      args.addAll(['-b:v', '$v', '-maxrate', '$v', '-bufsize', '${v * 2}']);
      args.addAll(['-c:a', 'aac', '-b:a', '${spec.audioBitrate}']);
    }
    args.addAll(['-movflags', '+faststart']);
    args.addAll(['-progress', 'pipe:1', '-nostats']);
    args.add(spec.output);
    return args;
  }

  @override
  Future<bool> transcode(TranscodeSpec spec) async {
    final ffmpeg = _ffmpegPath;
    if (ffmpeg == null) throw StateError('ffmpeg 未就绪(先 ensureReady)');
    if (_proc != null) throw StateError('已有转码任务进行中');
    _progress = 0;
    _cancelled = false;
    _total = (await probe(spec.input))?.duration ?? Duration.zero;

    final proc = await Process.start(ffmpeg, buildArgs(spec));
    _proc = proc;
    // 进度行:out_time_ms=1234567(微秒,ffmpeg 历史命名坑)
    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (_total == Duration.zero) return;
      final m = RegExp(r'^out_time_ms=(\d+)').firstMatch(line);
      if (m != null) {
        final us = int.parse(m[1]!);
        _progress =
            (us / 1000 / _total.inMilliseconds).clamp(0.0, 1.0);
      }
    });
    // stderr 必须排空(不排 ffmpeg 写满管道会卡死)
    proc.stderr.drain<void>();

    final code = await proc.exitCode;
    _proc = null;
    _progress = code == 0 ? 1 : _progress;
    if (_cancelled) return false;
    if (code != 0) {
      throw Exception('ffmpeg 转码失败(exit $code)');
    }
    return true;
  }

  @override
  Future<double> progress() async => _progress;

  @override
  Future<void> cancel() async {
    _cancelled = true;
    _proc?.kill();
  }
}
