import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:jovial_svg/jovial_svg.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/discourse_cache_manager.dart';
import '../../pages/image_viewer_page.dart';
import '../../utils/svg_utils.dart';

/// Discourse 图片组件
///
/// 基于 CachedNetworkImage，支持：
/// - 内存缓存 + 磁盘缓存
/// - SVG 图片渲染
/// - upload:// 短链接解析
/// - Cloudflare 鉴权
/// - 点击查看大图 (Lightbox)
class DiscourseImage extends StatefulWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final bool enableLightbox;
  final String? heroTag;
  final List<String> galleryImages;
  final int initialIndex;

  const DiscourseImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.enableLightbox = false,
    this.heroTag,
    this.galleryImages = const [],
    this.initialIndex = 0,
  });

  @override
  State<DiscourseImage> createState() => _DiscourseImageState();
}

class _DiscourseImageState extends State<DiscourseImage> {
  String? _resolvedUrl;
  bool _isLoading = true;
  bool _hasError = false;

  /// 缓存解析后的 ScalableImage，避免每次 build 都重新执行 getSingleFile() SQLite 查询
  ScalableImage? _svgSi;

  static final DiscourseCacheManager _cacheManager = DiscourseCacheManager();

  @override
  void initState() {
    super.initState();
    _resolveUrl();
  }

  @override
  void didUpdateWidget(DiscourseImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _svgSi = null;
      _resolveUrl();
    }
  }

  Future<void> _resolveUrl() async {
    if (!widget.url.startsWith('upload://')) {
      // 普通 URL，不需要解析
      if (mounted) {
        setState(() {
          _resolvedUrl = widget.url;
          _isLoading = false;
          _hasError = false;
        });
      }
      return;
    }

    // 需要解析短链接
    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    try {
      final resolved = await DiscourseService().resolveShortUrl(widget.url);
      if (mounted) {
        setState(() {
          _resolvedUrl = resolved;
          _isLoading = false;
          _hasError = resolved == null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  bool get _isSvg {
    if (_resolvedUrl == null) return false;
    final uri = Uri.tryParse(_resolvedUrl!);
    if (uri == null) return false;
    return uri.path.toLowerCase().endsWith('.svg');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return _buildPlaceholder(theme);
    }

    if (_hasError || _resolvedUrl == null) {
      return _buildErrorWidget(theme);
    }

    Widget imageWidget;
    if (_isSvg) {
      imageWidget = _buildSvgImage(theme);
    } else if (isNativeAnimatedUrl(_resolvedUrl!)) {
      // 动图(GIF/APNG/动画 WebP)走 native_animated_image Rust pipeline
      imageWidget = _buildNativeAnimatedImage(theme);
    } else {
      imageWidget = _buildCachedImage(theme);
    }

    // Hero 动画
    if (widget.heroTag != null) {
      imageWidget = Hero(tag: widget.heroTag!, child: imageWidget);
    }

    // Lightbox
    if (widget.enableLightbox && !_isSvg) {
      return GestureDetector(
        onTap: _openLightbox,
        child: imageWidget,
      );
    }

    return imageWidget;
  }

  /// 动图渲染 — 走 native_animated_image (Rust pipeline),不踩 Flutter Skia
  /// multi_frame_codec 的 #85831 / #94205 bug。
  Widget _buildNativeAnimatedImage(ThemeData theme) {
    return Image(
      image: discourseImageProvider(_resolvedUrl!),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: true,
      frameBuilder: (context, displayChild, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) return displayChild;
        return _buildPlaceholder(theme);
      },
      errorBuilder: (context, error, stack) => _buildErrorWidget(theme),
    );
  }

  Widget _buildCachedImage(ThemeData theme) {
    final dpr = MediaQuery.of(context).devicePixelRatio;

    // 优化内存占用：始终限制解码尺寸，避免原始分辨率图片占满内存缓存
    // 有明确宽度时按宽度缩放；否则以屏幕宽度为上限
    final int memCacheWidth;
    if (widget.width != null) {
      memCacheWidth = (widget.width! * dpr).toInt();
    } else {
      final screenWidth = MediaQuery.of(context).size.width;
      memCacheWidth = (screenWidth * dpr).toInt();
    }

    return CachedNetworkImage(
      imageUrl: _resolvedUrl!,
      cacheManager: _cacheManager,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      fadeInDuration: const Duration(milliseconds: 200),
      fadeOutDuration: const Duration(milliseconds: 200),
      placeholder: (context, url) => _buildPlaceholder(theme),
      errorWidget: (context, url, error) => _buildErrorWidget(theme),
      memCacheWidth: memCacheWidth,
      memCacheHeight: widget.height != null
          ? (widget.height! * dpr).toInt()
          : null,
    );
  }

  Widget _buildSvgImage(ThemeData theme) {
    // 已缓存 ScalableImage 则直接渲染
    if (_svgSi != null) {
      final siWidth = widget.width ?? _svgSi!.viewport.width;
      final siHeight = widget.height ?? _svgSi!.viewport.height;
      return SizedBox(
        width: siWidth,
        height: siHeight,
        child: ScalableImageWidget(si: _svgSi!, fit: widget.fit),
      );
    }

    // 首次加载：异步获取文件并缓存结果
    _loadSvgContent();
    return _buildPlaceholder(theme);
  }

  Future<void> _loadSvgContent() async {
    try {
      final file = await _cacheManager.getSingleFile(_resolvedUrl!);
      var content = await file.readAsString();
      content = SvgUtils.sanitize(content);
      final si = ScalableImage.fromSvgString(content, warnF: (_) {});

      if (mounted) {
        setState(() {
          _svgSi = si;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _hasError = true);
      }
    }
  }

  Widget _buildPlaceholder(ThemeData theme) {
    return Container(
      width: widget.width,
      height: widget.height ?? 100,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: theme.colorScheme.outline.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorWidget(ThemeData theme) {
    return Container(
      width: widget.width,
      height: widget.height ?? 60,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Center(
        child: Icon(
          Icons.broken_image_outlined,
          color: theme.colorScheme.outline,
          size: 24,
        ),
      ),
    );
  }

  void _openLightbox() {
    ImageViewerPage.open(
      context,
      _resolvedUrl!,
      heroTag: widget.heroTag,
      galleryImages: widget.galleryImages.isNotEmpty ? widget.galleryImages : null,
      initialIndex: widget.initialIndex,
      enableShare: true,
    );
  }

}
