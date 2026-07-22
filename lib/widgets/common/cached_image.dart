import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:native_animated_image/native_animated_image.dart'
    show NativeAnimatedImageProvider;

import '../../services/blob_image_cache.dart';
import '../../services/discourse_cache_manager.dart';
import '../../services/sticker_thumbnail_provider.dart';

/// 统一的缓存网络图片组件
///
/// 自动按 URL 后缀 + 是否有 target size 选 backend:
///
/// **有 [memCacheWidth] / [memCacheHeight] 的 sticker 场景**(grid thumbnail):
/// - `.avif` / `.gif` / `.webp` / `.apng` → [StickerThumbnailProvider]
///   首次解码 → 缩放 → PNG cache → 后续直接 Flutter 内置 PNG codec
///   (毫秒级,完全跳过 AV1 / GIF disposal 等慢路径)
///
/// **没 target size 的完整动画场景**(长按预览 / 大图查看):
/// - `.avif` → [AvifImageProvider] 完整动画 path
/// - `.gif` / `.webp` / `.apng` → [NativeAnimatedImageProvider]
///   (Rust pipeline,绕开 Skia multi_frame_codec 的 #85831 bug)
///
/// **静态图**(PNG / JPEG):
/// - 走 [CachedNetworkImageProvider] + 可选 [ResizeImage]
///
/// 直接使用 Flutter [Image] + [frameBuilder],不依赖 OctoImage,
/// 避免每张图加载时创建 Stack + 2 FadeWidget + 2 AnimationController 的开销。
class CachedImage extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit? fit;

  /// 图片字节所在 blob bucket(默认正文 content;贴纸传 stickerOriginal,
  /// emoji 传 emoji)。
  final String bucket;

  /// 限制图片在内存中的解码尺寸。
  ///
  /// 对静态图：通过 [ResizeImage] 让 codec 按目标尺寸解码。
  /// 配合 [thumbnailMode] 时,动图也只解第一帧 + 缩放 + PNG cache(sticker 场景)。
  final int? memCacheWidth;
  final int? memCacheHeight;

  /// 仅取第一帧并走 thumbnail PNG cache 快速路径。
  ///
  /// 只在 sticker grid / emoji grid 这种 "30 张缩略图同屏" 的场景设 true,
  /// 此时即使是动图(AVIF / GIF / WebP / APNG)也只解第一帧 + 缓存 PNG,
  /// 后续访问跳过 AV1 / GIF disposal 等慢路径。
  ///
  /// 贴内图片(`discourse_image`)等需要完整动画的场景必须留 false —
  /// 否则 GIF / 动画 WebP 只显示第一帧,动画丢失。
  final bool thumbnailMode;

  /// 图片加载中显示的占位组件
  final WidgetBuilder? placeholder;

  /// 图片加载失败时显示的组件
  final ImageErrorWidgetBuilder? errorBuilder;

  /// 图片淡入时长（保留 API 兼容，暂不使用）
  final Duration fadeInDuration;

  /// 占位组件淡出时长（保留 API 兼容，暂不使用）
  final Duration fadeOutDuration;

  const CachedImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit,
    this.bucket = BlobImageCache.contentBucket,
    this.memCacheWidth,
    this.memCacheHeight,
    this.thumbnailMode = false,
    this.placeholder,
    this.errorBuilder,
    this.fadeInDuration = const Duration(milliseconds: 300),
    this.fadeOutDuration = const Duration(milliseconds: 300),
  });

  @override
  Widget build(BuildContext context) {
    final hasTargetSize = memCacheWidth != null || memCacheHeight != null;
    final targetSize =
        hasTargetSize ? (memCacheWidth ?? memCacheHeight)! : null;

    final provider = _resolveProvider(hasTargetSize, targetSize);

    return Image(
      image: provider,
      width: width,
      height: height,
      fit: fit,
      gaplessPlayback: true,
      frameBuilder: placeholder != null ? _buildFrame : null,
      errorBuilder: _wrapErrorBuilder(provider),
    );
  }

  /// 兜底 evict:部分 provider(如 NativeAnimatedImageProvider)加载失败后,
  /// 错误 completer 会留在 ImageCache,同 key 的后续 Image 直接复用失败结果,
  /// 永久裂图直到重启。这里在错误浮出 UI 时把对应 key 从 ImageCache 踢出,
  /// 下次 rebuild 自动重试。`provider.evict()` 能正确解析 ResizeImage 等
  /// 包装类型的实际 cache key;幂等,重复调用无副作用。
  ImageErrorWidgetBuilder _wrapErrorBuilder(ImageProvider provider) {
    final inner = errorBuilder ?? _defaultErrorBuilder;
    return (context, error, stackTrace) {
      scheduleMicrotask(() => provider.evict());
      return inner(context, error, stackTrace);
    };
  }

  ImageProvider _resolveProvider(bool hasTargetSize, int? targetSize) {
    // sticker thumbnail 场景:任意动态格式都走统一的 thumbnail PNG cache
    if (thumbnailMode &&
        hasTargetSize &&
        StickerThumbnailProvider.supports(url)) {
      return StickerThumbnailProvider(
        url,
        targetSize: targetSize!,
        bucket: bucket,
      );
    }

    final lower = url.toLowerCase();

    // 完整 AVIF 动画(长按预览 / 大图):flutter_avif (libavif + dav1d) 解码
    if (lower.endsWith('.avif')) {
      return AvifImageProvider(url, bucket: bucket);
    }

    // 完整 GIF / animated WebP / APNG 动画:NativeAnimatedImageProvider 走
    // Rust pipeline,绕 Skia multi_frame_codec 的 #85831 bug。
    //
    // 安全性(v0.3.0 后):native_animated_image 已经把 AVIF 解码彻底剥离,
    // 即使 URL 后缀失真(`.gif/.webp` 实际是 AVIF bytes),Rust 端 AVIF
    // magic 现在返 UnsupportedFormat,触发 provider 内置 Flutter codec
    // fallback,不会再撞 zenavif crash。
    if (lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.apng')) {
      return NativeAnimatedImageProvider.fromBytesProvider(
        loader: () => BlobImageCache.fetch(bucket, url),
        tag: url,
      );
    }

    // 静态格式:blob 直寻址 + ResizeImage(节省内存)
    ImageProvider provider = BlobImageProvider(url, bucket: bucket);
    if (hasTargetSize) {
      provider = ResizeImage(
        provider,
        width: memCacheWidth,
        height: memCacheHeight,
      );
    }
    return provider;
  }

  Widget _buildFrame(
    BuildContext context,
    Widget child,
    int? frame,
    bool wasSynchronouslyLoaded,
  ) {
    // 图片已加载或同步加载：直接显示
    if (wasSynchronouslyLoaded || frame != null) return child;
    // 图片未加载：显示占位
    return placeholder!(context);
  }

  static Widget _defaultErrorBuilder(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
  ) {
    return const SizedBox.shrink();
  }
}
