import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../utils/link_launcher.dart';
import '../services/toast_service.dart';
import '../services/app_link_service.dart';
import '../services/network/cookie/cookie_store_observer.dart';
import '../services/network/cookie/webview_cookie_priming.dart';
import '../services/webview_settings.dart';
import '../services/windows_webview_environment_service.dart';
import '../widgets/common/app_link_confirm_dialog.dart';
import '../providers/web_bookmark_provider.dart';
import '../providers/web_history_provider.dart';
import '../providers/download_provider.dart';
import 'package:common_ui/common_ui.dart';
import '../l10n/s.dart';
import '../utils/dialog_utils.dart';

/// 通用内置浏览器页面
class WebViewPage extends ConsumerStatefulWidget {
  final String url;
  final String? title;
  final String? injectCss;

  const WebViewPage({super.key, required this.url, this.title, this.injectCss});

  /// 打开浏览器，url 为空字符串时显示空白页
  static Future<T?> open<T extends Object?>(
    BuildContext context,
    String url, {
    String? title,
    String? injectCss,
  }) {
    return Navigator.push<T>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            WebViewPage(url: url, title: title, injectCss: injectCss),
      ),
    );
  }

  @override
  ConsumerState<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends ConsumerState<WebViewPage> {
  InAppWebViewController? _controller;
  bool _isLoading = true;
  String _currentUrl = '';
  String _currentTitle = '';
  double _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;

  /// 对话框期间用静态截图盖住 WebView，避免 BackdropFilter 对
  /// hybrid composition（Android）/HWND（Windows）实时回读造成卡顿。
  Uint8List? _webViewSnapshot;


  @override
  void initState() {
    super.initState();
    _currentUrl = widget.url;
    _currentTitle = widget.title ?? '';
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final windowsWebViewEnvironment =
        WindowsWebViewEnvironmentService.instance.environment;

    final theme = Theme.of(context);
    final isBookmarked = ref.watch(
      webBookmarkProvider.select(
        (list) => list.any((e) => e.url == _currentUrl),
      ),
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _handleBackNavigation();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: GestureDetector(
            onTap: _showUrlInput,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _currentTitle.isNotEmpty
                          ? _currentTitle
                          : (_currentUrl.isNotEmpty
                                ? _currentUrl
                                : context.l10n.webview_inputUrl),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color:
                            _currentTitle.isNotEmpty || _currentUrl.isNotEmpty
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          leading: Center(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          leadingWidth: 48,
          actions: [
            IconButton(
              icon: Icon(
                Icons.chevron_left_rounded,
                color: _canGoBack ? null : theme.disabledColor,
              ),
              onPressed: _canGoBack ? () => _controller?.goBack() : null,
              tooltip: context.l10n.webview_goBack,
            ),
            IconButton(
              icon: Icon(
                Icons.chevron_right_rounded,
                color: _canGoForward ? null : theme.disabledColor,
              ),
              onPressed: _canGoForward ? () => _controller?.goForward() : null,
              tooltip: context.l10n.webview_goForward,
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _controller?.reload(),
              tooltip: context.l10n.common_refresh,
            ),
            SwipeDismissiblePopupMenuButton<String>(
              onSelected: _handleMenuAction,
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'toggle_bookmark',
                  child: Row(
                    children: [
                      Icon(
                        isBookmarked
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        isBookmarked
                            ? context.l10n.webview_removeBookmark
                            : context.l10n.webview_addBookmark,
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'copy_url',
                  child: Row(
                    children: [
                      const Icon(Icons.copy),
                      const SizedBox(width: 8),
                      Text(context.l10n.common_copyLink),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'open_external',
                  child: Row(
                    children: [
                      const Icon(Icons.open_in_browser),
                      const SizedBox(width: 8),
                      Text(context.l10n.webview_openExternal),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        body: Column(
              children: [
                if (_isLoading)
                  LinearProgressIndicator(
                    value: _progress,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Offstage(
                        offstage: _webViewSnapshot != null,
                        child: WebViewSettings.wrapWithScrollFix(
                      InAppWebView(
                            webViewEnvironment: windowsWebViewEnvironment,
                            initialSettings: WebViewSettings.visible
                              ..useShouldOverrideUrlLoading = true,
                            initialUserScripts:
                                WebViewSettings.compatPolyfillScripts,
                            shouldOverrideUrlLoading:
                                _shouldOverrideUrlLoading,
                            onReceivedServerTrustAuthRequest: (_, challenge) =>
                                WebViewSettings.handleServerTrustAuthRequest(
                                  challenge,
                                ),
                            onWebViewCreated: (controller) async {
                              _controller = controller;
                              // 老 WKWebView 的 JS 运行时错误回传到 LogWriter。
                              WebViewSettings.registerJsErrorReporter(controller);
                              if (widget.url.isNotEmpty) {
                                // v0.4.0: 取代 RawSetCookieQueue.flush
                                await WebViewCookiePriming.instance
                                    .prime(widget.url);
                                await controller.loadUrl(
                                  urlRequest:
                                      URLRequest(url: WebUri(widget.url)),
                                );
                              }
                              // Android: 启用 WebAuthn/PassKey 支持
                              if (io.Platform.isAndroid) {
                                WidgetsBinding.instance
                                    .addPostFrameCallback((_) {
                                  const MethodChannel('com.fluxdo/webauthn')
                                      .invokeMethod('enableWebAuthentication');
                                });
                              }
                            },
                            onLoadStart: (controller, url) {
                              setState(() {
                                _isLoading = true;
                                _currentUrl = url?.toString() ?? '';
                              });
                            },
                            onProgressChanged: (controller, progress) {
                              setState(() => _progress = progress / 100);
                            },
                            onLoadStop: (controller, url) async {
                              setState(() => _isLoading = false);
                              // 触发 cookie observer sweep (Android 主要触发点;
                              // Apple 平台 native observer 已有覆盖, 此处与 debounce
                              // 合并不会重复 sweep)
                              CookieStoreObserver.instance.notifyExternalChange();
                              await WebViewSettings.injectScrollFix(controller);
                              final title = await controller.getTitle();
                              final canGoBack = await controller.canGoBack();
                              final canGoForward =
                                  await controller.canGoForward();
                              final urlString = url?.toString();
                              setState(() {
                                _currentUrl = urlString ?? '';
                                _canGoBack = canGoBack;
                                _canGoForward = canGoForward;
                                if (title != null && title.isNotEmpty) {
                                  _currentTitle = title;
                                }
                              });
                              if (widget.injectCss != null) {
                                await controller.injectCSSCode(
                                  source: widget.injectCss!,
                                );
                              }
                              // 记录浏览历史
                              if (urlString != null && urlString.isNotEmpty) {
                                ref
                                    .read(webHistoryProvider.notifier)
                                    .record(urlString, _currentTitle);
                              }
                            },
                            onUpdateVisitedHistory:
                                (controller, url, isReload) async {
                                  final canGoBack =
                                      await controller.canGoBack();
                                  final canGoForward =
                                      await controller.canGoForward();
                                  final urlString = url?.toString();
                                  setState(() {
                                    _currentUrl = urlString ?? '';
                                    _canGoBack = canGoBack;
                                    _canGoForward = canGoForward;
                                  });
                                },
                            onTitleChanged: (controller, title) {
                              if (title != null && title.isNotEmpty) {
                                setState(() => _currentTitle = title);
                              }
                            },
                            onDownloadStarting: (controller, request) {
                              final url = request.url.toString();
                              ref
                                  .read(downloadProvider.notifier)
                                  .startDownload(
                                    url: url,
                                    suggestedFilename:
                                        request.suggestedFilename,
                                    mimeType: request.mimeType,
                                    contentLength: request.contentLength,
                                  );
                              return null;
                            },
                          ),
                          getController: () => _controller,
                        ),
                      ),
                      if (_webViewSnapshot != null)
                        Positioned.fill(
                          child: RepaintBoundary(
                            child: Image.memory(
                              _webViewSnapshot!,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
        ),
      ),
    );
  }

  /// 允许 WebView 内部加载的 scheme
  static const _allowedSchemes = {'http', 'https', 'about', 'data', 'blob'};

  /// 拦截 URL 加载：对非 HTTP(S) 的应用链接弹出确认对话框
  Future<NavigationActionPolicy> _shouldOverrideUrlLoading(
    InAppWebViewController controller,
    NavigationAction navigationAction,
  ) async {
    final url = navigationAction.request.url;
    if (url == null) return NavigationActionPolicy.ALLOW;

    final scheme = url.scheme.toLowerCase();

    // HTTP(S) 和内部 scheme 正常加载
    if (_allowedSchemes.contains(scheme)) {
      return NavigationActionPolicy.ALLOW;
    }

    // javascript: 静默阻止
    if (scheme == 'javascript') {
      return NavigationActionPolicy.CANCEL;
    }

    // 其他 scheme（应用链接）：解析目标应用并弹出确认对话框
    final urlString = url.toString();
    if (!mounted) return NavigationActionPolicy.CANCEL;

    // 通过原生代码解析目标应用信息
    final appInfo = await AppLinkService.resolveAppLink(urlString);

    if (!mounted) return NavigationActionPolicy.CANCEL;

    final confirmed = await showAppLinkConfirmDialog(
      context,
      urlString,
      appName: appInfo.appName,
      appIcon: appInfo.appIcon,
    );

    if (confirmed == true) {
      final success = await AppLinkService.launchAppLink(urlString);
      if (!success && mounted) {
        ToastService.showError(S.current.webview_noAppForLink);
      }
    }

    // 无论用户选择如何，都不让 WebView 加载此 URL
    return NavigationActionPolicy.CANCEL;
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'toggle_bookmark':
        _toggleBookmark();
        break;
      case 'copy_url':
        _copyUrl();
        break;
      case 'open_external':
        _openInExternalBrowser();
        break;
    }
  }

  /// 弹出 URL 输入对话框。
  ///
  /// 为避免 BackdropFilter 对实时 WebView 做高斯模糊导致的掉帧，
  /// 先截图盖在 WebView 之上，让对话框模糊的是静态图像。
  /// 截图覆盖后 WebView 也不再持有 InputConnection，键盘可立即弹出。
  Future<void> _showUrlInput() async {
    final snapshot = await _controller?.takeScreenshot();
    if (!mounted) return;
    if (snapshot != null) {
      setState(() => _webViewSnapshot = snapshot);
    }

    final textController = TextEditingController(text: _currentUrl);
    final focusNode = FocusNode();
    try {
      await showAppDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(S.current.webview_inputUrl),
          content: TextField(
            controller: textController,
            focusNode: focusNode,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              hintText: 'https://',
              suffixIcon: IconButton(
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () => textController.clear(),
              ),
            ),
            onSubmitted: (value) {
              Navigator.pop(ctx);
              _navigateToUrl(value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(S.current.common_cancel),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _navigateToUrl(textController.text);
              },
              child: Text(S.current.webview_go),
            ),
          ],
        ),
      );
    } finally {
      focusNode.dispose();
      textController.dispose();
      if (mounted && _webViewSnapshot != null) {
        setState(() => _webViewSnapshot = null);
      }
    }
  }

  void _navigateToUrl(String input) {
    var url = input.trim();
    if (url.isEmpty) return;
    // 自动补全 scheme
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  void _toggleBookmark() {
    if (_currentUrl.isEmpty) return;
    final added = ref
        .read(webBookmarkProvider.notifier)
        .toggle(_currentUrl, _currentTitle);
    ToastService.showSuccess(
      added
          ? S.current.webview_bookmarkAdded
          : S.current.webview_bookmarkRemoved,
    );
  }

  Future<void> _handleBackNavigation() async {
    final controller = _controller;
    if (controller == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final canGoBack = await controller.canGoBack();
    if (canGoBack) {
      await controller.goBack();
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _copyUrl() async {
    if (_currentUrl.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: _currentUrl));
      if (mounted) {
        ToastService.showSuccess(S.current.common_linkCopied);
      }
    }
  }

  Future<void> _openInExternalBrowser() async {
    if (_currentUrl.isEmpty) return;

    try {
      final success = await launchInExternalBrowser(_currentUrl);
      if (!success && mounted) {
        ToastService.showError(S.current.webview_cannotOpenBrowser);
      }
    } catch (e) {
      if (mounted) {
        ToastService.showError(S.current.webview_openFailed(e.toString()));
      }
    }
  }
}
