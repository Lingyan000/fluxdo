import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../constants.dart';
import '../../services/auth_session.dart';
import '../../services/cf_challenge_service.dart';
import '../../services/network/cookie/cookie_store_observer.dart';
import '../../services/network/cookie/webview_cookie_priming.dart';
import '../../services/webview_settings.dart';
import '../../services/windows_webview_environment_service.dart';

/// 通过可见浏览器导航读取页面，跨站 SSO 与验证全程留在同一浏览器。
class BrowserDocumentLoader extends StatefulWidget {
  const BrowserDocumentLoader({
    super.key,
    required this.url,
    required this.onDocument,
    required this.onError,
  });

  final String url;
  final ValueChanged<String> onDocument;
  final void Function(Object error, StackTrace stack) onError;

  @override
  State<BrowserDocumentLoader> createState() => _BrowserDocumentLoaderState();
}

class _BrowserDocumentLoaderState extends State<BrowserDocumentLoader> {
  InAppWebViewController? _controller;
  bool _ready = false;
  bool _finished = false;
  int _navigation = 0;
  late final int _authGeneration;
  late String _currentUrl;

  @override
  void initState() {
    super.initState();
    _authGeneration = AuthSession().generation;
    _currentUrl = widget.url;
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      await WindowsWebViewEnvironmentService.instance.initialize();
      // 主站的 host-only 登录 Cookie 不属于目标子域，需在 SSO 跳转前单独对齐。
      await WebViewCookiePriming.instance.prime(AppConstants.baseUrl);
      await WebViewCookiePriming.instance.prime(widget.url);
      if (!mounted) return;
      if (!AuthSession().isValid(_authGeneration)) {
        throw StateError('页面所属登录会话已结束');
      }
      setState(() => _ready = true);
    } catch (error, stack) {
      _fail(error, stack);
    }
  }

  void _fail(Object error, StackTrace stack) {
    if (!mounted || _finished) return;
    _finished = true;
    widget.onError(error, stack);
  }

  Future<void> _readDocument(InAppWebViewController controller) async {
    final navigation = _navigation;
    try {
      await WebViewSettings.injectScrollFix(controller);
      CookieStoreObserver.instance.notifyExternalChange();
      final result = await controller.evaluateJavascript(source: '''
JSON.stringify({url: location.href,
  html: document.readyState === 'complete' && document.documentElement
    ? document.documentElement.outerHTML : ''})
''');
      if (!mounted || _finished || navigation != _navigation) return;
      if (!AuthSession().isValid(_authGeneration)) {
        throw StateError('页面所属登录会话已结束');
      }
      if (result is! String || result.isEmpty) return;
      final document = jsonDecode(result) as Map<String, dynamic>;
      final actual = Uri.tryParse(document['url'] as String? ?? '');
      final target = Uri.parse(widget.url);
      // 只读取目标文档，SSO 中间页和跨域验证页由浏览器继续导航。
      if (actual == null ||
          !actual.hasAuthority ||
          actual.origin != target.origin ||
          actual.path != target.path) {
        return;
      }
      final html = document['html'] as String? ?? '';
      if (html.isEmpty ||
          CfChallengeService.isCfChallenge(html) ||
          CfChallengeService.hasActiveCfChallenge(html)) {
        return;
      }
      _finished = true;
      widget.onDocument(html);
    } catch (error, stack) {
      if (navigation == _navigation) _fail(error, stack);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const Center(child: CircularProgressIndicator());
    return WebViewSettings.wrapWithScrollFix(
      InAppWebView(
        webViewEnvironment:
            WindowsWebViewEnvironmentService.instance.environment,
        initialSettings: WebViewSettings.visible,
        initialUserScripts: WebViewSettings.compatPolyfillScripts,
        initialUrlRequest: URLRequest(url: WebUri(widget.url)),
        onWebViewCreated: (controller) => _controller = controller,
        onLoadStart: (_, url) {
          _navigation++;
          if (url != null) _currentUrl = url.toString();
        },
        onLoadStop: (controller, _) => _readDocument(controller),
        onReceivedServerTrustAuthRequest: (_, challenge) =>
            WebViewSettings.handleServerTrustAuthRequest(challenge),
        onReceivedError: (_, request, error) {
          if (request.isForMainFrame == true &&
              request.url.toString() == _currentUrl &&
              error.type != WebResourceErrorType.CANCELLED) {
            _fail(StateError(error.description), StackTrace.current);
          }
        },
      ),
      getController: () => _controller,
    );
  }
}
