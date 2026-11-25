import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../services/avif_image_provider.dart';
import '../services/svg_image_cache.dart';
import 'image_format.dart';
import 'svg_utils.dart';

/// 编辑器与 OCR 共用静态 PNG。动图取首帧，大图按像素预算等比缩放。
abstract final class ImageToolBytes {
  static const maxPixels = 16000000;

  static Future<Uint8List> png(Uint8List bytes) async {
    final ui.Image image;
    if (SvgUtils.isSvgBytes(bytes)) {
      final svg = await SvgImageCache.load(
        SvgUtils.sanitize(
          SvgUtils.stripActiveContent(SvgUtils.decodeSvgBytes(bytes)),
        ),
      );
      final size = svg.viewport.size;
      if (size.isEmpty) throw const FormatException('图片尺寸为空');
      final ratio = _ratio(size.width, size.height);
      await svg.prepareImages();
      try {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder)..scale(ratio);
        svg.paint(canvas);
        final picture = recorder.endRecording();
        try {
          image = await picture.toImage(
            math.max(1, (size.width * ratio).round()),
            math.max(1, (size.height * ratio).round()),
          );
        } finally {
          picture.dispose();
        }
      } finally {
        svg.unprepareImages();
      }
    } else if (bytesLookLikeAvif(bytes)) {
      image = await AvifImageProvider.decodeFirstFrame(bytes, maxDim: 4096);
    } else {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      buffer.dispose();
      final ratio = _ratio(
        descriptor.width.toDouble(),
        descriptor.height.toDouble(),
      );
      final codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * ratio).round()),
        targetHeight: math.max(1, (descriptor.height * ratio).round()),
      );
      try {
        image = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
        descriptor.dispose();
      }
    }
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw const FormatException('无法转换图片');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }
  }

  static double _ratio(double width, double height) => math.min(
    1.0,
    math.min(
      math.sqrt(maxPixels / (width * height)),
      16384 / math.max(width, height),
    ),
  );
}
