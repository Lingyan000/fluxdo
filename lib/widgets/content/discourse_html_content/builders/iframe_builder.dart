import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../../../constants.dart';
import '../../../../utils/layout_lock.dart';
import '../../../../utils/url_helper.dart';
import '../../../../pages/webview_page.dart';
import '../../../../l10n/s.dart';
import '../../../../services/webview_settings.dart';
import '../../../../services/windows_webview_environment_service.dart';

/// 是否需要交互遮罩（macOS 上 WebView 会捕获滚动事件）
bool get _needsInteractionMask => !kIsWeb && Platform.isMacOS;

/// iframe 属性解析结果
class IframeAttributes {
  final String src;
  final double? width;
  final double? height;
  final Set<String>? sandbox;
  final Set<String> allow;
  final bool allowFullscreen;
  final String? referrerPolicy;
  final bool lazyLoad;
  final String? title;
  final Set<String> classes;

  IframeAttributes({
    required this.src,
    this.width,
    this.height,
    this.sandbox,
    this.allow = const {},
    this.allowFullscreen = false,
    this.referrerPolicy,
    this.lazyLoad = false,
    this.title,
    this.classes = const {},
  });

  /// 从 HTML element 解析 iframe 属性
  factory IframeAttributes.fromElement(dynamic element) {
    final attrs = element.attributes;

    // src 属性
    final src =
        (attrs['src'] as String?) ?? (attrs['data-src'] as String?) ?? '';

    // 宽高属性
    final width = double.tryParse(attrs['width'] as String? ?? '');
    final height = double.tryParse(attrs['height'] as String? ?? '');

    // class 属性
    final classAttr = attrs['class'] as String?;
    final classes = classAttr?.split(RegExp(r'\s+')).toSet() ?? {};

    // sandbox 属性
    final sandboxAttr = attrs['sandbox'] as String?;
    final sandbox = sandboxAttr?.split(RegExp(r'\s+')).toSet();

    // allow 属性 (Permissions Policy)
    final allowAttr = attrs['allow'] as String?;
    final allow =
        allowAttr
            ?.split(';')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toSet() ??
        {};

    // allowfullscreen 属性
    final allowFullscreen =
        attrs.containsKey('allowfullscreen') ||
        attrs['allowfullscreen'] == 'true' ||
        attrs['allowfullscreen'] == '' ||
        allow.any((p) => p.startsWith('fullscreen'));

    // referrerpolicy 属性
    final referrerPolicy = attrs['referrerpolicy'] as String?;

    // loading 属性
    final loadingAttr = attrs['loading'] as String?;
    final lazyLoad = loadingAttr == 'lazy';

    // title 属性
    final title = attrs['title'] as String?;

    return IframeAttributes(
      src: src,
      width: width,
      height: height,
      sandbox: sandbox,
      allow: allow,
      allowFullscreen: allowFullscreen,
      referrerPolicy: referrerPolicy,
      lazyLoad: lazyLoad,
      title: title,
      classes: classes,
    );
  }

  /// 是否允许脚本执行
  bool get allowScripts =>
      sandbox == null || sandbox!.contains('allow-scripts');

  /// 是否允许自动播放
  bool get allowAutoplay => allow.any((p) => p.startsWith('autoplay'));

  /// 计算宽高比
  double get aspectRatio {
    // 视频 onebox 强制使用 16:9（遵循 Discourse CSS 规则）
    if (classes.contains('youtube-onebox') ||
        classes.contains('lazyYT') ||
        classes.contains('vimeo-onebox') ||
        classes.contains('loom-onebox')) {
      return 16 / 9;
    }

    // 其他情况：如果有明确的宽高，使用计算值
    if (width != null && width! > 0 && height != null && height! > 0) {
      return width! / height!;
    }

    // 默认 16:9
    return 16 / 9;
  }

  /// 获取完整 URL
  String get fullUrl => UrlHelper.resolveUrl(src);
}

/// 构建 iframe Widget
Widget? buildIframe({required BuildContext context, required dynamic element}) {
  // Web 平台不处理，让 flutter_widget_from_html 处理
  if (kIsWeb) return null;

  final attrs = IframeAttributes.fromElement(element);

  if (attrs.src.isEmpty) {
    return const SizedBox.shrink();
  }

  return IframeWidget(attributes: attrs);
}

/// iframe Widget
class IframeWidget extends StatefulWidget {
  final IframeAttributes attributes;

  const IframeWidget({super.key, required this.attributes});

  @override
  State<IframeWidget> createState() => _IframeWidgetState();
}

class _IframeWidgetState extends State<IframeWidget> {
  bool _isLoaded = false;
  bool _hasError = false;
  bool _didLockLayout = false;

  /// 桌面平台：是否进入交互模式
  bool _interacting = false;
  OverlayEntry? _overlayEntry;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _removeOverlay();
    _unlockLayoutIfNeeded();
    super.dispose();
  }

  void _enterInteractMode() {
    setState(() => _interacting = true);
    _showOverlay();
  }

  void _exitInteractMode() {
    _removeOverlay();
    setState(() => _interacting = false);
  }

  void _showOverlay() {
    _removeOverlay();
    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.of(context).padding.top + 8,
        left: 0,
        right: 0,
        child: Center(
          child: Material(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: _exitInteractMode,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.close, size: 18, color: Colors.white),
                    const SizedBox(width: 6),
                    Text(
                      S.current.iframe_exitInteraction,
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    final attrs = widget.attributes;
    final theme = Theme.of(context);
    final windowsWebViewEnvironment =
        WindowsWebViewEnvironmentService.instance.environment;

    // 构建内容 Widget
    Widget content = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: [
          // WebView - 始终渲染
          // 直接加载 URL，通过设置 Referer 头解决 origin 验证问题
          InAppWebView(
            webViewEnvironment: windowsWebViewEnvironment,
            initialUrlRequest: URLRequest(
              url: WebUri(attrs.fullUrl),
              headers: {'Referer': AppConstants.baseUrl},
            ),
            initialSettings: _buildSettings(attrs),
            onReceivedServerTrustAuthRequest: (_, challenge) =>
                WebViewSettings.handleServerTrustAuthRequest(challenge),
            // 允许 WebView 接收水平滑动手势
            gestureRecognizers: {
              Factory<HorizontalDragGestureRecognizer>(
                () => HorizontalDragGestureRecognizer(),
              ),
            },
            onEnterFullscreen: (controller) {
              _lockLayout();
            },
            onExitFullscreen: (controller) {
              _unlockLayoutIfNeeded();
            },
            onLoadStart: (controller, url) {
              if (mounted) {
                setState(() {
                  _isLoaded = false;
                  _hasError = false;
                });
              }
            },
            onLoadStop: (controller, url) async {
              if (mounted) {
                setState(() => _isLoaded = true);
              }
              // 注入 viewport meta 标签，确保内容正确缩放
              await controller.evaluateJavascript(
                source: '''
                    (function() {
                      var meta = document.querySelector('meta[name="viewport"]');
                      if (!meta) {
                        meta = document.createElement('meta');
                        meta.name = 'viewport';
                        document.head.appendChild(meta);
                      }
                      meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
                    })();
                  ''',
              );
            },
            onReceivedError: (controller, request, error) {
              // 只有主框架加载失败才显示错误
              // 忽略子资源（JS、图片、视频海报等）的加载错误
              if (mounted && request.isForMainFrame == true) {
                setState(() => _hasError = true);
              }
            },
            // 拦截用户点击的链接，使用 WebViewPage 打开
            shouldOverrideUrlLoading: (controller, navigationAction) async {
              // 只拦截用户主动点击的链接
              if (navigationAction.navigationType !=
                  NavigationType.LINK_ACTIVATED) {
                return NavigationActionPolicy.ALLOW;
              }

              final url = navigationAction.request.url?.toString();
              if (url == null) {
                return NavigationActionPolicy.ALLOW;
              }

              // 使用 WebViewPage 打开
              if (mounted) {
                WebViewPage.open(context, url);
              }
              return NavigationActionPolicy.CANCEL;
            },
          ),
          // 加载指示器
          if (!_isLoaded && !_hasError)
            Container(
              color: theme.colorScheme.surfaceContainerHighest,
              child: const Center(child: CircularProgressIndicator()),
            ),
          // 错误状态
          if (_hasError)
            Container(
              color: theme.colorScheme.surfaceContainerHighest,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 48,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      S.current.common_loadFailed,
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // 桌面平台：交互遮罩
          if (_needsInteractionMask && !_interacting && _isLoaded && !_hasError)
            Positioned.fill(
              child: GestureDetector(
                onTap: _enterInteractMode,
                child: Container(
                  color: Colors.black38,
                  child: const Center(
                    child: Icon(
                      Icons.touch_app,
                      size: 48,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    // 始终使用响应式宽高比布局，忽略固定像素尺寸
    // 这样可以适配不同屏幕尺寸，避免在小屏幕上溢出或在大屏幕上显得太小
    Widget sizedContent;

    // 特殊情况：如果只有固定高度（没有宽度或宽度是百分比），使用固定高度
    // 例如：width="100%" height="111"
    if (attrs.height != null && attrs.height! > 0 && attrs.width == null) {
      sizedContent = SizedBox(
        width: double.infinity,
        height: attrs.height,
        child: content,
      );
    } else {
      // 其他情况使用宽高比
      sizedContent = AspectRatio(
        aspectRatio: attrs.aspectRatio,
        child: content,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: sizedContent,
    );
  }

  InAppWebViewSettings _buildSettings(IframeAttributes attrs) {
    return InAppWebViewSettings(
      // User-Agent
      userAgent: AppConstants.webViewUserAgentOverride,

      // JavaScript（根据 sandbox 属性决定）
      javaScriptEnabled: attrs.allowScripts,

      // 媒体播放
      mediaPlaybackRequiresUserGesture: !attrs.allowAutoplay,
      allowsInlineMediaPlayback: true,

      // 全屏（根据 allowfullscreen 属性决定）
      iframeAllowFullscreen: attrs.allowFullscreen,

      // 外观
      transparentBackground: true,

      // 安全
      javaScriptCanOpenWindowsAutomatically: false,

      // 性能
      useHybridComposition: true,

      // 内容模式
      preferredContentMode: UserPreferredContentMode.RECOMMENDED,

      // 允许混合内容和第三方 cookies
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      thirdPartyCookiesEnabled: true,
    );
  }

  void _lockLayout() {
    if (_didLockLayout) return;
    _didLockLayout = true;
    LayoutLock.acquire();
  }

  void _unlockLayoutIfNeeded() {
    if (!_didLockLayout) return;
    _didLockLayout = false;
    LayoutLock.release();
  }
}
