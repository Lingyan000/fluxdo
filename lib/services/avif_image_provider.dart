import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_avif/flutter_avif.dart' as fa;
import '../l10n/s.dart';
import '../utils/scroll_busy_signal.dart';
import 'avif_fast_bridge.dart';
import 'blob_image_cache.dart';

/// 限制并发 AVIF 解码数(thumbnail batch 场景)。
///
/// 当前调到 8 —— 用户机器 8+ 核常见(M 系列、骁龙 8 Gen 2+),平台 native
/// ImageIO 内存友好,并发 8 同屏内存峰值可控。完整解码路径(长按预览 /
/// 大图)已经在 loadImage 内 bypass 这个 semaphore。
final _avifDecodeSemaphore = _Semaphore(8);
final _pendingThumbnailTasks = <String, Future<void>>{};
final _knownThumbnailKeys = <String>{};

/// MultiFrameAvifCodec 的 key 序列(Rust 端 decoder 注册表按 key 索引)。
int _avifCodecKeySeq = 0;

/// 平台(引擎内置)AVIF 解码是否已探明不可用。
///
/// 引擎的 ImageGeneratorRegistry 有平台兜底 codec:iOS 16+/macOS 13+ 走
/// ImageIO、Android 12+ 走 ImageDecoder,能直接解 AVIF;Windows/Linux/
/// 老系统没有。首次「引擎失败 + Rust 成功」(静态图)即断定平台不支持,
/// 后续不再白试(省一次 bytes 拷贝 + 探测异常)。
bool _avifPlatformCodecUnavailable = false;

/// 尝试用引擎内置 codec(平台兜底 ImageIO/ImageDecoder)解码 AVIF。
///
/// 成功返回 codec(已按 [maxDim] 做 decode-time 降采样 —— 解码器直接出
/// 小图,不经历"全尺寸 RGBA → GPU 缩放"),平台不支持/数据不认识返回 null。
///
/// 这条路解码全程在引擎 IO 线程,零主 isolate 拷贝;而 Rust FFI 路径每帧
/// 要在主 isolate 上做 protobuf 解析拷贝 + `Uint8List.fromList` +
/// `decodeImageFromPixels` 三次 MB 级搬运,静态大图首次解码卡顿的大头在此。
Future<ui.Codec?> _tryPlatformAvifCodec(Uint8List bytes, {int? maxDim}) async {
  ui.ImmutableBuffer? buffer;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    int? targetW, targetH;
    final w = descriptor.width, h = descriptor.height;
    if (maxDim != null && (w > maxDim || h > maxDim)) {
      // 只给长边,短边由引擎按宽高比推出
      if (w >= h) {
        targetW = maxDim;
      } else {
        targetH = maxDim;
      }
    }
    // 注意:codec 存活期间引用着 descriptor 的 generator,不能在这里
    // dispose descriptor(引擎自带的 instantiateImageCodecWithSize 同款
    // 处理 —— 只 dispose buffer,descriptor 随 codec 的 GC finalizer 走)。
    return await descriptor.instantiateCodec(
      targetWidth: targetW,
      targetHeight: targetH,
    );
  } catch (_) {
    return null;
  } finally {
    buffer?.dispose();
  }
}

/// ftyp box 的 major/compatible brands 是否含动画 brand(avis/msf1)。
///
/// 动画 AVIF 不走平台 codec:各平台对 avis 序列的支持参差(可能只解出
/// 首帧且不报错),静止退化肉眼难察觉;Rust 流式路径对动画工作正常。
bool _looksAnimatedAvif(Uint8List bytes) {
  if (bytes.length < 16) return false;
  // offset 4..8 应为 'ftyp'
  if (bytes[4] != 0x66 || bytes[5] != 0x74 || bytes[6] != 0x79 || bytes[7] != 0x70) {
    return false;
  }
  bool isAnimBrand(int o) {
    final b = String.fromCharCodes(bytes.sublist(o, o + 4)).toLowerCase();
    return b == 'avis' || b == 'msf1';
  }

  if (isAnimBrand(8)) return true; // major brand
  // compatible brands:16..ftyp box 末尾,4 字节一个
  final boxSize = (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  final end = boxSize.clamp(16, bytes.length);
  for (var o = 16; o + 4 <= end; o += 4) {
    if (isAnimBrand(o)) return true;
  }
  return false;
}

/// AVIF 图片 Provider
///
/// 通过 CacheManager 下载/缓存文件解码,两级 backend:
/// - 静态 AVIF → 引擎内置 codec(iOS 16+/macOS 13+ ImageIO、Android 12+
///   ImageDecoder;IO 线程解码 + decode-time 降采样,成本与 JPEG 同级)
/// - 动画 AVIF / 平台不支持 → flutter_avif(libavif + dav1d)流式逐帧
///
/// 支持单帧和多帧（动画）AVIF。
///
/// 当 [singleFrame] 且 [targetSize] 不为 null 时，走缩略图快速路径：
/// 首次解码后将缩放结果以 PNG 写入磁盘缓存，后续直接读取 PNG，
/// 完全绕过 AV1 解码，性能与普通 PNG 一致。
class AvifImageProvider extends ImageProvider<AvifImageProvider> {
  final String url;
  final double scale;

  /// 原文件所在 blob bucket(默认正文 content;贴纸场景传 stickerOriginal)。
  final String bucket;

  /// 只解码第一帧，不播放动画。用于缩略图网格等场景。
  final bool singleFrame;

  /// 缩略图目标像素尺寸（长边）。
  /// 仅在 [singleFrame] 为 true 时生效：首次解码后缩放并以 PNG 缓存，
  /// 后续直接读取缓存 PNG，不再触发 AV1 解码。
  final int? targetSize;

  /// 完整(动画)路径的帧尺寸上限(长边,物理像素)。解出的帧超过时
  /// GPU 缩放到该尺寸再 setImage —— AVIF 是自解码 provider,外层
  /// ResizeImage 的 targetSize 经 decode 回调传递、到不了 AV1 解码器,
  /// 不在这里自保护的话 4000px 级照片会全尺寸上传纹理(单帧 40MB+,
  /// raster 冻结 200ms 级)。2048 覆盖任何帖内显示宽度;查看器等
  /// 需要原图的场景显式传更大值或 null(不限制)。
  final int? maxDimension;

  const AvifImageProvider(
    this.url, {
    this.scale = 1.0,
    this.bucket = BlobImageCache.contentBucket,
    this.singleFrame = false,
    this.targetSize,
    this.maxDimension = 2048,
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
    String bucket = BlobImageCache.contentBucket,
  }) async {
    if (!isAvifUrl(url)) return;

    final thumbKey = _thumbnailCacheKey(url, targetSize);
    if (_knownThumbnailKeys.contains(thumbKey)) return;

    final cachedBytes = await _readCachedThumbnailBytes(thumbKey);
    if (cachedBytes != null) return;

    final pending = _pendingThumbnailTasks[thumbKey];
    if (pending != null) {
      await pending;
      return;
    }

    final task = _warmThumbnail(
      bucket: bucket,
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
      return OneFrameImageStreamCompleter(
        _loadThumbnail(key).catchError(_evictOnError(key)),
      );
    }
    // 完整动画路径:流式逐帧解码(不预解全帧),见 completer 注释
    return _AvifAnimatedImageStreamCompleter(
      codecFactory: () => _createCodec(key),
      scale: key.scale,
      singleFrame: key.singleFrame,
      maxDimension: key.maxDimension,
      onError: () {
        scheduleMicrotask(() {
          PaintingBinding.instance.imageCache.evict(key);
        });
      },
    );
  }

  /// 从 cache manager 拉 bytes 并初始化解码器。
  ///
  /// 静态 AVIF 优先平台 codec([_tryPlatformAvifCodec],IO 线程解码 +
  /// decode-time 降采样到 [maxDimension]);动画 / 平台不支持时回落
  /// Rust 增量解码 —— 优先 [AvifFastBridge](零拷贝帧桥,每帧免
  /// protobuf 解析 + 双重拷贝,且带 decode-time 降采样),桥不可用
  /// (理论上只有 web)才落官方 `MultiFrameAvifCodec`。
  static Future<fa.AvifCodec> _createCodec(AvifImageProvider key) async {
    final bytes = await BlobImageCache.fetch(key.bucket, key.url);
    if (!_avifPlatformCodecUnavailable && !_looksAnimatedAvif(bytes)) {
      final platformCodec =
          await _tryPlatformAvifCodec(bytes, maxDim: key.maxDimension);
      if (platformCodec != null) {
        return _PlatformAvifCodec(platformCodec);
      }
      // 静态 AVIF 平台解不了 → 断定平台无 AVIF 支持,后续不再白试。
      // (即使是文件损坏导致的误判,效果也只是回到全 Rust 现状。)
      _avifPlatformCodecUnavailable = true;
    }
    if (AvifFastBridge.available) {
      final codec = _FastAvifCodec(
        key: '${_avifCodecKeySeq++}',
        maxDim: key.maxDimension,
      );
      await codec.init(bytes);
      return codec;
    }
    final codec = fa.MultiFrameAvifCodec(
      key: _avifCodecKeySeq++,
      avifBytes: bytes,
    );
    await codec.ready();
    return codec;
  }

  /// 只解码第一帧并返回 [ui.Image]。
  ///
  /// 优先平台 codec(静态/动画通吃 —— 缩略图只要首帧,平台若解不了
  /// 动画序列会整体失败,自然回落),[maxDim] 传入时做 decode-time
  /// 降采样,解码器直接出小图,不经历"全尺寸 RGBA → GPU 缩放"。
  ///
  /// Rust 回落路径**不要用 `fa.decodeAvif`**:它把全部帧解完才返回 ——
  /// 50 帧动图 sticker = 50 次 AV1 解码 + 50 次主 isolate RGBA 拷贝 +
  /// 50 个 ui.Image,缩略图场景只留第 1 帧,其余全是浪费(这曾是
  /// "AVIF 单张 50-150ms"的大头)。这里用 MultiFrameAvifCodec 增量解
  /// 1 帧后立即 dispose Rust 端 decoder。
  static Future<ui.Image> decodeFirstFrame(
    Uint8List bytes, {
    int? maxDim,
  }) async {
    if (!_avifPlatformCodecUnavailable) {
      final platformCodec = await _tryPlatformAvifCodec(bytes, maxDim: maxDim);
      if (platformCodec != null) {
        try {
          final frame = await platformCodec.getNextFrame();
          return frame.image;
        } finally {
          platformCodec.dispose();
        }
      }
      if (!_looksAnimatedAvif(bytes)) {
        _avifPlatformCodecUnavailable = true;
      }
    }
    if (AvifFastBridge.available) {
      final key = 'ff${_avifCodecKeySeq++}';
      try {
        await AvifFastBridge.initDecoder(key, bytes);
        final frame = await AvifFastBridge.getNextFrame(key, maxDim: maxDim);
        return frame.image;
      } finally {
        unawaited(AvifFastBridge.disposeDecoder(key));
      }
    }
    final codec = fa.MultiFrameAvifCodec(
      key: _avifCodecKeySeq++,
      avifBytes: bytes,
    );
    try {
      await codec.ready();
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  }

  /// 加载失败时把错误 completer 从 ImageCache 踢出,下次 rebuild 自动重试,
  /// 避免一次网络抖动 / 解码失败导致同 key 永久裂图(NetworkImage 同款行为)。
  static Never Function(Object, StackTrace) _evictOnError(
    AvifImageProvider key,
  ) {
    return (Object e, StackTrace st) {
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      Error.throwWithStackTrace(e, st);
    };
  }

  // ==================== 缩略图路径 ====================

  Future<ImageInfo> _loadThumbnail(AvifImageProvider key) async {
    final thumbKey = _thumbnailCacheKey(key.url, key.targetSize!);

    // 快速路径：PNG 缓存命中 → 用 Flutter 内置 codec 解码（毫秒级）
    final cachedBytes = await _readCachedThumbnailBytes(thumbKey);
    if (cachedBytes != null) {
      return _decodeThumbnailBytes(cachedBytes, key.scale);
    }

    // 首次解码提前走预热逻辑，避免重复解码同一缩略图。
    await precacheThumbnail(
      key.url,
      targetSize: key.targetSize!,
      bucket: key.bucket,
    );
    final warmedBytes = await _readCachedThumbnailBytes(thumbKey);
    if (warmedBytes != null) {
      return _decodeThumbnailBytes(warmedBytes, key.scale);
    }

    // 缓存写入失败时兜底：仍然现场解码并显示，避免出现空白。
    final displayImage = await _decodeThumbnailImage(
      bucket: key.bucket,
      url: key.url,
      targetSize: key.targetSize!,
    );
    unawaited(_cacheThumbnail(thumbKey, displayImage));

    return ImageInfo(image: displayImage, scale: key.scale);
  }

  static Future<Uint8List?> _readCachedThumbnailBytes(
    String thumbKey,
  ) async {
    final bytes = await BlobImageCache.read(
      BlobImageCache.stickerThumbBucket,
      thumbKey,
    );
    if (bytes == null) return null;
    _knownThumbnailKeys.add(thumbKey);
    return bytes;
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
    required String bucket,
    required String url,
    required int targetSize,
    required String thumbKey,
  }) async {
    ui.Image? displayImage;
    try {
      displayImage = await _decodeThumbnailImage(
        bucket: bucket,
        url: url,
        targetSize: targetSize,
      );
      await _cacheThumbnail(thumbKey, displayImage);
      _knownThumbnailKeys.add(thumbKey);
    } finally {
      displayImage?.dispose();
    }
  }

  static Future<ui.Image> _decodeThumbnailImage({
    required String bucket,
    required String url,
    required int targetSize,
  }) async {
    await _avifDecodeSemaphore.acquire();
    ui.Image srcImage;
    try {
      final bytes = await BlobImageCache.fetch(bucket, url);
      // 只解第一帧 —— 缩略图不需要其余帧;maxDim 让平台 codec 在
      // decode-time 直接出 targetSize 小图(Rust 回落路径不认 maxDim,
      // 仍出全尺寸,由下面的 GPU 缩放兜底)
      srcImage = await AvifImageProvider.decodeFirstFrame(
        bytes,
        maxDim: targetSize,
      );
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

  static Future<void> _cacheThumbnail(String key, ui.Image image) async {
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData != null) {
        await BlobImageCache.write(
          BlobImageCache.stickerThumbBucket,
          key,
          byteData.buffer.asUint8List(),
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
  //
  // 完整动画(长按预览、大图查看)走 [_AvifAnimatedImageStreamCompleter]
  // 流式逐帧解码,不再用 `fa.decodeAvif` 全帧预解(N 帧 RGBA 全驻内存 +
  // 首帧延迟 = 全量解码时间)。这条路不走 [_avifDecodeSemaphore] ——
  // 否则 sticker grid 的 thumbnail 解码会把用户长按预览的请求挤在队列
  // 后面,长按预览感知慢;单张交互场景也不存在 batch 内存爆炸问题。

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AvifImageProvider &&
        other.url == url &&
        other.bucket == bucket &&
        other.scale == scale &&
        other.singleFrame == singleFrame &&
        other.targetSize == targetSize &&
        other.maxDimension == maxDimension;
  }

  @override
  int get hashCode =>
      Object.hash(url, bucket, scale, singleFrame, targetSize, maxDimension);

  @override
  String toString() => 'AvifImageProvider("$url", scale: $scale)';
}

/// 把引擎内置 [ui.Codec] 适配成 [fa.AvifCodec] 接口,喂给
/// [_AvifAnimatedImageStreamCompleter](静态 AVIF 平台解码路径)。
///
/// decode-time 降采样已在 instantiateCodec 时生效,出来的帧天然 ≤
/// maxDimension,completer 里的 GPU 缩放兜底不会触发。
class _PlatformAvifCodec implements fa.AvifCodec {
  _PlatformAvifCodec(this._codec);

  final ui.Codec _codec;

  @override
  int get frameCount => _codec.frameCount;

  @override
  int get durationMs => -1;

  @override
  Future<void> ready() async {}

  @override
  Future<fa.AvifFrameInfo> getNextFrame() async {
    final frame = await _codec.getNextFrame();
    return fa.AvifFrameInfo(image: frame.image, duration: frame.duration);
  }

  @override
  void dispose() => _codec.dispose();
}

/// [AvifFastBridge] 的 [fa.AvifCodec] 适配:Rust 增量解码(动画 AVIF /
/// 无平台 codec 的静态 AVIF),每帧零拷贝 + decode-time 降采样。
///
/// 与官方 `MultiFrameAvifCodec` 共用 Rust 端 decoder 注册表与调用契约,
/// 仅 Dart 桥不同(见 avif_fast_bridge.dart 头注释)。
class _FastAvifCodec implements fa.AvifCodec {
  _FastAvifCodec({required String key, this.maxDim}) : _key = key;

  final String _key;

  /// 帧长边上限,超限帧解码时直接降采样(替代 completer 的 GPU 缩放兜底)。
  final int? maxDim;

  int _frameCount = 1;
  double _durationSec = 0;

  @override
  int get frameCount => _frameCount;

  @override
  int get durationMs => (_durationSec * 1000).round();

  Future<void> init(Uint8List bytes) async {
    final info = await AvifFastBridge.initDecoder(_key, bytes);
    _frameCount = info.imageCount;
    _durationSec = info.durationSec;
  }

  @override
  Future<void> ready() async {}

  @override
  Future<fa.AvifFrameInfo> getNextFrame() async {
    final frame = await AvifFastBridge.getNextFrame(_key, maxDim: maxDim);
    return fa.AvifFrameInfo(image: frame.image, duration: frame.duration);
  }

  @override
  void dispose() {
    unawaited(AvifFastBridge.disposeDecoder(_key));
  }
}

/// AVIF 流式动画 Completer。
///
/// 与旧实现("`fa.decodeAvif` 全帧预解,Timer 轮播内存中的帧列表")的区别:
///
/// - **首帧立即显示**:容器解析完解出第 1 帧就 setImage,不等全量解码。
///   50 帧 512px 的 sticker 首帧延迟从"50 次 AV1 解码"降到 1 次。
/// - **内存只驻留当前帧**:逐帧 `getNextFrame` 按需解码(Rust 端到尾自动
///   回绕循环),不再 N 帧 RGBA 全驻内存(50 帧 ≈ 50 MB → ~1 MB)。
/// - **无监听时彻底释放**:flutter_avif 自带的 AvifImageStreamCompleter
///   从不调 `codec.dispose()`,Rust 端 decoder 注册表会随预览次数泄漏。
///   这里在最后一个 listener 移除时 dispose 解码器,重新监听时通过
///   [codecFactory] 重建(bytes 来自磁盘缓存,重建是毫秒级)。
class _AvifAnimatedImageStreamCompleter extends ImageStreamCompleter {
  _AvifAnimatedImageStreamCompleter({
    required Future<fa.AvifCodec> Function() codecFactory,
    required this.scale,
    this.singleFrame = false,
    this.maxDimension,
    VoidCallback? onError,
  })  : _codecFactory = codecFactory,
        _onError = onError;

  final Future<fa.AvifCodec> Function() _codecFactory;
  final double scale;

  /// 只播第一帧(provider 的 singleFrame 且无 targetSize 的场景)。
  final bool singleFrame;

  /// 帧尺寸上限(长边)。超限帧 GPU 缩放后 setImage,防全尺寸纹理上传。
  final int? maxDimension;

  /// 初始化 / 解帧失败时回调(provider 用它做 ImageCache evict)。
  final VoidCallback? _onError;

  fa.AvifCodec? _codec;
  bool _starting = false;
  Timer? _timer;

  /// 是否已交付过至少一帧。滚动冻结只拦**后续帧**:首帧要放行,否则
  /// 滚动中进入视口的图整个 busy 窗口(1s)只有占位,"加载很慢"的
  /// 观感大头;静态图(平台 codec/单帧)滚动中本来就允许首绘,口径对齐。
  bool _hasEmittedFrame = false;

  /// 暂停代号:每次 [_pause] 自增,使在途的异步解码结果作废。
  int _generation = 0;

  @override
  void addListener(ImageStreamListener listener) {
    final hadListeners = hasListeners;
    super.addListener(listener);
    if (!hadListeners) {
      _start();
    }
  }

  @override
  void removeListener(ImageStreamListener listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _pause();
    }
  }

  Future<void> _start() async {
    if (_codec != null || _starting) return;
    _starting = true;
    final gen = _generation;
    try {
      final codec = await _codecFactory();
      if (gen != _generation || !hasListeners) {
        // 等待初始化期间监听已撤销(预览关闭)
        codec.dispose();
        return;
      }
      _codec = codec;
      await _decodeAndEmitNext();
    } catch (error, stack) {
      _onError?.call();
      reportError(
        context: ErrorDescription(S.current.common_decodeAvif),
        exception: error,
        stack: stack,
      );
    } finally {
      _starting = false;
    }
  }

  Future<void> _decodeAndEmitNext() async {
    final codec = _codec;
    if (codec == null || !hasListeners) return;
    // 滚动繁忙时冻结动图:逐帧解码(native worker 线程)与每帧纹理
    // 上传(raster)在滚动中是持续负载 —— 生产 CPU 采样:动图楼滚动
    // 时匿名解码线程合计吃 40%+ 单核,raster 反复 50~200ms 大帧且
    // imageCache 零增量(动图帧不进缓存增量,是它的指纹)。冻结在
    // 当前帧、静默后恢复播放;滚动中肉眼无感,和首绘闸门口径一致。
    // 首帧除外:占位→首帧是一次性成本,拦它只会把"加载慢"拖满整个
    // busy 窗口。
    if (_hasEmittedFrame && ScrollBusySignal.isBusy) {
      _timer?.cancel();
      _timer = Timer(const Duration(milliseconds: 250), _decodeAndEmitNext);
      return;
    }
    final gen = _generation;

    final fa.AvifFrameInfo frame;
    try {
      frame = await codec.getNextFrame();
    } catch (error, stack) {
      if (gen != _generation) return; // 已暂停,decoder 已释放,静默退出
      _onError?.call();
      reportError(
        context: ErrorDescription(S.current.common_decodeAvif),
        exception: error,
        stack: stack,
      );
      return;
    }
    if (gen != _generation || !hasListeners) {
      frame.image.dispose();
      return;
    }

    // 超限帧缩到上限再交付:防原图级帧全尺寸上传纹理独占 raster
    var image = frame.image;
    final cap = maxDimension;
    if (cap != null && (image.width > cap || image.height > cap)) {
      final resized = await AvifImageProvider._resize(image, cap);
      image.dispose();
      if (gen != _generation || !hasListeners) {
        resized.dispose();
        return;
      }
      image = resized;
    }

    // setImage 接管 image 所有权(替换时基类会 dispose 旧帧)
    setImage(ImageInfo(image: image, scale: scale));
    _hasEmittedFrame = true;

    if (singleFrame || codec.frameCount <= 1) {
      // 静态图 / 单帧:不会再要帧,立即释放 Rust 端 decoder
      codec.dispose();
      _codec = null;
      return;
    }
    final delay = frame.duration.inMilliseconds > 0
        ? frame.duration
        : const Duration(milliseconds: 100);
    _timer?.cancel();
    _timer = Timer(delay, _decodeAndEmitNext);
  }

  void _pause() {
    _timer?.cancel();
    _timer = null;
    _generation++;
    _codec?.dispose();
    _codec = null;
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
