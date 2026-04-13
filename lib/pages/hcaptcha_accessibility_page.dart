import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../l10n/s.dart';
import '../services/hcaptcha_accessibility_service.dart';
import '../services/toast_service.dart';
import '../services/webview_settings.dart';
import '../services/windows_webview_environment_service.dart';

/// hCaptcha 无障碍注册页面
///
/// 加载 hCaptcha 无障碍页面，用户完成注册后点击"完成"按钮，
/// 自动读取 Cookie 并保存。
class HCaptchaAccessibilityPage extends StatefulWidget {
  const HCaptchaAccessibilityPage({super.key});

  @override
  State<HCaptchaAccessibilityPage> createState() =>
      _HCaptchaAccessibilityPageState();
}

class _HCaptchaAccessibilityPageState extends State<HCaptchaAccessibilityPage> {
  InAppWebViewController? _controller;
  bool _isLoading = true;
  double _progress = 0;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final windowsWebViewEnvironment =
        WindowsWebViewEnvironmentService.instance.environment;

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.hcaptcha_webviewTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.content_paste_outlined),
            tooltip: context.l10n.hcaptcha_pasteLink,
            onPressed: _pasteLink,
          ),
          TextButton(
            onPressed: _onDone,
            child: Text(context.l10n.hcaptcha_done),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isLoading) LinearProgressIndicator(value: _progress),
          Expanded(
            child: WebViewSettings.wrapWithScrollFix(
              InAppWebView(
                webViewEnvironment: windowsWebViewEnvironment,
                initialUrlRequest: URLRequest(
                  url: WebUri('https://www.hcaptcha.com/accessibility'),
                ),
                initialSettings: WebViewSettings.visible,
                onReceivedServerTrustAuthRequest: (_, challenge) =>
                    WebViewSettings.handleServerTrustAuthRequest(challenge),
                onWebViewCreated: (controller) {
                  _controller = controller;
                },
                onLoadStart: (controller, url) => setState(() {
                  _isLoading = true;
                }),
                onProgressChanged: (controller, progress) =>
                    setState(() => _progress = progress / 100),
                onLoadStop: (controller, url) async {
                  setState(() => _isLoading = false);
                  await WebViewSettings.injectScrollFix(controller);
                },
              ),
              getController: () => _controller,
            ),
          ),
        ],
      ),
    );
  }

  /// 从剪贴板粘贴邮箱登录链接并在 WebView 中加载
  Future<void> _pasteLink() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';

    if (text.isEmpty) {
      ToastService.showError(S.current.hcaptcha_pasteLinkInvalid);
      return;
    }

    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme || !uri.host.contains('hcaptcha.com')) {
      ToastService.showError(S.current.hcaptcha_pasteLinkInvalid);
      return;
    }

    _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(text)));
  }

  Future<void> _onDone() async {
    final cookieManager =
        WindowsWebViewEnvironmentService.instance.cookieManager;
    final cookies = await cookieManager.getCookies(
      url: WebUri('https://www.hcaptcha.com'),
    );

    String? cookieValue;
    for (final cookie in cookies) {
      if (cookie.name == HCaptchaAccessibilityService.cookieName) {
        cookieValue = cookie.value;
        break;
      }
    }

    if (cookieValue != null && cookieValue.isNotEmpty) {
      await HCaptchaAccessibilityService().setCookie(cookieValue);
      ToastService.showSuccess(S.current.hcaptcha_cookieSaved);
      if (mounted) Navigator.of(context).pop(true);
    } else {
      ToastService.showError(S.current.hcaptcha_cookieNotFound);
    }
  }
}
