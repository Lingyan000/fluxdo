import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:native_animated_image/native_animated_image.dart'
    show NativeAnimatedImageProvider;
import 'avif_image_provider.dart';
export 'avif_image_provider.dart' show AvifImageProvider;
import 'blob_image_cache.dart';
export 'blob_image_cache.dart' show BlobImageCache, BlobImageProvider;
import 'dio_http_client.dart';
import 'throttled_cache_object_provider.dart';

/// 全部图片缓存 manager 的 cacheKey。
///
/// 同时是 sqlite 索引库文件名（ApplicationSupport/{key}.db）与缓存文件
/// 目录名（Temporary/{key}/）。migration v7 依赖此列表清理孤儿文件，
/// 新增 manager 时必须同步追加。
///
/// `emojiImageCache` 已退役(emoji 改走 [BlobImageCache] 零索引寻址,
/// migration v8 清理旧目录),字面量保留供迁移引用。
const List<String> kImageCacheKeys = [
  DiscourseCacheManager.key,
  kLegacyEmojiCacheKey,
  ExternalImageCacheManager.key,
  StickerCacheManager.key,
];

/// 旧 emoji 缓存的 cacheKey(仅供迁移/清理引用)。
const String kLegacyEmojiCacheKey = 'emojiImageCache';

/// Discourse 图片缓存管理器
///
/// 基于 flutter_cache_manager，使用 Dio 作为 HTTP 客户端，
/// 支持流式下载、Cookie 管理和 Cloudflare 验证
class DiscourseCacheManager extends CacheManager with ImageCacheManager {
  static const String key = 'discourseImageCache';
  static DiscourseCacheManager? _instance;

  factory DiscourseCacheManager() {
    _instance ??= DiscourseCacheManager._();
    return _instance!;
  }

  DiscourseCacheManager._() : super(
    Config(
      key,
      stalePeriod: const Duration(days: 7),
      maxNrOfCacheObjects: 500,
      repo: ThrottledCacheObjectProvider(databaseName: key),
      fileService: HttpFileService(httpClient: DioHttpClient()),
    ),
  );

  /// 内存级 URL 索引：记录已知存在于磁盘缓存中的 URL
  ///
  /// 避免每次 isImageCached / preloadImage 都查询磁盘缓存。
  /// 仅用于 "跳过已缓存" 的快速判断，不影响 CachedNetworkImage 自身的加载流程。
  final Set<String> _knownCachedUrls = {};

  /// 正在下载中的 URL，避免并发重复下载
  final Set<String> _pendingUrls = {};

  /// 获取图片的字节数据
  ///
  /// 优先从缓存获取，如果缓存不存在则下载
  /// 用于保存图片等需要原始字节数据的场景
  Future<Uint8List?> getImageBytes(String url) async {
    try {
      final file = await getSingleFile(url);
      _knownCachedUrls.add(url);
      return await file.readAsBytes();
    } catch (e) {
      debugPrint('[DiscourseCacheManager] Failed to get image bytes: $e');
      return null;
    }
  }

  /// 获取图片的缓存文件（如果存在）
  ///
  /// 仅返回已缓存的文件，不会触发下载
  Future<File?> getCachedFile(String url) async {
    try {
      final fileInfo = await getFileFromCache(url);
      if (fileInfo != null) {
        _knownCachedUrls.add(url);
        return fileInfo.file;
      }
      return null;
    } catch (e) {
      debugPrint('[DiscourseCacheManager] Failed to get cached file: $e');
      return null;
    }
  }

  /// 检查图片是否已缓存
  Future<bool> isImageCached(String url) async {
    // 先查内存索引，命中则跳过磁盘查询
    if (_knownCachedUrls.contains(url)) return true;

    try {
      final fileInfo = await getFileFromCache(url);
      if (fileInfo != null) {
        _knownCachedUrls.add(url);
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// 预加载图片到缓存
  ///
  /// 用于预加载画廊中的相邻图片
  Future<void> preloadImage(String url) async {
    // 内存索引快速跳过已缓存 URL，避免磁盘查询
    if (_knownCachedUrls.contains(url)) return;
    // 避免并发重复下载同一 URL
    if (_pendingUrls.contains(url)) return;

    _pendingUrls.add(url);
    try {
      // downloadFile 内部会先查缓存再决定是否下载
      await downloadFile(url);
      _knownCachedUrls.add(url);
    } catch (e) {
      debugPrint('[DiscourseCacheManager] Failed to preload image: $e');
    } finally {
      _pendingUrls.remove(url);
    }
  }

  /// 预加载多张图片
  Future<void> preloadImages(List<String> urls) async {
    for (final url in urls) {
      preloadImage(url);
    }
  }
}

/// 通用外部图片缓存管理器
///
/// 用于第三方服务的图片（如 mermaid.ink、GitHub 等）
/// 使用默认 HTTP 客户端，不需要 Discourse 认证
class ExternalImageCacheManager extends CacheManager with ImageCacheManager {
  static const String key = 'externalImageCache';
  static ExternalImageCacheManager? _instance;

  factory ExternalImageCacheManager() {
    _instance ??= ExternalImageCacheManager._();
    return _instance!;
  }

  ExternalImageCacheManager._() : super(
    Config(
      key,
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 200,
      repo: ThrottledCacheObjectProvider(databaseName: key),
    ),
  );
}

/// 表情包（Sticker）专用缓存管理器
///
/// 与 emoji / 内容图片分离，使用 DioHttpClient 携带 Sec-CH-UA 等请求头。
/// 表情包图片体积较大、数量多，独立缓存避免互相淘汰。
class StickerCacheManager extends CacheManager with ImageCacheManager {
  static const String key = 'stickerImageCache';
  static StickerCacheManager? _instance;

  factory StickerCacheManager() {
    _instance ??= StickerCacheManager._();
    return _instance!;
  }

  StickerCacheManager._() : super(
    Config(
      key,
      // 用户订阅 10+ group(每 group 100-300 张),原图 + thumbnail PNG
      // 双 entry,2000 上限 = 1000 张 unique sticker 就满,远不够。
      // 90 天 + 20000 容量,基本覆盖订阅多 group 的实际用量。
      stalePeriod: const Duration(days: 90),
      maxNrOfCacheObjects: 20000,
      repo: ThrottledCacheObjectProvider(databaseName: key),
      fileService: HttpFileService(httpClient: DioHttpClient()),
    ),
  );
}

/// 检查 URL 是否指向 AVIF 图片
bool _isAvifUrl(String url) {
  try {
    final path = Uri.parse(url).path.toLowerCase();
    return path.endsWith('.avif');
  } catch (_) {
    return false;
  }
}

/// 检查 URL 是否指向需要走 native 解码器的动图(GIF / APNG / 动画 WebP)
///
/// 走 native_animated_image 的 Rust pipeline,绕开 Flutter Skia
/// multi_frame_codec 的 #85831 bug。
bool isNativeAnimatedUrl(String url) => _isNativeAnimatedUrl(url);

bool _isNativeAnimatedUrl(String url) {
  try {
    final path = Uri.parse(url).path.toLowerCase();
    // .gif 一定走 native(Skia 在某些 disposal 组合下会失败)
    // .apng / .webp 也走 native(后续 Rust 端补全解码器)
    return path.endsWith('.gif') ||
        path.endsWith('.apng') ||
        path.endsWith('.webp');
  } catch (_) {
    return false;
  }
}

/// 创建 Discourse 图片 Provider
///
/// 用于需要 ImageProvider 的场景（CircleAvatar、DecorationImage 等）
/// - AVIF URL → AvifImageProvider (flutter_avif libavif + dav1d)
/// - GIF / APNG / 动画 WebP → NativeAnimatedImageProvider (Rust pipeline,
///   绕 Skia multi_frame_codec 的 #85831 bug)
/// - 其他静态格式 → CachedNetworkImageProvider
///
/// 需要限制解码尺寸时在外层包 decode-time 的 `ResizeImage(policy: fit)`。
/// 刻意不透传 CachedNetworkImageProvider 的 maxWidth/maxHeight —— 那走
/// flutter_cache_manager 的 resize 路径:webp 不在 supportedFileNames 里
/// 静默原图返回,jpg/png 解码后 PNG 重编码再写第二份磁盘缓存。
ImageProvider discourseImageProvider(String url, {double scale = 1.0}) {
  if (_isAvifUrl(url)) {
    return AvifImageProvider(url, scale: scale);
  }
  if (_isNativeAnimatedUrl(url)) {
    final cache = DiscourseCacheManager();
    return NativeAnimatedImageProvider.fromBytesProvider(
      loader: () async {
        final bytes = await cache.getImageBytes(url);
        if (bytes == null || bytes.isEmpty) {
          throw Exception('NativeAnimatedImageProvider: empty bytes for $url');
        }
        return bytes;
      },
      tag: url,
      scale: scale,
    );
  }
  return CachedNetworkImageProvider(
    url,
    scale: scale,
    cacheManager: DiscourseCacheManager(),
  );
}

/// 创建 Emoji 图片 Provider
///
/// 走 [BlobImageCache](Telegram 式 MD5 确定性寻址,零 sqlite 索引)。
/// emoji 全集实测 100% 静态 PNG,单一路径即可;64px 目标尺寸走解码
/// 闸门的小图旁路,由引擎 worker 池并行解码。
ImageProvider emojiImageProvider(String url, {double scale = 1.0}) {
  return BlobImageProvider(
    url,
    bucket: BlobImageCache.emojiBucket,
    scale: scale,
  );
}

/// 创建表情包（Sticker）图片 Provider
///
/// 使用独立的 [StickerCacheManager]，AVIF URL 自动使用 AvifImageProvider 解码
ImageProvider stickerImageProvider(String url, {double scale = 1.0}) {
  if (_isAvifUrl(url)) {
    return AvifImageProvider(url, scale: scale, cacheManager: StickerCacheManager());
  }
  return CachedNetworkImageProvider(
    url,
    scale: scale,
    cacheManager: StickerCacheManager(),
  );
}
