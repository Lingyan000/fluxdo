part of 'image_viewer_page.dart';

/// 查看器只持有字节。SVG 转为位图后走同一套缩放、拖动与导出逻辑，
/// 不启用脚本、动画引擎或外链资源加载。
class _ViewerMemoryImage {
  const _ViewerMemoryImage(this.bytes);
  final Uint8List bytes;

  static Future<_ViewerMemoryImage> prepare(
    Uint8List bytes,
    int maxDimension,
  ) async {
    if (bytes.isEmpty) throw const FormatException('图片为空');
    if (!SvgUtils.isSvgBytes(bytes)) return _ViewerMemoryImage(bytes);

    final svg = await SvgImageCache.load(SvgUtils.decodeSvgBytes(bytes));
    final viewport = svg.viewport;
    if (viewport.isEmpty ||
        !viewport.width.isFinite ||
        !viewport.height.isFinite) {
      throw const FormatException('图片尺寸不可用');
    }
    final scale = maxDimension / viewport.size.longestSide;
    if (!scale.isFinite) throw const FormatException('图片尺寸不可用');
    try {
      await svg.prepareImages();
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder)
        ..scale(scale)
        ..translate(-viewport.left, -viewport.top);
      svg.paint(canvas);
      final picture = recorder.endRecording();
      try {
        final image = await picture.toImage(
          (viewport.width * scale).round().clamp(1, maxDimension),
          (viewport.height * scale).round().clamp(1, maxDimension),
        );
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          if (data == null) throw const FormatException('图片转换失败');
          return _ViewerMemoryImage(data.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      } finally {
        picture.dispose();
      }
    } finally {
      svg.unprepareImages();
    }
  }

  String get extension {
    if (bytesLookLikeAvif(bytes)) return 'avif';
    final mime = lookupMimeType('', headerBytes: bytes);
    return (mime == null ? null : extensionFromMime(mime)) ?? 'png';
  }

  /// 剪贴板图片使用 PNG；保存和分享仍保留原始容器及动图帧。
  Future<Uint8List> clipboardPng() async {
    if (extension == 'png') return bytes;
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      try {
        final png = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (png == null) throw const FormatException('图片转换失败');
        return png.buffer.asUint8List();
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }
}
