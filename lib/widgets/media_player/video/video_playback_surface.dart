import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// Android 原生视图正确消费解码器 crop/rotation；屏外卸载 SurfaceView，
/// 避免平台视图离开 Flutter 视口后仍覆盖其他内容（flutter/flutter#164899）。
/// Session 保留控制器，重新进入视口只重新绑定表面，不重新请求视频。
class VideoPlaybackSurface extends StatefulWidget {
  const VideoPlaybackSurface({super.key, required this.controller});
  final VideoPlayerController controller;

  @override
  State<VideoPlaybackSurface> createState() => _VideoPlaybackSurfaceState();
}

class _VideoPlaybackSurfaceState extends State<VideoPlaybackSurface> {
  final _visibilityKey = UniqueKey();
  bool _visible = true;

  @override
  Widget build(BuildContext context) {
    if (widget.controller.viewType != VideoViewType.platformView) {
      return VideoPlayer(widget.controller);
    }
    return VisibilityDetector(
      key: _visibilityKey,
      onVisibilityChanged: (info) {
        final visible = info.visibleFraction > 0;
        if (mounted && visible != _visible) {
          setState(() => _visible = visible);
          if (!visible && widget.controller.value.isPlaying) {
            widget.controller.pause();
          }
        }
      },
      child: ClipRect(
        child: _visible
            ? VideoPlayer(widget.controller)
            : const SizedBox.expand(),
      ),
    );
  }
}
