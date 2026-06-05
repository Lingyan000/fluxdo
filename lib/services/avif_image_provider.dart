import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_avif/flutter_avif.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:native_animated_image/native_animated_image.dart' show NativeAvifPlatform;
import '../l10n/s.dart';
import 'discourse_cache_manager.dart';

/// 限制并发 AVIF 解码数(thumbnail batch 场景 / fallback flutter_avif)。
///
/// 当前调到 8 —— 用户机器 8+ 核常见(M 系列、骁龙 8 Gen 2+),平台 native
/// ImageIO 内存友好,并发 8 同屏内存峰值可控。完整解码路径(长按预览 /
/// 大图)已经在 _decodeAvif 内 bypass 这个 semaphore,见 _decodeAvif 注释。
final _avifDecodeSemaphore = _Semaphore(8);
final _pendingThumbnailTasks = <String, Future<void>>{};
final _knownThumbnailKeys = <String>{};

/// AVIF 图片 Provider
///
/// 通过 CacheManager 下载/缓存文件，
/// 使用 flutter_avif 的 decodeAvif 解码为 dart:ui Image
/// 支持单帧和多帧（动画）AVIF
///
/// 当 [singleFrame] 且 [targetSize] 不为 null 时，走缩略图快速路径：
/// 首次解码后将缩放结果以 PNG 写入磁盘缓存，后续直接读取 PNG，
/// 完全绕过 AV1 解码，性能与普通 PNG 一致。
class AvifImageProvider extends ImageProvider<AvifImageProvider> {
  final String url;
  final double scale;
  final BaseCacheManager? cacheManager;

  /// 只解码第一帧，不播放动画。用于缩略图网格等场景。
  final bool singleFrame;

  /// 缩略图目标像素尺寸（长边）。
  /// 仅在 [singleFrame] 为 true 时生效：首次解码后缩放并以 PNG 缓存，
  /// 后续直接读取缓存 PNG，不再触发 AV1 解码。
  final int? targetSize;

  const AvifImageProvider(
    this.url, {
    this.scale = 1.0,
    this.cacheManager,
    this.singleFrame = false,
    this.targetSize,
  });

  static bool isAvifUrl(String url) {
    try {
      return Uri.parse(url).path.toLowerCase().endsWith('.avif');
    } catch (_) {
      return url.toLowerCase().endsWith('.avif');
    }
  }

  static String _thumbnailCacheKey(String url, int targetSize) {
    return 'avif_thumb:$targetSize:$url';
  }

  /// 预热 AVIF 缩略图缓存。
  ///
  /// 适合在列表展示前后台执行，避免首次进入视口时现场解码 AVIF。
  static Future<void> precacheThumbnail(
    String url, {
    required int targetSize,
    BaseCacheManager? cacheManager,
  }) async {
    if (!isAvifUrl(url)) return;

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
  Future<AvifImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<AvifImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    AvifImageProvider key,
    ImageDecoderCallback decode,
  ) {
    // 缩略图快速路径：PNG 缓存 → 内置 codec，不走 AV1
    if (key.singleFrame && key.targetSize != null) {
      return OneFrameImageStreamCompleter(_loadThumbnail(key));
    }
    return _AvifAnimatedImageStreamCompleter(
      framesLoader: _decodeAvif(key),
      scale: key.scale,
    );
  }

  // ==================== 缩略图路径 ====================

  Future<ImageInfo> _loadThumbnail(AvifImageProvider key) async {
    final manager = key.cacheManager ?? DiscourseCacheManager();
    final thumbKey = _thumbnailCacheKey(key.url, key.targetSize!);

    // 快速路径：PNG 缓存命中 → 用 Flutter 内置 codec 解码（毫秒级）
    final cachedBytes = await _readCachedThumbnailBytes(manager, thumbKey);
    if (cachedBytes != null) {
      return _decodeThumbnailBytes(cachedBytes, key.scale);
    }

    // 首次解码提前走预热逻辑，避免重复解码同一缩略图。
    await precacheThumbnail(
      key.url,
      targetSize: key.targetSize!,
      cacheManager: manager,
    );
    final warmedBytes = await _readCachedThumbnailBytes(manager, thumbKey);
    if (warmedBytes != null) {
      return _decodeThumbnailBytes(warmedBytes, key.scale);
    }

    // 缓存写入失败时兜底：仍然现场解码并显示，避免出现空白。
    final displayImage = await _decodeThumbnailImage(
      manager: manager,
      url: key.url,
      targetSize: key.targetSize!,
    );
    unawaited(_cacheThumbnail(manager, thumbKey, displayImage));

    return ImageInfo(image: displayImage, scale: key.scale);
  }

  static Future<Uint8List?> _readCachedThumbnailBytes(
    BaseCacheManager manager,
    String thumbKey,
  ) async {
    final cached = await manager.getFileFromCache(thumbKey);
    if (cached == null) return null;
    _knownThumbnailKeys.add(thumbKey);
    return cached.file.readAsBytes();
  }

  static Future<ImageInfo> _decodeThumbnailBytes(
    Uint8List bytes,
    double scale,
  ) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await ui.instantiateImageCodecFromBuffer(buffer);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return ImageInfo(image: frame.image, scale: scale);
  }

  static Future<void> _warmThumbnail({
    required BaseCacheManager manager,
    required String url,
    required int targetSize,
    required String thumbKey,
  }) async {
    ui.Image? displayImage;
    try {
      displayImage = await _decodeThumbnailImage(
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

  static Future<ui.Image> _decodeThumbnailImage({
    required BaseCacheManager manager,
    required String url,
    required int targetSize,
  }) async {
    await _avifDecodeSemaphore.acquire();
    ui.Image srcImage;
    try {
      final file = await manager.getSingleFile(url);
      final bytes = await file.readAsBytes();
      // 平台 native 优先 + flutter_avif fallback
      final frames = await _decodeViaPlatformOrFallback(bytes);
      srcImage = frames.first.image;
      for (int i = 1; i < frames.length; i++) {
        frames[i].image.dispose();
      }
    } finally {
      _avifDecodeSemaphore.release();
    }

    if (srcImage.width > targetSize || srcImage.height > targetSize) {
      final resized = await _resize(srcImage, targetSize);
      srcImage.dispose();
      return resized;
    }
    return srcImage;
  }

  static Future<void> _cacheThumbnail(
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

  static Future<ui.Image> _resize(ui.Image src, int maxDim) async {
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

  // ==================== 完整解码路径 ====================

  Future<List<AvifFrameInfo>> _decodeAvif(AvifImageProvider key) async {
    // 完整解码路径(singleFrame=false): 长按预览、大图查看等单张交互场景。
    // 这条路不走 [_avifDecodeSemaphore] —— 否则 sticker grid 的 thumbnail 解码
    // (走 _decodeThumbnailImage,会 acquire semaphore)会把用户长按预览的请求
    // 挤在队列后面,长按预览感知慢。
    //
    // 单张完整解码本来就 1 个任务,不会有 batch 内存爆炸的问题。
    final manager = key.cacheManager ?? DiscourseCacheManager();
    final file = await manager.getSingleFile(key.url);
    final bytes = await file.readAsBytes();

    // 优先走系统 ImageIO/ImageDecoder(Safari iOS 16.4+/macOS 13.4+/Android 31+),
    // Apple/Google 的内部 AVIF 实现含 SIMD + 部分硬件加速,比 flutter_avif
    // 自带的第三方 libavif 快 2-5x。平台不支持时无缝回退 flutter_avif。
    final frames = await _decodeViaPlatformOrFallback(bytes);

    if (key.singleFrame && frames.length > 1) {
      for (int i = 1; i < frames.length; i++) {
        frames[i].image.dispose();
      }
      return [frames.first];
    }
    return frames;
  }

  /// 优先平台 native(ImageIO/ImageDecoder),失败 fallback flutter_avif。
  static Future<List<AvifFrameInfo>> _decodeViaPlatformOrFallback(
      Uint8List bytes) async {
    if (await NativeAvifPlatform.canUse()) {
      try {
        final decoded = await NativeAvifPlatform.decode(bytes);
        final frames = <AvifFrameInfo>[];
        for (final frame in decoded.frames) {
          final image = await _rgbaToUiImage(
              frame.rgba, decoded.width, decoded.height);
          frames.add(AvifFrameInfo(image: image, duration: frame.delay));
        }
        return frames;
      } catch (e, st) {
        // 平台 decoder 异常(罕见,如不支持的 profile) → fallback flutter_avif,保证不退化
        debugPrint(
            '[AvifImageProvider] platform decode failed, fallback flutter_avif: $e\n$st');
      }
    }
    // Fallback: flutter_avif (bundled libavif)
    return decodeAvif(bytes);
  }

  static Future<ui.Image> _rgbaToUiImage(
      Uint8List rgba, int width, int height) {
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

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AvifImageProvider &&
        other.url == url &&
        other.scale == scale &&
        other.singleFrame == singleFrame &&
        other.targetSize == targetSize;
  }

  @override
  int get hashCode => Object.hash(url, scale, singleFrame, targetSize);

  @override
  String toString() => 'AvifImageProvider("$url", scale: $scale)';
}

/// AVIF 多帧图片流 Completer
///
/// 单帧 AVIF 直接显示；多帧 AVIF 按帧 duration 循环播放。
/// 无监听时自动暂停动画，重新添加监听时恢复。
class _AvifAnimatedImageStreamCompleter extends ImageStreamCompleter {
  _AvifAnimatedImageStreamCompleter({
    required Future<List<AvifFrameInfo>> framesLoader,
    required this.scale,
  }) {
    framesLoader.then(
      _handleFrames,
      onError: (Object error, StackTrace stack) {
        reportError(
          context: ErrorDescription(S.current.common_decodeAvif),
          exception: error,
          stack: stack,
        );
      },
    );
  }

  final double scale;
  List<AvifFrameInfo>? _frames;
  int _currentFrameIndex = 0;
  Timer? _timer;

  void _handleFrames(List<AvifFrameInfo> frames) {
    if (frames.isEmpty) {
      reportError(
        context: ErrorDescription(S.current.error_avifDecodeNoFrames),
        exception: Exception(S.current.error_avifDecodeNoFrames),
        stack: StackTrace.current,
      );
      return;
    }
    _frames = frames;
    _emitFrame();
  }

  void _emitFrame() {
    final frames = _frames;
    if (frames == null || !hasListeners) return;

    final frame = frames[_currentFrameIndex];
    setImage(ImageInfo(image: frame.image.clone(), scale: scale));

    // 多帧时调度下一帧
    if (frames.length > 1) {
      final delay = frame.duration.inMilliseconds > 0
          ? frame.duration
          : const Duration(milliseconds: 100);
      _currentFrameIndex = (_currentFrameIndex + 1) % frames.length;
      _timer?.cancel();
      _timer = Timer(delay, _emitFrame);
    }
  }

  @override
  void addListener(ImageStreamListener listener) {
    final hadListeners = hasListeners;
    super.addListener(listener);
    // 恢复已暂停的动画
    if (!hadListeners &&
        _frames != null &&
        _frames!.length > 1 &&
        _timer == null) {
      _emitFrame();
    }
  }

  @override
  void removeListener(ImageStreamListener listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
    }
  }
}

/// 简单的异步信号量，用于限制并发操作数
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
