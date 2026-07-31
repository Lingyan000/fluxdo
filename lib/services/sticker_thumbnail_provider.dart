import 'dart:async';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:native_animated_image/native_animated_image.dart'
    show NativeAnimatedImageFfi, NativeAnimatedImageException;

import 'avif_image_provider.dart';
import 'blob_image_cache.dart';

// 与 native_animated_image 内部定义的错误码保持一致(Rust 端 ERR_UNSUPPORTED = -2),
// dart 端没单独 export 这个常量,我们直接复用数字 — 这是 stable FFI contract。
const int _kErrUnsupported = -2;

/// 按 magic bytes 判断是不是 AVIF(ISO BMFF `ftyp` box,brand avif/avis/mif1/msf1)。
///
/// 必须用 magic 而不是 URL 后缀分流:Discourse / CDN 可能给 `.gif` `.webp` 后缀
/// 的 URL 实际内容是 AVIF,这种情况 URL 分流会让 AVIF bytes 进 Rust pipeline,
/// 内部 magic bytes dispatch 会送到 zenavif (rav1d-safe),触发 ARM SIMD panic
/// (mc_arm.rs:5905)整个 app crash。
bool _bytesLookLikeAvif(Uint8List bytes) {
  if (bytes.length < 12) return false;
  // 'ftyp' at offset 4
  if (bytes[4] != 0x66 || bytes[5] != 0x74 || bytes[6] != 0x79 || bytes[7] != 0x70) {
    return false;
  }
  // brand at 8..12: avif | avis | mif1 | msf1
  final b8 = bytes[8], b9 = bytes[9], b10 = bytes[10], b11 = bytes[11];
  // 'avif'
  if (b8 == 0x61 && b9 == 0x76 && b10 == 0x69 && b11 == 0x66) return true;
  // 'avis'
  if (b8 == 0x61 && b9 == 0x76 && b10 == 0x69 && b11 == 0x73) return true;
  // 'mif1'
  if (b8 == 0x6D && b9 == 0x69 && b10 == 0x66 && b11 == 0x31) return true;
  // 'msf1'
  if (b8 == 0x6D && b9 == 0x73 && b10 == 0x66 && b11 == 0x31) return true;
  return false;
}

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
    this.bucket = BlobImageCache.stickerOriginalBucket,
  });

  /// 主动 cancel 所有 in-flight thumbnail decode。
  ///
  /// sticker panel dispose 时调用。Bumps 一个 generation counter,
  /// `_decodeFirstFrameImage` 内的多个 await 检查点会发现 mismatch 立即抛
  /// `_ThumbnailCancelled` 退出 —— 排队中的解码任务全部作废,panel 关闭后
  /// 不再占用解码资源。已经在跑的单张解码不可中断,但跑完即停。
  static void cancelInflight() {
    _bumpThumbnailGeneration();
  }

  final String url;

  /// 缩略图目标像素尺寸(长边)。首次解码后缩放到这个尺寸再存 PNG。
  final int targetSize;

  final double scale;

  /// 原文件所在 blob bucket(贴纸默认 stickerOriginal)。
  final String bucket;

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

  /// 批量预热缩略图缓存(sticker 面板打开时一次性 30 张这种场景)。
  ///
  /// 关键优化:把 30 个 `Isolate.run` 调用换成 chunked batch(默认 8 张一组),
  /// spawn 开销从 30× 摊到 ~4×。每个 chunk 之前调一次 [shouldContinue],
  /// 用户切组 / 关 panel 时立即停下后续 chunk,避免无效 CPU。
  ///
  /// 已在 cache 或正在解的 URL 自动跳过,主 isolate 只做轻量 IO + ui.Image 创建。
  static Future<void> precacheBatch(
    List<String> urls, {
    required int targetSize,
    String bucket = BlobImageCache.stickerOriginalBucket,
    bool Function()? shouldContinue,
  }) async {
    // 全程流水线:每张图「下载 → magic 分流 → 解码 → 写缩略图」独立
    // 链式推进,不再是"全部下载完才开始解码"的两段式 —— 旧形态下载
    // 串行(30 张 × 数百 ms = 十几秒)且总时长 = 下载总和 + 解码总和;
    // 现在下载并发由 sticker 通道(3 槽)限,解码并发由 AVIF(4)/
    // 非 AVIF worker pool 各自限,总时长 ≈ max(下载, 解码)。
    //
    // 分流关键不变:用**实际 magic bytes** 而不是 URL 后缀。CDN 给的
    // .gif/.webp URL 实际内容可能是 AVIF,后缀分流会让 AVIF bytes 进
    // Rust → crash。
    //
    // shouldContinue 在每张的下载前与解码前各检查一次,切组/关 panel
    // 后在途任务自然收敛(已发起的单张下载/解码不可中断,跑完即停)。
    Future<void> one(String url) async {
      if (!supports(url)) return;
      final thumbKey = _thumbnailCacheKey(url, targetSize);
      if (_knownThumbnailKeys.contains(thumbKey)) return;
      if (_pendingThumbnailTasks.containsKey(thumbKey)) return;
      if (shouldContinue != null && !shouldContinue()) return;

      try {
        final cachedBytes = await _readCachedThumbnailBytes(thumbKey);
        if (cachedBytes != null) return;

        final bytes = await BlobImageCache.fetch(bucket, url);
        if (shouldContinue != null && !shouldContinue()) return;

        if (_bytesLookLikeAvif(bytes)) {
          // AVIF → precache(_pendingThumbnailTasks 去重,与 grid 现场
          // 解码互不重复;_avifSemaphore(4) 限流)
          await precache(url, targetSize: targetSize, bucket: bucket);
        } else {
          // 非 AVIF → Rust worker pool(池内并发限流)
          final reply = await _DecoderWorkerPool.instance.decode(bytes);
          if (reply == null) return;
          if (shouldContinue != null && !shouldContinue()) return;
          await _writeThumbnailFromRustOrFallback(
            url: url,
            bytes: bytes,
            reply: reply,
            targetSize: targetSize,
          );
        }
      } on _ThumbnailCancelled {
        // 面板关闭触发的取消,静默
      } catch (e) {
        debugPrint('[StickerThumbnail] prefetch failed $url: $e');
      }
    }

    await Future.wait([for (final url in urls) one(url)]);
  }

  static Future<void> _writeThumbnailFromRustOrFallback({
    required String url,
    required Uint8List bytes,
    required _DecodeReply reply,
    required int targetSize,
  }) async {
    ui.Image? srcImage;
    try {
      if (reply.rgba != null) {
        srcImage = await _rgbaToUiImage(reply.rgba!, reply.width, reply.height);
      } else if (reply.unsupported) {
        // Rust 不识别 → Flutter codec(静态 webp / png / jpeg)
        try {
          srcImage = await _decodeFirstFrameViaFlutterCodec(bytes);
        } catch (e) {
          debugPrint('[StickerThumbnail] both decoders failed $url: $e');
          return;
        }
      } else {
        // decode error or cancelled
        return;
      }
      final displayImage =
          (srcImage.width > targetSize || srcImage.height > targetSize)
              ? await _resize(srcImage, targetSize)
              : srcImage;
      await _cacheThumbnail(
        _thumbnailCacheKey(url, targetSize),
        displayImage,
      );
      _knownThumbnailKeys.add(_thumbnailCacheKey(url, targetSize));
      if (displayImage != srcImage) displayImage.dispose();
    } finally {
      srcImage?.dispose();
    }
  }

  /// 单 URL 预热(已 cache 立即 short-circuit;in-flight 等同一个 future)。
  ///
  /// 用于用户实际访问 + 没命中 batch prefetch 的 cache miss 路径。
  static Future<void> precache(
    String url, {
    required int targetSize,
    String bucket = BlobImageCache.stickerOriginalBucket,
  }) async {
    if (!supports(url)) return;

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
  Future<StickerThumbnailProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<StickerThumbnailProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    StickerThumbnailProvider key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      _loadThumbnail(key).catchError((Object e, StackTrace st) {
        // 失败的 completer 不能留在 ImageCache —— 否则同 key 的后续 Image
        // 直接复用错误结果,永久裂图直到重启(NetworkImage 官方实现同款 evict)。
        // evict 后下次 rebuild 自动重试;面板关闭触发的 _ThumbnailCancelled
        // 也走这里,重开面板即重解。
        scheduleMicrotask(() {
          PaintingBinding.instance.imageCache.evict(key);
        });
        Error.throwWithStackTrace(e, st);
      }),
    );
  }

  Future<ImageInfo> _loadThumbnail(StickerThumbnailProvider key) async {
    final thumbKey = _thumbnailCacheKey(key.url, key.targetSize);

    // 快速路径:PNG 缓存命中 → Flutter 内置 PNG codec(毫秒级)
    final cachedBytes = await _readCachedThumbnailBytes(thumbKey);
    if (cachedBytes != null) {
      return _decodeThumbnailBytes(cachedBytes, key.scale);
    }

    // 首次解码走预热,避免重复
    await precache(
      key.url,
      targetSize: key.targetSize,
      bucket: key.bucket,
    );
    final warmedBytes = await _readCachedThumbnailBytes(thumbKey);
    if (warmedBytes != null) {
      return _decodeThumbnailBytes(warmedBytes, key.scale);
    }

    // 缓存写入失败兜底:现场解 + 显示,不让用户看到空白
    final displayImage = await _decodeFirstFrameImage(
      bucket: key.bucket,
      url: key.url,
      targetSize: key.targetSize,
    );
    unawaited(_cacheThumbnail(thumbKey, displayImage));
    return ImageInfo(image: displayImage, scale: key.scale);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is StickerThumbnailProvider &&
        other.url == url &&
        other.bucket == bucket &&
        other.targetSize == targetSize &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(url, bucket, targetSize, scale);

  @override
  String toString() =>
      'StickerThumbnailProvider("$url", targetSize: $targetSize)';
}

// ==================== Internal helpers ====================

/// AVIF 解码并发。
///
/// flutter_avif 3.x 是 **FFI + native port 异步**:AV1 解码跑在 native
/// 线程,主 isolate 只承担"单帧 RGBA 解包 + decodeImageFromPixels"
/// (配合 [AvifImageProvider.decodeFirstFrame] 单帧解码,每张就一次,
/// 毫秒级)。早期"method channel 全帧 marshal 阻塞主线程必须限 1 并发"
/// 的约束已不存在,放开到 4 让首开 30 张 AVIF 从串行 3-9s 变成秒级。
final _avifSemaphore = _Semaphore(4);

/// 非 AVIF (GIF / WebP / APNG) 解码并发。decode 走 `_DecoderWorkerPool`
/// (long-lived worker isolate)在后台串行,主 isolate 只做轻量 ui.Image
/// 创建,可以放开并发到 8。
///
/// 关键:跟 AVIF 用**独立** semaphore,AVIF 慢不会阻塞 GIF/WebP/APNG 解码。
final _nonAvifSemaphore = _Semaphore(8);

/// in-flight prefetch task,去重避免重复解
final _pendingThumbnailTasks = <String, Future<void>>{};

/// 已知 PNG cache 命中(进程级 in-memory 索引,跳过磁盘查询)
final _knownThumbnailKeys = <String>{};

/// 生成号 — 每次 [StickerThumbnailProvider.cancelInflight] 调用 ++,
/// `_decodeFirstFrameImage` 内部 await 链的多个检查点都 captures 起始号,
/// 任意 await 后比对发现 mismatch → throw 立即 abort。
///
/// 关键场景:用户打开 sticker panel,30 张缩略图同时 enqueue 排队解码。
/// 用户 0.5s 内关闭 panel,还在排队的 task 应该立即作废,不再占用解码
/// 资源(否则"关闭面板还在后台解码")。已经在跑的单张解码不可中断,
/// 但跑完即停。
int _thumbnailGeneration = 0;

/// 主动 cancel 当前所有 in-flight thumbnail decode。
/// `_decodeFirstFrameImage` 内部检查 generation,mismatch 即 throw 退出。
void _bumpThumbnailGeneration() {
  _thumbnailGeneration++;
}

class _ThumbnailCancelled implements Exception {
  const _ThumbnailCancelled();
  @override
  String toString() => 'sticker thumbnail decode cancelled';
}

String _thumbnailCacheKey(String url, int targetSize) {
  return 'sticker_thumb:$targetSize:$url';
}

/// 缩略图 PNG 走 [BlobImageCache](零 sqlite 寻址):30 张同屏的 grid
/// 场景下,cache_manager 的每 key 一次 SELECT 是纯浪费。原图字节仍走
/// cache manager(下载进度/大文件语义)。
Future<Uint8List?> _readCachedThumbnailBytes(String thumbKey) async {
  final bytes = await BlobImageCache.read(
    BlobImageCache.stickerThumbBucket,
    thumbKey,
  );
  if (bytes == null) return null;
  _knownThumbnailKeys.add(thumbKey);
  return bytes;
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
  required String bucket,
  required String url,
  required int targetSize,
  required String thumbKey,
}) async {
  ui.Image? displayImage;
  try {
    displayImage = await _decodeFirstFrameImage(
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

/// 从 cache 拿 bytes → backend dispatch 解第一帧 → 必要时缩放到 targetSize。
///
/// 用 magic bytes 决定走 AVIF semaphore 还是非 AVIF semaphore。两者**独立**
/// 限流,AVIF 慢不阻塞 GIF/WebP/APNG。
Future<ui.Image> _decodeFirstFrameImage({
  required String bucket,
  required String url,
  required int targetSize,
}) async {
  final startGen = _thumbnailGeneration;
  void checkCancel() {
    if (_thumbnailGeneration != startGen) throw const _ThumbnailCancelled();
  }

  // 先把 bytes 拉出来,根据 magic 选 semaphore(不能用 URL 后缀 — CDN 可能
  // 给 `.gif/.webp` 后缀但实际是 AVIF)。bytes 读取本身是 IO async,不占
  // semaphore 配额。
  final bytes = await BlobImageCache.fetch(bucket, url);
  checkCancel();

  final isAvif = _bytesLookLikeAvif(bytes);
  final semaphore = isAvif ? _avifSemaphore : _nonAvifSemaphore;

  await semaphore.acquire();
  // 拿到 semaphore 槽后再检查 — 关 panel 后排队中的任务在这里立即
  // release 槽 + abort,不再发起新的解码;已经在跑的解码跑完即停。
  try {
    checkCancel();
  } catch (e) {
    semaphore.release();
    rethrow;
  }
  ui.Image srcImage;
  try {
    srcImage = await _decodeFirstFrame(url, bytes, targetSize: targetSize);
  } finally {
    semaphore.release();
  }
  checkCancel();

  if (srcImage.width > targetSize || srcImage.height > targetSize) {
    final resized = await _resize(srcImage, targetSize);
    srcImage.dispose();
    return resized;
  }
  return srcImage;
}

/// 解第一帧。按**实际 magic bytes** dispatch backend:
///
/// - **AVIF**(magic ftyp/avif/avis/mif1/msf1):走 `flutter_avif`(libavif + dav1d,
///   C 实现,工业标准稳定)。不进 native_animated_image 的 Rust pipeline。
///
/// - **GIF / animated WebP / APNG**:走 [_DecoderWorkerPool](long-lived worker
///   isolate),解码在 background isolate 串行,**主线程零 spawn 开销**。
///
/// - **其它 / 静态格式**:worker 返 unsupported → Flutter 内置 codec fallback。
Future<ui.Image> _decodeFirstFrame(
  String url,
  Uint8List bytes, {
  int? targetSize,
}) async {
  // 必须按 magic 判,不能信 URL 后缀(CDN 可能给 .webp/.gif 后缀但实际是 AVIF)
  if (_bytesLookLikeAvif(bytes)) {
    return _decodeAvifFirstFrame(bytes, url, targetSize: targetSize);
  }

  final reply = await _DecoderWorkerPool.instance.decode(bytes);
  if (reply == null) {
    throw StateError('decode cancelled: $url');
  }
  if (reply.unsupported) {
    return _decodeFirstFrameViaFlutterCodec(bytes);
  }
  if (reply.rgba == null) {
    throw StateError('decode failed: $url (${reply.error})');
  }
  return _rgbaToUiImage(reply.rgba!, reply.width, reply.height);
}

Future<ui.Image> _decodeAvifFirstFrame(
  Uint8List bytes,
  String url, {
  int? targetSize,
}) async {
  // 平台 codec 可用时 targetSize 直接 decode-time 降采样出小图;
  // Rust 回落 = 增量解码:只解第 1 帧立即 dispose,不像 fa.decodeAvif
  // 全帧解完丢 N-1 帧
  return AvifImageProvider.decodeFirstFrame(bytes, maxDim: targetSize);
}

/// Flutter 内置 codec fallback:Rust pipeline 不识别的格式走这条
/// (主要是静态 webp / png / jpeg)。只取第一帧,丢弃多余 codec 资源。
Future<ui.Image> _decodeFirstFrameViaFlutterCodec(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final codec = await ui.instantiateImageCodecFromBuffer(buffer);
  try {
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec.dispose();
  }
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

Future<void> _cacheThumbnail(String key, ui.Image image) async {
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

// ==================== Long-lived decoder worker isolate ====================
//
// 之前每张 sticker decode 走一次 `Isolate.run`(每次都 spawn 新 isolate),
// 30 张同屏 sticker = 30 次 spawn,主线程几百到上千 ms 卡顿。
//
// 这里改成 long-lived worker:进程内 spawn 一次,所有 thumbnail decode 走它,
// 主 isolate 通过 SendPort 派任务、ReceivePort 收结果。worker 串行处理
// (decode 本身 CPU-bound,worker 内并行无意义)。spawn 开销摊到 ~1 次,
// 后续 0 isolate spawn。
//
// Cancel:主 isolate 维护 `pending<taskId, Completer>`。`cancelToken` 触发
// 时立即从 pending 移除并 complete null。worker 完成的 reply 如果 taskId
// 已不在 pending,直接丢弃 — worker 任务不可真正中断(Rust FFI 是 sync),
// 但主 isolate 的"无效结果"路径会立即停止,不污染 ImageCache、不占主
// isolate 后续工作。

class _DecodeReply {
  const _DecodeReply.ok(this.width, this.height, this.rgba)
      : error = null,
        unsupported = false;
  const _DecodeReply.unsupported()
      : width = 0,
        height = 0,
        rgba = null,
        error = null,
        unsupported = true;
  const _DecodeReply.err(this.error)
      : width = 0,
        height = 0,
        rgba = null,
        unsupported = false;

  final int width;
  final int height;
  final Uint8List? rgba;
  final Object? error;
  final bool unsupported;
}

/// Token 用于取消正在 enqueue 或正在跑的 decode 任务。
/// 当 [isCancelled] 为 true 时,pool 会立即从 pending 移除该 task,
/// worker 完成结果也会被丢弃。
class _CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class _DecoderWorkerPool {
  _DecoderWorkerPool._();
  static final _DecoderWorkerPool instance = _DecoderWorkerPool._();

  /// worker 条数。旧值 1 的注释是"decode CPU-bound,worker 内并行无意义"
  /// —— 对单核成立,对现代 8+ 核机器不成立:1 条 isolate 串行吃 30 张
  /// GIF/WebP,其余核全闲。3 条对齐 AVIF 侧 _avifSemaphore(4) 的量级,
  /// 冷开面板解码段 ≈ 1/3;spawn 仍是一次性成本(long-lived)。
  static const int _workerCount = 3;

  final List<SendPort> _sendPorts = [];
  Future<void>? _initFuture;
  int _nextTaskId = 0;
  int _nextWorker = 0;
  final Map<int, Completer<_DecodeReply>> _pending = {};

  Future<void> _ensureInit() {
    if (_sendPorts.length == _workerCount) return Future.value();
    if (_initFuture != null) return _initFuture!;
    final completer = Completer<void>();
    _initFuture = completer.future;
    final receivePort = ReceivePort();
    receivePort.listen((dynamic msg) {
      if (msg is SendPort) {
        _sendPorts.add(msg);
        if (_sendPorts.length == _workerCount && !completer.isCompleted) {
          completer.complete();
        }
        return;
      }
      if (msg is List && msg.length == 2 && msg[0] is int) {
        final taskId = msg[0] as int;
        final reply = msg[1] as _DecodeReply;
        final pending = _pending.remove(taskId);
        // pending 为 null 表示已被 cancel,丢弃结果
        if (pending != null) pending.complete(reply);
      }
    });
    for (var i = 0; i < _workerCount; i++) {
      Isolate.spawn<SendPort>(_decoderWorkerEntry, receivePort.sendPort,
              debugName: 'StickerThumbnailWorker#$i')
          .then((_) {});
    }
    return completer.future;
  }

  /// 提交一个 decode 任务(round-robin 派给某条 worker,各自串行)。
  /// 如果在解码过程中 [token] 被 cancel,Future 立即 complete `_DecodeReply.err`
  /// (用 sentinel 错误),后续 ui.Image 创建会被跳过。
  Future<_DecodeReply?> decode(
    Uint8List bytes, {
    _CancelToken? token,
  }) async {
    await _ensureInit();
    if (token != null && token.isCancelled) return null;
    final taskId = _nextTaskId++;
    final completer = Completer<_DecodeReply>();
    _pending[taskId] = completer;
    _sendPorts[_nextWorker].send([taskId, bytes]);
    _nextWorker = (_nextWorker + 1) % _sendPorts.length;

    if (token != null) {
      // 监听 cancel:如果在等待期间 token 被 cancel,主动从 pending 移除
      // (worker 完成的 reply 会因为 taskId 不在 pending 而被丢弃)
      Future.microtask(() async {
        while (!completer.isCompleted) {
          if (token.isCancelled) {
            final pending = _pending.remove(taskId);
            if (pending != null && !pending.isCompleted) {
              pending.complete(const _DecodeReply.err('cancelled'));
            }
            return;
          }
          await Future.delayed(const Duration(milliseconds: 50));
        }
      });
    }

    return completer.future;
  }
}

/// Worker isolate 入口。
@pragma('vm:entry-point')
void _decoderWorkerEntry(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  receivePort.listen((dynamic msg) {
    if (msg is! List || msg.length != 2) return;
    final taskId = msg[0] as int;
    final bytes = msg[1] as Uint8List;
    try {
      final decoded = NativeAnimatedImageFfi.instance.decode(bytes);
      if (decoded.frames.isEmpty) {
        mainSendPort.send([taskId, const _DecodeReply.err('empty')]);
        return;
      }
      final first = decoded.frames.first;
      mainSendPort.send(
        [taskId, _DecodeReply.ok(decoded.width, decoded.height, first.rgba)],
      );
    } on NativeAnimatedImageException catch (e) {
      if (e.code == _kErrUnsupported) {
        mainSendPort.send([taskId, const _DecodeReply.unsupported()]);
      } else {
        mainSendPort.send([taskId, _DecodeReply.err(e)]);
      }
    } catch (e) {
      mainSendPort.send([taskId, _DecodeReply.err(e)]);
    }
  });
}
