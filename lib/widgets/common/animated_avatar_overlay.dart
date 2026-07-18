import 'package:flutter/material.dart';

import '../../services/discourse_cache_manager.dart';

/// 动图头像播放 overlay:压在静态首帧之上的圆形动图层。
///
/// ready(下载 gif 原件 + 全帧 Rust 解码,首次可达数百 ms)之前完全
/// 透明 —— 底下的静态模板小图(几 KB 秒出)先顶住观感,ready 后原位
/// 开始播放;出错保持透明,底图兜底。RepaintBoundary 把逐帧重绘限制
/// 在头像小区域。
class AnimatedAvatarOverlay extends StatelessWidget {
  const AnimatedAvatarOverlay({super.key, required this.url});

  /// 动画头像原件 URL(gif 全文件)
  final String url;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipOval(
        child: Image(
          image: discourseImageProvider(url),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSync) =>
              (wasSync || frame != null) ? child : const SizedBox.expand(),
          errorBuilder: (_, _, _) => const SizedBox.expand(),
        ),
      ),
    );
  }
}
