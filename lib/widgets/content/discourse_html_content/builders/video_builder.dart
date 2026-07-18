import 'dart:async';
import 'dart:convert';

import 'package:chewie/chewie.dart' as lib;
import 'package:flutter/foundation.dart'
    show TargetPlatform, ValueListenable, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:video_player/video_player.dart' as lib;
import 'package:window_manager/window_manager.dart';

import '../../../../providers/preferences_provider.dart';
import '../../../../services/embedded_browser_controller_pool.dart';
import '../../../../services/dynamic_content_suspension_service.dart';
import '../../../../services/navigation/app_route_observer.dart';
import '../../../../services/webview_settings.dart';
import '../../../../services/windows_webview_environment_service.dart';
import '../../../../utils/layout_lock.dart';
import '../../../../utils/platform_utils.dart';
import '../../../common/anchor_guard_sliver.dart';

/// 自定义视频播放器，基于 fwfh_chewie 的 VideoPlayer，
/// 增加全屏时 LayoutLock 保护，防止横屏导致底层页面重新布局。
class DiscourseVideoPlayer extends StatefulWidget {
  /// 视频源 URL
  final String url;

  /// 初始宽高比
  final double aspectRatio;

  /// 是否自动调整尺寸
  final bool autoResize;

  /// 是否自动播放
  final bool autoplay;

  /// 是否显示控制条
  final bool controls;

  /// 错误回调
  final Widget Function(BuildContext context, String url, dynamic error)?
  errorBuilder;

  /// 加载中回调
  final Widget Function(BuildContext context, String url, Widget child)?
  loadingBuilder;

  /// 是否循环播放
  final bool loop;

  /// 封面
  final Widget? poster;

  /// HTML `<video>` / `<source>` 声明的 MIME。URL 后缀不可信时
  /// （例如实际是 MP4 却以 `.xz` 结尾）必须优先使用该值。
  final String? mimeType;

  /// 封面 URL，Windows 浏览器视频后端直接写入 poster 属性。
  final String? posterUrl;

  const DiscourseVideoPlayer(
    this.url, {
    required this.aspectRatio,
    this.autoResize = true,
    this.autoplay = false,
    this.controls = false,
    this.errorBuilder,
    super.key,
    this.loadingBuilder,
    this.loop = false,
    this.mimeType,
    this.poster,
    this.posterUrl,
  });

  @override
  State<DiscourseVideoPlayer> createState() => _DiscourseVideoPlayerState();
}

class _DiscourseVideoPlayerState extends State<DiscourseVideoPlayer>
    with
        WidgetsBindingObserver,
        WindowListener,
        RouteAware,
        AutomaticKeepAliveClientMixin {
  lib.ChewieController? _controller;
  dynamic _error;
  lib.VideoPlayerController? _vpc;
  bool _didLockLayout = false;

  /// 视频真实宽高比缓存(url → 实测比例)。HTML 无尺寸的视频占位只能猜
  /// 16:9,初始化完成才知道真实比例;帖子滚出 cacheExtent 被销毁、滚
  /// 回来重建时若没有这份记忆,每次路过都会"占位比 → 真实比"跳一次,
  /// 布局高度突变把滚动拉断(视口上方的视频尤甚)。有记忆后重建直接
  /// 以真实比例占位,初始化完成零布局变化。
  static final Map<String, double> _knownAspectRatios = {};

  /// 展示用宽高比:构建期 = 记忆值 ?? widget.aspectRatio;autoResize
  /// 时初始化完成后在安全时机(静止帧,武装锚定哨兵)更新为实测值
  late double _displayAspectRatio;

  /// 等待滚停再展开真实比例的一次性监听(见 [_maybeApplyRealAspectRatio])
  ValueListenable<bool>? _scrollIdleNotifier;
  VoidCallback? _scrollIdleListener;

  /// 上层路由（对话框/BottomSheet）弹出时自动暂停视频，
  /// 避免 BackdropFilter 对视频纹理每帧重做高斯模糊造成卡顿。
  /// 只有在被我们主动暂停时才在路由返回后恢复播放。
  bool _pausedByRouteOverlay = false;
  bool _pausedByDynamicSuspension = false;

  /// 退出全屏时，标记等待屏幕尺寸恢复后再释放 LayoutLock。
  /// 移动端：等 chewie 恢复屏幕方向后尺寸变化回调触发；
  /// 桌面端：等 onWindowLeaveFullScreen 回调触发。
  bool _pendingLockRelease = false;

  static final bool _isDesktop = PlatformUtils.isDesktop;
  static final bool _useWindowsBrowserBackend =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// 全屏期间(含退出全屏的恢复窗口)钉住列表项,防止 macOS 进/出系统
  /// 全屏引发的窗口尺寸连环变化把本项挤出 cacheExtent 而被回收——
  /// 宿主一死,embedded ChewieState 连带 PlayerNotifier 就地销毁,
  /// 全屏路由的控制条还在引用它们,即"used after disposed"崩溃。
  @override
  bool get wantKeepAlive => _didLockLayout || _pendingLockRelease;

  /// 全屏期间缓存控制器与 Chewie 子树的 GlobalKey，防止窗口/屏幕尺寸
  /// 变化导致 widget 重建时销毁 chewie 全屏路由正在使用的控制器。
  /// GlobalKey 让重建后的宿主同帧收养旧 Chewie 子树：ChewieState 及其
  /// PlayerNotifier 不销毁 —— 全屏路由的控制条引用该 notifier，pop
  /// 全屏路由的控制权也在该 ChewieState 手里，二者都死不得。
  static final Map<
      String,
      ({
        lib.VideoPlayerController vpc,
        lib.ChewieController cc,
        GlobalKey chewieKey,
      })> _fullscreenCache = {};

  /// embedded Chewie 的身份键：全屏期间宿主被重建时，新 State 从
  /// [_fullscreenCache] 继承此 key，同帧内原样收养旧 Chewie 子树。
  GlobalKey _chewieKey = GlobalKey(debugLabel: 'DiscourseVideoPlayer.chewie');

  Widget? get placeholder =>
      widget.poster != null ? Center(child: widget.poster) : null;

  @override
  void initState() {
    super.initState();
    DynamicContentSuspensionService.instance.addListener(
      _handleDynamicContentSuspension,
    );
    _displayAspectRatio = widget.autoResize
        ? (_knownAspectRatios[widget.url] ?? widget.aspectRatio)
        : widget.aspectRatio;
    if (_useWindowsBrowserBackend) return;
    WidgetsBinding.instance.addObserver(this);
    if (_isDesktop) {
      windowManager.addListener(this);
    }
    _initControllers();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_useWindowsBrowserBackend) return;
    final route = ModalRoute.of(context);
    if (route != null) {
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    // 上层 push 了对话框/BottomSheet：暂停播放以省掉 BackdropFilter 的代价
    final vpc = _vpc;
    if (vpc != null && vpc.value.isPlaying) {
      vpc.pause();
      _pausedByRouteOverlay = true;
    }
  }

  @override
  void didPopNext() {
    if (!_pausedByRouteOverlay) return;
    _pausedByRouteOverlay = false;
    if (!_pausedByDynamicSuspension) _vpc?.play();
  }

  void _handleDynamicContentSuspension() {
    if (_useWindowsBrowserBackend) return;
    final suspended = DynamicContentSuspensionService.instance.suspended;
    final vpc = _vpc;
    if (suspended) {
      if (vpc != null && vpc.value.isPlaying) {
        _pausedByDynamicSuspension = true;
        vpc.pause();
      }
    } else if (_pausedByDynamicSuspension) {
      _pausedByDynamicSuspension = false;
      if (!_pausedByRouteOverlay) vpc?.play();
    }
  }

  @override
  void dispose() {
    DynamicContentSuspensionService.instance.removeListener(
      _handleDynamicContentSuspension,
    );
    if (_useWindowsBrowserBackend) {
      super.dispose();
      return;
    }
    appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    if (_scrollIdleListener != null) {
      _scrollIdleNotifier?.removeListener(_scrollIdleListener!);
      _scrollIdleListener = null;
      _scrollIdleNotifier = null;
    }
    if (_isDesktop) {
      windowManager.removeListener(this);
    }
    _controller?.removeListener(_onControllerChanged);
    // 释放 LayoutLock（含等待恢复的延迟释放）
    if (_didLockLayout || _pendingLockRelease) {
      LayoutLock.release();
      _didLockLayout = false;
      _pendingLockRelease = false;
    }
    // 全屏期间，控制器仍被全屏路由使用，跳过销毁
    final cached = _fullscreenCache[widget.url];
    if (cached != null && cached.vpc == _vpc) {
      super.dispose();
      return;
    }
    _vpc?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 要求
    if (_useWindowsBrowserBackend) {
      return BrowserDiscourseVideoPlayer(
        key: ValueKey('${widget.url}|${widget.mimeType ?? ''}'),
        url: widget.url,
        mimeType: widget.mimeType,
        posterUrl: widget.posterUrl,
        poster: widget.poster,
        aspectRatio: _displayAspectRatio,
        autoplay: widget.autoplay,
        loop: widget.loop,
        errorBuilder: widget.errorBuilder,
      );
    }
    // 展示比例由 [_displayAspectRatio] 统一供给:初始 = 记忆值/占位值,
    // 真实比例的展开时机由 [_maybeApplyRealAspectRatio] 治理(静止帧 +
    // 武装哨兵),不在 build 里直接追 controller 的实测值 —— 那会让
    // 初始化完成瞬间高度突变,滚动路径上方的视频把内容拉断。
    final aspectRatio = _displayAspectRatio;

    Widget? child;
    final controller = _controller;
    if (controller != null) {
      child = lib.Chewie(key: _chewieKey, controller: controller);
    } else if (_error != null) {
      final errorBuilder = widget.errorBuilder;
      if (errorBuilder != null) {
        child = errorBuilder(context, widget.url, _error);
      }
    } else {
      child = placeholder;

      final loadingBuilder = widget.loadingBuilder;
      if (loadingBuilder != null) {
        child = loadingBuilder(
          context,
          widget.url,
          child ?? const SizedBox.shrink(),
        );
      }
    }

    return AspectRatio(aspectRatio: aspectRatio, child: child);
  }

  Future<void> _initControllers() async {
    // 桌面全屏期间 widget 被重建时，复用缓存的控制器。
    // 只读不取走：macOS 进全屏动画会连续多次改窗口尺寸，widget 可能
    // 重建不止一轮；若在此 remove，复用方又不会重新入缓存
    // （_onControllerChanged 的入缓存分支被 _didLockLayout 挡住），
    // 第二轮 dispose 查不到缓存就会把全屏路由正在使用的控制器销毁。
    // 缓存条目由退出全屏时的 _onControllerChanged 统一移除。
    final cached = _fullscreenCache[widget.url];
    if (cached != null) {
      _vpc = cached.vpc;
      final controller = cached.cc;
      controller.addListener(_onControllerChanged);
      _controller = controller;
      // 继承 GlobalKey，同帧收养旧 Chewie 子树（ChewieState/PlayerNotifier
      // 不销毁），全屏路由的控制条与 pop 控制权保持有效
      _chewieKey = cached.chewieKey;
      _didLockLayout = true;
      LayoutLock.acquire();
      if (mounted) setState(() {});
      _maybeApplyRealAspectRatio();
      return;
    }

    final vpc = _vpc = lib.VideoPlayerController.networkUrl(
      Uri.parse(widget.url),
      formatHint: videoFormatHintFromMime(widget.mimeType),
    );
    Object? vpcError;
    try {
      await vpc.initialize().timeout(const Duration(seconds: 15));
    } catch (error) {
      vpcError = error;
      // 平台差异排查的关键线索:AVFoundation(iOS/macOS)对签名 URL、
      // Content-Type、容器细节远比 ExoPlayer 挑剔,失败原因只在这里可见
      debugPrint(
        '[Video] 初始化失败 url=${widget.url} '
        'mime=${widget.mimeType} error=$error',
      );
    }

    if (!mounted) {
      return;
    }

    setState(() {
      if (vpcError != null) {
        _error = vpcError;
        return;
      }

      final controller = lib.ChewieController(
        autoPlay: widget.autoplay,
        looping: widget.loop,
        placeholder: placeholder,
        showControls: widget.controls,
        videoPlayerController: vpc,
      );
      // 监听全屏状态变化，控制 LayoutLock
      controller.addListener(_onControllerChanged);
      _controller = controller;
    });
    if (vpcError == null) {
      _maybeApplyRealAspectRatio();
    }
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
    final real = _vpc?.value.aspectRatio;
    if (real == null || real <= 0) return;
    _knownAspectRatios[widget.url] = real;
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
    final real = _vpc?.value.aspectRatio;
    if (real == null || real <= 0) return;
    if ((real - _displayAspectRatio).abs() < 0.01) return;
    // 静默布局变化落地:武装哨兵,上方视频的比例展开被同帧补偿
    AnchorGuardSliver.arm();
    setState(() => _displayAspectRatio = real);
  }

  @override
  void didChangeMetrics() {
    // 移动端退出全屏后，chewie 会恢复屏幕方向，此时屏幕尺寸变化
    // 触发此回调，可以安全释放 LayoutLock
    if (_pendingLockRelease && !_isDesktop) {
      _pendingLockRelease = false;
      updateKeepAlive();
      // 延迟一帧确保 chewie 的全屏路由 pop 动画完成
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_didLockLayout) {
          LayoutLock.release();
          // 恢复竖屏锁定（chewie 退出全屏会重置方向为全部允许）
          PreferencesNotifier.restoreOrientationLock();
        }
      });
    }
  }

  @override
  void onWindowLeaveFullScreen() {
    // 桌面端：窗口退出全屏动画完成，安全释放 LayoutLock
    if (_pendingLockRelease) {
      _pendingLockRelease = false;
      LayoutLock.release();
      updateKeepAlive();
    }
  }

  /// 全屏状态变化时 acquire/release LayoutLock，
  /// 桌面平台同时切换系统级全屏。
  void _onControllerChanged() {
    final isFullScreen = _controller?.isFullScreen ?? false;
    if (isFullScreen && !_didLockLayout) {
      _didLockLayout = true;
      LayoutLock.acquire();
      updateKeepAlive();
      // 缓存控制器，防止屏幕尺寸变化导致 widget 重建时销毁它们
      if (_vpc != null && _controller != null) {
        _fullscreenCache[widget.url] =
            (vpc: _vpc!, cc: _controller!, chewieKey: _chewieKey);
      }
      if (_isDesktop) {
        // 延迟到下一帧，确保 chewie 全屏路由已推入后再触发窗口变化
        WidgetsBinding.instance.addPostFrameCallback((_) {
          windowManager.setFullScreen(true);
        });
      }
    } else if (!isFullScreen && _didLockLayout) {
      _didLockLayout = false;
      // 退出全屏，清除缓存
      _fullscreenCache.remove(widget.url);
      // 不立即释放 LayoutLock，等屏幕尺寸恢复后再释放，
      // 防止恢复期间触发布局切换导致控制器被销毁。
      // 移动端：didChangeMetrics 回调中释放
      // 桌面端：onWindowLeaveFullScreen 回调中释放
      _pendingLockRelease = true;
      if (_isDesktop) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          windowManager.setFullScreen(false);
        });
      }
    }
  }
}

/// 把 HTML 声明的 MIME 转为 video_player 可用的格式提示。
///
/// `video/mp4` / `video/webm` 等普通容器映射为 [lib.VideoFormat.other]，
/// 这会在 Android 上强制走 progressive 媒体路径，不再信任 `.xz`
/// 之类伪装后缀。
@visibleForTesting
lib.VideoFormat? videoFormatHintFromMime(String? mimeType) {
  final mime = mimeType?.split(';').first.trim().toLowerCase();
  if (mime == null || mime.isEmpty) return null;
  if (mime == 'application/dash+xml') return lib.VideoFormat.dash;
  if (mime == 'application/vnd.apple.mpegurl' ||
      mime == 'application/x-mpegurl' ||
      mime == 'audio/mpegurl' ||
      mime == 'audio/x-mpegurl') {
    return lib.VideoFormat.hls;
  }
  if (mime == 'application/vnd.ms-sstr+xml') return lib.VideoFormat.ss;
  if (mime.startsWith('video/') || mime.startsWith('audio/')) {
    return lib.VideoFormat.other;
  }
  return null;
}

/// Windows 上的视频使用 WebView2 `<video>` 播放。
///
/// Flutter 官方 video_player 当前没有 Windows 后端；浏览器又能直接
/// 使用 `<source type="...">` 强制 MIME。为避免浏览帖子时自动创建大量
/// WebView2 Controller，只在用户点击播放后创建，并且全局同时只保留
/// 一个视频 Controller。
class BrowserDiscourseVideoPlayer extends StatefulWidget {
  const BrowserDiscourseVideoPlayer({
    super.key,
    required this.url,
    required this.aspectRatio,
    this.mimeType,
    this.posterUrl,
    this.poster,
    this.autoplay = false,
    this.loop = false,
    this.errorBuilder,
  });

  final String url;
  final String? mimeType;
  final String? posterUrl;
  final Widget? poster;
  final double aspectRatio;
  final bool autoplay;
  final bool loop;
  final Widget Function(BuildContext context, String url, dynamic error)?
  errorBuilder;

  @override
  State<BrowserDiscourseVideoPlayer> createState() =>
      _BrowserDiscourseVideoPlayerState();
}

class _BrowserDiscourseVideoPlayerState
    extends State<BrowserDiscourseVideoPlayer> {
  late final int _sessionId;
  InAppWebViewController? _webViewController;
  Timer? _readyTimeout;
  EmbeddedBrowserLease? _browserLease;
  bool _active = false;
  bool _ready = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    DynamicContentSuspensionService.instance.addListener(
      _handleDynamicContentSuspension,
    );
    _sessionId = _BrowserVideoSessionCoordinator.instance.register(
      _deactivateFromCoordinator,
    );
    if (widget.autoplay) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _activate());
    }
  }

  void _handleDynamicContentSuspension() {
    if (DynamicContentSuspensionService.instance.suspended) {
      _deactivateFromCoordinator();
    }
  }

  void _activate() {
    if (!mounted ||
        _active ||
        DynamicContentSuspensionService.instance.suspended) {
      return;
    }
    _BrowserVideoSessionCoordinator.instance.activate(_sessionId);
    final lease = EmbeddedBrowserControllerPool.instance.tryAcquire(
      priority: EmbeddedBrowserPriority.video,
      onRevoked: _deactivateFromCoordinator,
    );
    if (lease == null) {
      setState(() => _error = StateError('浏览器播放槽位暂时不可用'));
      return;
    }
    _browserLease = lease;
    setState(() {
      _active = true;
      _ready = false;
      _error = null;
    });
    _readyTimeout?.cancel();
    _readyTimeout = Timer(const Duration(seconds: 20), () {
      if (!mounted || _ready) return;
      setState(() {
        _error = TimeoutException('视频加载超时');
        _stopBrowserController();
      });
    });
  }

  void _deactivateFromCoordinator() {
    if (!mounted || !_active) return;
    _readyTimeout?.cancel();
    _webViewController = null;
    _browserLease?.release();
    _browserLease = null;
    setState(() {
      _active = false;
      _ready = false;
      _error = null;
    });
  }

  void _handleVideoState(List<dynamic> arguments) {
    if (!mounted || arguments.isEmpty) return;
    final state = arguments.first?.toString();
    if (state == 'ready') {
      _readyTimeout?.cancel();
      if (!_ready) setState(() => _ready = true);
      return;
    }
    if (state == 'error') {
      _readyTimeout?.cancel();
      final detail = arguments.length > 1 ? arguments[1] : '未知错误';
      setState(() {
        _error = StateError('浏览器视频错误: $detail');
        _stopBrowserController();
      });
    }
  }

  void _stopBrowserController() {
    _readyTimeout?.cancel();
    _webViewController = null;
    _browserLease?.release();
    _browserLease = null;
    _active = false;
    _ready = false;
  }

  Future<void> _installVideoBridge(InAppWebViewController controller) async {
    try {
      await WebViewSettings.injectScrollFix(controller);
      await controller
          .evaluateJavascript(
            source: r'''
(() => {
  const video = document.querySelector('video');
  if (!video || video.__fluxdoBound) return;
  video.__fluxdoBound = true;
  const send = (state, detail = '') => {
    window.flutter_inappwebview.callHandler('fluxdoVideoState', state, detail);
  };
  const ready = () => send('ready', `${video.videoWidth}x${video.videoHeight}`);
  video.addEventListener('loadedmetadata', ready, {once: true});
  video.addEventListener('canplay', ready, {once: true});
  video.addEventListener('error', () => {
    const error = video.error;
    send('error', error ? `${error.code}:${error.message || ''}` : 'unknown');
  });
  if (video.readyState >= 1) ready();
  video.play().catch(() => {});
})()
''',
          )
          .timeout(const Duration(seconds: 2));
    } catch (error) {
      debugPrint('[BrowserVideo] 安装状态桥失败: $error');
    }
  }

  @override
  void dispose() {
    DynamicContentSuspensionService.instance.removeListener(
      _handleDynamicContentSuspension,
    );
    _readyTimeout?.cancel();
    _browserLease?.release();
    _BrowserVideoSessionCoordinator.instance.unregister(_sessionId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (_error != null) {
      final errorContent =
          widget.errorBuilder?.call(context, widget.url, _error) ??
          _buildVideoError(context, _error!);
      content = Semantics(
        button: true,
        label: '视频播放失败，点击重试',
        child: InkWell(
          onTap: () {
            setState(() => _error = null);
            _activate();
          },
          child: errorContent,
        ),
      );
    } else if (!_active) {
      content = _buildPlayPlaceholder(context);
    } else {
      final webView = InAppWebView(
        webViewEnvironment:
            WindowsWebViewEnvironmentService.instance.environment,
        initialData: InAppWebViewInitialData(
          data: _buildBrowserVideoHtml(
            url: widget.url,
            mimeType: widget.mimeType,
            posterUrl: widget.posterUrl,
            loop: widget.loop,
          ),
          baseUrl: WebUri(widget.url),
          mimeType: 'text/html',
          encoding: 'utf-8',
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          transparentBackground: false,
          supportZoom: false,
          disableContextMenu: true,
          verticalScrollBarEnabled: false,
          horizontalScrollBarEnabled: false,
          disableVerticalScroll: true,
          disableHorizontalScroll: true,
          allowsInlineMediaPlayback: true,
          mediaPlaybackRequiresUserGesture: false,
          cacheEnabled: true,
        ),
        onWebViewCreated: (controller) {
          _webViewController = controller;
          controller.addJavaScriptHandler(
            handlerName: 'fluxdoVideoState',
            callback: _handleVideoState,
          );
        },
        onLoadStop: (controller, _) => _installVideoBridge(controller),
        onReceivedError: (_, request, error) {
          if (request.isForMainFrame == true && mounted) {
            setState(() {
              _error = StateError('视频页面加载失败: ${error.description}');
              _stopBrowserController();
            });
          }
        },
      );
      content = Stack(
        fit: StackFit.expand,
        children: [
          WebViewSettings.wrapWithScrollFix(
            webView,
            getController: () => _webViewController,
          ),
          if (!_ready) _buildLoadingOverlay(),
        ],
      );
    }

    return AspectRatio(aspectRatio: widget.aspectRatio, child: content);
  }

  Widget _buildPlayPlaceholder(BuildContext context) {
    return Material(
      color: Colors.black,
      child: InkWell(
        onTap: _activate,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (widget.poster != null) widget.poster!,
            Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.68),
                  shape: BoxShape.circle,
                ),
                child: const Padding(
                  padding: EdgeInsets.all(14),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 34,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingOverlay() {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.35),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.poster != null) widget.poster!,
          const Center(
            child: SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoError(BuildContext context, Object error) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '视频播放失败\n$error\n\n点击重试',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.white70),
          ),
        ),
      ),
    );
  }
}

class _BrowserVideoSessionCoordinator {
  _BrowserVideoSessionCoordinator._();

  static final instance = _BrowserVideoSessionCoordinator._();

  final Map<int, VoidCallback> _deactivateCallbacks = {};
  int _nextId = 0;
  int? _activeId;

  int register(VoidCallback onDeactivate) {
    final id = ++_nextId;
    _deactivateCallbacks[id] = onDeactivate;
    return id;
  }

  void activate(int id) {
    final previous = _activeId;
    if (previous == id) return;
    _activeId = id;
    if (previous != null) _deactivateCallbacks[previous]?.call();
  }

  void unregister(int id) {
    _deactivateCallbacks.remove(id);
    if (_activeId == id) _activeId = null;
  }
}

String _buildBrowserVideoHtml({
  required String url,
  required String? mimeType,
  required String? posterUrl,
  required bool loop,
}) {
  const escape = HtmlEscape(HtmlEscapeMode.attribute);
  final escapedUrl = escape.convert(url);
  final escapedMime = mimeType == null
      ? null
      : escape.convert(mimeType.split(';').first.trim());
  final escapedPoster = posterUrl == null ? null : escape.convert(posterUrl);
  final sourceType = escapedMime == null || escapedMime.isEmpty
      ? ''
      : ' type="$escapedMime"';
  final poster = escapedPoster == null || escapedPoster.isEmpty
      ? ''
      : ' poster="$escapedPoster"';
  final loopAttribute = loop ? ' loop' : '';
  return '<!doctype html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; '
      'media-src https: http: data: blob:; img-src https: http: data: blob:; '
      'style-src \'unsafe-inline\'; script-src \'none\'; connect-src \'none\';">'
      '<style>html,body{margin:0;width:100%;height:100%;overflow:hidden;'
      'background:#000}video{display:block;width:100%;height:100%;'
      'object-fit:contain;background:#000}</style></head><body>'
      '<video controls autoplay playsinline$loopAttribute$poster>'
      '<source src="$escapedUrl"$sourceType>'
      '</video></body></html>';
}
