import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../../../../services/discourse_cache_manager.dart';
import '../../../../services/image_decode_spec_memo.dart';
import '../../../../utils/url_helper.dart';
import '../image_utils.dart';
import '../../lazy_load_scope.dart';
import 'image_carousel_builder.dart';

/// 构建 Discourse 图片网格 (d-image-grid)
/// 支持 grid 和 carousel 两种模式
Widget? buildImageGrid({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
  required GalleryInfo galleryInfo,
}) {
  // 提取所有图片
  final images = extractGridImages(element);
  if (images.isEmpty) return null;

  // 检测 carousel 模式：data-mode="carousel" 或 class 包含 d-image-grid--carousel
  final dataMode = element.attributes['data-mode'] as String?;
  final isCarousel = dataMode == 'carousel' ||
      (element.classes as Iterable<String>).contains('d-image-grid--carousel');

  if (isCarousel) {
    return buildImageCarousel(
      context: context,
      theme: theme,
      images: images,
      galleryInfo: galleryInfo,
    );
  }

  // 解析列数，默认 2 列
  final dataColumns = element.attributes['data-columns'] as String?;
  final columns = int.tryParse(dataColumns ?? '') ?? 2;

  // 使用全局画廊信息
  final galleryImages = galleryInfo.images;
  final heroTags = galleryInfo.heroTags;

  // 计算间距（与 Discourse 一致）
  const double spacing = 6.0;

  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        // 计算每列宽度
        final columnWidth = (availableWidth - (columns - 1) * spacing) / columns;

        // 使用 Wrap 布局实现网格
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: images.map((imageData) {
            // 使用 GalleryInfo.findIndex 查找全局索引
            final globalIndex = galleryInfo.findIndex(imageData.src) 
                ?? galleryInfo.findIndex(imageData.fullSrc)
                ?? -1;
            
            // 生成 heroTag
            final heroTag = globalIndex >= 0 && globalIndex < heroTags.length
                ? heroTags[globalIndex]
                : 'grid_${imageData.src.hashCode}';

            return _GridImageTile(
              theme: theme,
              imageData: imageData,
              columnWidth: columnWidth,
              heroTag: heroTag,
              gridOriginalImages: galleryImages,
              gridThumbnailImages: galleryImages,  // 原图列表
              heroTags: heroTags,
              index: globalIndex >= 0 ? globalIndex : 0,
              filenames: galleryInfo.filenames,
            );
          }).toList(),
        );
      },
    ),
  );
}

/// 提取图片数据（从 d-image-grid 元素中）
List<GridImageData> extractGridImages(dynamic element) {
  final images = <GridImageData>[];
  final imgElements = element.getElementsByTagName('img');

  for (final img in imgElements) {
    // 排除 emoji、头像等
    final classes = (img.classes as Iterable<String>?)?.toList() ?? [];
    if (classes.contains('emoji') ||
        classes.contains('avatar') ||
        classes.contains('thumbnail') ||
        classes.contains('ytp-thumbnail-image')) {
      continue;
    }

    var src = img.attributes['src'] as String?;
    if (src == null || src.isEmpty) continue;

    // 处理相对路径（但保留 upload:// 协议）
    if (!DiscourseImageUtils.isUploadUrl(src)) {
      src = UrlHelper.resolveUrlWithCdn(src);
    }

    // 尝试获取原图链接
    String? fullSrc = DiscourseImageUtils.findOriginalImageUrl(img);
    if (fullSrc != null && !DiscourseImageUtils.isUploadUrl(fullSrc)) {
      fullSrc = UrlHelper.resolveUrlWithCdn(fullSrc);
    }

    // 尝试获取宽高
    final widthStr = img.attributes['width'] as String?;
    final heightStr = img.attributes['height'] as String?;
    final width = double.tryParse(widthStr ?? '');
    final height = double.tryParse(heightStr ?? '');

    images.add(GridImageData(
      src: src,
      fullSrc: fullSrc ?? (DiscourseImageUtils.isUploadUrl(src) ? src : DiscourseImageUtils.getOriginalUrl(src)),
      width: width,
      height: height,
    ));
  }

  return images;
}

/// 网格图片瓦片（懒加载：进入视口才开始下载图片）
class _GridImageTile extends StatefulWidget {
  final ThemeData theme;
  final GridImageData imageData;
  final double columnWidth;
  final String heroTag;
  final List<String> gridOriginalImages;
  final List<String> gridThumbnailImages;
  final List<String> heroTags;
  final int index;
  final List<String?> filenames;

  const _GridImageTile({
    required this.theme,
    required this.imageData,
    required this.columnWidth,
    required this.heroTag,
    required this.gridOriginalImages,
    required this.gridThumbnailImages,
    required this.heroTags,
    required this.index,
    required this.filenames,
  });

  @override
  State<_GridImageTile> createState() => _GridImageTileState();
}

class _GridImageTileState extends State<_GridImageTile> {
  bool _shouldLoad = false;
  bool _initialized = false;

  String get _cacheKey => 'grid_tile_${widget.heroTag}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      // 检查 LazyLoadScope 缓存，避免重建时重复走 VisibilityDetector
      if (LazyLoadScope.isLoaded(context, _cacheKey)) {
        _shouldLoad = true;
      }
    }
  }

  void _triggerLoad() {
    if (!_shouldLoad) {
      LazyLoadScope.markLoaded(context, _cacheKey);
      setState(() => _shouldLoad = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 计算显示高度，保持宽高比，限制最大高度
    double displayHeight;
    if (widget.imageData.width != null && widget.imageData.height != null && widget.imageData.width! > 0) {
      final aspectRatio = widget.imageData.height! / widget.imageData.width!;
      displayHeight = widget.columnWidth * aspectRatio;
      displayHeight = displayHeight.clamp(80.0, 300.0);
    } else {
      displayHeight = widget.columnWidth * 0.75;
    }

    // 未进入视口：显示占位符 + VisibilityDetector
    if (!_shouldLoad) {
      return VisibilityDetector(
        key: Key('grid-lazy-${widget.heroTag}'),
        onVisibilityChanged: (info) {
          if (!_shouldLoad && info.visibleFraction > 0) {
            _triggerLoad();
          }
        },
        child: SizedBox(
          width: widget.columnWidth,
          height: displayHeight,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Container(
              color: widget.theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ),
      );
    }

    // 已进入视口：加载图片
    // 检查是否是 upload:// 短链接
    if (!DiscourseImageUtils.isUploadUrl(widget.imageData.src)) {
      // 普通 URL，直接渲染
      return _buildImageWidget(context, widget.imageData.src, widget.imageData.fullSrc, displayHeight);
    }

    // upload:// 短链接：命中缓存直接渲染（缓存仅含成功结果）
    final cachedUrl = DiscourseImageUtils.getCachedUploadUrl(widget.imageData.src);
    if (cachedUrl != null) {
      return _buildImageWidget(context, cachedUrl, cachedUrl, displayHeight);
    }

    // 首次加载：使用 FutureBuilder 解析
    return FutureBuilder<String?>(
      future: DiscourseImageUtils.resolveUploadUrl(widget.imageData.src),
      builder: (context, snapshot) {
        // 加载中
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildLoadingWidget(displayHeight);
        }

        // 解析失败
        if (snapshot.data == null) {
          return _buildErrorWidget(displayHeight);
        }

        // 解析成功
        final resolvedUrl = snapshot.data!;
        return _buildImageWidget(context, resolvedUrl, resolvedUrl, displayHeight);
      },
    );
  }

  Widget _buildImageWidget(BuildContext context, String displayUrl, String fullUrl, double displayHeight) {
    // cover 布局按短边撑满,解码按格子长边 × dpr 双向 cap(fit 策略保持
    // 宽高比):只 cap 宽的话 1:10 长图会解出上万像素高的超限纹理,
    // 上传瞬间 raster 冻结(与 LazyImage 同款问题)
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final maxSide =
        widget.columnWidth > displayHeight ? widget.columnWidth : displayHeight;
    final cachePx = (maxSide * dpr).round();
    // 登记解码参数:查看器缩略图占位同参重建 → 同 key 命中缓存
    ImageDecodeSpecMemo.remember(displayUrl, cachePx, cachePx);
    return SizedBox(
      width: widget.columnWidth,
      height: displayHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: GestureDetector(
          onTap: () => _openViewer(context, fullUrl),
          child: Hero(
            tag: widget.heroTag,
            // RepaintBoundary:加载 spinner 动画/首绘隔离在格子内,
            // 不连带整个帖子 segment 每帧重绘
            child: RepaintBoundary(
              child: Image(
                image: ResizeImage(
                  discourseImageProvider(displayUrl),
                  width: cachePx,
                  height: cachePx,
                  policy: ResizeImagePolicy.fit,
                ),
                fit: BoxFit.cover,
                width: widget.columnWidth,
                height: displayHeight,
                gaplessPlayback: true,
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  final total = loadingProgress.expectedTotalBytes;
                  // 无总长 = 不定态用 LoadingSpinner;有进度走 wavy 圆环
                  return Container(
                    color: widget.theme.colorScheme.surfaceContainerHighest,
                    child: Center(
                      child: RepaintBoundary(
                        child: total != null
                            ? M3eCircularProgress(
                                value:
                                    loadingProgress.cumulativeBytesLoaded /
                                        total,
                                size: 24,
                                strokeWidth: 2,
                              )
                            : const LoadingSpinner(size: 24),
                      ),
                    ),
                  );
                },
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    color: widget.theme.colorScheme.surfaceContainerHighest,
                    child: Icon(
                      Symbols.broken_image_rounded,
                      color: widget.theme.colorScheme.outline,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openViewer(BuildContext context, String resolvedFullUrl) {
    // 确保所有画廊图片都使用原图 URL
    final resolvedGalleryImages = widget.gridOriginalImages
        .map((url) => DiscourseImageUtils.getOriginalUrl(url))
        .toList();
    // 当前点击的图片使用解析后的 URL
    if (widget.index >= 0 && widget.index < resolvedGalleryImages.length) {
      resolvedGalleryImages[widget.index] = DiscourseImageUtils.getOriginalUrl(resolvedFullUrl);
    }

    DiscourseImageUtils.openViewer(
      context: context,
      imageUrl: DiscourseImageUtils.getOriginalUrl(resolvedFullUrl),
      heroTag: widget.heroTag,
      thumbnailUrl: resolvedFullUrl,
      galleryImages: resolvedGalleryImages,
      thumbnailUrls: widget.gridThumbnailImages,
      heroTags: widget.heroTags,
      initialIndex: widget.index >= 0 ? widget.index : 0,
      filenames: widget.filenames,
      // 网格瓦片是 cover 裁剪 + 圆角 4:启用飞行 crossfade,
      // 消除起飞/落地瞬间「裁剪图↔完整图」跳变
      heroSourceFit: BoxFit.cover,
      heroSourceRadius: 4,
    );
  }

  Widget _buildLoadingWidget(double displayHeight) {
    return SizedBox(
      width: widget.columnWidth,
      height: displayHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Container(
          color: widget.theme.colorScheme.surfaceContainerHighest,
          child: const Center(
            child: LoadingSpinner(size: 24),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorWidget(double displayHeight) {
    return SizedBox(
      width: widget.columnWidth,
      height: displayHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Container(
          color: widget.theme.colorScheme.surfaceContainerHighest,
          child: Icon(
            Symbols.broken_image_rounded,
            color: widget.theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }
}

/// 图片数据
class GridImageData {
  final String src;
  final String fullSrc;
  final double? width;
  final double? height;

  GridImageData({
    required this.src,
    required this.fullSrc,
    this.width,
    this.height,
  });
}


