import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/discourse_cache_manager.dart';
import '../../pages/image_viewer_page.dart';
import 'svg_view.dart';

/// Discourse 图片组件
///
/// 基于 [discourseImageProvider](内存缓存 + 磁盘缓存),支持:
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

  /// 加载/解码失败时的替代 UI;不传用默认破图占位。
  final WidgetBuilder? errorBuilder;

  /// 加载中的占位 UI;不传用默认 spinner 块。
  /// 浏览器语义场景(无尺寸 img 加载中零占位)传 SizedBox.shrink。
  final WidgetBuilder? placeholderBuilder;

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
    this.errorBuilder,
    this.placeholderBuilder,
  });

  @override
  State<DiscourseImage> createState() => _DiscourseImageState();
}

class _DiscourseImageState extends State<DiscourseImage> {
  /// 解码高度上限(物理像素):防长截图类窄高图按宽度解出超高位图
  /// (与 LazyImage 同款,4096 是低端 GPU 的普遍纹理安全上限)。
  static const int _kMaxDecodeHeight = 4096;

  String? _resolvedUrl;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _resolveUrl();
  }

  @override
  void didUpdateWidget(DiscourseImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
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
    final dpr = MediaQuery.devicePixelRatioOf(context);

    // 优化内存占用:始终限制解码尺寸,避免原始分辨率图片占满内存缓存。
    // 有明确宽度时按宽度缩放;否则以屏幕宽度为上限。高度必须同时 cap
    // (fit 策略保持宽高比):只约束宽度时长截图类窄高图会按宽度解出
    // 超高位图,超 GPU 纹理上限、上传瞬间 raster 冻结。
    final logicalWidth = widget.width ?? MediaQuery.sizeOf(context).width;
    final cacheWidth = (logicalWidth * dpr).round().clamp(1, 1 << 16);
    final cacheHeight = widget.height != null
        ? (widget.height! * dpr).round().clamp(1, _kMaxDecodeHeight)
        : _kMaxDecodeHeight;

    return Image(
      image: ResizeImage(
        discourseImageProvider(_resolvedUrl!),
        width: cacheWidth,
        height: cacheHeight,
        policy: ResizeImagePolicy.fit,
      ),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: true,
      // 占位挂 frameBuilder(以"首帧是否到达"为准,覆盖所有 provider);
      // AnimatedSwitcher 做占位→图片 200ms 交叉淡化,对齐原
      // CachedNetworkImage 的 fadeIn/fadeOut 视觉。缓存同步命中直出。
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: frame == null
              ? KeyedSubtree(
                  key: const ValueKey('placeholder'),
                  child: _buildPlaceholder(theme),
                )
              : KeyedSubtree(key: const ValueKey('image'), child: child),
        );
      },
      // 解码失败兜底:无 .svg 扩展名的 SVG(动态徽章服务等)按字节
      // 嗅探转入统一 SVG 管线;非 SVG 才显示破图。
      errorBuilder: (context, error, stack) => SvgSniffFallback(
        url: _resolvedUrl!,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        placeholderBuilder: widget.placeholderBuilder,
        brokenBuilder: (_) => _buildErrorWidget(theme),
      ),
    );
  }

  Widget _buildSvgImage(ThemeData theme) {
    // 统一走 DiscourseSvgView:内容嗅探动画,静态 jovial_svg /
    // 动画 full_svg_flutter(首帧快照 + 点击播放 + 防注入)。
    return DiscourseSvgView(
      url: _resolvedUrl!,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      placeholderBuilder: (_) => _buildPlaceholder(theme),
      errorBuilder: (_) => _buildErrorWidget(theme),
    );
  }

  Widget _buildPlaceholder(ThemeData theme) {
    final custom = widget.placeholderBuilder;
    if (custom != null) return custom(context);
    return Container(
      width: widget.width,
      height: widget.height ?? 100,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Center(
        child: LoadingSpinner(
          size: 20,
          color: theme.colorScheme.outline.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  Widget _buildErrorWidget(ThemeData theme) {
    final custom = widget.errorBuilder;
    if (custom != null) return custom(context);
    return Container(
      width: widget.width,
      height: widget.height ?? 60,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Center(
        child: Icon(
          Symbols.broken_image_rounded,
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
