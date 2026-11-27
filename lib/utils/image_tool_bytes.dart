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

  /// OCR 专用的快速字节准备：对未超像素预算的常规静态 JPEG/PNG 直接透传原字节，
  /// 跳过耗时的 `ui.Image.toByteData(format: png)` 重压缩；动图/AVIF/SVG/超大图再回退转单帧 PNG。
  static Future<Uint8List> ocrBytes(Uint8List bytes) async {
    if (bytes.length >= 12 &&
        !SvgUtils.isSvgBytes(bytes) &&
        !bytesLookLikeAvif(bytes) &&
        (_isJpeg(bytes) || _isStaticPng(bytes))) {
      try {
        final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        buffer.dispose();
        final ratio = _ratio(
          descriptor.width.toDouble(),
          descriptor.height.toDouble(),
        );
        descriptor.dispose();
        if (ratio >= 1.0) return bytes;
      } catch (_) {
        // 头嗅探异常时回退到统一转码路径
      }
    }
    return png(bytes);
  }

  static bool _isJpeg(Uint8List bytes) =>
      bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF;

  /// 检测静态 PNG（带 `acTL` 块的 APNG 排除，需取首帧）。
  static bool _isStaticPng(Uint8List bytes) {
    if (bytes.length < 24 ||
        bytes[0] != 0x89 ||
        bytes[1] != 0x50 ||
        bytes[2] != 0x4E ||
        bytes[3] != 0x47) {
      return false;
    }
    // 扫描 IHDR 之后、IDAT 之前的块头，检查是否存在 APNG 的 `acTL` 块。
    var offset = 8;
    while (offset + 8 <= bytes.length) {
      final length =
          (bytes[offset] << 24) |
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];
      final b0 = bytes[offset + 4];
      final b1 = bytes[offset + 5];
      final b2 = bytes[offset + 6];
      final b3 = bytes[offset + 7];
      // 'acTL'
      if (b0 == 0x61 && b1 == 0x63 && b2 == 0x54 && b3 == 0x4C) return false;
      // 'IDAT' — 到达图像数据后不会再出现 acTL
      if (b0 == 0x49 && b1 == 0x44 && b2 == 0x41 && b3 == 0x54) return true;
      final next = offset + 12 + length;
      if (length < 0 || next <= offset) break;
      offset = next;
    }
    return true;
  }

  static double _ratio(double width, double height) => math.min(
    1.0,
    math.min(
      math.sqrt(maxPixels / (width * height)),
      16384 / math.max(width, height),
    ),
  );
}
