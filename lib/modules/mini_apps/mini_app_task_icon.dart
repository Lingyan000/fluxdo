import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'mini_app_artwork_image.dart';

/// 任务图标始终读取真实 LOGO，不能截取尚在加载中的工具栏占位图。
abstract final class MiniAppTaskIcon {
  static Future<Uint8List?> load(String url, ui.Brightness brightness) async {
    if (url.isEmpty) return null;
    try {
      const size = 96;
      final image = await MiniAppArtworkImage.load(
        url,
        brightness: brightness,
        size: size,
        fit: BoxFit.cover,
      );
      try {
        final recorder = ui.PictureRecorder();
        Canvas(recorder)
          ..clipRSuperellipse(
            RSuperellipse.fromRectAndRadius(
              const Rect.fromLTWH(0, 0, 96, 96),
              const Radius.circular(96 * .3),
            ),
          )
          ..drawImage(image, Offset.zero, Paint());
        final picture = recorder.endRecording();
        try {
          final icon = await picture.toImage(size, size);
          try {
            final data = await icon.toByteData(format: ui.ImageByteFormat.png);
            return data?.buffer.asUint8List(
              data.offsetInBytes,
              data.lengthInBytes,
            );
          } finally {
            icon.dispose();
          }
        } finally {
          picture.dispose();
        }
      } finally {
        image.dispose();
      }
    } catch (_) {
      // 下载或解码失败时保留系统侧的应用首字图标，不影响打开窗口。
      return null;
    }
  }
}
