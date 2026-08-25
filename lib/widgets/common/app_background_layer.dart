import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/app_background.dart';
import '../../theme/neutral_ramps.dart';

/// 透明模式的根背景层：用户背景图 + 遮罩。
///
/// 垫在 Navigator 之下（MaterialApp.builder 的 Stack 最底层），配合
/// 透明中性层让背景图透出来。图片固定不滚动，内容在其上滚动。
///
/// 遮罩颜色跟随亮度（浅色盖白、深色盖黑），透明度由用户调节且
/// 明暗分开记忆——同一张图在两种亮度下都能调出可读性。
class AppBackgroundLayer extends StatelessWidget {
  const AppBackgroundLayer({super.key, required this.background});

  final AppBackground background;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final scrim = background.scrimFor(brightness);

    // 解码尺寸限制在屏幕长边 × dpr（上限 4096），避免原图全尺寸
    // 解码造成的内存尖峰；文件本体保留原图，不做转码。
    final mq = MediaQuery.of(context);
    final longEdge = math.max(mq.size.width, mq.size.height);
    final cacheWidth = (longEdge * mq.devicePixelRatio).clamp(0, 4096).round();

    Widget image = Image.file(
      File(background.imagePath!),
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      // 主题重建（如切亮度）时保留上一帧，避免背景闪烁
      gaplessPlayback: true,
      // 文件被外部删除等异常：退化为不透明中性底，不留透明窟窿
      errorBuilder: (context, error, stackTrace) => ColoredBox(
        color: brightness == Brightness.light
            ? NeutralRamp.light.surface
            : NeutralRamp.dark.surface,
      ),
    );

    if (background.blurSigma > 0) {
      image = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: background.blurSigma,
          sigmaY: background.blurSigma,
        ),
        child: image,
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        image,
        ColoredBox(
          color:
              (brightness == Brightness.light
                      ? const Color(0xFFFFFFFF)
                      : const Color(0xFF000000))
                  .withValues(alpha: scrim),
        ),
      ],
    );
  }
}
