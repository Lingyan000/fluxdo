import 'dart:async';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:native_animated_image/native_animated_image.dart'
    show NativeAvifPlatform, NativeAnimatedImageFfi;

import 'discourse_cache_manager.dart';

/// 通用 sticker thumbnail provider — 单帧解码 + 缩放 + PNG cache。
///
/// 这是 fluxdo sticker 面板的"地板": 30 张同屏的 grid 场景下,任何格式
/// (.avif / .gif / .webp / .apng) 都走同一个 thumbnail PNG cache 路径,
/// 首次解码后写 PNG 到磁盘,后续直接 Flutter 内置 codec 读 PNG
/// (毫秒级,完全跳过 AV1 / GIF disposal 这类慢路径)。
///
/// 之前架构错误:`AvifImageProvider` 只覆盖 AVIF,GIF/WebP sticker group
/// 直接走 `CachedNetworkImageProvider` 没任何优化 → 30 个 GIF 同屏卡死。
/// 这个 provider 把 thumbnail cache / 并发限流 / prefetch / 取消都做成
/// backend-agnostic,GIF/AVIF group 都受益。
///
/// 完整动画解码(长按预览 / 大图查看)**不**走这个 provider —
/// 那是另一套路径,见 [AvifImageProvider] 和 `NativeAnimatedImageProvider`。
class StickerThumbnailProvider
    extends ImageProvider<StickerThumbnailProvider> {
  const StickerThumbnailProvider(
    this.url, {
    required this.targetSize,
    this.scale = 1.0,
    this.cacheManager,
  });

  final String url;

  /// 缩略图目标像素尺寸(长边)。首次解码后缩放到这个尺寸再存 PNG。
  final int targetSize;

  final double scale;
  final BaseCacheManager? cacheManager;

  /// URL 是否走得通这个 provider(AVIF / GIF / animated WebP / APNG)。
  /// 静态图(PNG/JPEG)和其它格式应该走 `CachedNetworkImageProvider`。
  static bool supports(String url) {
    try {
      final path = Uri.parse(url).path.toLowerCase();
      return path.endsWith('.avif') ||
          path.endsWith('.gif') ||
          path.endsWith('.webp') ||
          path.endsWith('.apng');
    } catch (_) {
      final lower = url.toLowerCase();
      return lower.endsWith('.avif') ||
          lower.endsWith('.gif') ||
          lower.endsWith('.webp') ||
          lower.endsWith('.apng');
    }
  }

  /// 预热缩略图缓存(后台 idle 时调用,sticker_provider 的 prefetch hook 用)。
  ///
  /// 命中 cache 或已经在解的 URL 直接 short-circuit,避免重复 work。
  static Future<void> precache(
    String url, {
    required int targetSize,
    BaseCacheManager? cacheManager,
  }) async {
    if (!supports(url)) return;

    final manager = cacheManager ?? DiscourseCacheManager();
    final thumbKey = _thumbnailCacheKey(url, targetSize);
    if (_knownThumbnailKeys.contains(thumbKey)) return;

    final cachedBytes = await _readCachedThumbnailBytes(manager, thumbKey);
    if (cachedBytes != null) return;

    final pending = _pendingThumbnailTasks[thumbKey];
    if (pending != null) {
      await pending;
      return;
    }

    final task = _warmThumbnail(
      manager: manager,
      url: url,
      targetSize: targetSize,
      thumbKey: thumbKey,
    );
    _pendingThumbnailTasks[thumbKey] = task;
    try {
      await task;
    } finally {
      _pendingThumbnailTasks.remove(thumbKey);
    }
  }

  @override
  Future<StickerThumbnailProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<StickerThumbnailProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    StickerThumbnailProvider key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(_loadThumbnail(key));
  }

  Future<ImageInfo> _loadThumbnail(StickerThumbnailProvider key) async {
    final manager = key.cacheManager ?? DiscourseCacheManager();
    final thumbKey = _thumbnailCacheKey(key.url, key.targetSize);

    // 快速路径:PNG 缓存命中 → Flutter 内置 PNG codec(毫秒级)
    final cachedBytes = await _readCachedThumbnailBytes(manager, thumbKey);
    if (cachedBytes != null) {
      return _decodeThumbnailBytes(cachedBytes, key.scale);
    }

    // 首次解码走预热,避免重复
    await precache(
      key.url,
      targetSize: key.targetSize,
      cacheManager: manager,
    );
    final warmedBytes = await _readCachedThumbnailBytes(manager, thumbKey);
    if (warmedBytes != null) {
      return _decodeThumbnailBytes(warmedBytes, key.scale);
    }

    // 缓存写入失败兜底:现场解 + 显示,不让用户看到空白
    final displayImage = await _decodeFirstFrameImage(
      manager: manager,
      url: key.url,
      targetSize: key.targetSize,
    );
    unawaited(_cacheThumbnail(manager, thumbKey, displayImage));
    return ImageInfo(image: displayImage, scale: key.scale);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is StickerThumbnailProvider &&
        other.url == url &&
        other.targetSize == targetSize &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(url, targetSize, scale);

  @override
  String toString() =>
      'StickerThumbnailProvider("$url", targetSize: $targetSize)';
}

// ==================== Internal helpers ====================

/// 并发限制 thumbnail 解码,避免 30 张同屏同时解爆内存。
final _decodeSemaphore = _Semaphore(8);

/// in-flight prefetch task,去重避免重复解
final _pendingThumbnailTasks = <String, Future<void>>{};

/// 已知 PNG cache 命中(进程级 in-memory 索引,跳过磁盘查询)
final _knownThumbnailKeys = <String>{};

String _thumbnailCacheKey(String url, int targetSize) {
  return 'sticker_thumb:$targetSize:$url';
}

Future<Uint8List?> _readCachedThumbnailBytes(
  BaseCacheManager manager,
  String thumbKey,
) async {
  final cached = await manager.getFileFromCache(thumbKey);
  if (cached == null) return null;
  _knownThumbnailKeys.add(thumbKey);
  return cached.file.readAsBytes();
}

Future<ImageInfo> _decodeThumbnailBytes(
  Uint8List bytes,
  double scale,
) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final codec = await ui.instantiateImageCodecFromBuffer(buffer);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return ImageInfo(image: frame.image, scale: scale);
}

Future<void> _warmThumbnail({
  required BaseCacheManager manager,
  required String url,
  required int targetSize,
  required String thumbKey,
}) async {
  ui.Image? displayImage;
  try {
    displayImage = await _decodeFirstFrameImage(
      manager: manager,
      url: url,
      targetSize: targetSize,
    );
    await _cacheThumbnail(manager, thumbKey, displayImage);
    _knownThumbnailKeys.add(thumbKey);
  } finally {
    displayImage?.dispose();
  }
}

/// 从 cache 拿 bytes → backend dispatch 解第一帧 → 必要时缩放到 targetSize。
Future<ui.Image> _decodeFirstFrameImage({
  required BaseCacheManager manager,
  required String url,
  required int targetSize,
}) async {
  await _decodeSemaphore.acquire();
  ui.Image srcImage;
  try {
    final file = await manager.getSingleFile(url);
    final bytes = await file.readAsBytes();
    srcImage = await _decodeFirstFrame(url, bytes);
  } finally {
    _decodeSemaphore.release();
  }

  if (srcImage.width > targetSize || srcImage.height > targetSize) {
    final resized = await _resize(srcImage, targetSize);
    srcImage.dispose();
    return resized;
  }
  return srcImage;
}

/// 按 URL 后缀分发到对应 backend,解出第一帧 ui.Image。
///
/// - `.avif` → `NativeAvifPlatform`(平台 ImageIO/ImageDecoder + 内部 Rust 回退)
/// - `.gif/.webp/.apng` → `NativeAnimatedImageFfi`(Rust pipeline,Isolate 内跑;
///   静态 webp/png 会被 native_animated_image 内部 fallback 到 Flutter 内置 codec)
/// - 其它 → Flutter 内置 codec(理论不会进这条 — supports() 已 gate)
Future<ui.Image> _decodeFirstFrame(String url, Uint8List bytes) async {
  final lower = url.toLowerCase();

  if (lower.endsWith('.avif')) {
    // AVIF: NativeAvifPlatform.decode 内部已经做 platform → Rust 两级回退
    final decoded = await NativeAvifPlatform.decode(bytes);
    if (decoded.frames.isEmpty) {
      throw StateError('AVIF decoded 0 frames: $url');
    }
    final first = decoded.frames.first;
    return _rgbaToUiImage(first.rgba, decoded.width, decoded.height);
  }

  // GIF / animated WebP / APNG → 走 Isolate 解,主线程不阻塞
  // (NativeAnimatedImageFfi 是 sync FFI,必须放 Isolate 里)
  final decoded = await Isolate.run(
    () => NativeAnimatedImageFfi.instance.decode(bytes),
    debugName: 'StickerThumbnail.decode',
  );
  if (decoded.frames.isEmpty) {
    throw StateError('Animated image decoded 0 frames: $url');
  }
  final first = decoded.frames.first;
  return _rgbaToUiImage(first.rgba, decoded.width, decoded.height);
}

Future<ui.Image> _rgbaToUiImage(Uint8List rgba, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    (image) => completer.complete(image),
  );
  return completer.future;
}

Future<void> _cacheThumbnail(
  BaseCacheManager manager,
  String key,
  ui.Image image,
) async {
  try {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData != null) {
      await manager.putFile(
        key,
        byteData.buffer.asUint8List(),
        fileExtension: 'png',
      );
    }
  } catch (_) {
    // 缓存写入失败不影响显示
  }
}

Future<ui.Image> _resize(ui.Image src, int maxDim) async {
  final double ratio = src.width / src.height;
  final int w, h;
  if (ratio >= 1) {
    w = maxDim;
    h = (maxDim / ratio).round().clamp(1, maxDim);
  } else {
    h = maxDim;
    w = (maxDim * ratio).round().clamp(1, maxDim);
  }
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    src,
    ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.low,
  );
  final pic = recorder.endRecording();
  final result = await pic.toImage(w, h);
  pic.dispose();
  return result;
}

/// 简单异步信号量,限制并发解码数。
class _Semaphore {
  _Semaphore(this.maxCount);

  final int maxCount;
  int _current = 0;
  final _queue = <Completer<void>>[];

  Future<void> acquire() {
    if (_current < maxCount) {
      _current++;
      return SynchronousFuture(null);
    }
    final c = Completer<void>();
    _queue.add(c);
    return c.future;
  }

  void release() {
    if (_queue.isNotEmpty) {
      _queue.removeAt(0).complete();
    } else {
      _current--;
    }
  }
}
