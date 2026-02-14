import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../constants.dart';
import '../../services/discourse_cache_manager.dart';
import '../../utils/svg_utils.dart';
import '../../utils/color_utils.dart';
import '../../utils/font_awesome_helper.dart';

/// Flair 徽章组件
/// 用于在头像右下角显示用户的群组/身份标识
class FlairBadge extends StatelessWidget {
  final String? flairUrl;
  final String? flairName;
  final String? flairBgColor;
  final String? flairColor;
  final double size;

  const FlairBadge({
    super.key,
    this.flairUrl,
    this.flairName,
    this.flairBgColor,
    this.flairColor,
    this.size = 24,
  });

  /// 检查是否有有效的 flair 数据
  bool get hasFlair => flairUrl != null && flairUrl!.isNotEmpty;

  /// 检查是否是图片 URL
  bool get _isImageUrl {
    if (flairUrl == null) return false;
    // 完整 URL、相对路径、emoji 名称都是图片
    return flairUrl!.startsWith('http://') ||
           flairUrl!.startsWith('https://') ||
           flairUrl!.startsWith('/') ||
           (flairUrl!.startsWith(':') && flairUrl!.endsWith(':'));
  }

  /// 检查是否是 SVG 图片
  bool get _isSvg {
    if (flairUrl == null) return false;
    final url = flairUrl!.toLowerCase();
    return url.endsWith('.svg') || url.contains('.svg?');
  }

  /// 获取 FA 图标名称（不是 URL 的就是图标名称）
  String? get _faIconName {
    if (flairUrl == null || _isImageUrl) return null;
    return flairUrl;
  }


  /// 获取完整的 flair URL
  String _getFullFlairUrl() {
    if (flairUrl == null || flairUrl!.isEmpty) return '';

    // 如果已经是完整 URL，直接返回
    if (flairUrl!.startsWith('http://') || flairUrl!.startsWith('https://')) {
      return flairUrl!;
    }

    // 检查是否是 emoji 名称（如 :heart:）
    if (flairUrl!.startsWith(':') && flairUrl!.endsWith(':')) {
      final emojiName = flairUrl!.substring(1, flairUrl!.length - 1);
      return '${AppConstants.baseUrl}/images/emoji/twitter/$emojiName.png?v=12';
    }

    // 相对路径，拼接 baseUrl
    if (flairUrl!.startsWith('/')) {
      return '${AppConstants.baseUrl}$flairUrl';
    }

    return '${AppConstants.baseUrl}/$flairUrl';
  }

  @override
  Widget build(BuildContext context) {
    if (!hasFlair) return const SizedBox.shrink();

    final bgColor = ColorUtils.tryParseHex(flairBgColor);
    final fgColor = ColorUtils.tryParseHex(flairColor);
    final hasBgColor = bgColor != null;

    // 如果是图标名称（不是 URL）
    final iconName = _faIconName;
    if (iconName != null) {
      final iconData = FontAwesomeHelper.getIcon(iconName);

      // 如果没有匹配到图标，不显示
      if (iconData == null) return const SizedBox.shrink();

      // 有背景时图标缩小一点，留出内边距
      final iconSize = hasBgColor ? size * 0.6 : size * 0.8;
      // 图标颜色：优先使用 flairColor，否则有背景用白色，无背景用主题色
      final iconColor = fgColor ?? (hasBgColor ? Colors.white : Theme.of(context).colorScheme.onSurface);

      return Tooltip(
        message: flairName ?? '',
        child: Container(
          width: size,
          height: size,
          decoration: hasBgColor
              ? BoxDecoration(
                  color: bgColor,
                  shape: BoxShape.circle,
                )
              : null,
          child: Center(
            child: FaIcon(
              iconData,
              size: iconSize,
              color: iconColor,
            ),
          ),
        ),
      );
    }

    // 有背景时图片缩小一点，留出内边距
    final imageSize = hasBgColor ? size * 0.7 : size;
    final fullUrl = _getFullFlairUrl();

    // SVG 图片使用 DiscourseCacheManager 下载后用 flutter_svg 渲染
    if (_isSvg) {
      return _SvgFlairBadge(
        url: fullUrl,
        size: size,
        imageSize: imageSize,
        bgColor: bgColor,
        hasBgColor: hasBgColor,
        flairName: flairName,
      );
    }

    // 普通图片使用 Image 渲染
    return Tooltip(
      message: flairName ?? '',
      child: Container(
        width: size,
        height: size,
        decoration: hasBgColor
            ? BoxDecoration(
                color: bgColor,
                shape: BoxShape.circle,
              )
            : null,
        child: Center(
          child: Image(
            image: discourseImageProvider(fullUrl),
            width: imageSize,
            height: imageSize,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) {
              // 如果图片加载失败，显示首字母
              final initial = (flairName ?? '').isNotEmpty
                  ? flairName![0].toUpperCase()
                  : '?';
              return Text(
                initial,
                style: TextStyle(
                  fontSize: size * 0.6,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 带 Flair 的头像组件
/// 在头像右下角叠加 Flair 徽章
class AvatarWithFlair extends StatelessWidget {
  final Widget avatar;
  final String? flairUrl;
  final String? flairName;
  final String? flairBgColor;
  final String? flairColor;
  /// Flair 徽章大小，需要调用方根据头像大小自行设置
  final double flairSize;
  /// Flair 徽章右偏移，需要调用方根据头像大小自行设置
  final double flairRight;
  /// Flair 徽章下偏移，需要调用方根据头像大小自行设置
  final double flairBottom;

  const AvatarWithFlair({
    super.key,
    required this.avatar,
    this.flairUrl,
    this.flairName,
    this.flairBgColor,
    this.flairColor,
    required this.flairSize,
    this.flairRight = 0,
    this.flairBottom = 0,
  });

  bool get _hasFlair => flairUrl != null && flairUrl!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    if (!_hasFlair) return avatar;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(
          right: flairRight,
          bottom: flairBottom,
          child: FlairBadge(
            flairUrl: flairUrl,
            flairName: flairName,
            flairBgColor: flairBgColor,
            flairColor: flairColor,
            size: flairSize,
          ),
        ),
      ],
    );
  }
}

/// SVG Flair 徽章组件（使用 DiscourseCacheManager 加载）
class _SvgFlairBadge extends StatefulWidget {
  final String url;
  final double size;
  final double imageSize;
  final Color? bgColor;
  final bool hasBgColor;
  final String? flairName;

  const _SvgFlairBadge({
    required this.url,
    required this.size,
    required this.imageSize,
    this.bgColor,
    required this.hasBgColor,
    this.flairName,
  });

  @override
  State<_SvgFlairBadge> createState() => _SvgFlairBadgeState();
}

class _SvgFlairBadgeState extends State<_SvgFlairBadge> {
  String? _svgContent;
  bool _loading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _loadSvg();
  }

  @override
  void didUpdateWidget(_SvgFlairBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _loadSvg();
    }
  }

  Future<void> _loadSvg() async {
    setState(() {
      _loading = true;
      _hasError = false;
    });

    try {
      final file = await DiscourseCacheManager().getSingleFile(widget.url);
      // 读取 SVG 内容并清理动画/不支持的元素
      String content = await file.readAsString();
      content = SvgUtils.sanitize(content);
      
      if (mounted) {
        setState(() {
          _svgContent = content;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _hasError = true;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget content;

    if (_loading) {
      content = SizedBox(width: widget.imageSize, height: widget.imageSize);
    } else if (_hasError || _svgContent == null) {
      content = Icon(
        Icons.broken_image,
        size: widget.imageSize * 0.8,
        color: Theme.of(context).colorScheme.outline,
      );
    } else {
      content = SvgPicture.string(
        _svgContent!,
        width: widget.imageSize,
        height: widget.imageSize,
        fit: BoxFit.contain,
      );
    }

    return Tooltip(
      message: widget.flairName ?? '',
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: widget.hasBgColor
            ? BoxDecoration(
                color: widget.bgColor,
                shape: BoxShape.circle,
              )
            : null,
        child: Center(child: content),
      ),
    );
  }
}
