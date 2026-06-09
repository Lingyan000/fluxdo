import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../l10n/s.dart';
import '../services/network/cookie/boundary_sync_service.dart';
import '../services/network/cookie/raw_set_cookie_queue.dart';
import '../services/webview_settings.dart';
import '../services/windows_webview_environment_service.dart';

class LdcOAuthWebViewPage extends StatefulWidget {
  final String authUrl;
  final Future<bool> Function() checkAuthorized;

  const LdcOAuthWebViewPage({
    super.key,
    required this.authUrl,
    required this.checkAuthorized,
  });

  static Future<bool?> open(
    BuildContext context, {
    required String authUrl,
    required Future<bool> Function() checkAuthorized,
  }) {
    return Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => LdcOAuthWebViewPage(
          authUrl: authUrl,
          checkAuthorized: checkAuthorized,
        ),
      ),
    );
  }

  @override
  State<LdcOAuthWebViewPage> createState() => _LdcOAuthWebViewPageState();
}

class _LdcOAuthWebViewPageState extends State<LdcOAuthWebViewPage> {
  InAppWebViewController? _controller;
  bool _isLoading = true;
  bool _isChecking = false;
  bool _authHandled = false;
  String _currentUrl = '';
  double _progress = 0;
  String? _pendingAuthorizationUrl;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.authUrl;
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

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.metaverse_ldcService)),
      body: Column(
        children: [
          if (_isLoading)
            LinearProgressIndicator(value: _progress == 0 ? null : _progress),
          Expanded(
            child: WebViewSettings.wrapWithScrollFix(
              InAppWebView(
                webViewEnvironment: windowsWebViewEnvironment,
                initialSettings: WebViewSettings.visible
                  ..useShouldOverrideUrlLoading = true,
                initialUserScripts: WebViewSettings.ios15PolyfillScripts,
                shouldOverrideUrlLoading: _shouldOverrideUrlLoading,
                onReceivedServerTrustAuthRequest: (_, challenge) =>
                    WebViewSettings.handleServerTrustAuthRequest(challenge),
                onWebViewCreated: (controller) async {
                  _controller = controller;
                  await RawSetCookieQueue.instance.flushToWebView();
                  await controller.loadUrl(
                    urlRequest: URLRequest(url: WebUri(widget.authUrl)),
                  );
                  if (io.Platform.isAndroid) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      const MethodChannel(
                        'com.fluxdo/webauthn',
                      ).invokeMethod('enableWebAuthentication');
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
                  setState(() {
                    _isLoading = false;
                    _currentUrl = url?.toString() ?? _currentUrl;
                  });
                  await WebViewSettings.injectScrollFix(controller);
                  await _checkAuthorization(controller, _currentUrl);
                },
                onUpdateVisitedHistory: (controller, url, isReload) async {
                  final currentUrl = url?.toString() ?? '';
                  setState(() => _currentUrl = currentUrl);
                  await _checkAuthorization(controller, currentUrl);
                },
              ),
              getController: () => _controller,
            ),
          ),
        ],
      ),
    );
  }

  Future<NavigationActionPolicy> _shouldOverrideUrlLoading(
    InAppWebViewController controller,
    NavigationAction navigationAction,
  ) async {
    final url = navigationAction.request.url;
    if (url == null) return NavigationActionPolicy.CANCEL;

    final scheme = url.scheme.toLowerCase();
    if (scheme == 'http' ||
        scheme == 'https' ||
        scheme == 'about' ||
        scheme == 'data' ||
        scheme == 'blob') {
      return NavigationActionPolicy.ALLOW;
    }
    return NavigationActionPolicy.CANCEL;
  }

  Future<void> _checkAuthorization(
    InAppWebViewController controller,
    String currentUrl,
  ) async {
    if (_authHandled || currentUrl.isEmpty) return;

    if (_isChecking) {
      _pendingAuthorizationUrl = currentUrl;
      return;
    }

    final uri = Uri.tryParse(currentUrl);
    if (uri == null || uri.host != 'credit.linux.do') {
      return;
    }

    _isChecking = true;
    try {
      await BoundarySyncService.instance.syncFromWebView(
        currentUrl: currentUrl,
        controller: controller,
        allowLowConfidenceSessionCookies: true,
      );

      final authorized = await widget.checkAuthorized();
      if (!mounted || !authorized) return;

      _authHandled = true;
      Navigator.of(context).pop(true);
    } finally {
      _isChecking = false;
      final pendingAuthorizationUrl = _pendingAuthorizationUrl;
      _pendingAuthorizationUrl = null;
      if (!_authHandled &&
          mounted &&
          pendingAuthorizationUrl != null &&
          pendingAuthorizationUrl.isNotEmpty) {
        unawaited(_checkAuthorization(controller, pendingAuthorizationUrl));
      }
    }
  }
}
