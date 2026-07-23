import 'package:flutter/painting.dart';
import 'package:native_animated_image/native_animated_image.dart'
    show NativeAnimatedImageProvider;
import 'avif_image_provider.dart';
export 'avif_image_provider.dart' show AvifImageProvider;
import 'blob_image_cache.dart';
export 'blob_image_cache.dart' show BlobImageCache, BlobImageProvider;
import 'dio_http_client.dart' show DownloadPriority;
export 'dio_http_client.dart' show DownloadPriority;

/// 旧 flutter_cache_manager 时代的缓存 cacheKey(2026-07 全量退役,
/// 仅供迁移 v7/v8/v9 清理旧目录与 db 引用)。
///
/// 当时每个 key 同时是 sqlite 索引库文件名(ApplicationSupport/{key}.db)
/// 与缓存文件目录名(Temporary/{key}/)。现全部图片走 [BlobImageCache]
/// 零索引寻址。
const List<String> kLegacyImageCacheKeys = [
  'discourseImageCache',
  kLegacyEmojiCacheKey,
  'externalImageCache',
  'stickerImageCache',
];

/// 旧 emoji 缓存的 cacheKey(仅供迁移/清理引用)。
const String kLegacyEmojiCacheKey = 'emojiImageCache';

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
/// - 其他静态格式 → BlobImageProvider(content bucket,零 sqlite 寻址)
///
/// 需要限制解码尺寸时在外层包 decode-time 的 `ResizeImage(policy: fit)`。
ImageProvider discourseImageProvider(
  String url, {
  double scale = 1.0,
  String bucket = BlobImageCache.contentBucket,
  DownloadPriority priority = DownloadPriority.normal,
}) {
  if (_isAvifUrl(url)) {
    return AvifImageProvider(url, scale: scale, bucket: bucket);
  }
  if (_isNativeAnimatedUrl(url)) {
    return NativeAnimatedImageProvider.fromBytesProvider(
      loader: () => BlobImageCache.fetch(bucket, url, priority: priority),
      tag: url,
      scale: scale,
    );
  }
  return BlobImageProvider(
    url,
    bucket: bucket,
    scale: scale,
    priority: priority,
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
/// 原文件走 stickerOriginal bucket;AVIF URL 自动使用 AvifImageProvider 解码
ImageProvider stickerImageProvider(String url, {double scale = 1.0}) {
  if (_isAvifUrl(url)) {
    return AvifImageProvider(
      url,
      scale: scale,
      bucket: BlobImageCache.stickerOriginalBucket,
    );
  }
  return BlobImageProvider(
    url,
    bucket: BlobImageCache.stickerOriginalBucket,
    scale: scale,
  );
}
