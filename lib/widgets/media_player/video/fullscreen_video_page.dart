import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../controls/media_controls_overlay.dart';
import 'fullscreen_coordinator.dart';
import 'video_player_session.dart';

/// 视频全屏页:自推路由(参照 ImageViewerPage.open),纯黑底 fade 转场。
///
/// 控制器所有权在 [VideoPlayerSession],本页只是租户 —— open() 先
/// retain,pop 完成后 release。全屏期间 inline 宿主被 cacheExtent 回收
/// 也不影响本页(旧 chewie 方案的 use-after-dispose 问题类在此结构下
/// 不存在)。
class FullscreenVideoPage extends StatefulWidget {
  const FullscreenVideoPage({super.key, required this.session});

  final VideoPlayerSession session;

  /// 全屏切换互斥门:快速连点全屏钮/双击会在 push 动画期间重入,
  /// 叠两个全屏路由(session retain 翻倍、Coordinator 时序错乱)。
  static bool _opening = false;

  /// 进入全屏。方向按视频比例决定(横视频转横屏,竖视频不动);
  /// LayoutLock / 系统全屏时序由 [FullscreenMediaCoordinator] 治理。
  static Future<void> open(
    BuildContext context,
    VideoPlayerSession session,
  ) async {
    if (_opening || session.isFullscreen) return;
    _opening = true;
    final navigator = Navigator.of(context, rootNavigator: true);
    session.retain();
    session.isFullscreen = true;
    final aspectRatio = session.controller.value.aspectRatio;
    try {
      await FullscreenMediaCoordinator.instance.enter(
        landscape: aspectRatio > 1,
      );
      _opening = false; // 路由已在推,后续重入被 isFullscreen 挡
      await navigator.push(
        PageRouteBuilder(
          opaque: true,
          barrierColor: Colors.black,
          transitionDuration: const Duration(milliseconds: 200),
          reverseTransitionDuration: const Duration(milliseconds: 180),
          pageBuilder: (_, _, _) => FullscreenVideoPage(session: session),
          transitionsBuilder: (_, animation, _, child) =>
              FadeTransition(opacity: animation, child: child),
        ),
      );
    } finally {
      _opening = false;
      session.isFullscreen = false;
      await FullscreenMediaCoordinator.instance.exit();
      session.release();
    }
  }

  @override
  State<FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<FullscreenVideoPage> {
  VideoPlayerController get _controller => widget.session.controller;

  static const _seekStep = Duration(seconds: 10);

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final value = _controller.value;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        value.isPlaying ? _controller.pause() : _controller.play();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        var target = value.position - _seekStep;
        if (target < Duration.zero) target = Duration.zero;
        _controller.seekTo(target);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        var target = value.position + _seekStep;
        if (target > value.duration) target = value.duration;
        _controller.seekTo(target);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _controller.setVolume((value.volume + 0.05).clamp(0.0, 1.0));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        _controller.setVolume((value.volume - 0.05).clamp(0.0, 1.0));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyF:
      case LogicalKeyboardKey.escape:
        if (event is KeyDownEvent) Navigator.of(context).maybePop();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _handleKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: VideoPlayer(_controller),
              ),
            ),
            MediaControlsOverlay(
              session: widget.session,
              isFullscreen: true,
              onFullscreenToggle: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
      ),
    );
  }
}
