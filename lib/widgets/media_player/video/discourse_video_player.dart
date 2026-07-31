import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../services/dynamic_content_suspension_service.dart';
import '../../../services/media/playback_position_store.dart';
import '../../../services/navigation/app_route_observer.dart';
import '../../common/anchor_guard_sliver.dart';
import '../controls/media_controls_overlay.dart';
import 'fullscreen_video_page.dart';
import 'video_player_session.dart';

/// 帖内 inline 视频播放器(自绘控制层,六端统一)。
///
/// 控制器所有权在 [VideoPlayerSession](见其文档):本 State 只是租户,
/// initState retain / dispose release。全屏是另一个租户
/// ([FullscreenVideoPage]),宿主被 cacheExtent 回收不连坐。
class DiscourseVideoPlayer extends StatefulWidget {
  const DiscourseVideoPlayer(
    this.url, {
    required this.aspectRatio,
    this.autoResize = true,
    this.autoplay = false,
    this.errorBuilder,
    super.key,
    this.loadingBuilder,
    this.loop = false,
    this.mimeType,
    this.poster,
  });

  /// 视频源 URL
  final String url;

  /// 初始宽高比
  final double aspectRatio;

  /// 是否自动调整尺寸
  final bool autoResize;

  /// 是否自动播放
  final bool autoplay;

  /// 错误回调
  final Widget Function(BuildContext context, String url, dynamic error)?
      errorBuilder;

  /// 加载中回调
  final Widget Function(BuildContext context, String url, Widget child)?
      loadingBuilder;

  /// 是否循环播放
  final bool loop;

  /// HTML `<video>` / `<source>` 声明的 MIME。URL 后缀不可信时
  /// (例如实际是 MP4 却以 `.xz` 结尾)必须优先使用该值。
  final String? mimeType;

  /// 封面
  final Widget? poster;

  @override
  State<DiscourseVideoPlayer> createState() => _DiscourseVideoPlayerState();
}

class _DiscourseVideoPlayerState extends State<DiscourseVideoPlayer>
    with RouteAware {
  VideoPlayerSession? _session;
  Object? _error;

  /// 展示用宽高比:构建期 = 记忆值 ?? widget.aspectRatio;autoResize
  /// 时初始化完成后在安全时机(静止帧,武装锚定哨兵)更新为实测值
  late double _displayAspectRatio;

  /// 等待滚停再展开真实比例的一次性监听(见 [_maybeApplyRealAspectRatio])
  ValueListenable<bool>? _scrollIdleNotifier;
  VoidCallback? _scrollIdleListener;

  /// 上层路由(对话框/BottomSheet)弹出时自动暂停视频,
  /// 避免 BackdropFilter 对视频纹理每帧重做高斯模糊造成卡顿。
  /// 只有在被我们主动暂停时才在路由返回后恢复播放。
  bool _pausedByRouteOverlay = false;
  bool _pausedByDynamicSuspension = false;

  VideoPlayerController? get _controller => _session?.controller;

  @override
  void initState() {
    super.initState();
    DynamicContentSuspensionService.instance.addListener(
      _handleDynamicContentSuspension,
    );
    _displayAspectRatio = widget.autoResize
        ? (VideoSessionRegistry.knownAspectRatios[widget.url] ??
            widget.aspectRatio)
        : widget.aspectRatio;
    unawaited(_initSession());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    // 全屏路由是自己人(同一 session 的另一个租户),不算「上层弹窗」
    if (_session?.isFullscreen ?? false) return;
    // 上层 push 了对话框/BottomSheet:暂停播放以省掉 BackdropFilter 的代价
    final controller = _controller;
    if (controller != null && controller.value.isPlaying) {
      controller.pause();
      _pausedByRouteOverlay = true;
    }
  }

  @override
  void didPopNext() {
    if (!_pausedByRouteOverlay) return;
    _pausedByRouteOverlay = false;
    if (!_pausedByDynamicSuspension) _controller?.play();
  }

  void _handleDynamicContentSuspension() {
    final suspended = DynamicContentSuspensionService.instance.suspended;
    final controller = _controller;
    if (suspended) {
      if (controller != null && controller.value.isPlaying) {
        _pausedByDynamicSuspension = true;
        controller.pause();
      }
    } else if (_pausedByDynamicSuspension) {
      _pausedByDynamicSuspension = false;
      if (!_pausedByRouteOverlay) controller?.play();
    }
  }

  @override
  void dispose() {
    DynamicContentSuspensionService.instance.removeListener(
      _handleDynamicContentSuspension,
    );
    appRouteObserver.unsubscribe(this);
    if (_scrollIdleListener != null) {
      _scrollIdleNotifier?.removeListener(_scrollIdleListener!);
      _scrollIdleListener = null;
      _scrollIdleNotifier = null;
    }
    _session?.controller.removeListener(_onSessionTick);
    _session?.fullscreenNotifier.removeListener(_onFullscreenChanged);
    _session?.release();
    _session = null;
    super.dispose();
  }

  Future<void> _initSession() async {
    final session = VideoSessionRegistry.obtain(
      widget.url,
      mimeType: widget.mimeType,
    );
    session.retain();
    _session = session;
    session.controller.addListener(_onSessionTick);
    session.fullscreenNotifier.addListener(_onFullscreenChanged);

    if (session.isInitialized) {
      // 命中现存 session(滚出滚回/全屏期间重建):直接可用
      if (mounted) setState(() {});
      _maybeApplyRealAspectRatio();
      return;
    }

    try {
      await session.controller
          .initialize()
          .timeout(const Duration(seconds: 15));
      await session.controller.setLooping(widget.loop);
      // 位置记忆:初始化完成即静默 seek,封面帧直接停在续播点;
      // 「已从 xx:xx 继续播放」提示留给用户首次点播放时(控制层)
      final resumed =
          await PlaybackPositionStore.instance.restore(widget.url);
      if (resumed != null) {
        session.resumedPosition = resumed;
        await session.controller.seekTo(resumed);
      }
      if (widget.autoplay) {
        unawaited(session.controller.play());
      }
    } catch (error) {
      // 平台差异排查的关键线索:AVFoundation(iOS/macOS)对签名 URL、
      // Content-Type、容器细节远比 ExoPlayer/mpv 挑剔,失败原因只在这里可见
      debugPrint(
        '[Video] 初始化失败 url=${widget.url} '
        'mime=${widget.mimeType} error=$error',
      );
      if (mounted) setState(() => _error = error);
      return;
    }

    if (!mounted) return;
    setState(() {});
    _maybeApplyRealAspectRatio();
  }

  /// inline build 实际消费的 controller 状态指纹。播放中 controller 每
  /// ~500ms tick 一次(position 变化),但 inline 结构只依赖这几个字段
  /// (进度/时长归控制条自己的 ValueListenableBuilder 管)—— 指纹不变
  /// 就跳过 setState,滚动路径上不为无关 tick 重建整棵播放器子树。
  int _buildFingerprint() {
    final value = _session?.controller.value;
    if (value == null) return 0;
    final posterVisible =
        !value.isPlaying && value.position == Duration.zero;
    return Object.hash(value.isInitialized, value.isPlaying, posterVisible,
        value.aspectRatio);
  }

  int _lastFingerprint = 0;

  /// controller 状态驱动的重建(session 可能被其他租户操作,如全屏页
  /// 改播放态,inline 的封面/占位判断要跟上)。带指纹短路。
  void _onSessionTick() {
    if (!mounted) return;
    final fingerprint = _buildFingerprint();
    if (fingerprint == _lastFingerprint) return;
    _lastFingerprint = fingerprint;
    setState(() {});
  }

  /// 全屏进/出各重建一次(Texture ↔ 占位切换)。暂停态没有 controller
  /// tick,必须显式监听,否则退出全屏后 inline 卡在占位。
  void _onFullscreenChanged() {
    if (mounted) setState(() {});
  }

  /// 初始化完成后把展示比例安全地展开为实测比例。
  ///
  /// - 记忆命中(比例差 < 1%):零布局变化,什么都不用做;
  /// - 静止:武装锚定哨兵后立即展开,视口上方视频的高度变化被同帧补偿;
  /// - 滚动中:保持占位比例(视频暂以 letterbox 居中显示,不变形),
  ///   滚停后推迟一帧再展开 —— 与 msgbus 滚停回放同一哲学:滚动中
  ///   不动布局;推迟一帧是因为 isScrollingNotifier 翻 false 与惯性
  ///   末 tick 同帧,当帧 pixels 仍在变,哨兵无法比较基线。
  void _maybeApplyRealAspectRatio() {
    if (!widget.autoResize || !mounted) return;
    final real = _controller?.value.aspectRatio;
    if (real == null || real <= 0) return;
    VideoSessionRegistry.knownAspectRatios[widget.url] = real;
    if ((real - _displayAspectRatio).abs() < 0.01) return;

    final position = Scrollable.maybeOf(context)?.position;
    final notifier = position?.isScrollingNotifier;
    if (notifier == null || !notifier.value) {
      _applyRealAspectRatio();
      return;
    }

    if (_scrollIdleListener != null) return; // 已在等滚停
    void listener() {
      if (notifier.value) return;
      notifier.removeListener(listener);
      _scrollIdleListener = null;
      _scrollIdleNotifier = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _applyRealAspectRatio();
      });
    }

    _scrollIdleNotifier = notifier;
    _scrollIdleListener = listener;
    notifier.addListener(listener);
  }

  void _applyRealAspectRatio() {
    final real = _controller?.value.aspectRatio;
    if (real == null || real <= 0) return;
    if ((real - _displayAspectRatio).abs() < 0.01) return;
    // 静默布局变化落地:武装哨兵,上方视频的比例展开被同帧补偿
    AnchorGuardSliver.arm();
    setState(() => _displayAspectRatio = real);
  }

  Widget? get _placeholder =>
      widget.poster != null ? Center(child: widget.poster) : null;

  @override
  Widget build(BuildContext context) {
    final session = _session;

    Widget? child;
    if (_error != null) {
      final errorBuilder = widget.errorBuilder;
      if (errorBuilder != null) {
        child = errorBuilder(context, widget.url, _error);
      }
    } else if (session != null && session.isInitialized) {
      if (session.isFullscreen) {
        // 全屏路由在场:inline 不画 Texture(单附着最稳),只留封面/黑底
        child = ColoredBox(
          color: Colors.black,
          child: _placeholder ?? const SizedBox.expand(),
        );
      } else {
        child = Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Colors.black),
            Center(
              child: AspectRatio(
                aspectRatio: session.controller.value.aspectRatio,
                child: VideoPlayer(session.controller),
              ),
            ),
            // 出画前露封面,播放/seek 过即淡出(硬切会闪一帧)
            if (widget.poster != null)
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: (!session.controller.value.isPlaying &&
                          session.controller.value.position ==
                              Duration.zero)
                      ? 1
                      : 0,
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                  child: _placeholder,
                ),
              ),
            MediaControlsOverlay(
              session: session,
              isFullscreen: false,
              onFullscreenToggle: () {
                unawaited(FullscreenVideoPage.open(context, session));
              },
            ),
          ],
        );
      }
    } else {
      child = _placeholder;

      final loadingBuilder = widget.loadingBuilder;
      if (loadingBuilder != null) {
        child = loadingBuilder(
          context,
          widget.url,
          child ?? const SizedBox.shrink(),
        );
      }
    }

    // 展示比例由 [_displayAspectRatio] 统一供给:初始 = 记忆值/占位值,
    // 真实比例的展开时机由 [_maybeApplyRealAspectRatio] 治理(静止帧 +
    // 武装哨兵),不在 build 里直接追 controller 的实测值 —— 那会让
    // 初始化完成瞬间高度突变,滚动路径上方的视频把内容拉断。
    return AspectRatio(aspectRatio: _displayAspectRatio, child: child);
  }
}
