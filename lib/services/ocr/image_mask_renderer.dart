import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:image/image.dart' as img;

/// 隐私打码渲染样式。
enum PrivacyMaskStyle { mosaic, blur, solid }

/// 在后台 isolate 对图片指定矩形区域渲染马赛克、高斯模糊或纯色遮挡。
abstract final class ImageMaskRenderer {
  /// 按图片短边计算默认马赛克块像素尺寸，确保在各类分辨率下颗粒清晰均匀。
  static int defaultMosaicTileSize(int width, int height) =>
      (math.min(width, height) / 90).round().clamp(5, 16);

  /// 预生成整张图的缩略马赛克 RGBA 网格，供打码页以最近邻采样（FilterQuality.none）
  /// 实时预览真实像素马赛克，做到所见即所得。
  static Future<({Uint8List rgba, int width, int height})?>
  buildMosaicPreviewGrid(Uint8List imageBytes) =>
      Isolate.run(() => _buildMosaicGridInIsolate(imageBytes));

  static Future<Uint8List> render({
    required Uint8List imageBytes,
    required List<Rect> rects,
    required PrivacyMaskStyle style,
    bool encodePng = true,
    int jpegQuality = 92,
  }) async {
    if (rects.isEmpty) return imageBytes;
    final serializedRects = [
      for (final r in rects) [r.left, r.top, r.right, r.bottom],
    ];
    return Isolate.run(
      () => _renderInIsolate(
        imageBytes,
        serializedRects,
        style.index,
        encodePng,
        jpegQuality,
      ),
    );
  }

  /// 统一将 PNG/JPEG/16-bit 宽色域图归一化为 8-bit uint8 图像，
  /// 避免 16-bit (0..65535) 像素被截断成纯白（预览）或按 255/65535 写回变纯黑（导出）。
  static img.Image? _decodeUint8(Uint8List imageBytes) {
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) return null;
    if (decoded.format != img.Format.uint8 || decoded.hasPalette) {
      return decoded.convert(
        format: img.Format.uint8,
        numChannels: decoded.hasAlpha ? 4 : 3,
      );
    }
    return decoded;
  }

  static ({Uint8List rgba, int width, int height})? _buildMosaicGridInIsolate(
    Uint8List imageBytes,
  ) {
    final image = _decodeUint8(imageBytes);
    if (image == null) return null;
    final tile = defaultMosaicTileSize(image.width, image.height);
    final gridW = math.max(1, (image.width + tile - 1) ~/ tile);
    final gridH = math.max(1, (image.height + tile - 1) ~/ tile);
    final rgba = Uint8List(gridW * gridH * 4);
    var offset = 0;
    for (var gy = 0; gy < gridH; gy++) {
      final by = gy * tile;
      final bh = math.min(tile, image.height - by);
      for (var gx = 0; gx < gridW; gx++) {
        final bx = gx * tile;
        final bw = math.min(tile, image.width - bx);
        final c = _sampleMosaicTile(image, bx, by, bw, bh);
        rgba[offset++] = c.r;
        rgba[offset++] = c.g;
        rgba[offset++] = c.b;
        rgba[offset++] = 255;
      }
    }
    return (rgba: rgba, width: gridW, height: gridH);
  }

  static Uint8List _renderInIsolate(
    Uint8List imageBytes,
    List<List<double>> rects,
    int styleIndex,
    bool encodePng,
    int jpegQuality,
  ) {
    final image = _decodeUint8(imageBytes);
    if (image == null) throw const FormatException('无法解码打码图片');
    final style = PrivacyMaskStyle.values[styleIndex];
    final maxW = image.width;
    final maxH = image.height;
    final baseTile = defaultMosaicTileSize(maxW, maxH);

    for (final raw in rects) {
      final x1 = raw[0].floor().clamp(0, maxW - 1);
      final y1 = raw[1].floor().clamp(0, maxH - 1);
      final x2 = raw[2].ceil().clamp(0, maxW);
      final y2 = raw[3].ceil().clamp(0, maxH);
      final w = x2 - x1;
      final h = y2 - y1;
      if (w <= 1 || h <= 1) continue;

      switch (style) {
        case PrivacyMaskStyle.mosaic:
          _applyMosaic(image, x1, y1, w, h, baseTile);
        case PrivacyMaskStyle.blur:
          _applyBlur(image, x1, y1, w, h);
        case PrivacyMaskStyle.solid:
          _applySolid(image, x1, y1, w, h);
      }
    }

    return Uint8List.fromList(
      encodePng
          ? img.encodePng(image)
          : img.encodeJpg(image, quality: jpegQuality),
    );
  }

  static void _applyMosaic(
    img.Image image,
    int x1,
    int y1,
    int w,
    int h,
    int baseTile,
  ) {
    // 小字号文本框缩小颗粒尺寸，避免整行只剩 1~2 行块导致糊成纯色条。
    final blockSize = math
        .min(baseTile, math.max(5, (math.min(w, h) / 3.2).round()))
        .clamp(4, 16);
    for (var by = y1; by < y1 + h; by += blockSize) {
      final bh = math.min(blockSize, y1 + h - by);
      for (var bx = x1; bx < x1 + w; bx += blockSize) {
        final bw = math.min(blockSize, x1 + w - bx);
        final sampled = _sampleMosaicTile(image, bx, by, bw, bh);
        for (var py = by; py < by + bh; py++) {
          for (var px = bx; px < bx + bw; px++) {
            image.setPixelRgb(px, py, sampled.r, sampled.g, sampled.b);
          }
        }
      }
    }
  }

  /// 计算单个马赛克块的颜色：融合块均值与块内对比最强像素，
  /// 在保留真实画面色彩的同时，避免深/浅纯色背景上的细文字被均值冲淡成一整块纯黑或纯白。
  static ({int r, int g, int b}) _sampleMosaicTile(
    img.Image image,
    int bx,
    int by,
    int bw,
    int bh,
  ) {
    var rSum = 0;
    var gSum = 0;
    var bSum = 0;
    var count = 0;
    for (var py = by; py < by + bh; py++) {
      for (var px = bx; px < bx + bw; px++) {
        final p = image.getPixel(px, py);
        rSum += p.r.toInt();
        gSum += p.g.toInt();
        bSum += p.b.toInt();
        count++;
      }
    }
    if (count == 0) return (r: 0, g: 0, b: 0);
    final avgR = rSum / count;
    final avgG = gSum / count;
    final avgB = bSum / count;

    var maxDistSq = -1.0;
    var farR = avgR;
    var farG = avgG;
    var farB = avgB;
    for (var py = by; py < by + bh; py++) {
      for (var px = bx; px < bx + bw; px++) {
        final p = image.getPixel(px, py);
        final dr = p.r.toDouble() - avgR;
        final dg = p.g.toDouble() - avgG;
        final db = p.b.toDouble() - avgB;
        final distSq = dr * dr + dg * dg + db * db;
        if (distSq > maxDistSq) {
          maxDistSq = distSq;
          farR = p.r.toDouble();
          farG = p.g.toDouble();
          farB = p.b.toDouble();
        }
      }
    }

    // 平滑色块（如照片背景）中 farthest≈avg，自然退化为纯均值；
    // 高对比文字笔画处保留适度颗粒反差，观感更接近真实像素马赛克。
    const peakWeight = 0.38;
    const avgWeight = 1.0 - peakWeight;
    return (
      r: (avgR * avgWeight + farR * peakWeight).round().clamp(0, 255),
      g: (avgG * avgWeight + farG * peakWeight).round().clamp(0, 255),
      b: (avgB * avgWeight + farB * peakWeight).round().clamp(0, 255),
    );
  }

  static void _applyBlur(img.Image image, int x1, int y1, int w, int h) {
    final radius = math.max(6, (math.min(w, h) * 0.24).round()).clamp(6, 20);
    // 适度扩张裁剪边，避免模糊边缘出现黑边。
    final margin = math.min(radius, 12);
    final cx1 = math.max(0, x1 - margin);
    final cy1 = math.max(0, y1 - margin);
    final cx2 = math.min(image.width, x1 + w + margin);
    final cy2 = math.min(image.height, y1 + h + margin);
    final crop = img.copyCrop(
      image,
      x: cx1,
      y: cy1,
      width: cx2 - cx1,
      height: cy2 - cy1,
    );
    final blurred = img.gaussianBlur(crop, radius: radius);
    final offsetX = x1 - cx1;
    final offsetY = y1 - cy1;
    for (var dy = 0; dy < h; dy++) {
      for (var dx = 0; dx < w; dx++) {
        image.setPixel(
          x1 + dx,
          y1 + dy,
          blurred.getPixel(offsetX + dx, offsetY + dy),
        );
      }
    }
  }

  static void _applySolid(img.Image image, int x1, int y1, int w, int h) {
    // 采样紧邻外框周围像素的平均亮度，浅底用深墨灰、深底用柔和浅灰，保证清晰美观。
    final luma = _sampleBorderLuminance(image, x1, y1, w, h);
    final color = luma > 110
        ? img.ColorRgb8(30, 32, 38)
        : img.ColorRgb8(216, 220, 228);
    final radius = math.min(6, (math.min(w, h) * 0.18).round());
    img.fillRect(
      image,
      x1: x1,
      y1: y1,
      x2: x1 + w - 1,
      y2: y1 + h - 1,
      color: color,
      radius: radius,
    );
  }

  static double _sampleBorderLuminance(
    img.Image image,
    int x1,
    int y1,
    int w,
    int h,
  ) {
    var sum = 0.0;
    var count = 0;
    void sample(int x, int y) {
      if (x < 0 || y < 0 || x >= image.width || y >= image.height) return;
      final p = image.getPixel(x, y);
      sum += 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      count++;
    }

    final stepX = math.max(1, w ~/ 16);
    for (var x = x1; x < x1 + w; x += stepX) {
      sample(x, y1 - 2);
      sample(x, y1 + h + 1);
    }
    final stepY = math.max(1, h ~/ 8);
    for (var y = y1; y < y1 + h; y += stepY) {
      sample(x1 - 2, y);
      sample(x1 + w + 1, y);
    }
    return count > 0 ? sum / count : 200;
  }
}
