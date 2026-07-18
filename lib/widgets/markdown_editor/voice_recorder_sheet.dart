/// 语音消息录音面板(底部弹层):录制 → 试听/重录 → 发送。
///
/// 录音规格:AAC-LC 32kbps / 16kHz / 单声道(语音清晰度足够;10 分钟
/// 上限 ≈ 2.4MB,天然低于站点 4MB 上传上限,无需压缩)。产物 `.m4a`
/// 经改名 `.xz` 上传,标签 type 写 `audio/mp4`(AVFoundation / 浏览器
/// 通吃)。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../services/media_transcoder/media_transcoder.dart';
import 'debug_voice_sample.dart';

/// 弹出录音面板;完成返回录音文件路径(m4a),取消返回 null。
Future<String?> showVoiceRecorderSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    showDragHandle: true,
    builder: (_) => const _VoiceRecorderSheet(),
  );
}

/// 录制时长上限(32kbps 下 ≈ 2.4MB,留足 4MB 余量)。
const _kMaxRecordDuration = Duration(minutes: 10);

class _VoiceRecorderSheet extends StatefulWidget {
  const _VoiceRecorderSheet();

  @override
  State<_VoiceRecorderSheet> createState() => _VoiceRecorderSheetState();
}

enum _Phase { idle, recording, recorded }

class _VoiceRecorderSheetState extends State<_VoiceRecorderSheet> {
  /// 懒构造:点「录制」才建(打开面板即建会在插件缺失/热重启场景
  /// 白抛异常;debug 合成路径完全不碰录音插件)。
  AudioRecorder? _recorder;
  AudioPlayer? _player;

  _Phase _phase = _Phase.idle;
  String? _path;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;
  double _amplitude = 0; // 0..1 归一化(录制中脉冲指示)
  StreamSubscription<Amplitude>? _ampSub;
  String? _error;

  @override
  void dispose() {
    _ticker?.cancel();
    _ampSub?.cancel();
    _recorder?.dispose();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final recorder = _recorder ??= AudioRecorder();
    try {
      if (!await recorder.hasPermission()) {
        if (mounted) {
          setState(() => _error = '未获得麦克风权限,请在系统设置中允许');
        }
        return;
      }
    } on MissingPluginException {
      // 新加的原生插件,热重启不注册平台实现 —— 只能完整冷启动
      if (mounted) {
        setState(() => _error = '录音组件未就绪,请完全退出并重新打开应用');
      }
      return;
    } catch (e) {
      if (mounted) setState(() => _error = '录音初始化失败:$e');
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = p.join(
      dir.path,
      'voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
    );
    try {
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 32000,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
    } catch (e) {
      if (mounted) setState(() => _error = '录音启动失败:$e');
      return;
    }
    _ampSub = recorder
        .onAmplitudeChanged(const Duration(milliseconds: 120))
        .listen((a) {
      // dBFS(约 -45..0)→ 0..1
      final norm = ((a.current + 45) / 45).clamp(0.0, 1.0);
      if (mounted) setState(() => _amplitude = norm);
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed += const Duration(seconds: 1));
      if (_elapsed >= _kMaxRecordDuration) _stop();
    });
    setState(() {
      _phase = _Phase.recording;
      _path = path;
      _elapsed = Duration.zero;
      _error = null;
    });
  }

  Future<void> _stop() async {
    _ticker?.cancel();
    await _ampSub?.cancel();
    _ampSub = null;
    final path = await _recorder?.stop();
    if (!mounted) return;
    if (path == null) {
      setState(() {
        _phase = _Phase.idle;
        _error = '录音失败,请重试';
      });
      return;
    }
    setState(() {
      _phase = _Phase.recorded;
      _path = path;
    });
  }

  /// debug:合成测试音频代替真实录音(不碰麦克风/录音插件)。
  /// 优先经转码腿转成与真实录音同规格的 m4a(顺带真验转码链);
  /// 转码不可用(热重启/无 ffmpeg)降级直接用 wav —— 播放端两种都认。
  Future<void> _debugSynthesize() async {
    setState(() => _error = null);
    const duration = Duration(seconds: 8);
    String path;
    try {
      path = await synthesizeTestVoiceWav(duration: duration);
    } catch (e) {
      if (mounted) setState(() => _error = '合成失败:$e');
      return;
    }
    final transcoder = MediaTranscoder.forCurrentPlatform();
    if (transcoder != null && await transcoder.ensureReady() == null) {
      try {
        final m4a = path.replaceFirst(RegExp(r'\.wav$'), '.m4a');
        final ok = await transcoder.transcode(TranscodeSpec(
          input: path,
          output: m4a,
          audioOnly: true,
          audioBitrate: 32000,
          audioSampleRate: 16000,
          audioChannels: 1,
        ));
        if (ok) path = m4a;
      } catch (_) {
        // 转码腿不可用(如热重启后通道缺失):wav 直用
      }
    }
    if (!mounted) return;
    setState(() {
      _phase = _Phase.recorded;
      _path = path;
      _elapsed = duration;
    });
  }

  Future<void> _togglePreview() async {
    final path = _path;
    if (path == null) return;
    final player = _player ??= AudioPlayer();
    if (player.playing) {
      await player.pause();
      return;
    }
    if (player.audioSource == null ||
        player.processingState == ProcessingState.completed) {
      await player.setFilePath(path);
    }
    unawaited(player.play());
  }

  Future<void> _retake() async {
    await _player?.stop();
    final old = _path;
    if (old != null) {
      unawaited(File(old).delete().catchError((_) => File(old)));
    }
    setState(() {
      _phase = _Phase.idle;
      _path = null;
      _elapsed = Duration.zero;
    });
  }

  void _cancel() {
    final path = _path;
    if (path != null) {
      unawaited(File(path).delete().catchError((_) => File(path)));
    }
    Navigator.of(context).pop(null);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('语音消息', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              switch (_phase) {
                _Phase.idle => '点击开始录制(最长 10 分钟)',
                _Phase.recording => '录制中…',
                _Phase.recorded => '试听确认后发送',
              },
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style:
                      theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
            ],
            const SizedBox(height: 20),
            Text(
              _fmt(_elapsed),
              style: theme.textTheme.displaySmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 20),
            // 主按钮:录制/停止(录制中带幅度脉冲圈)
            if (_phase != _Phase.recorded)
              GestureDetector(
                onTap: _phase == _Phase.recording ? _stop : _start,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: 76 + (_phase == _Phase.recording ? _amplitude * 14 : 0),
                  height: 76 + (_phase == _Phase.recording ? _amplitude * 14 : 0),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _phase == _Phase.recording
                        ? scheme.errorContainer
                        : scheme.primaryContainer,
                  ),
                  child: Icon(
                    _phase == _Phase.recording
                        ? Icons.stop_rounded
                        : Icons.mic_rounded,
                    size: 34,
                    color: _phase == _Phase.recording
                        ? scheme.onErrorContainer
                        : scheme.onPrimaryContainer,
                  ),
                ),
              )
            else
              // 试听行
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  StreamBuilder<PlayerState>(
                    stream: _player?.playerStateStream,
                    builder: (context, snap) {
                      final playing = (snap.data?.playing ?? false) &&
                          snap.data?.processingState !=
                              ProcessingState.completed;
                      return IconButton.filledTonal(
                        iconSize: 32,
                        icon: Icon(playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded),
                        onPressed: _togglePreview,
                      );
                    },
                  ),
                ],
              ),
            if (kDebugMode && _phase == _Phase.idle) ...[
              const SizedBox(height: 10),
              TextButton.icon(
                icon: const Icon(Icons.science_outlined, size: 16),
                label: const Text('生成测试音频(debug)',
                    style: TextStyle(fontSize: 12)),
                onPressed: _debugSynthesize,
              ),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                TextButton(onPressed: _cancel, child: const Text('取消')),
                const Spacer(),
                if (_phase == _Phase.recorded) ...[
                  TextButton(onPressed: _retake, child: const Text('重录')),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.send_rounded, size: 18),
                    label: const Text('发送'),
                    onPressed: () => Navigator.of(context).pop(_path),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
