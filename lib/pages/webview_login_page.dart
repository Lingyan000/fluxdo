import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../constants.dart';
import '../services/discourse/discourse_service.dart';
import '../services/preloaded_data_service.dart';
import '../services/network/cookie/cookie_jar_service.dart';
import '../services/network/cookie/cookie_sync_service.dart';
import '../services/webview_settings.dart';

/// WebView 登录页面（统一使用 flutter_inappwebview）
class WebViewLoginPage extends StatefulWidget {
  const WebViewLoginPage({super.key});

  @override
  State<WebViewLoginPage> createState() => _WebViewLoginPageState();
}

class _WebViewLoginPageState extends State<WebViewLoginPage> {
  final _service = DiscourseService();
  final _cookieJar = CookieJarService();
  InAppWebViewController? _controller;
  bool _isLoading = true;
  String _url = '${AppConstants.baseUrl}/';
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    // 打开 WebView 前先同步 Cookie 到 WebView
    _cookieJar.syncToWebView();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录 Linux.do'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => _controller?.reload(), tooltip: '刷新'),
        ],
      ),
      body: Column(
        children: [
          if (_isLoading) LinearProgressIndicator(value: _progress),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                Icon(Icons.lock, size: 14, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(_url, style: Theme.of(context).textTheme.bodySmall, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri('${AppConstants.baseUrl}/')),
              initialSettings: WebViewSettings.visible,
              onWebViewCreated: (controller) => _controller = controller,
              onLoadStart: (controller, url) => setState(() { _isLoading = true; _url = url?.toString() ?? ''; }),
              onProgressChanged: (controller, progress) => setState(() => _progress = progress / 100),
              onLoadStop: (controller, url) async {
                setState(() { _isLoading = false; _url = url?.toString() ?? ''; });
                // 自动检测登录状态
                await _checkLoginStatus(controller);
              },
              // 处理 window.open()（Google OAuth 等第三方登录弹窗）
              onCreateWindow: (controller, createWindowAction) async {
                // 在同一个 WebView 中加载弹窗 URL
                final url = createWindowAction.request.url;
                if (url != null) {
                  controller.loadUrl(urlRequest: createWindowAction.request);
                }
                return true;
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 检测登录状态，登录成功自动关闭
  Future<void> _checkLoginStatus(InAppWebViewController controller) async {
    final cookieManager = CookieManager.instance();
    final cookies = await cookieManager.getCookies(url: WebUri('${AppConstants.baseUrl}/'));

    String? tToken;
    String? cfClearance;

    for (final cookie in cookies) {
      if (cookie.name == '_t') tToken = cookie.value;
      if (cookie.name == 'cf_clearance') cfClearance = cookie.value;
    }

    if (tToken == null || tToken.isEmpty) return;

    // 尝试从页面获取用户名
    String? username;
    try {
      final result = await controller.evaluateJavascript(source: '''
        (function() {
          try {
            var meta = document.querySelector('meta[name="current-username"]');
            if (meta && meta.content) return meta.content;
            if (typeof Discourse !== 'undefined' && Discourse.User && Discourse.User.current()) {
              return Discourse.User.current().username;
            }
            return null;
          } catch(e) { return null; }
        })();
      ''');

      if (result != null && result.toString().isNotEmpty && result.toString() != 'null') {
        username = result.toString();
      }
    } catch (e) {
      debugPrint('[WebViewLogin] 获取用户名失败: $e');
    }

    // 保存 tokens 和用户名
    await _service.saveTokens(tToken: tToken, cfClearance: cfClearance);
    if (username != null && username.isNotEmpty) {
      await _service.saveUsername(username);
    }
    // 同步 CSRF（从页面 meta 获取）
    try {
      final csrf = await controller.evaluateJavascript(source: '''
        (function() {
          var meta = document.querySelector('meta[name="csrf-token"]');
          return meta && meta.content ? meta.content : null;
        })();
      ''');
      if (csrf != null && csrf.toString().isNotEmpty && csrf.toString() != 'null') {
        CookieSyncService().setCsrfToken(csrf.toString());
      }
    } catch (e) {
      debugPrint('[WebViewLogin] 同步 CSRF 失败: $e');
    }
    // 登录后从 WebView 同步 Cookie 到 CookieJar
    await _cookieJar.syncFromWebView();
    // 登录后重新加载预热数据
    await PreloadedDataService().refresh();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('登录成功！${username != null ? '用户: $username' : ''}'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.of(context).pop(true);
    }
  }
}
