import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:jovial_svg/jovial_svg.dart';

import '../../services/discourse_cache_manager.dart';
import '../../utils/svg_utils.dart';

/// 卡片取色与系统任务图标共享的首帧栅格化，复用公共下载和图片缓存。
/// 返回的图片由调用方释放，不依赖页面是否已经绘制。
abstract final class MiniAppArtworkImage {
  static Future<ui.Image> load(
    String url, {
    required ui.Brightness brightness,
    int size = 32,
    BoxFit fit = BoxFit.fill,
  }) async {
    final bytes = await BlobImageCache.fetch(
      BlobImageCache.contentBucket,
      url,
    ).timeout(const Duration(seconds: 10));
    if (!SvgUtils.isSvgBytes(bytes)) return _raster(url, size, fit);
    // 可选的系统图标和背景装饰不能因大型 SVG 阻塞主线程。
    if (bytes.length > 256 * 1024) {
      throw const FormatException('Mini app artwork too large');
    }
    final source = SvgUtils.sanitize(
      SvgUtils.stripActiveContent(
        SvgUtils.resolveColorSchemeMedia(
          SvgUtils.decodeSvgBytes(bytes),
          dark: brightness == ui.Brightness.dark,
        ),
      ),
    );
    final svg = ScalableImage.fromSvgString(source, warnF: (_) {});
    final viewport = svg.viewport;
    if (viewport.isEmpty) throw const FormatException('Empty mini app artwork');
    await svg.prepareImages();
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final target = Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble());
      final fitted = applyBoxFit(fit, viewport.size, target.size);
      final src = Alignment.center.inscribe(
        fitted.source,
        Offset.zero & viewport.size,
      );
      final dst = Alignment.center.inscribe(fitted.destination, target);
      canvas
        ..clipRect(target)
        ..translate(dst.left, dst.top)
        ..scale(dst.width / src.width, dst.height / src.height)
        ..translate(-src.left, -src.top);
      // ScalableImage.paint 自身处理 viewport 的非零原点。
      svg.paint(canvas);
      final picture = recorder.endRecording();
      try {
        return await picture.toImage(size, size);
      } finally {
        picture.dispose();
      }
    } finally {
      svg.unprepareImages();
    }
  }

  static Future<ui.Image> _raster(String url, int size, BoxFit fit) async {
    final stream = ResizeImage(
      discourseImageProvider(url),
      width: size,
      height: size,
      policy: ResizeImagePolicy.fit,
    ).resolve(ImageConfiguration.empty);
    final firstFrame = Completer<ui.Image>();
    final listener = ImageStreamListener(
      (info, _) {
        if (!firstFrame.isCompleted) firstFrame.complete(info.image.clone());
        info.dispose();
      },
      onError: (Object error, StackTrace? stack) {
        if (!firstFrame.isCompleted) firstFrame.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    try {
      final image = await firstFrame.future.timeout(
        const Duration(seconds: 10),
      );
      try {
        final recorder = ui.PictureRecorder();
        paintImage(
          canvas: Canvas(recorder),
          rect: Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
          image: image,
          fit: fit,
          filterQuality: FilterQuality.medium,
        );
        final picture = recorder.endRecording();
        try {
          return await picture.toImage(size, size);
        } finally {
          picture.dispose();
        }
      } finally {
        image.dispose();
      }
    } finally {
      stream.removeListener(listener);
    }
  }
}
