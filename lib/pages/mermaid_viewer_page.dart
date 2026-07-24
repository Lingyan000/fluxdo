import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:app_icons/app_icons.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../l10n/s.dart';
import 'image_viewer_page.dart';

/// Mermaid 矢量查看页 —— WebView 顶级文档加载 kroki SVG。
///
/// 定位:**辅助入口**(mermaid 块顶栏放大按钮),不是点图默认路径 ——
/// 点图仍走位图查看器(手势/保存/分享体验成熟)。大图(mindmap 等)
/// kroki PNG 恒 1x 放大必糊,这里 SVG 矢量任意缩放不糊。
///
/// UI:常规 M3 页面(AppBar + 正文),不抄 ImageViewerPage 的沉浸式
/// 浮钮 —— SVG 文档顶格排版,浮钮会盖住首行内容;灰底文档页也撑不起
/// 全屏照片那套视觉。AppBar 动作位提供「图片查看器」切换。
///
/// 为什么是 WebView:mermaid SVG 含 `<foreignObject>`(HTML 标签),
/// Flutter 侧 SVG 库均渲染不了(jovial_svg 无 marker/级联 CSS,已勘探
/// 定案),只有浏览器引擎能完整渲染;顶级文档打开 SVG 自带 pinch 缩放。
/// 性能:独立 push 页,平台视图不在滚动列表里,无 HC 全页合成问题。
class MermaidViewerPage extends StatefulWidget {
  const MermaidViewerPage({
    super.key,
    required this.svgUrl,
    required this.fallbackImageUrl,
  });

  /// kroki SVG 端点 URL。
  final String svgUrl;

  /// 降级位图 URL(kroki PNG / mermaid.ink)。
  final String fallbackImageUrl;

  static void open(
    BuildContext context, {
    required String svgUrl,
    required String fallbackImageUrl,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MermaidViewerPage(
          svgUrl: svgUrl,
          fallbackImageUrl: fallbackImageUrl,
        ),
      ),
    );
  }

  @override
  State<MermaidViewerPage> createState() => _MermaidViewerPageState();
}

class _MermaidViewerPageState extends State<MermaidViewerPage> {
  bool _loaded = false;
  bool _error = false;
  int _attempt = 0;

  /// 切位图查看器(复用其手势/保存/分享体系)。
  void _openAsImage() {
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.transparent,
        pageBuilder: (_, _, _) => ImageViewerPage(
          imageUrl: widget.fallbackImageUrl,
          enableShare: true,
        ),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    // 内容底色对齐 mermaid 块容器灰底(282a36/f6f8fa):kroki SVG 背景
    // 透明,dark 主题图形浅色线条,必须深底才可读。
    final canvasColor =
        isDark ? const Color(0xff282a36) : const Color(0xfff6f8fa);

    return Scaffold(
      appBar: AppBar(
        title: Text(S.current.codeBlock_chart),
        actions: [
          IconButton(
            icon: const Icon(Symbols.image_rounded),
            tooltip: S.current.common_view,
            onPressed: _openAsImage,
          ),
        ],
      ),
      body: Container(
        color: canvasColor,
        child: Stack(
          children: [
            if (!_error)
              Positioned.fill(
                child: InAppWebView(
                  key: ValueKey('mermaid-svg-$_attempt'),
                  initialUrlRequest: URLRequest(url: WebUri(widget.svgUrl)),
                  initialSettings: InAppWebViewSettings(
                    // 纯 SVG 静态文档,无需 JS
                    javaScriptEnabled: false,
                    transparentBackground: true,
                    // Android pinch 缩放三件套(iOS 默认支持)
                    supportZoom: true,
                    builtInZoomControls: true,
                    displayZoomControls: false,
                    // 大图初始 fit 屏宽,再由用户放大
                    useWideViewPort: true,
                    loadWithOverviewMode: true,
                  ),
                  onLoadStop: (controller, url) {
                    if (mounted) setState(() => _loaded = true);
                  },
                  onReceivedError: (controller, request, error) {
                    if (request.isForMainFrame ?? true) {
                      if (mounted) setState(() => _error = true);
                    }
                  },
                  onReceivedHttpError: (controller, request, response) {
                    if (request.isForMainFrame ?? true) {
                      if (mounted) setState(() => _error = true);
                    }
                  },
                ),
              ),
            if (!_loaded && !_error)
              const Center(child: LoadingSpinner()),
            if (_error)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Symbols.error_rounded,
                        color: theme.colorScheme.error),
                    const SizedBox(height: 12),
                    Text(
                      S.current.codeBlock_chartLoadFailed,
                      style: TextStyle(
                        color: theme.colorScheme.error,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton.icon(
                          onPressed: () => setState(() {
                            _error = false;
                            _loaded = false;
                            _attempt++;
                          }),
                          icon: const Icon(Symbols.refresh_rounded, size: 16),
                          label: Text(S.current.common_retry),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: _openAsImage,
                          icon: const Icon(Symbols.image_rounded, size: 16),
                          label: Text(S.current.common_view),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
