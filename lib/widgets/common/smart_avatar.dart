import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:jovial_svg/jovial_svg.dart';
import '../../services/discourse_cache_manager.dart';
import '../../utils/svg_utils.dart';

/// 智能头像组件
///
/// 使用 CachedNetworkImage 加载图片，自动支持 GIF 动画。
/// 静态头像会先检测内容是否为 SVG，避免伪装成 PNG 的 SVG 进入位图解码器。
class SmartAvatar extends StatefulWidget {
  final String? imageUrl;
  final double radius;
  final String? fallbackText;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final BoxBorder? border;

  const SmartAvatar({
    super.key,
    this.imageUrl,
    required this.radius,
    this.fallbackText,
    this.backgroundColor,
    this.foregroundColor,
    this.border,
  });

  @override
  State<SmartAvatar> createState() => _SmartAvatarState();
}

class _SmartAvatarState extends State<SmartAvatar> {
  static final DiscourseCacheManager _cacheManager = DiscourseCacheManager();

  /// SVG 探测结果的全局记忆(URL → svg 内容,null = 已确认非 SVG)。
  ///
  /// 绝大多数头像不是 SVG,却在**每次挂载**付一次 cache_manager 查询
  /// (sqlite + 文件 stat)+ FutureBuilder 两阶段 rebuild(loading →
  /// CNI)—— 列表快滚一屏十几个头像张张交税,是单卡首建成本的组成
  /// 部分。记忆后重访头像同步单阶段直达;URL 版本化(带 hash),
  /// 换头像即新条目。"未下载时记为非 SVG"不破坏语义:下载后若真是
  /// SVG,仍由 CNI errorWidget → _SvgFallbackBuilder 内容嗅探兜底。
  static final Map<String, String?> _svgProbeMemo = {};
  static const int _svgProbeMemoCap = 1500;

  static void _memoizeSvgProbe(String url, String? content) {
    _svgProbeMemo.remove(url);
    _svgProbeMemo[url] = content;
    if (_svgProbeMemo.length > _svgProbeMemoCap) {
      _svgProbeMemo.remove(_svgProbeMemo.keys.first);
    }
  }

  Future<String?>? _svgProbeFuture;

  /// memo 命中(或无需探测)时为 true:build 走同步单阶段,零 FutureBuilder
  bool _svgProbeResolved = false;
  String? _svgProbeSync;

  @override
  void initState() {
    super.initState();
    _setupSvgProbe(widget.imageUrl);
  }

  @override
  void didUpdateWidget(SmartAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _setupSvgProbe(widget.imageUrl);
    }
  }

  void _setupSvgProbe(String? imageUrl) {
    if (imageUrl == null || imageUrl.isEmpty || isNativeAnimatedUrl(imageUrl)) {
      _svgProbeResolved = true;
      _svgProbeSync = null;
      _svgProbeFuture = null;
      return;
    }
    if (_svgProbeMemo.containsKey(imageUrl)) {
      _svgProbeResolved = true;
      _svgProbeSync = _svgProbeMemo[imageUrl];
      _svgProbeFuture = null;
      return;
    }
    _svgProbeResolved = false;
    _svgProbeSync = null;
    _svgProbeFuture = _loadSvgContentIfPresent(imageUrl).then((content) {
      _memoizeSvgProbe(imageUrl, content);
      return content;
    });
  }

  Future<String?> _loadSvgContentIfPresent(String imageUrl) async {
    try {
      // 用 getFileFromCache 只查缓存元信息,不主动触发下载
      // (下载由后面的 CachedNetworkImage 负责,避免重复请求)。
      final fileInfo = await _cacheManager.getFileFromCache(imageUrl);
      if (fileInfo == null) return null;
      // 信任响应头:flutter_cache_manager 根据 Content-Type
      // (image/svg+xml → .svg)给缓存文件起名,这里只看后缀,
      // 避开读整文件 + 字节嗅探。
      // 服务端撒谎(回 image/png 但实际是 SVG)的边界场景,
      // 由 CachedNetworkImage 的 errorWidget → _SvgFallbackBuilder 内容嗅探兜底。
      if (!fileInfo.file.path.toLowerCase().endsWith('.svg')) return null;
      final bytes = await fileInfo.file.readAsBytes();
      if (bytes.isEmpty) return null;
      return SvgUtils.sanitize(SvgUtils.decodeSvgBytes(bytes));
    } catch (_) {
      return null;
    }
  }

  /// 静态图路径:CachedNetworkImage,解码失败时再次嗅探 SVG 兜底。
  Widget _buildStaticImage(
    Color fgColor,
    double innerRadius,
    double innerSize,
  ) {
    // 解码尺寸约束:头像显示直径 innerSize(常见 32~72dp),但服务端
    // 返回的头像位图可能远大于显示尺寸,不约束就按原图解码上传 —— 快滚
    // 多头像同帧首绘时纹理上传叠加成 raster 尖峰(书签/话题列表 raster
    // 大帧的头像份额)。按显示直径 × dpr 解码,单张纹理量降一到两个
    // 数量级;× 2 留一档清晰度余量,cover 裁切不糊。
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final decodeSide = (innerSize * dpr * 2).round().clamp(1, 512);
    return CachedNetworkImage(
      imageUrl: widget.imageUrl!,
      cacheManager: _cacheManager,
      width: innerSize,
      height: innerSize,
      memCacheWidth: decodeSide,
      memCacheHeight: decodeSide,
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 150),
      fadeOutDuration: const Duration(milliseconds: 150),
      placeholder: (context, url) => _buildLoading(fgColor, innerRadius),
      errorWidget: (context, url, error) => _SvgFallbackBuilder(
        imageUrl: widget.imageUrl!,
        cacheManager: _cacheManager,
        size: innerSize,
        fallback: _buildFallback(fgColor, innerRadius),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 默认透明背景，只有在需要 fallback 时才用主题色
    final bgColor = widget.backgroundColor ?? Colors.transparent;
    final fgColor =
        widget.foregroundColor ?? theme.colorScheme.onPrimaryContainer;

    // 计算边框宽度，边框包含在 radius 内部
    double borderWidth = 0;
    if (widget.border is Border) {
      borderWidth = (widget.border as Border).top.width;
    }
    final innerRadius = widget.radius - borderWidth;
    final innerSize = innerRadius * 2;

    Widget child;
    if (widget.imageUrl == null || widget.imageUrl!.isEmpty) {
      child = _buildFallback(fgColor, innerRadius);
    } else if (isNativeAnimatedUrl(widget.imageUrl!)) {
      // 动图(GIF/APNG/动画 WebP)走 native_animated_image Rust pipeline,
      // 绕开 Flutter Skia multi_frame_codec 的 #85831 bug。
      // RepaintBoundary 将每帧 setImage 触发的重绘限制在头像区域内,
      // 避免列表中多个动图头像同时连累整个 list item 重绘。
      child = RepaintBoundary(
        child: Image(
          image: discourseImageProvider(widget.imageUrl!),
          width: innerSize,
          height: innerSize,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          frameBuilder: (context, displayChild, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded || frame != null) return displayChild;
            return _buildLoading(fgColor, innerRadius);
          },
          errorBuilder: (context, error, stack) {
            // 动图链路出错(网络 / Rust 解码失败),退化到字母 fallback
            return _buildFallback(fgColor, innerRadius);
          },
        ),
      );
    } else if (_svgProbeResolved) {
      // 探测结果已知(memo 命中 / 无需探测):同步单阶段,零 FutureBuilder。
      // 快滚重访头像走这里 —— 不再付 sqlite 查询与两阶段 rebuild。
      child = _svgProbeSync != null
          ? (_buildSvg(_svgProbeSync!, innerSize) ??
                _buildFallback(fgColor, innerRadius))
          : _buildStaticImage(fgColor, innerRadius, innerSize);
    } else {
      child = FutureBuilder<String?>(
        future: _svgProbeFuture,
        builder: (context, snapshot) {
          final svgContent = snapshot.data;
          if (svgContent != null) {
            return _buildSvg(svgContent, innerSize) ??
                _buildFallback(fgColor, innerRadius);
          }

          if (snapshot.connectionState != ConnectionState.done) {
            return _buildLoading(fgColor, innerRadius);
          }

          // 静态图使用 CachedNetworkImage，解码失败时再次嗅探 SVG 兜底。
          return _buildStaticImage(fgColor, innerRadius, innerSize);
        },
      );
    }

    // 使用 BoxDecoration + shape: circle 确保 Hero 动画时保持圆形
    // ClipOval 在 Hero 飞行时不会被正确应用
    Widget avatar = Container(
      width: innerRadius * 2,
      height: innerRadius * 2,
      decoration: BoxDecoration(color: bgColor, shape: BoxShape.circle),
      clipBehavior: Clip.antiAlias,
      child: child,
    );

    // 如果有边框，在外层添加，总尺寸保持 radius * 2
    if (widget.border != null) {
      avatar = Container(
        width: widget.radius * 2,
        height: widget.radius * 2,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: widget.border,
        ),
        alignment: Alignment.center,
        child: avatar,
      );
    }

    return avatar;
  }

  Widget? _buildSvg(String svgContent, double size) {
    try {
      final si = ScalableImage.fromSvgString(svgContent, warnF: (_) {});
      return SizedBox(
        width: size,
        height: size,
        child: ScalableImageWidget(si: si, fit: BoxFit.cover),
      );
    } catch (_) {
      return null;
    }
  }

  Widget _buildLoading(Color fgColor, double radius) {
    // 静态灰底占位 — 头像 loading 时间极短,
    // 用 CircularProgressIndicator 会带来 60fps 自转 + InheritedTheme 查询,
    // 在列表多头像同时占位时是热点开销。
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: fgColor.withValues(alpha: 0.08),
      ),
    );
  }

  Widget _buildFallback(Color fgColor, double radius) {
    if (widget.fallbackText != null && widget.fallbackText!.isNotEmpty) {
      return Center(
        child: Text(
          widget.fallbackText![0].toUpperCase(),
          style: TextStyle(
            color: fgColor,
            fontWeight: FontWeight.w600,
            fontSize: radius * 0.8,
          ),
        ),
      );
    }
    return Center(
      child: Icon(Symbols.person_rounded, size: radius, color: fgColor),
    );
  }
}

/// SVG 检测和渲染组件
///
/// 当 CachedNetworkImage 解码失败时，检测缓存文件是否为 SVG
class _SvgFallbackBuilder extends StatefulWidget {
  final String imageUrl;
  final DiscourseCacheManager cacheManager;
  final double size;
  final Widget fallback;

  const _SvgFallbackBuilder({
    required this.imageUrl,
    required this.cacheManager,
    required this.size,
    required this.fallback,
  });

  @override
  State<_SvgFallbackBuilder> createState() => _SvgFallbackBuilderState();
}

class _SvgFallbackBuilderState extends State<_SvgFallbackBuilder> {
  String? _svgContent;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    _checkForSvg();
  }

  Future<void> _checkForSvg() async {
    try {
      final file = await widget.cacheManager.getSingleFile(widget.imageUrl);
      final bytes = await file.readAsBytes();

      if (bytes.isEmpty || !mounted) return;

      if (SvgUtils.isSvgBytes(bytes)) {
        final svgString = SvgUtils.sanitize(SvgUtils.decodeSvgBytes(bytes));
        if (mounted) {
          setState(() {
            _svgContent = svgString;
            _checked = true;
          });
        }
      } else {
        if (mounted) {
          setState(() => _checked = true);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _checked = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_svgContent != null) {
      try {
        final si = ScalableImage.fromSvgString(_svgContent!, warnF: (_) {});
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: ScalableImageWidget(si: si, fit: BoxFit.cover),
        );
      } catch (_) {
        return widget.fallback;
      }
    }

    if (!_checked) {
      // 检测中，显示空白避免闪烁
      return const SizedBox.shrink();
    }

    return widget.fallback;
  }
}
