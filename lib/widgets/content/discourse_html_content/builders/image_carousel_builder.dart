import 'dart:async' show unawaited;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../../../../services/discourse_cache_manager.dart';
import '../../../../services/image_decode_spec_memo.dart';
import '../image_utils.dart';
import 'image_grid_builder.dart';

/// 构建 Discourse 图片轮播 (d-image-grid mode=carousel)
Widget buildImageCarousel({
  required BuildContext context,
  required ThemeData theme,
  required List<GridImageData> images,
  required GalleryInfo galleryInfo,
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: _ImageCarousel(
      theme: theme,
      images: images,
      galleryInfo: galleryInfo,
    ),
  );
}

/// 图片轮播组件
/// 参考 Discourse image-carousel.gjs 实现
class _ImageCarousel extends StatefulWidget {
  final ThemeData theme;
  final List<GridImageData> images;
  final GalleryInfo galleryInfo;

  const _ImageCarousel({
    required this.theme,
    required this.images,
    required this.galleryInfo,
  });

  @override
  State<_ImageCarousel> createState() => _ImageCarouselState();
}

class _ImageCarouselState extends State<_ImageCarousel> {
  /// 与 Discourse 一致：超过 10 张时用计数器替代圆点
  static const int _maxDots = 10;

  /// 轮播高度
  static const double _carouselHeight = 300.0;

  /// 预加载范围：当前页 ± _preloadRange
  static const int _preloadRange = 1;

  late final PageController _pageController;
  int _currentIndex = 0;

  /// 已解析的 URL 缓存 (index -> resolvedUrl)
  final Map<int, String> _resolvedUrls = {};

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _initResolvedUrls();
    _resolveUploadUrls();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// 初始化：将非 upload:// 的 URL 和已缓存的 upload:// URL 直接填入
  void _initResolvedUrls() {
    for (int i = 0; i < widget.images.length; i++) {
      final src = widget.images[i].src;
      if (DiscourseImageUtils.isUploadUrl(src)) {
        final cached = DiscourseImageUtils.getCachedUploadUrl(src);
        if (cached != null) _resolvedUrls[i] = cached;
      } else {
        _resolvedUrls[i] = src;
      }
    }
  }

  /// 异步批量解析 upload:// 短链接，优先解析当前页附近的
  Future<void> _resolveUploadUrls() async {
    // 收集需要解析的索引
    final pending = <int>[];
    for (int i = 0; i < widget.images.length; i++) {
      if (!_resolvedUrls.containsKey(i)) {
        pending.add(i);
      }
    }
    if (pending.isEmpty) {
      // 所有 URL 已就绪，预加载相邻图片
      _preloadAdjacent(_currentIndex);
      return;
    }

    // 按距当前页的距离排序，优先解析近的
    pending.sort((a, b) =>
        (a - _currentIndex).abs().compareTo((b - _currentIndex).abs()));

    for (final i in pending) {
      if (!mounted) return;
      final src = widget.images[i].src;
      final resolved = await DiscourseImageUtils.resolveUploadUrl(src);
      if (resolved != null && mounted) {
        setState(() => _resolvedUrls[i] = resolved);
        // 当前页或相邻页解析完成后，触发预加载
        if ((i - _currentIndex).abs() <= _preloadRange) {
          _preloadAdjacent(_currentIndex);
        }
      }
    }
  }

  /// 预加载当前页 ± _preloadRange 的图片到磁盘缓存
  void _preloadAdjacent(int centerIndex) {
    final start = math.max(0, centerIndex - _preloadRange);
    final end = math.min(widget.images.length - 1, centerIndex + _preloadRange);
    for (int i = start; i <= end; i++) {
      final url = _resolvedUrls[i];
      if (url != null) {
        unawaited(
          BlobImageCache.precache(BlobImageCache.contentBucket, url),
        );
      }
    }
  }

  bool get _isSingle => widget.images.length < 2;
  bool get _showDots => widget.images.length <= _maxDots;

  void _goToPage(int index) {
    if (index < 0 || index >= widget.images.length) return;
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _onPageChanged(int index) {
    setState(() => _currentIndex = index);
    _preloadAdjacent(index);
  }

  void _openViewer(BuildContext context, int imageIndex, String resolvedFullUrl) {
    final imageData = widget.images[imageIndex];
    final galleryImages = widget.galleryInfo.images;
    final heroTags = widget.galleryInfo.heroTags;
    final globalIndex = widget.galleryInfo.findIndex(imageData.src)
        ?? widget.galleryInfo.findIndex(imageData.fullSrc)
        ?? -1;

    final heroTag = globalIndex >= 0 && globalIndex < heroTags.length
        ? heroTags[globalIndex]
        : 'carousel_${imageData.src.hashCode}';

    final resolvedGalleryImages = galleryImages
        .map((url) => DiscourseImageUtils.getOriginalUrl(url))
        .toList();
    if (globalIndex >= 0 && globalIndex < resolvedGalleryImages.length) {
      resolvedGalleryImages[globalIndex] =
          DiscourseImageUtils.getOriginalUrl(resolvedFullUrl);
    }

    DiscourseImageUtils.openViewer(
      context: context,
      imageUrl: DiscourseImageUtils.getOriginalUrl(resolvedFullUrl),
      heroTag: heroTag,
      thumbnailUrl: resolvedFullUrl,
      galleryImages: resolvedGalleryImages,
      thumbnailUrls: galleryImages,
      heroTags: heroTags,
      initialIndex: globalIndex >= 0 ? globalIndex : 0,
      filenames: widget.galleryInfo.filenames,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 轮播轨道
        SizedBox(
          height: _carouselHeight,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              children: [
                // 背景色
                Positioned.fill(
                  child: Container(
                    color: widget.theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
                // PageView
                PageView.builder(
                  controller: _pageController,
                  itemCount: widget.images.length,
                  onPageChanged: _onPageChanged,
                  itemBuilder: (context, index) {
                    return _CarouselSlide(
                      index: index,
                      resolvedUrl: _resolvedUrls[index],
                      imageData: widget.images[index],
                      galleryInfo: widget.galleryInfo,
                      carouselHeight: _carouselHeight,
                      theme: widget.theme,
                      onTap: _openViewer,
                    );
                  },
                ),
                // 导航按钮（仅多张图片时显示）
                if (!_isSingle) ...[
                  // 上一张
                  Positioned(
                    left: 8,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: _NavButton(
                        icon: Symbols.chevron_left_rounded,
                        onTap: _currentIndex > 0
                            ? () => _goToPage(_currentIndex - 1)
                            : null,
                      ),
                    ),
                  ),
                  // 下一张
                  Positioned(
                    right: 8,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: _NavButton(
                        icon: Symbols.chevron_right_rounded,
                        onTap: _currentIndex < widget.images.length - 1
                            ? () => _goToPage(_currentIndex + 1)
                            : null,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        // 指示器（仅多张图片时显示）
        if (!_isSingle) ...[
          const SizedBox(height: 8),
          if (_showDots)
            _DotsIndicator(
              count: widget.images.length,
              currentIndex: _currentIndex,
              onTap: _goToPage,
            )
          else
            Text(
              '${_currentIndex + 1} / ${widget.images.length}',
              style: widget.theme.textTheme.bodySmall?.copyWith(
                color: widget.theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ],
    );
  }
}

/// 单张轮播幻灯片（带 KeepAlive，避免滑回时重新加载）
class _CarouselSlide extends StatefulWidget {
  final int index;
  final String? resolvedUrl;
  final GridImageData imageData;
  final GalleryInfo galleryInfo;
  final double carouselHeight;
  final ThemeData theme;
  final void Function(BuildContext context, int imageIndex, String resolvedFullUrl) onTap;

  const _CarouselSlide({
    required this.index,
    required this.resolvedUrl,
    required this.imageData,
    required this.galleryInfo,
    required this.carouselHeight,
    required this.theme,
    required this.onTap,
  });

  @override
  State<_CarouselSlide> createState() => _CarouselSlideState();
}

class _CarouselSlideState extends State<_CarouselSlide>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final url = widget.resolvedUrl;
    if (url == null) {
      // URL 还在解析中
      return const Center(
        child: LoadingSpinner(size: 24),
      );
    }

    final globalIndex = widget.galleryInfo.findIndex(widget.imageData.src)
        ?? widget.galleryInfo.findIndex(widget.imageData.fullSrc)
        ?? -1;
    final heroTags = widget.galleryInfo.heroTags;
    final heroTag = globalIndex >= 0 && globalIndex < heroTags.length
        ? heroTags[globalIndex]
        : 'carousel_${widget.imageData.src.hashCode}';

    // 解码尺寸双向 cap(decode-time ResizeImage,engine 下采样,全格式
    // 生效)。不要走 CachedNetworkImageProvider 的 maxWidth/maxHeight ——
    // 那是 flutter_cache_manager 的 resize 路径:webp 不在
    // supportedFileNames 里直接原图返回(等于没约束);jpg/png 则解码后
    // PNG 重编码再写第二份磁盘缓存,首次加载反而多付几百 ms。
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (MediaQuery.sizeOf(context).width * dpr).round();
    final cacheHeight = (widget.carouselHeight * dpr).round();
    // 登记解码参数:查看器缩略图占位同参重建 → 同 key 命中缓存
    ImageDecodeSpecMemo.remember(url, cacheWidth, cacheHeight);

    return GestureDetector(
      onTap: () => widget.onTap(context, widget.index, url),
      child: Hero(
        tag: heroTag,
        child: Image(
          image: ResizeImage(
            discourseImageProvider(url),
            width: cacheWidth,
            height: cacheHeight,
            policy: ResizeImagePolicy.fit,
          ),
          fit: BoxFit.contain,
          width: double.infinity,
          height: widget.carouselHeight,
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            final total = loadingProgress.expectedTotalBytes;
            // 无总长 = 不定态用 LoadingSpinner;有进度走 wavy 圆环
            return Center(
              child: total != null
                  ? M3eCircularProgress(
                      value: loadingProgress.cumulativeBytesLoaded / total,
                      size: 24,
                      strokeWidth: 2,
                    )
                  : const LoadingSpinner(size: 24),
            );
          },
          errorBuilder: (context, error, stackTrace) {
            return Center(
              child: Icon(
                Symbols.broken_image_rounded,
                color: widget.theme.colorScheme.outline,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 导航按钮
class _NavButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _NavButton({
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: onTap != null ? 1.0 : 0.3,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.8),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 4,
              ),
            ],
          ),
          child: Icon(
            icon,
            size: 20,
            color: theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

/// 圆点指示器
/// 与 Discourse 一致：活跃的圆点更宽（胶囊状）
class _DotsIndicator extends StatelessWidget {
  final int count;
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _DotsIndicator({
    required this.count,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (index) {
        final isActive = index == currentIndex;
        return GestureDetector(
          onTap: () => onTap(index),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: isActive ? 20.0 : 8.0,
            height: 8.0,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              color: isActive
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
          ),
        );
      }),
    );
  }
}
