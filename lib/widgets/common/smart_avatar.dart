import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../services/discourse_cache_manager.dart';
import '../../utils/svg_utils.dart';

/// 智能头像组件
///
/// 使用 CachedNetworkImage 加载图片，自动支持 GIF 动画。
/// 当图片解码失败时，检测内容是否为 SVG 并渲染。
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

  // 当检测到 SVG 时存储内容
  String? _svgContent;
  bool _isSvgDetected = false;

  @override
  void didUpdateWidget(SmartAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      // URL 变化时重置 SVG 状态
      _svgContent = null;
      _isSvgDetected = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 默认透明背景，只有在需要 fallback 时才用主题色
    final bgColor = widget.backgroundColor ?? Colors.transparent;
    final fgColor = widget.foregroundColor ?? theme.colorScheme.onPrimaryContainer;

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
    } else if (_isSvgDetected && _svgContent != null) {
      // 已检测到 SVG，直接渲染
      child = SvgPicture.string(
        _svgContent!,
        width: innerSize,
        height: innerSize,
        fit: BoxFit.cover,
      );
    } else {
      // 使用 CachedNetworkImage，解码失败时检测 SVG
      child = CachedNetworkImage(
        imageUrl: widget.imageUrl!,
        cacheManager: _cacheManager,
        width: innerSize,
        height: innerSize,
        fit: BoxFit.cover,
        fadeInDuration: const Duration(milliseconds: 150),
        fadeOutDuration: const Duration(milliseconds: 150),
        placeholder: (context, url) => _buildLoading(fgColor, innerRadius),
        errorWidget: (context, url, error) => _SvgFallbackBuilder(
          imageUrl: widget.imageUrl!,
          cacheManager: _cacheManager,
          size: innerSize,
          onSvgDetected: (svgContent) {
            // 缓存 SVG 内容，下次直接渲染
            if (mounted) {
              setState(() {
                _svgContent = svgContent;
                _isSvgDetected = true;
              });
            }
          },
          fallback: _buildFallback(fgColor, innerRadius),
        ),
      );
    }

    // 使用 BoxDecoration + shape: circle 确保 Hero 动画时保持圆形
    // ClipOval 在 Hero 飞行时不会被正确应用
    Widget avatar = Container(
      width: innerRadius * 2,
      height: innerRadius * 2,
      decoration: BoxDecoration(
        color: bgColor,
        shape: BoxShape.circle,
      ),
      clipBehavior: Clip.hardEdge,
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

  Widget _buildLoading(Color fgColor, double radius) {
    return Center(
      child: SizedBox(
        width: radius * 0.6,
        height: radius * 0.6,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: fgColor.withValues(alpha: 0.5),
        ),
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
            fontWeight: FontWeight.bold,
            fontSize: radius * 0.8,
          ),
        ),
      );
    }
    return Center(
      child: Icon(
        Icons.person,
        size: radius,
        color: fgColor,
      ),
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
  final void Function(String svgContent) onSvgDetected;
  final Widget fallback;

  const _SvgFallbackBuilder({
    required this.imageUrl,
    required this.cacheManager,
    required this.size,
    required this.onSvgDetected,
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

      if (_isSvgContent(bytes)) {
        final svgString = SvgUtils.sanitize(String.fromCharCodes(bytes));
        if (mounted) {
          setState(() {
            _svgContent = svgString;
            _checked = true;
          });
          widget.onSvgDetected(svgString);
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

  /// 通过内容嗅探检测是否为 SVG
  bool _isSvgContent(List<int> bytes) {
    if (bytes.length < 5) return false;

    // 跳过可能的 BOM 和空白字符
    int start = 0;
    while (start < bytes.length &&
        (bytes[start] <= 32 ||
            bytes[start] == 0xEF ||
            bytes[start] == 0xBB ||
            bytes[start] == 0xBF)) {
      start++;
    }

    if (start >= bytes.length - 4) return false;

    // 检查是否以 <svg 或 <?xml 开头
    final prefix = String.fromCharCodes(bytes.sublist(start, start + 5));
    return prefix.startsWith('<svg') || prefix.startsWith('<?xml');
  }

  @override
  Widget build(BuildContext context) {
    if (_svgContent != null) {
      return SvgPicture.string(
        _svgContent!,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
      );
    }

    if (!_checked) {
      // 检测中，显示空白避免闪烁
      return const SizedBox.shrink();
    }

    return widget.fallback;
  }
}