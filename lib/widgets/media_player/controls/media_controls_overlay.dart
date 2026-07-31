import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:video_player/video_player.dart';

import '../../../l10n/s.dart';
import '../../../utils/platform_utils.dart';
import '../video/video_player_session.dart';
import 'media_gesture_layer.dart';
import 'media_overlay_style.dart';
import 'media_progress_bar.dart';
import 'playback_speed_menu.dart';
import 'volume_brightness_indicator.dart';

/// 视频控制层总装(inline 与全屏共用):手势层 + 顶/底渐变控制条 +
/// 中央播放大按钮 + 双击 seek 提示 + 竖滑/滚轮 HUD + 长按 2x 角标 +
/// 续播提示胶囊。
///
/// 视觉:黑底白字 overlay 体系,浮层质感统一走 [MediaOverlayStyle]
/// (半透深底+发丝描边+投影,不用 BackdropFilter —— 视频纹理上每帧
/// 重做高斯模糊是已知卡顿源)。控制条出入场为滑入+淡入。
///
/// 音量的端别分工:
/// - 移动端:全屏竖滑调系统音量(手势层);控制条只留静音钮
///   (窗口态有硬件音量键,不摆滑条)。
/// - 桌面端:静音钮悬停展开音量滑条 + 悬停滚轮调音量(播放器级
///   controller.setVolume,不动系统音量)。
class MediaControlsOverlay extends StatefulWidget {
  const MediaControlsOverlay({
    super.key,
    required this.session,
    required this.isFullscreen,
    required this.onFullscreenToggle,
  });

  final VideoPlayerSession session;
  final bool isFullscreen;

  /// inline 请求进全屏 / 全屏页请求退出。
  final VoidCallback onFullscreenToggle;

  @override
  State<MediaControlsOverlay> createState() => _MediaControlsOverlayState();
}

class _MediaControlsOverlayState extends State<MediaControlsOverlay>
    with TickerProviderStateMixin {
  static final bool _isDesktop = PlatformUtils.isDesktop;
  static const Duration _autoHideDelay = Duration(seconds: 3);

  VideoPlayerController get _controller => widget.session.controller;

  bool _controlsVisible = true;
  bool _draggingProgress = false;
  bool _longPressBoost = false;
  bool _volumeExpanded = false;

  /// 全屏锁定:锁住后手势/控制条全部失效,只留解锁钮(防误触)。
  bool _locked = false;
  bool _lockButtonVisible = true;
  Timer? _lockButtonHideTimer;

  Timer? _hideTimer;
  Timer? _volumeCollapseTimer;

  /// 中央播放钮 play↔pause 图标形变(0=play,1=pause)。
  late final AnimationController _playPauseIcon = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: _controller.value.isPlaying ? 1 : 0,
  );

  // 竖滑/滚轮 HUD 状态
  bool _hudVisible = false;
  bool _hudIsVolume = true;
  double _hudValue = 0;
  Timer? _hudHideTimer;

  // 横滑 seek 预览(顶部中央「目标 / 总长」胶囊);null = 未在横滑
  Duration? _seekPreviewTarget;
  bool _seekPreviewForward = true;
  bool _seekPreviewCancelArmed = false;

  // 续播提示胶囊(「已从 xx:xx 继续播放」)
  Duration? _resumedHint;
  Timer? _resumedHintTimer;

  /// 中央播放钮的「稳定暂停」判定:seek 期间后端会瞬时回报
  /// isPlaying=false,直接跟随会让大按钮闪现一帧。暂停态持续 250ms
  /// 才算真暂停;恢复播放立即撤。
  bool _stablyPaused = false;
  Timer? _pauseDebounce;

  void _syncStablyPaused(bool playing) {
    if (playing) {
      _pauseDebounce?.cancel();
      _pauseDebounce = null;
      if (_stablyPaused) {
        // build 中触发,推迟到帧尾翻转
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _controller.value.isPlaying) {
            setState(() => _stablyPaused = false);
          }
        });
      }
    } else if (!_stablyPaused && _pauseDebounce == null) {
      _pauseDebounce = Timer(const Duration(milliseconds: 250), () {
        _pauseDebounce = null;
        if (mounted && !_controller.value.isPlaying) {
          setState(() => _stablyPaused = true);
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hudHideTimer?.cancel();
    _resumedHintTimer?.cancel();
    _volumeCollapseTimer?.cancel();
    _lockButtonHideTimer?.cancel();
    _pauseDebounce?.cancel();
    _playPauseIcon.dispose();
    super.dispose();
  }

  // ---- 控制条显隐 ----
  //
  // 端别策略:
  // - 移动端:单击 toggle(手势层),播放中 3s 无交互自动隐藏。
  // - 桌面端:纯悬停驱动 —— 鼠标移动即显示、静止 3s 或移出播放器即
  //   隐藏;点击不参与显隐(点击=播/停),两种模态不再打架。

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_autoHideDelay, () {
      if (!mounted) return;
      // 拖动中/暂停态不隐藏
      if (_draggingProgress || !_controller.value.isPlaying) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  /// 移动端单击 toggle(桌面端手势层不会调用)。
  void _toggleControls() {
    if (_controlsVisible) {
      _hideTimer?.cancel();
      setState(() => _controlsVisible = false);
    } else {
      _showControls();
    }
  }

  /// 桌面端:鼠标移出播放器区域即隐藏(暂停/拖动中除外)。
  void _hideOnExit() {
    _hideTimer?.cancel();
    if (!mounted) return;
    if (_draggingProgress || !_controller.value.isPlaying) return;
    setState(() => _controlsVisible = false);
  }

  // ---- 播放操作 ----

  void _togglePlay() {
    final value = _controller.value;
    if (value.isPlaying) {
      _controller.pause();
    } else {
      _maybeShowResumedHint();
      if (value.isCompleted) {
        _controller.seekTo(Duration.zero);
      }
      _controller.play();
    }
    _showControls();
  }

  /// 首次点播放时在播放器内弹「已从 xx:xx 继续播放」胶囊
  /// (位置记忆命中的场景),短暂停留后淡出。
  void _maybeShowResumedHint() {
    final resumed = widget.session.resumedPosition;
    if (resumed == null) return;
    widget.session.resumedPosition = null;
    setState(() => _resumedHint = resumed);
    _resumedHintTimer?.cancel();
    _resumedHintTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _resumedHint = null);
    });
  }

  // ---- 全屏锁定 ----

  void _toggleLock() {
    setState(() {
      _locked = !_locked;
      if (_locked) {
        // 锁定:收起控制条,锁钮短暂可见后隐藏
        _hideTimer?.cancel();
        _controlsVisible = false;
        _lockButtonVisible = true;
        _scheduleLockButtonHide();
      } else {
        _lockButtonHideTimer?.cancel();
        _lockButtonVisible = true;
        _showControls();
      }
    });
  }

  void _scheduleLockButtonHide() {
    _lockButtonHideTimer?.cancel();
    _lockButtonHideTimer = Timer(_autoHideDelay, () {
      if (mounted && _locked) {
        setState(() => _lockButtonVisible = false);
      }
    });
  }

  /// 锁定态下单击画面:只唤出/隐藏锁钮。
  void _onLockedTap() {
    setState(() => _lockButtonVisible = !_lockButtonVisible);
    if (_lockButtonVisible) _scheduleLockButtonHide();
  }

  void _onLongPressSpeed(bool active) {
    final session = widget.session;
    if (active) {
      if (!_controller.value.isPlaying) return;
      session.speedBeforeLongPress = _controller.value.playbackSpeed;
      _controller.setPlaybackSpeed(2.0);
      setState(() => _longPressBoost = true);
    } else {
      if (!_longPressBoost) return;
      _controller.setPlaybackSpeed(session.speedBeforeLongPress);
      setState(() => _longPressBoost = false);
    }
  }

  void _toggleMute() {
    final session = widget.session;
    final value = _controller.value;
    if (value.volume > 0) {
      session.volumeBeforeMute = value.volume;
      _controller.setVolume(0);
    } else {
      _controller.setVolume(
          session.volumeBeforeMute > 0 ? session.volumeBeforeMute : 1.0);
    }
    _showControls();
  }

  void _setPlayerVolume(double volume) {
    final clamped = volume.clamp(0.0, 1.0);
    if (clamped > 0) widget.session.volumeBeforeMute = clamped;
    _controller.setVolume(clamped);
  }

  /// 桌面端:悬停滚轮调音量(播放器级)+ HUD 反馈。
  void _handleScrollVolume(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final delta = event.scrollDelta.dy > 0 ? -0.05 : 0.05;
    final volume =
        (_controller.value.volume + delta).clamp(0.0, 1.0).toDouble();
    _setPlayerVolume(volume);
    setState(() {
      _hudIsVolume = true;
      _hudValue = volume;
      _hudVisible = true;
    });
    _hudHideTimer?.cancel();
    _hudHideTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _hudVisible = false);
    });
  }

  /// 桌面端:静音钮/滑条区悬停展开,移出延迟收起(留出移动到滑条的空隙)。
  void _setVolumeHover(bool hovering) {
    _volumeCollapseTimer?.cancel();
    if (hovering) {
      if (!_volumeExpanded) setState(() => _volumeExpanded = true);
    } else {
      _volumeCollapseTimer = Timer(const Duration(milliseconds: 350), () {
        if (mounted) setState(() => _volumeExpanded = false);
      });
    }
  }

  Future<void> _pickSpeed(BuildContext anchorContext) async {
    _hideTimer?.cancel(); // 菜单开着不隐藏
    final speed = await showPlaybackSpeedMenu(
      anchorContext,
      current: _controller.value.playbackSpeed,
      darkOverlay: true,
    );
    if (speed != null) {
      await _controller.setPlaybackSpeed(speed);
    }
    if (mounted) _showControls();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: _controller,
      builder: (context, value, _) {
        // play↔pause 图标形变跟随真实播放态
        if (value.isPlaying &&
            _playPauseIcon.status != AnimationStatus.forward &&
            _playPauseIcon.value != 1) {
          _playPauseIcon.forward();
        } else if (!value.isPlaying &&
            _playPauseIcon.status != AnimationStatus.reverse &&
            _playPauseIcon.value != 0) {
          _playPauseIcon.reverse();
        }
        _syncStablyPaused(value.isPlaying);

        final showLoading = !value.isInitialized ||
            (value.isBuffering && value.isPlaying);

        // 全屏锁定态:整层只剩「单击唤锁钮 + 解锁钮 + 迷你进度条」
        if (_locked) {
          return Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _onLockedTap,
              ),
              _buildLockButton(),
              _buildMiniProgress(value, visible: true),
            ],
          );
        }

        Widget overlay = Stack(
          fit: StackFit.expand,
          children: [
            // 手势层(最底,吃单击/双击/长按/横滑/竖滑)
            MediaGestureLayer(
              onToggleControls: _toggleControls,
              onTogglePlay: _togglePlay,
              onLongPressSpeedChanged: _onLongPressSpeed,
              onDesktopDoubleTapFullscreen: widget.onFullscreenToggle,
              enableVerticalGestures: widget.isFullscreen,
              positionProvider: () => _controller.value.position,
              durationProvider: () => _controller.value.duration,
              onSeekPreview: (target, {required forward, required cancelArmed}) {
                if (!mounted) return;
                setState(() {
                  _seekPreviewTarget = target;
                  _seekPreviewForward = forward;
                  _seekPreviewCancelArmed = cancelArmed;
                });
              },
              onSeekCommit: (target) {
                widget.session.resumedPosition = null;
                _controller.seekTo(target);
              },
              onVerticalAdjust: (isVolume, v, visible) {
                if (!mounted) return;
                _hudHideTimer?.cancel();
                setState(() {
                  _hudIsVolume = isVolume;
                  _hudValue = v;
                  _hudVisible = visible;
                });
              },
            ),
            // 中央播放大按钮:只在「稳定暂停」时作为「可播放」召唤物
            // 出现(seek 期间后端瞬时回报 isPlaying=false,直接跟随会
            // 闪现一帧);播放中画面保持完全干净
            if (!showLoading && _stablyPaused && !value.isPlaying)
              _CenterPlayButton(
                isCompleted: value.isCompleted,
                expressive: M3eFlags.of(context).enabled,
                onTap: _togglePlay,
              ),
            // 竖滑/滚轮 HUD
            VolumeBrightnessIndicator(
              visible: _hudVisible,
              isVolume: _hudIsVolume,
              value: _hudValue,
            ),
            // 横滑 seek 预览:上部中央「→ 目标 / 总长」胶囊;
            // 拖入顶部取消区变为「松开取消」
            if (_seekPreviewTarget != null)
              Align(
                alignment: const Alignment(0, -0.5),
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: MediaOverlayStyle.pill(radius: 10),
                    child: _seekPreviewCancelArmed
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.close_rounded,
                                  color: MediaOverlayStyle.foreground,
                                  size: 18),
                              const SizedBox(width: 8),
                              Text(
                                S.current.mediaPlayer_releaseToCancel,
                                style: const TextStyle(
                                  color: MediaOverlayStyle.foreground,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _seekPreviewForward
                                    ? Icons.fast_forward_rounded
                                    : Icons.fast_rewind_rounded,
                                color: MediaOverlayStyle.foreground,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Text.rich(
                                TextSpan(
                                  text: _fmt(_seekPreviewTarget!),
                                  style: const TextStyle(
                                    color: MediaOverlayStyle.foreground,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    fontFeatures: [
                                      FontFeature.tabularFigures()
                                    ],
                                  ),
                                  children: [
                                    TextSpan(
                                      text:
                                          ' / ${_fmt(_controller.value.duration)}',
                                      style: const TextStyle(
                                        color: MediaOverlayStyle
                                            .foregroundDim,
                                        fontWeight: FontWeight.w400,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            // 长按 2x 角标
            _FastForwardBadge(
              visible: _longPressBoost,
              top: widget.isFullscreen ? 48 : 8,
            ),
            // 续播提示胶囊(左下,控制条上方,播放器内替代全局 toast)
            if (_resumedHint != null)
              Positioned(
                left: 12,
                bottom: widget.isFullscreen ? 96 : 72,
                child: IgnorePointer(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    builder: (context, t, child) => Opacity(
                      opacity: t,
                      child: Transform.translate(
                        offset: Offset(0, 8 * (1 - t)),
                        child: child,
                      ),
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: MediaOverlayStyle.pill(radius: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.history_rounded,
                              color: Colors.white70, size: 15),
                          const SizedBox(width: 6),
                          Text(
                            S.current
                                .mediaPlayer_resumedFrom(_fmt(_resumedHint!)),
                            style: const TextStyle(
                              color: MediaOverlayStyle.foreground,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            // 加载中指示(圆底衬,初始化后 buffering 也显示)。
            // LoadingSpinner 自适应 M3E 开关,与帖内其他加载态同款,
            // 避免同一次加载先后出现两种风格的指示器
            if (showLoading)
              IgnorePointer(
                child: Center(
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                      color: Color(0x66000000),
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(12),
                    child: const LoadingSpinner(
                      size: 28,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            // 顶部控制条(下沉入场)
            if (widget.isFullscreen)
              _SlidingBar(
                visible: _controlsVisible,
                alignment: Alignment.topCenter,
                child: _buildTopBar(),
              ),
            // 底部控制条(上浮入场)
            _SlidingBar(
              visible: _controlsVisible,
              alignment: Alignment.bottomCenter,
              child: _buildBottomBar(value),
            ),
            // 贴底迷你进度条:控制条隐藏时的常驻进度指示,不可交互
            _buildMiniProgress(value,
                visible: !_controlsVisible && value.isInitialized),
            // 全屏锁定钮(仅移动端全屏;锁定态在上方 early-return 分支)
            if (widget.isFullscreen && !_isDesktop) _buildLockButton(),
          ],
        );
        // 桌面端:控制条纯悬停驱动(移动显示/静止 3s 隐藏/移出即隐藏);
        // 滚轮调音量只在全屏挂 —— inline 挂上会劫持列表滚动:
        // onPointerSignal 不参与手势仲裁,光标恰好停在正文视频上滚页面
        // 时音量会被一并改掉
        if (_isDesktop) {
          Widget wrapped = MouseRegion(
            onHover: (_) => _showControls(),
            onExit: (_) => _hideOnExit(),
            child: overlay,
          );
          if (widget.isFullscreen) {
            wrapped = Listener(
              onPointerSignal: _handleScrollVolume,
              child: wrapped,
            );
          }
          overlay = wrapped;
        }
        return overlay;
      },
    );
  }

  /// 贴底迷你进度条:控制条隐藏时保留 3px 细进度线(含缓冲段),
  /// 不可交互 —— 播放中扫一眼即知进度,不必唤出控制条。
  Widget _buildMiniProgress(VideoPlayerValue value,
      {required bool visible}) {
    final totalMs = value.duration.inMilliseconds;
    return Align(
      alignment: Alignment.bottomCenter,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: MediaOverlayStyle.barDuration,
          child: SizedBox(
            height: 3,
            width: double.infinity,
            child: totalMs <= 0
                ? const SizedBox.shrink()
                : Stack(
                    children: [
                      const ColoredBox(color: Color(0x33FFFFFF)),
                      for (final range in value.buffered)
                        FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: (range.end.inMilliseconds / totalMs)
                              .clamp(0.0, 1.0),
                          child: const ColoredBox(color: Color(0x4DFFFFFF)),
                        ),
                      FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor:
                            (value.position.inMilliseconds / totalMs)
                                .clamp(0.0, 1.0),
                        child: const ColoredBox(color: Color(0xCCFFFFFF)),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  /// 全屏锁定/解锁钮:左缘垂直居中的圆钮。
  /// SafeArea 必须:横屏全屏时左缘正是刘海/挖孔区(异形屏),
  /// 不避让会被摄像头岛遮住或不可点。
  Widget _buildLockButton() {
    final visible = _locked ? _lockButtonVisible : _controlsVisible;
    return SafeArea(
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 16),
          child: IgnorePointer(
            ignoring: !visible,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: MediaOverlayStyle.barDuration,
              child: Material(
                color: const Color(0x8A000000),
                shape: const CircleBorder(
                  side: BorderSide(color: Color(0x24FFFFFF)),
                ),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _toggleLock,
                  child: Padding(
                    padding: const EdgeInsets.all(11),
                    child: Icon(
                      _locked
                          ? Icons.lock_rounded
                          : Icons.lock_open_rounded,
                      color: MediaOverlayStyle.foreground,
                      size: 22,
                      semanticLabel: _locked
                          ? S.current.mediaPlayer_unlockControls
                          : S.current.mediaPlayer_lockControls,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      decoration:
          const BoxDecoration(gradient: MediaOverlayStyle.topScrim),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              color: MediaOverlayStyle.foreground,
              tooltip: S.current.mediaPlayer_exitFullscreen,
              onPressed: widget.onFullscreenToggle,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(VideoPlayerValue value) {
    return Container(
      decoration:
          const BoxDecoration(gradient: MediaOverlayStyle.bottomScrim),
      // SafeArea 只在全屏需要(inline 在正文流里,底部 inset 与它无关,
      // 包上反而平白垫高控制条)
      child: widget.isFullscreen
          ? SafeArea(top: false, child: _buildFullscreenBar(value))
          : _buildInlineBar(value),
    );
  }

  /// inline 单行紧凑条(高 36):[▶] 00:41 ──进度── 02:31 (倍速|音量) [⛶]
  /// 倍速/音量只在桌面 inline 摆(移动端窄,倍速走全屏或长按)。
  Widget _buildInlineBar(VideoPlayerValue value) {
    return SizedBox(
      height: 36,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: [
            _CompactIconButton(
              icon: value.isCompleted && !value.isPlaying
                  ? const Icon(Icons.replay_rounded)
                  : AnimatedIcon(
                      icon: AnimatedIcons.play_pause,
                      progress: _playPauseIcon,
                    ),
              size: 22,
              tooltip: value.isPlaying
                  ? S.current.mediaPlayer_pause
                  : S.current.mediaPlayer_play,
              onTap: _togglePlay,
            ),
            const SizedBox(width: 4),
            Text(
              _fmt(value.position),
              style: const TextStyle(
                color: MediaOverlayStyle.foreground,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: _buildProgressBar(value)),
            const SizedBox(width: 8),
            Text(
              _fmt(value.duration),
              style: const TextStyle(
                color: MediaOverlayStyle.foregroundDim,
                fontSize: 11.5,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            if (_isDesktop) ...[
              _buildSpeedButton(value),
              _buildMuteAndVolume(value),
            ],
            const SizedBox(width: 4),
            _CompactIconButton(
              icon: const Icon(Icons.fullscreen_rounded),
              size: 22,
              tooltip: S.current.mediaPlayer_fullscreen,
              onTap: widget.onFullscreenToggle,
            ),
          ],
        ),
      ),
    );
  }

  /// 全屏两行(B 站全屏样式):独立进度行 + 按钮行。
  Widget _buildFullscreenBar(VideoPlayerValue value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: _buildProgressBar(value),
          ),
          Row(
            children: [
              _buildPlayButton(value, iconSize: 26),
              // 当前时间强、总时长弱,信息分层
              Text.rich(
                TextSpan(
                  text: _fmt(value.position),
                  style: const TextStyle(
                    color: MediaOverlayStyle.foreground,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                  children: [
                    TextSpan(
                      text: '  /  ${_fmt(value.duration)}',
                      style: const TextStyle(
                        color: MediaOverlayStyle.foregroundDim,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              _buildSpeedButton(value),
              _buildMuteAndVolume(value),
              _buildFullscreenButton(iconSize: 24),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar(VideoPlayerValue value) {
    return MediaProgressBar(
      value: value,
      // 控制条隐藏时禁用悬停预览,并让进度条清掉悬停残留
      // (IgnorePointer 下 onExit 不会派发,否则气泡卡死)
      hoverPreviewEnabled: _controlsVisible,
      // M3E 开启时进度条走 Expressive 媒体形态(波浪已播段+竖条把手)
      expressive: M3eFlags.of(context).enabled,
      onSeek: (target) {
        // 手动 seek 视为用户已知位置,静默消费续播提示
        widget.session.resumedPosition = null;
        _controller.seekTo(target);
      },
      onDragActive: (active) {
        _draggingProgress = active;
        if (active) {
          _hideTimer?.cancel();
        } else {
          _scheduleHide();
        }
      },
    );
  }

  Widget _buildPlayButton(VideoPlayerValue value,
      {required double iconSize}) {
    return IconButton(
      icon: value.isCompleted && !value.isPlaying
          ? const Icon(Icons.replay_rounded)
          : AnimatedIcon(
              icon: AnimatedIcons.play_pause,
              progress: _playPauseIcon,
            ),
      color: MediaOverlayStyle.foreground,
      iconSize: iconSize,
      visualDensity: VisualDensity.compact,
      tooltip: value.isPlaying
          ? S.current.mediaPlayer_pause
          : S.current.mediaPlayer_play,
      onPressed: _togglePlay,
    );
  }

  Widget _buildSpeedButton(VideoPlayerValue value) {
    return Builder(
      builder: (buttonContext) => TextButton(
        onPressed: () => _pickSpeed(buttonContext),
        style: TextButton.styleFrom(
          minimumSize: const Size(40, 32),
          padding: const EdgeInsets.symmetric(horizontal: 6),
        ),
        child: Text(
          formatPlaybackSpeed(value.playbackSpeed),
          style: TextStyle(
            color: value.playbackSpeed == 1.0
                ? MediaOverlayStyle.foreground
                : MediaOverlayStyle.accent,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildMuteAndVolume(VideoPlayerValue value) {
    return MouseRegion(
      onEnter: _isDesktop ? (_) => _setVolumeHover(true) : null,
      onExit: _isDesktop ? (_) => _setVolumeHover(false) : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              value.volume > 0
                  ? Icons.volume_up_rounded
                  : Icons.volume_off_rounded,
            ),
            color: MediaOverlayStyle.foreground,
            iconSize: 22,
            visualDensity: VisualDensity.compact,
            tooltip: value.volume > 0
                ? S.current.mediaPlayer_mute
                : S.current.mediaPlayer_unmute,
            onPressed: _toggleMute,
          ),
          if (_isDesktop)
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: _volumeExpanded ? 84 : 0,
                child: _volumeExpanded
                    // 自绘音量条:不用 Material Slider —— 全局 M3E
                    // year2023 新滑块(粗轨+竖条把手)会无视这里的
                    // SliderTheme 覆盖,黑底控制条上是一根粗白棒;
                    // 自绘与进度条同一视觉语言
                    ? Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _MiniVolumeSlider(
                          value: value.volume.clamp(0.0, 1.0),
                          onChanged: _setPlayerVolume,
                        ),
                      )
                    : null,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFullscreenButton({required double iconSize}) {
    return IconButton(
      icon: Icon(
        widget.isFullscreen
            ? Icons.fullscreen_exit_rounded
            : Icons.fullscreen_rounded,
      ),
      color: MediaOverlayStyle.foreground,
      iconSize: iconSize,
      visualDensity: VisualDensity.compact,
      tooltip: widget.isFullscreen
          ? S.current.mediaPlayer_exitFullscreen
          : S.current.mediaPlayer_fullscreen,
      onPressed: widget.onFullscreenToggle,
    );
  }
}

/// 控制条容器:滑入 + 淡入出入场(顶栏下沉、底栏上浮)。
class _SlidingBar extends StatelessWidget {
  const _SlidingBar({
    required this.visible,
    required this.alignment,
    required this.child,
  });

  final bool visible;
  final Alignment alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final fromTop = alignment == Alignment.topCenter;
    return Align(
      alignment: alignment,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedSlide(
          offset: visible
              ? Offset.zero
              : Offset(0, fromTop ? -0.3 : 0.3),
          duration: MediaOverlayStyle.barDuration,
          curve: MediaOverlayStyle.barCurve,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: MediaOverlayStyle.barDuration,
            curve: Curves.easeOut,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 紧凑图标钮:36×36 触达面积(IconButton 默认 48dp 最小约束会把
/// inline 单行条撑高)。
class _CompactIconButton extends StatelessWidget {
  const _CompactIconButton({
    required this.icon,
    required this.onTap,
    this.size = 22,
    this.tooltip,
  });

  final Widget icon;
  final VoidCallback onTap;
  final double size;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    Widget button = InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: SizedBox(
        width: 36,
        height: 36,
        child: IconTheme(
          data: IconThemeData(
            color: MediaOverlayStyle.foreground,
            size: size,
          ),
          child: Center(child: icon),
        ),
      ),
    );
    if (tooltip != null) {
      button = Tooltip(message: tooltip!, child: button);
    }
    return button;
  }
}

/// 中央播放大按钮:出入场缩放 + 按压反馈。
/// 仅在暂停/播完时挂载(播放中不遮挡画面)。
///
/// 形态两档:
/// - expressive(M3E):圆角方钮,按压时圆角收紧 + 缩放 —— M3
///   Expressive 媒体控件的 shape-morph 签名;
/// - 经典:圆形 scrim 钮。
class _CenterPlayButton extends StatefulWidget {
  const _CenterPlayButton({
    required this.isCompleted,
    required this.onTap,
    this.expressive = false,
  });

  final bool isCompleted;
  final VoidCallback onTap;
  final bool expressive;

  @override
  State<_CenterPlayButton> createState() => _CenterPlayButtonState();
}

class _CenterPlayButtonState extends State<_CenterPlayButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    // M3E:56dp 圆角方(radius 18↔12 按压形变);经典:64dp 圆
    final expressive = widget.expressive;
    final radius = expressive ? (_pressed ? 12.0 : 18.0) : 32.0;
    final side = expressive ? 56.0 : 64.0;
    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: MediaOverlayStyle.barDuration,
        curve: MediaOverlayStyle.barCurve,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.scale(scale: 0.8 + 0.2 * t, child: child),
        ),
        child: AnimatedScale(
          scale: _pressed ? 0.88 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: GestureDetector(
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) {
              setState(() => _pressed = false);
              widget.onTap();
            },
            onTapCancel: () => setState(() => _pressed = false),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOutCubic,
              width: side,
              height: side,
              decoration: BoxDecoration(
                color: const Color(0x8A000000),
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: const Color(0x24FFFFFF)),
              ),
              child: Icon(
                widget.isCompleted
                    ? Icons.replay_rounded
                    : Icons.play_arrow_rounded,
                color: MediaOverlayStyle.foreground,
                size: expressive ? 32 : 36,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 桌面控制条内嵌迷你音量条:自绘轨道+把手(悬停/拖动变粗放大),
/// 视觉与 MediaProgressBar 同一语言。
class _MiniVolumeSlider extends StatefulWidget {
  const _MiniVolumeSlider({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_MiniVolumeSlider> createState() => _MiniVolumeSliderState();
}

class _MiniVolumeSliderState extends State<_MiniVolumeSlider> {
  bool _active = false;

  void _setFromDx(double dx, double width) {
    widget.onChanged((dx / width).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _active = true),
          onExit: (_) => setState(() => _active = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _setFromDx(d.localPosition.dx, width),
            onHorizontalDragStart: (d) =>
                _setFromDx(d.localPosition.dx, width),
            onHorizontalDragUpdate: (d) =>
                _setFromDx(d.localPosition.dx, width),
            child: SizedBox(
              height: 28,
              child: CustomPaint(
                size: Size(width, 28),
                painter: _MiniSliderPainter(
                  fraction: widget.value,
                  active: _active,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MiniSliderPainter extends CustomPainter {
  const _MiniSliderPainter({required this.fraction, required this.active});

  final double fraction;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final trackHeight = active ? 4.0 : 3.0;
    final centerY = size.height / 2;
    final radius = Radius.circular(trackHeight / 2);
    final paint = Paint();

    RRect track(double start, double end) => RRect.fromLTRBR(
          size.width * start,
          centerY - trackHeight / 2,
          size.width * end,
          centerY + trackHeight / 2,
          radius,
        );

    paint.color = const Color(0x4DFFFFFF);
    canvas.drawRRect(track(0, 1), paint);
    paint.color = Colors.white;
    canvas.drawRRect(track(0, fraction), paint);
    canvas.drawCircle(
      Offset(size.width * fraction, centerY),
      active ? 6.5 : 5,
      paint,
    );
  }

  @override
  bool shouldRepaint(_MiniSliderPainter old) =>
      old.fraction != fraction || old.active != active;
}

/// 长按 2x 角标(带缩放淡入)。
class _FastForwardBadge extends StatelessWidget {
  const _FastForwardBadge({required this.visible, required this.top});

  final bool visible;
  final double top;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: top,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 120),
          child: AnimatedScale(
            scale: visible ? 1 : 0.85,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: MediaOverlayStyle.pill(radius: 14),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '2x ',
                      style: TextStyle(
                        color: MediaOverlayStyle.foreground,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Icon(Icons.fast_forward_rounded,
                        color: MediaOverlayStyle.foreground, size: 16),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
