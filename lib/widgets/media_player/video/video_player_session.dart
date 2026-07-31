import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../services/media/playback_position_store.dart';

/// 视频控制器的唯一 owner。inline 播放器与全屏页都只是「租户」:
/// retain()/release() 引用计数,归零才 dispose。
///
/// 这是旧 chewie 方案 `_fullscreenCache` + GlobalKey 收养机制的替代:
/// 旧方案的复杂度根因是 chewie 全屏路由跨路由引用 embedded ChewieState,
/// 宿主被 cacheExtent 回收就 use-after-dispose。Session 模型下
/// `VideoPlayer(controller)` 只是 textureId 的展示层,inline 与全屏两处
/// 各自 build 自己的展示与控制层,谁死都不连坐 —— 只要控制器活在
/// Session 里。全屏期间宿主被回收:inline release 后 refCount 仍 ≥1
/// (全屏页持有),控制器安然无恙;宿主滚回来重建时 obtain() 命中现存
/// session 直接复用(顺带获得重进秒开)。
class VideoPlayerSession {
  VideoPlayerSession._({
    required this.url,
    required this.controller,
  });

  /// 已解析好的真实播放 URL(session 身份键)。
  final String url;

  final VideoPlayerController controller;

  int _refCount = 0;
  bool _disposed = false;

  /// 全屏路由在场标志。用 ValueNotifier 而非裸 bool:inline 靠它在全屏
  /// 进/出时各重建一次(Texture ↔ 占位切换)—— 不能指望 controller tick
  /// 驱动,暂停状态下没有 tick,裸 bool 会让退出全屏后 inline 卡在占位。
  /// inline 据此:
  /// - 不画 Texture(避免双附着歧义,单附着最稳);
  /// - RouteAware.didPushNext 豁免(全屏是自己人,不是「上层弹窗」)。
  final ValueNotifier<bool> fullscreenNotifier = ValueNotifier(false);

  bool get isFullscreen => fullscreenNotifier.value;
  set isFullscreen(bool value) => fullscreenNotifier.value = value;

  /// 长按 2x 快进前的原倍速,松手恢复用。
  double speedBeforeLongPress = 1.0;

  /// 静音前的原音量,取消静音恢复用。
  double volumeBeforeMute = 1.0;

  /// 初始化完成后从 [PlaybackPositionStore] 恢复到的续播位置;
  /// 控制层用它在用户首次点播放时提示「已从 xx:xx 继续播放」,
  /// 提示过后置 null。
  Duration? resumedPosition;

  Timer? _positionSaveTimer;
  bool _wakelockOn = false;

  /// 初始化完成(拿到 duration/尺寸)后为 true。
  bool get isInitialized => controller.value.isInitialized;

  void _start() {
    controller.addListener(_onControllerTick);
  }

  /// 播放状态驱动的横切逻辑:wakelock 开关 + 播放中位置节流保存。
  void _onControllerTick() {
    final value = controller.value;
    final playing = value.isPlaying;
    if (playing != _wakelockOn) {
      _wakelockOn = playing;
      unawaited(WakelockPlus.toggle(enable: playing));
    }
    if (playing) {
      _positionSaveTimer ??= Timer.periodic(
        const Duration(seconds: 10),
        (_) => _savePosition(),
      );
    } else if (_positionSaveTimer != null) {
      _positionSaveTimer!.cancel();
      _positionSaveTimer = null;
      // 暂停/播完是一次确定的记忆点
      _savePosition();
    }
  }

  void _savePosition() {
    final value = controller.value;
    if (!value.isInitialized || value.duration == Duration.zero) return;
    unawaited(
      PlaybackPositionStore.instance.save(url, value.position, value.duration),
    );
  }

  void retain() {
    assert(!_disposed, 'VideoPlayerSession($url) used after dispose');
    _refCount++;
  }

  void release() {
    assert(_refCount > 0);
    if (--_refCount > 0) return;
    _disposed = true;
    _positionSaveTimer?.cancel();
    _savePosition();
    // flush 内部有 dirty 短路:没有未落盘变更时是纯空操作,不会让
    // 快速滚动中批量销毁的暂停视频各写一次磁盘
    unawaited(PlaybackPositionStore.instance.flush());
    if (_wakelockOn) {
      unawaited(WakelockPlus.disable());
    }
    controller.removeListener(_onControllerTick);
    fullscreenNotifier.dispose();
    unawaited(controller.dispose());
    VideoSessionRegistry._sessions.remove(url);
  }
}

/// url → session 全局表。同一视频在列表内滚出滚回、inline 与全屏并存
/// 时共享同一控制器。
class VideoSessionRegistry {
  VideoSessionRegistry._();

  static final Map<String, VideoPlayerSession> _sessions = {};

  /// 视频真实宽高比记忆(url → 实测比例)。HTML 无尺寸的视频占位只能猜
  /// 16:9,初始化完成才知道真实比例;帖子滚出 cacheExtent 被销毁、滚
  /// 回来重建时若没有这份记忆,每次路过都会"占位比 → 真实比"跳一次,
  /// 布局高度突变把滚动拉断(视口上方的视频尤甚)。有记忆后重建直接
  /// 以真实比例占位,初始化完成零布局变化。
  static final Map<String, double> knownAspectRatios = {};

  /// 取得(或创建)[url] 的 session。调用方必须配对 retain()/release()。
  static VideoPlayerSession obtain(String url, {String? mimeType}) {
    final existing = _sessions[url];
    if (existing != null) return existing;
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      formatHint: videoFormatHintFromMime(mimeType),
    );
    final session = VideoPlayerSession._(url: url, controller: controller);
    session._start();
    _sessions[url] = session;
    return session;
  }
}

/// 把 HTML 声明的 MIME 转为 video_player 可用的格式提示。
///
/// `video/mp4` / `video/webm` 等普通容器映射为 [VideoFormat.other]，
/// 这会在 Android 上强制走 progressive 媒体路径,不再信任 `.xz`
/// 之类伪装后缀。media_kit 后端(Windows/Linux)忽略该提示,
/// mpv/ffmpeg 按内容 probe,天然无视扩展名。
@visibleForTesting
VideoFormat? videoFormatHintFromMime(String? mimeType) {
  final mime = mimeType?.split(';').first.trim().toLowerCase();
  if (mime == null || mime.isEmpty) return null;
  if (mime == 'application/dash+xml') return VideoFormat.dash;
  if (mime == 'application/vnd.apple.mpegurl' ||
      mime == 'application/x-mpegurl' ||
      mime == 'audio/mpegurl' ||
      mime == 'audio/x-mpegurl') {
    return VideoFormat.hls;
  }
  if (mime == 'application/vnd.ms-sstr+xml') return VideoFormat.ss;
  if (mime.startsWith('video/') || mime.startsWith('audio/')) {
    return VideoFormat.other;
  }
  return null;
}
