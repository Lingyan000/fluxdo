import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../constants.dart';
import '../providers/preferences_provider.dart';
import '../services/credential_store_service.dart';
import '../services/auth_session.dart';
import '../services/discourse/discourse_service.dart';
import '../services/preloaded_data_service.dart';
import '../services/network/cookie/boundary_sync_service.dart';
import '../services/network/cookie/cookie_jar_service.dart';
import '../services/network/cookie/csrf_token_service.dart';
import '../services/network/cookie/raw_set_cookie_queue.dart';
import '../services/network/adapters/webview_http_adapter.dart';
import '../services/toast_service.dart';
import '../services/hcaptcha_accessibility_service.dart';
import '../services/webview_settings.dart';
import '../services/windows_webview_environment_service.dart';
import '../services/log/log_writer.dart';
import '../widgets/common/dismissible_popup_menu.dart';
import '../l10n/s.dart';
import '../utils/dialog_utils.dart';

/// WebView 登录页面（统一使用 flutter_inappwebview）
class WebViewLoginPage extends ConsumerStatefulWidget {
  /// 初始加载的 URL，默认为登录页面
  /// 用于邮箱链接登录等场景，可传入 email-login URL
  final String? initialUrl;

  const WebViewLoginPage({super.key, this.initialUrl});

  @override
  ConsumerState<WebViewLoginPage> createState() => _WebViewLoginPageState();
}

class _WebViewLoginPageState extends ConsumerState<WebViewLoginPage> {
  final _service = DiscourseService();
  final _cookieJar = CookieJarService();
  final _credentialStore = CredentialStoreService();
  final Uri _baseUri = Uri.parse(AppConstants.baseUrl);
  InAppWebViewController? _controller;
  bool _isLoading = true;
  bool _loginHandled = false;
  bool _loginInProgress = false;
  bool _isCompletingLogin = false;
  String? _lastHomeResponseUrl;
  String _url = AppConstants.baseUrl;
  double _progress = 0;
  String? _savedUsername;
  Future<int>? _initialCookieFlushFuture;

  @override
  void initState() {
    super.initState();
    _initialCookieFlushFuture = () async {
      await WebViewHttpAdapter().runStartupSessionCookieSelfCheckOnce(
        reason: 'login_page',
      );
      return RawSetCookieQueue.instance.flushToWebView();
    }();
    HCaptchaAccessibilityService().syncToWebView();
    _loadSavedUsername();
  }

  Future<void> _loadSavedUsername() async {
    final credentials = await _credentialStore.load();
    if (mounted &&
        credentials.username != null &&
        credentials.username!.isNotEmpty) {
      setState(() => _savedUsername = credentials.username);
    }
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
      appBar: AppBar(
        title: Text(context.l10n.webviewLogin_title),
        actions: [
          IconButton(
            icon: const Icon(Icons.content_paste_outlined),
            tooltip: context.l10n.webviewLogin_emailLoginPaste,
            onPressed: _pasteEmailLoginLink,
          ),
          if (_savedUsername != null)
            SwipeDismissiblePopupMenuButton<String>(
              icon: const Icon(Icons.key_rounded),
              tooltip: context.l10n.webviewLogin_savedPassword,
              onSelected: (value) {
                if (value == 'clear') {
                  _clearCredentials();
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  enabled: false,
                  child: Text(
                    context.l10n.webviewLogin_lastLogin(_savedUsername!),
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'clear',
                  child: Row(
                    children: [
                      const Icon(Icons.delete_outline_rounded, size: 20),
                      const SizedBox(width: 8),
                      Text(context.l10n.webviewLogin_clearSaved),
                    ],
                  ),
                ),
              ],
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller?.reload(),
            tooltip: context.l10n.common_refresh,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isLoading || _isCompletingLogin)
            LinearProgressIndicator(
              value: _isCompletingLogin ? null : _progress,
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                Icon(
                  Icons.lock,
                  size: 14,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _url,
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                WebViewSettings.wrapWithScrollFix(
                  InAppWebView(
                    webViewEnvironment: windowsWebViewEnvironment,
                    initialUrlRequest: URLRequest(
                      url: WebUri(
                        widget.initialUrl ?? '${AppConstants.baseUrl}/login',
                      ),
                    ),
                    initialSettings: WebViewSettings.visible,
                    initialUserScripts: WebViewSettings.ios15PolyfillScripts,
                    onReceivedServerTrustAuthRequest: (_, challenge) =>
                        WebViewSettings.handleServerTrustAuthRequest(challenge),
                    onWebViewCreated: (controller) {
                      _controller = controller;
                      // 注册 JS Handler，用于在登录按钮点击时接收凭证
                      controller.addJavaScriptHandler(
                        handlerName: 'onLoginCredentials',
                        callback: (args) {
                          if (args.isNotEmpty &&
                              ref.read(preferencesProvider).autoFillLogin) {
                            try {
                              final data = args[0] as Map<String, dynamic>;
                              final username = data['username'] as String?;
                              final password = data['password'] as String?;
                              if (username != null &&
                                  username.isNotEmpty &&
                                  password != null &&
                                  password.isNotEmpty) {
                                _credentialStore.save(username, password);
                                if (mounted) {
                                  setState(() => _savedUsername = username);
                                }
                              }
                            } catch (_) {}
                          }
                        },
                      );
                    },
                    onLoadStart: (controller, url) => setState(() {
                      _isLoading = true;
                      _url = url?.toString() ?? '';
                      _lastHomeResponseUrl = null;
                    }),
                    onProgressChanged: (controller, progress) =>
                        setState(() => _progress = progress / 100),
                    onLoadResource: (controller, resource) {
                      _handleLoadedResource(controller, resource);
                    },
                    onLoadStop: (controller, url) async {
                      setState(() {
                        _isLoading = false;
                        _url = url?.toString() ?? '';
                      });
                      _recheckCount = 0;
                      await WebViewSettings.injectScrollFix(controller);
                      // 自动填充登录表单
                      await _autoFillLoginForm(controller, url);
                      // 自动检测登录状态
                      await _checkLoginStatus(
                        controller,
                        currentUrl: url?.toString(),
                      );
                    },
                    onUpdateVisitedHistory: (controller, url, isReload) {
                      if (!_loginHandled && isReload != true) {
                        // SPA 路由变化时也尝试检测登录状态
                        _recheckCount = 0;
                        _checkLoginStatus(
                          controller,
                          currentUrl: url?.toString(),
                        );
                      }
                    },
                  ),
                  getController: () => _controller,
                ),
                if (_isCompletingLogin)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Theme.of(
                        context,
                      ).colorScheme.surface.withValues(alpha: 0.88),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            Text(context.l10n.webviewLogin_loginSuccess),
                            const SizedBox(height: 8),
                            Text(
                              '正在同步登录状态...',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _clearCredentials() async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.webviewLogin_clearSavedTitle),
        content: Text(context.l10n.webviewLogin_clearSavedContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.common_delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _credentialStore.clear();
      if (mounted) setState(() => _savedUsername = null);
    }
  }

  /// 从剪贴板粘贴邮箱登录链接
  Future<void> _pasteEmailLoginLink() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';

    if (text.isEmpty) {
      ToastService.showError(S.current.webviewLogin_emailLoginInvalidLink);
      return;
    }

    // 验证是否为有效的邮箱登录链接
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.path.startsWith('/session/email-login/')) {
      ToastService.showError(S.current.webviewLogin_emailLoginInvalidLink);
      return;
    }

    // 在 WebView 中加载该链接
    _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(text)));
  }

  /// 自动填充登录表单 + 注入凭证捕获脚本
  Future<void> _autoFillLoginForm(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    final autoFill = ref.read(preferencesProvider).autoFillLogin;
    if (!autoFill) return;

    final urlStr = url?.toString() ?? '';
    final host = Uri.tryParse(urlStr)?.host;
    if (host == null || host != Uri.parse(AppConstants.baseUrl).host) return;
    // 邮箱链接登录页无需自动填充
    if (urlStr.contains('/session/email-login/')) return;

    final credentials = await _credentialStore.load();
    final hasCredentials =
        credentials.username != null &&
        credentials.username!.isNotEmpty &&
        credentials.password != null &&
        credentials.password!.isNotEmpty;

    // 转义特殊字符防止 JS 注入
    final escapedUsername = hasCredentials
        ? jsonEncode(credentials.username!)
        : 'null';
    final escapedPassword = hasCredentials
        ? jsonEncode(credentials.password!)
        : 'null';

    await controller.evaluateJavascript(
      source:
          '''
      (function() {
        var savedUser = $escapedUsername;
        var savedPass = $escapedPassword;
        var filled = false;
        var hooked = false;
        var attempts = 0;
        var timer = setInterval(function() {
          var userInput = document.getElementById('login-account-name');
          var passInput = document.getElementById('login-account-password');
          if (userInput && passInput) {
            // 自动填充（仅一次）
            if (!filled && savedUser && savedPass) {
              filled = true;
              userInput.value = savedUser;
              passInput.value = savedPass;
              userInput.dispatchEvent(new Event('input', {bubbles: true}));
              passInput.dispatchEvent(new Event('input', {bubbles: true}));
            }
            // 监听登录按钮点击，在提交前捕获凭证
            if (!hooked) {
              hooked = true;
              var loginBtn = document.getElementById('login-button');
              if (loginBtn) {
                loginBtn.addEventListener('click', function() {
                  var u = document.getElementById('login-account-name');
                  var p = document.getElementById('login-account-password');
                  if (u && p && u.value && p.value) {
                    window.flutter_inappwebview.callHandler('onLoginCredentials', {
                      username: u.value,
                      password: p.value
                    });
                  }
                }, true);
              }
            }
            clearInterval(timer);
          }
          if (++attempts > 30) clearInterval(timer);
        }, 300);
      })();
    ''',
    );
  }

  /// 检测登录状态，登录成功自动关闭
  Future<void> _checkLoginStatus(
    InAppWebViewController controller, {
    String? currentUrl,
  }) async {
    if (_loginHandled || _loginInProgress) return;
    _loginInProgress = true;

    try {
      final username = await _readCurrentUsername(controller);
      if (username == null || username.isEmpty) {
        if (_lastHomeResponseUrl != null &&
            _isHomePageUrl(_lastHomeResponseUrl)) {
          _scheduleLoginRecheck(controller);
        }
        return;
      }

      currentUrl ??= (await controller.getUrl())?.toString();
      await _awaitInitialCookieFlush();
      if (mounted && !_isCompletingLogin) {
        setState(() {
          _isCompletingLogin = true;
          _isLoading = true;
        });
      }

      await BoundarySyncService.instance.syncFromWebView(
        currentUrl: currentUrl,
        controller: controller,
        allowLowConfidenceSessionCookies: true,
      );
      final tToken = await _readTTokenFromWebView(
        controller,
        currentUrl: currentUrl,
      );
      if (tToken == null || tToken.isEmpty) {
        if (mounted && _isCompletingLogin) {
          setState(() {
            _isCompletingLogin = false;
            _isLoading = false;
          });
        }
        debugPrint('[Login] 已检测到 currentUser=$username，但尚未读到 _t，等待后续同步');
        _scheduleLoginRecheck(controller);
        return;
      }

      _loginHandled = true;
      final finalToken = await _finalizeLoginBeforeExit(
        controller,
        username: username,
        currentUrl: currentUrl,
        webViewToken: tToken,
      );

      if (mounted) {
        ToastService.showSuccess(S.current.webviewLogin_loginSuccess);
        Navigator.of(context).pop(true);
      }

      unawaited(
        _finalizeLoginAfterExit(currentUrl: currentUrl, token: finalToken),
      );
    } finally {
      _loginInProgress = false;
    }
  }

  Future<String> _finalizeLoginBeforeExit(
    InAppWebViewController controller, {
    required String username,
    required String? currentUrl,
    required String webViewToken,
  }) async {
    await _service.saveUsername(username);
    await _syncCsrfFromPage(controller);

    // 先切断旧请求，防止登录收口期间旧响应的 Set-Cookie 写入竞争
    AuthSession().advance();

    await BoundarySyncService.instance.syncFromWebView(
      currentUrl: currentUrl,
      controller: controller,
      cookieNames: CookieJarService.sessionCookieNames,
      allowLowConfidenceSessionCookies: true,
    );

    final jarToken = await _cookieJar.getTToken();
    final finalToken = (jarToken != null && jarToken.isNotEmpty)
        ? jarToken
        : webViewToken;
    final tokenMatch = jarToken == webViewToken;
    final jarSessionCookies = await _cookieJar.getSessionCookieDiagnosticsForRequest(
      uri: Uri.parse(AppConstants.baseUrl),
    );
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': tokenMatch ? 'info' : 'warning',
      'type': 'auth',
      'event': 'login_cookie_finalize',
      'message': tokenMatch ? '登录收口 Cookie 对齐' : '登录收口 Cookie 不一致',
      'currentUrl': currentUrl,
      'username': username,
      'webViewTokenLen': webViewToken.length,
      'jarTokenLen': jarToken?.length,
      'finalTokenLen': finalToken.length,
      'tokenMatch': tokenMatch,
      'jarTokenMissing': jarToken == null || jarToken.isEmpty,
      'jarSessionCookies': jarSessionCookies,
    });
    if (!tokenMatch) {
      debugPrint(
        '[Login] _t 不一致! WebView=${webViewToken.length}chars, Jar=${jarToken?.length}chars',
      );
    }

    _service.setToken(finalToken);
    _service.onLoginSuccess(finalToken);
    return finalToken;
  }

  Future<void> _finalizeLoginAfterExit({
    required String? currentUrl,
    required String token,
  }) async {
    try {
      final reusedPreloaded = false;
      if (!reusedPreloaded) {
        debugPrint('[Login] 当前页面无可复用首页数据，回退到 HTTP refresh');
        await PreloadedDataService().refresh();
      }

      final jarToken = await _cookieJar.getTToken();
      final tokenMatch = jarToken == token;
      final jarSessionCookies = await _cookieJar.getSessionCookieDiagnosticsForRequest(
        uri: Uri.parse(AppConstants.baseUrl),
      );
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'info',
        'type': 'lifecycle',
        'event': 'login',
        'message': '用户登录成功',
        'jarTokenLen': jarToken?.length,
        'webViewTokenLen': token.length,
        'tokenMatch': tokenMatch,
        'currentUrl': currentUrl,
        'jarSessionCookies': jarSessionCookies,
      });
    } catch (e) {
      debugPrint('[Login] 登录态后台收尾失败: $e');
    }
  }

  Future<String?> _readCurrentUsername(
    InAppWebViewController controller,
  ) async {
    try {
      final result = await controller.evaluateJavascript(
        source: '''
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
      ''',
      );

      if (result == null) {
        return null;
      }

      final username = result.toString();
      if (username.isEmpty || username == 'null') {
        return null;
      }
      return username;
    } catch (_) {
      return null;
    }
  }

  Future<void> _syncCsrfFromPage(InAppWebViewController controller) async {
    try {
      final csrf = await controller.evaluateJavascript(
        source: '''
        (function() {
          var meta = document.querySelector('meta[name="csrf-token"]');
          return meta && meta.content ? meta.content : null;
        })();
      ''',
      );
      if (csrf != null &&
          csrf.toString().isNotEmpty &&
          csrf.toString() != 'null') {
        CsrfTokenService().setCsrfToken(csrf.toString());
      }
    } catch (_) {}
  }

  Future<void> _handleLoadedResource(
    InAppWebViewController controller,
    LoadedResource resource,
  ) async {
    final resourceUrl = resource.url?.toString();
    if (!_isHomePageUrl(resourceUrl)) {
      return;
    }

    _lastHomeResponseUrl = resourceUrl;
    debugPrint(
      '[Login] 检测到首页响应: url=$resourceUrl, initiatorType=${resource.initiatorType}',
    );
    await _checkLoginStatus(controller, currentUrl: resourceUrl);
  }

  Future<void> _awaitInitialCookieFlush() async {
    final future = _initialCookieFlushFuture;
    if (future == null) return;
    try {
      await future.timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('[Login] 等待初始 Cookie 回放完成失败: $e');
    }
  }

  Future<String?> _readTTokenFromWebView(
    InAppWebViewController controller, {
    String? currentUrl,
  }) async {
    final cookieManager =
        WindowsWebViewEnvironmentService.instance.cookieManager;
    final candidates = <String>{
      AppConstants.baseUrl,
      '${AppConstants.baseUrl}/',
      if (currentUrl != null && currentUrl.isNotEmpty) currentUrl,
    };

    for (final url in candidates) {
      final cookies = await cookieManager.getCookies(url: WebUri(url));

      for (final cookie in cookies) {
        if (cookie.name == '_t' && cookie.value.isNotEmpty) {
          return cookie.value;
        }
      }
    }

    return _cookieJar.readCookieValueFromController(
      controller,
      '_t',
      currentUrl: currentUrl,
    );
  }

  int _recheckCount = 0;
  static const _maxRechecks = 15;
  static const _recheckInterval = Duration(milliseconds: 500);

  void _scheduleLoginRecheck(InAppWebViewController controller) {
    if (_recheckCount >= _maxRechecks) {
      debugPrint('[Login] 已达最大重试次数($_maxRechecks)，停止重试');
      return;
    }
    _recheckCount++;
    Future.delayed(_recheckInterval, () {
      if (!mounted || _loginHandled || _controller != controller) {
        return;
      }
      _checkLoginStatus(controller);
    });
  }

  bool _isHomePageUrl(String? rawUrl) {
    final uri = Uri.tryParse(rawUrl ?? '');
    if (uri == null) {
      return false;
    }
    if (uri.scheme != _baseUri.scheme || uri.host != _baseUri.host) {
      return false;
    }
    if (uri.hasPort != _baseUri.hasPort) {
      return false;
    }
    if (uri.hasPort && uri.port != _baseUri.port) {
      return false;
    }

    final currentPath = _normalizePath(uri.path);
    final homePath = _normalizePath(_baseUri.path);
    return currentPath == homePath;
  }

  String _normalizePath(String path) {
    if (path.isEmpty || path == '/') {
      return '/';
    }
    return path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
  }
}
