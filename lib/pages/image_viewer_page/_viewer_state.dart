part of '../image_viewer_page.dart';

/// SVG 图片 fallback 组件
/// 当普通图片解码失败时，检测是否为 SVG 并渲染
class _SvgImageFallback extends StatefulWidget {
  final String imageUrl;
  final DiscourseCacheManager cacheManager;

  const _SvgImageFallback({
    required this.imageUrl,
    required this.cacheManager,
  });

  @override
  State<_SvgImageFallback> createState() => _SvgImageFallbackState();
}

class _SvgImageFallbackState extends State<_SvgImageFallback> {
  String? _svgContent;
  bool _checked = false;
  bool _isSvg = false;

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
            _isSvg = true;
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

  bool _isSvgContent(List<int> bytes) {
    if (bytes.length < 5) return false;

    int start = 0;
    while (start < bytes.length &&
        (bytes[start] <= 32 ||
            bytes[start] == 0xEF ||
            bytes[start] == 0xBB ||
            bytes[start] == 0xBF)) {
      start++;
    }

    if (start >= bytes.length - 4) return false;

    final prefix = String.fromCharCodes(bytes.sublist(start, start + 5));
    return prefix.startsWith('<svg') || prefix.startsWith('<?xml');
  }

  @override
  Widget build(BuildContext context) {
    if (_isSvg && _svgContent != null) {
      return Center(
        child: SvgPicture.string(
          _svgContent!,
          fit: BoxFit.contain,
        ),
      );
    }

    if (!_checked) {
      return const Center(child: LoadingSpinner());
    }

    // 不是 SVG，显示错误图标
    return const Center(
      child: Icon(
        Icons.broken_image_outlined,
        size: 64,
        color: Colors.white54,
      ),
    );
  }
}
