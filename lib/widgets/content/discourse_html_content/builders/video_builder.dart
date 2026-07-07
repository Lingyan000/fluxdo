import 'dart:async';

import 'package:chewie/chewie.dart' as lib;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart' as lib;
import 'package:window_manager/window_manager.dart';

import '../../../../providers/preferences_provider.dart';
import '../../../../services/navigation/app_route_observer.dart';
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
    this.poster,
  });

  @override
  State<DiscourseVideoPlayer> createState() => _DiscourseVideoPlayerState();
}

class _DiscourseVideoPlayerState extends State<DiscourseVideoPlayer>
    with WidgetsBindingObserver, WindowListener, RouteAware {
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

  /// 退出全屏时，标记等待屏幕尺寸恢复后再释放 LayoutLock。
  /// 移动端：等 chewie 恢复屏幕方向后尺寸变化回调触发；
  /// 桌面端：等 onWindowLeaveFullScreen 回调触发。
  bool _pendingLockRelease = false;

  static final bool _isDesktop = PlatformUtils.isDesktop;

  /// 全屏期间缓存控制器，防止窗口/屏幕尺寸变化导致 widget 重建时
  /// 销毁 chewie 全屏路由正在使用的控制器。
  static final Map<String,
          ({lib.VideoPlayerController vpc, lib.ChewieController cc})>
      _fullscreenCache = {};

  Widget? get placeholder =>
      widget.poster != null ? Center(child: widget.poster) : null;

  @override
  void initState() {
    super.initState();
    _displayAspectRatio = widget.autoResize
        ? (_knownAspectRatios[widget.url] ?? widget.aspectRatio)
        : widget.aspectRatio;
    WidgetsBinding.instance.addObserver(this);
    if (_isDesktop) {
      windowManager.addListener(this);
    }
    _initControllers();
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
    // 上层 push 了对话框/BottomSheet：暂停播放以省掉 BackdropFilter 的代价
    final vpc = _vpc;
    if (vpc != null && vpc.value.isPlaying) {
      vpc.pause();
      _pausedByRouteOverlay = true;
    }
  }

  @override
  void didPopNext() {
    if (_pausedByRouteOverlay) {
      _pausedByRouteOverlay = false;
      _vpc?.play();
    }
  }

  @override
  void dispose() {
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
    // 展示比例由 [_displayAspectRatio] 统一供给:初始 = 记忆值/占位值,
    // 真实比例的展开时机由 [_maybeApplyRealAspectRatio] 治理(静止帧 +
    // 武装哨兵),不在 build 里直接追 controller 的实测值 —— 那会让
    // 初始化完成瞬间高度突变,滚动路径上方的视频把内容拉断。
    final aspectRatio = _displayAspectRatio;

    Widget? child;
    final controller = _controller;
    if (controller != null) {
      child = lib.Chewie(controller: controller);
    } else if (_error != null) {
      final errorBuilder = widget.errorBuilder;
      if (errorBuilder != null) {
        child = errorBuilder(context, widget.url, _error);
      }
    } else {
      child = placeholder;

      final loadingBuilder = widget.loadingBuilder;
      if (loadingBuilder != null) {
        child = loadingBuilder(context, widget.url, child ?? const SizedBox.shrink());
      }
    }

    return AspectRatio(
      aspectRatio: aspectRatio,
      child: child,
    );
  }

  Future<void> _initControllers() async {
    // 桌面全屏期间 widget 被重建时，复用缓存的控制器
    final cached = _fullscreenCache.remove(widget.url);
    if (cached != null) {
      _vpc = cached.vpc;
      final controller = cached.cc;
      controller.addListener(_onControllerChanged);
      _controller = controller;
      _didLockLayout = true;
      LayoutLock.acquire();
      if (mounted) setState(() {});
      _maybeApplyRealAspectRatio();
      return;
    }

    // ignore: deprecated_member_use
    final vpc = _vpc = lib.VideoPlayerController.network(widget.url);
    Object? vpcError;
    try {
      await vpc.initialize();
    } catch (error) {
      vpcError = error;
      // 平台差异排查的关键线索:AVFoundation(iOS/macOS)对签名 URL、
      // Content-Type、容器细节远比 ExoPlayer 挑剔,失败原因只在这里可见
      debugPrint('[Video] 初始化失败 url=${widget.url} error=$error');
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
    }
  }

  /// 全屏状态变化时 acquire/release LayoutLock，
  /// 桌面平台同时切换系统级全屏。
  void _onControllerChanged() {
    final isFullScreen = _controller?.isFullScreen ?? false;
    if (isFullScreen && !_didLockLayout) {
      _didLockLayout = true;
      LayoutLock.acquire();
      // 缓存控制器，防止屏幕尺寸变化导致 widget 重建时销毁它们
      if (_vpc != null && _controller != null) {
        _fullscreenCache[widget.url] = (vpc: _vpc!, cc: _controller!);
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
