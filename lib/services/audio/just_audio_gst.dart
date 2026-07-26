import 'dart:async';

import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// Linux 的 just_audio 后端:桥接到 audioplayers_linux(GStreamer)。
///
/// 为什么不用 media_kit(Windows 同款):media_kit_libs_linux 不打包
/// libmpv(指望系统已装),且其 CMake 会在 configure 期联网下载 mimalloc,
/// 在 flatpak 禁网沙箱里是 FATAL_ERROR;运行时 GNOME runtime 也没有
/// libmpv,dlopen 直接抛异常。而 GStreamer(core/base/good + gst-libav,
/// 覆盖 AAC/MP3/Opus)本来就在 GNOME runtime 里 —— wpe-layer 的 WebKit
/// 播媒体用的就是它,audioplayers_linux 的 CMake 只 pkg-config 查系统
/// GStreamer、零构建期下载,禁网沙箱天然可编。
///
/// 只实现本项目用到的子集(单曲 URL:load/play/pause/seek/音量/倍速)。
/// 播放列表、ClippingAudioSource 等 just_audio 高级音源不支持 —— 帖内
/// 音频条与语音评论预览都是单文件播放。
class JustAudioGst extends JustAudioPlatform {
  final _players = <String, _GstAudioPlayer>{};

  /// 在 main() 里于创建任何 AudioPlayer 之前调用(仅 Linux)。
  static void registerWith() {
    JustAudioPlatform.instance = JustAudioGst();
  }

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    if (_players.containsKey(request.id)) {
      throw PlatformException(
        code: 'error',
        message: 'Player ${request.id} already exists',
      );
    }
    final player = _GstAudioPlayer(request.id);
    await player._create();
    _players[request.id] = player;
    return player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
    DisposePlayerRequest request,
  ) async {
    await _players.remove(request.id)?._dispose();
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
    DisposeAllPlayersRequest request,
  ) async {
    final players = _players.values.toList(growable: false);
    _players.clear();
    for (final player in players) {
      await player._dispose();
    }
    return DisposeAllPlayersResponse();
  }
}

class _GstAudioPlayer extends AudioPlayerPlatform {
  _GstAudioPlayer(super.id);

  static AudioplayersPlatformInterface get _api =>
      AudioplayersPlatformInterface.instance;

  final _events = StreamController<PlaybackEventMessage>.broadcast();
  StreamSubscription<AudioEvent>? _eventSub;

  var _processingState = ProcessingStateMessage.idle;
  Duration? _duration;

  /// 最后一次确知的播放位置。just_audio 前端按
  /// `updatePosition + (now - updateTime)` 自行插值,platform 侧无需轮询,
  /// 只要在状态转换点(load/play/pause/seek/completed)上报准确锚点。
  var _position = Duration.zero;
  var _playing = false;
  var _disposed = false;
  Completer<void>? _prepared;

  Future<void> _create() async {
    await _api.create(id);
    // 对齐 just_audio 语义:播完停在 completed、可 seek 回去重播。
    // audioplayers 默认 release 会把已加载的源一并释放。
    await _api.setReleaseMode(id, ReleaseMode.stop);
    _eventSub = _api.getEventStream(id).listen(_onEvent, onError: _onError);
  }

  Future<void> _dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _eventSub?.cancel();
    await _events.close();
    await _api.dispose(id);
  }

  void _onEvent(AudioEvent event) {
    if (_disposed) return;
    switch (event.eventType) {
      case AudioEventType.prepared:
        if (event.isPrepared ?? false) {
          _prepared?.complete();
          _prepared = null;
        }
      case AudioEventType.duration:
        _duration = event.duration;
        if (_processingState == ProcessingStateMessage.ready) {
          _broadcast();
        }
      case AudioEventType.complete:
        _processingState = ProcessingStateMessage.completed;
        _playing = false;
        _position = _duration ?? _position;
        _broadcast();
      case AudioEventType.seekComplete:
        // seek() 已乐观上报目标位置;GStreamer 落到关键帧后校准一次。
        unawaited(_refreshPosition());
      case AudioEventType.log:
        break;
    }
  }

  void _onError(Object error) {
    if (_disposed) return;
    final prepared = _prepared;
    if (prepared != null && !prepared.isCompleted) {
      _prepared = null;
      prepared.completeError(
        PlatformException(code: 'load_failed', message: '$error'),
      );
      return;
    }
    _events.addError(error);
  }

  Future<void> _refreshPosition() async {
    final positionMs = await _api.getCurrentPosition(id);
    if (_disposed || positionMs == null) return;
    _position = Duration(milliseconds: positionMs);
    _broadcast();
  }

  void _broadcast() {
    if (_disposed) return;
    _events.add(
      PlaybackEventMessage(
        processingState: _processingState,
        updateTime: DateTime.now(),
        updatePosition: _position,
        // GStreamer 侧无缓冲进度事件,用当前位置兜底(进度条不画缓冲带)。
        bufferedPosition: _position,
        duration: _duration,
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      ),
    );
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    final source = request.audioSourceMessage;
    if (source is! UriAudioSourceMessage) {
      throw PlatformException(
        code: 'unsupported',
        message: 'JustAudioGst 仅支持 URL 音源(setUrl/setFilePath)',
      );
    }
    _processingState = ProcessingStateMessage.loading;
    _duration = null;
    _position = Duration.zero;
    _broadcast();

    final prepared = _prepared = Completer<void>();
    final uri = Uri.parse(source.uri);
    await _api.setSourceUrl(
      id,
      source.uri,
      isLocal: uri.scheme.isEmpty || uri.scheme == 'file',
    );
    // setSourceUrl 返回不代表就绪,等 prepared 事件;失败经 _onError 抛出。
    await prepared.future;

    final durationMs = await _api.getDuration(id);
    if (durationMs != null && durationMs > 0) {
      _duration = Duration(milliseconds: durationMs);
    }
    if (request.initialPosition != null &&
        request.initialPosition! > Duration.zero) {
      _position = request.initialPosition!;
      await _api.seek(id, _position);
    }
    _processingState = ProcessingStateMessage.ready;
    _broadcast();
    return LoadResponse(duration: _duration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    if (_playing) return PlayResponse();
    _playing = true;
    await _api.resume(id);
    _broadcast();
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    if (!_playing) return PauseResponse();
    _playing = false;
    await _api.pause(id);
    // 暂停后取真实位置作为新锚点,消除插值累计误差。
    await _refreshPosition();
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _position = request.position ?? Duration.zero;
    if (_processingState == ProcessingStateMessage.completed) {
      _processingState = ProcessingStateMessage.ready;
    }
    await _api.seek(id, _position);
    _broadcast();
    return SeekResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    await _api.setVolume(id, request.volume);
    return SetVolumeResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    await _api.setPlaybackRate(id, request.speed);
    return SetSpeedResponse();
  }
}
