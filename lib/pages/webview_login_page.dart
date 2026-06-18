import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

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
import '../services/network/cookie/webview_cookie_priming.dart';
import '../services/toast_service.dart';
import '../services/webview_settings.dart';
import '../services/webview_session_cookie_refresh_service.dart';
import '../services/windows_webview_environment_service.dart';
import '../services/log/log_writer.dart';
import '../services/login_ready_coordinator.dart';
import 'package:common_ui/common_ui.dart';
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
  static const Set<String> _runtimeCookieNames = {'_rt'};

  final _service = DiscourseService();
  final _cookieJar = CookieJarService();
  final _credentialStore = CredentialStoreService();
  final int _flowGeneration = AuthSession().generation;
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
  Future<void>? _initialCookieFlushFuture;
  Completer<void>? _fingerprintCompleter;
  bool _fingerprintDone = false;

  /// 对话框期间用静态截图盖住 WebView，避免 BackdropFilter 对
  /// hybrid composition 实时回读造成的卡顿。
  Uint8List? _webViewSnapshot;

  @override
  void initState() {
    super.initState();
    // v0.4.0: WV cookie 重灌 (取代 RawSetCookieQueue.flush + 启动自检)
    _initialCookieFlushFuture = WebViewCookiePriming.instance.prime(
      AppConstants.baseUrl,
    );
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
                Offstage(
                  offstage: _webViewSnapshot != null,
                  child: WebViewSettings.wrapWithScrollFix(
                    InAppWebView(
                      webViewEnvironment: windowsWebViewEnvironment,
                      initialSettings: WebViewSettings.visible,
                      initialUserScripts: UnmodifiableListView([
                        ...WebViewSettings.compatPolyfillScripts,
                        UserScript(
                          source: '''
                          new MutationObserver(function(_, obs) {
                            var el = document.querySelector('[data-preloaded]');
                            if (!el) return;
                            obs.disconnect();
                            var parts = [el.outerHTML];
                            document.querySelectorAll('meta[name]').forEach(function(m) {
                              parts.push(m.outerHTML);
                            });
                            var setup = document.getElementById('data-discourse-setup');
                            if (setup) parts.push(setup.outerHTML);
                            window.__rawPreloaded = parts.join('\\n');
                          }).observe(document.documentElement, {childList: true, subtree: true});
                        ''',
                          injectionTime:
                              UserScriptInjectionTime.AT_DOCUMENT_START,
                        ),
                      ]),
                      onReceivedServerTrustAuthRequest: (_, challenge) =>
                          WebViewSettings.handleServerTrustAuthRequest(
                            challenge,
                          ),
                      onWebViewCreated: (controller) async {
                        _controller = controller;
                        // 老 WKWebView 的 JS 运行时错误回传到 LogWriter，
                        // 避免 Discourse 升级用了新 ES API 时出现无声白屏。
                        WebViewSettings.registerJsErrorReporter(controller);
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
                        controller.addJavaScriptHandler(
                          handlerName: 'onFingerprintDone',
                          callback: (_) {
                            _fingerprintDone = true;
                            final c = _fingerprintCompleter;
                            if (c != null && !c.isCompleted) c.complete();
                            return null;
                          },
                        );
                        // 等待 cookie flush 完成再加载 URL，
                        // 确保 WebView 引擎初始化后 cookie 已就位
                        await _awaitInitialCookieFlush();
                        await controller.loadUrl(
                          urlRequest: URLRequest(
                            url: WebUri(
                              widget.initialUrl ??
                                  '${AppConstants.baseUrl}/login',
                            ),
                          ),
                        );
                        // Android: 启用 WebAuthn/PassKey 支持
                        if (Platform.isAndroid) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            const MethodChannel(
                              'com.fluxdo/webauthn',
                            ).invokeMethod('enableWebAuthentication');
                          });
                        }
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
                        _injectFingerprintHook(controller);
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
    final snapshot = await _controller?.takeScreenshot();
    if (!mounted) return;
    if (snapshot != null) {
      setState(() => _webViewSnapshot = snapshot);
    }
    final bool? confirmed;
    try {
      confirmed = await showAppDialog<bool>(
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
    } finally {
      if (mounted && _webViewSnapshot != null) {
        setState(() => _webViewSnapshot = null);
      }
    }
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
        cookieNames: null,
        excludeCookieNames: CookieJarService.authCookieNames,
        requestGeneration: _flowGeneration,
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
      if (!AuthSession().isValid(_flowGeneration)) {
        if (mounted && _isCompletingLogin) {
          setState(() {
            _isCompletingLogin = false;
            _isLoading = false;
          });
        }
        debugPrint('[Login] 登录 WebView 流程已过期，跳过会话同步');
        return;
      }

      _loginHandled = true;
      final finalToken = await _finalizeLoginBeforeExit(
        controller,
        username: username,
        currentUrl: currentUrl,
        webViewToken: tToken,
      );
      final browserSessionSynced = await _syncRuntimeCookiesBeforeLoginReady(
        controller,
        currentUrl: currentUrl,
        requestGeneration: AuthSession().generation,
        token: finalToken,
      );
      String? pageHtml;
      try {
        pageHtml =
            await controller.evaluateJavascript(
                  source: 'window.__rawPreloaded || null',
                )
                as String?;
      } catch (_) {}

      await _finalizeLoginBootstrap(
        currentUrl: currentUrl,
        token: finalToken,
        pageHtml: pageHtml,
        browserSessionSynced: browserSessionSynced,
      );

      if (mounted) {
        ToastService.showSuccess(S.current.webviewLogin_loginSuccess);
        Navigator.of(context).pop(true);
      }
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
    final loginGeneration = AuthSession().generation;

    await _syncAuthCookiesFromWebView(
      controller,
      currentUrl: currentUrl,
      requestGeneration: loginGeneration,
    );

    final jarToken = await _cookieJar.getTToken();
    final finalToken = (jarToken != null && jarToken.isNotEmpty)
        ? jarToken
        : webViewToken;
    final tokenMatch = jarToken == webViewToken;
    final jarAuthCookies = await _cookieJar.getAuthCookieDiagnosticsForRequest(
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
      'jarAuthCookies': jarAuthCookies,
    });
    if (!tokenMatch) {
      debugPrint(
        '[Login] _t 不一致! WebView=${webViewToken.length}chars, Jar=${jarToken?.length}chars',
      );
    }

    _service.setToken(finalToken);
    return finalToken;
  }

  Future<void> _syncAuthCookiesFromWebView(
    InAppWebViewController controller, {
    required String? currentUrl,
    required int requestGeneration,
  }) async {
    await BoundarySyncService.instance.syncFromWebView(
      currentUrl: currentUrl,
      controller: controller,
      cookieNames: CookieJarService.authCookieNames,
      allowLowConfidenceSessionCookies: true,
      requestGeneration: requestGeneration,
    );
  }

  Future<bool> _syncRuntimeCookiesBeforeLoginReady(
    InAppWebViewController controller, {
    required String? currentUrl,
    required int requestGeneration,
    required String token,
  }) async {
    const fingerprintWait = Duration(milliseconds: 2500);
    const bootstrapTimeout = Duration(seconds: 8);
    final startedAt = DateTime.now();

    var fingerprintObserved = _fingerprintDone;
    var bootstrapAttempted = false;
    var bootstrapOk = false;
    List<Map<String, dynamic>> runtimeDetails = const [];

    try {
      if (!fingerprintObserved) {
        fingerprintObserved = await _waitForFingerprintPost(
          timeout: fingerprintWait,
        );
      }

      if (!AuthSession().isValid(requestGeneration)) {
        _logRuntimeCookieSync(
          currentUrl: currentUrl,
          requestGeneration: requestGeneration,
          fingerprintObserved: fingerprintObserved,
          bootstrapAttempted: bootstrapAttempted,
          bootstrapOk: bootstrapOk,
          hasRuntimeCookie: false,
          runtimeCookieDetails: runtimeDetails,
          elapsedMs: DateTime.now().difference(startedAt).inMilliseconds,
          skippedReason: 'stale_generation',
        );
        return false;
      }

      await BoundarySyncService.instance.syncFromWebView(
        currentUrl: currentUrl,
        controller: controller,
        cookieNames: null,
        allowLowConfidenceSessionCookies: true,
        requestGeneration: requestGeneration,
        trusted: true,
      );
      runtimeDetails = await _runtimeCookieDiagnostics();
      var hasRuntimeCookie = _hasRuntimeCookie(runtimeDetails);

      if (!hasRuntimeCookie) {
        bootstrapAttempted = true;
        bootstrapOk = await WebViewSessionCookieRefreshService.instance
            .runOnController(
              controller,
              reason: 'webview_login_success',
              pluginCandidates: PreloadedDataService().pluginCandidatesSync,
              timeout: bootstrapTimeout,
            );

        if (AuthSession().isValid(requestGeneration)) {
          await BoundarySyncService.instance.syncFromWebView(
            currentUrl: currentUrl,
            controller: controller,
            cookieNames: null,
            allowLowConfidenceSessionCookies: true,
            requestGeneration: requestGeneration,
            trusted: true,
          );
          runtimeDetails = await _runtimeCookieDiagnostics();
          hasRuntimeCookie = _hasRuntimeCookie(runtimeDetails);
        }
      }

      if (!AuthSession().isValid(requestGeneration)) {
        _logRuntimeCookieSync(
          currentUrl: currentUrl,
          requestGeneration: requestGeneration,
          fingerprintObserved: fingerprintObserved,
          bootstrapAttempted: bootstrapAttempted,
          bootstrapOk: bootstrapOk,
          hasRuntimeCookie: hasRuntimeCookie,
          runtimeCookieDetails: runtimeDetails,
          elapsedMs: DateTime.now().difference(startedAt).inMilliseconds,
          skippedReason: 'stale_generation_after_bootstrap',
        );
        return false;
      }

      final browserSessionSynced = hasRuntimeCookie;
      if (browserSessionSynced) {
        WebViewSessionCookieRefreshService.instance.markSynced(
          reason: 'webview_login_success',
          tToken: token,
          hasRuntimeCookie: hasRuntimeCookie,
        );
      }
      await WebViewSessionCookieRefreshService.instance.logCookieSummary(
        reason: 'webview_login_success',
        bootstrapOk: bootstrapAttempted ? bootstrapOk : null,
      );
      _logRuntimeCookieSync(
        currentUrl: currentUrl,
        requestGeneration: requestGeneration,
        fingerprintObserved: fingerprintObserved,
        bootstrapAttempted: bootstrapAttempted,
        bootstrapOk: bootstrapOk,
        hasRuntimeCookie: hasRuntimeCookie,
        runtimeCookieDetails: runtimeDetails,
        elapsedMs: DateTime.now().difference(startedAt).inMilliseconds,
      );
      return browserSessionSynced;
    } catch (e) {
      _logRuntimeCookieSync(
        currentUrl: currentUrl,
        requestGeneration: requestGeneration,
        fingerprintObserved: fingerprintObserved,
        bootstrapAttempted: bootstrapAttempted,
        bootstrapOk: bootstrapOk,
        hasRuntimeCookie: _hasRuntimeCookie(runtimeDetails),
        runtimeCookieDetails: runtimeDetails,
        elapsedMs: DateTime.now().difference(startedAt).inMilliseconds,
        error: e.toString(),
      );
      debugPrint('[Login] 登录运行态 Cookie 同步失败: $e');
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> _runtimeCookieDiagnostics() {
    return _cookieJar.getCookieDiagnosticsForRequest(
      Uri.parse(AppConstants.baseUrl),
      names: _runtimeCookieNames,
    );
  }

  bool _hasRuntimeCookie(List<Map<String, dynamic>> details) {
    return details.any(
      (cookie) =>
          _runtimeCookieNames.contains(cookie['name']) &&
          _cookieValueLength(cookie) > 0,
    );
  }

  int _cookieValueLength(Map<String, dynamic> cookie) {
    final value = cookie['valueLength'];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  void _logRuntimeCookieSync({
    required String? currentUrl,
    required int requestGeneration,
    required bool fingerprintObserved,
    required bool bootstrapAttempted,
    required bool bootstrapOk,
    required bool hasRuntimeCookie,
    required List<Map<String, dynamic>> runtimeCookieDetails,
    required int elapsedMs,
    String? skippedReason,
    String? error,
  }) {
    final ok = error == null && skippedReason == null && hasRuntimeCookie;
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': ok ? 'info' : 'warning',
      'type': 'auth',
      'event': 'login_runtime_cookie_sync',
      'message': '登录收口运行态 Cookie 同步',
      'currentUrl': currentUrl,
      'requestGeneration': requestGeneration,
      'fingerprintObserved': fingerprintObserved,
      'bootstrapAttempted': bootstrapAttempted,
      'bootstrapOk': bootstrapOk,
      'hasRuntimeCookie': hasRuntimeCookie,
      'runtimeCookieNames': _runtimeCookieNames.toList(growable: false),
      'runtimeCookieDetails': runtimeCookieDetails,
      'elapsedMs': elapsedMs,
      'skippedReason': ?skippedReason,
      'error': ?error,
    });
  }

  Future<void> _finalizeLoginBootstrap({
    required String? currentUrl,
    required String token,
    String? pageHtml,
    required bool browserSessionSynced,
  }) async {
    // PreloadedDataService.refresh 底层 Dio 请求没有显式超时，极端网络下
    // 可能挂住很久；这里整段限时 8 秒，超时也要兜底广播登录成功，
    // 避免用户被永久卡在「正在同步登录状态…」界面。
    const finalizeTimeout = Duration(seconds: 8);

    var loginReadyNotified = false;
    try {
      final reusedPreloaded = await LoginReadyCoordinator(
        hydrateFromHtml: PreloadedDataService().hydrateFromHtml,
        refreshPreloadedData: () async {
          debugPrint('[Login] 当前页面无可复用首页数据，回退到 HTTP refresh');
          await PreloadedDataService().refresh();
        },
        notifyLoginReady: (finalToken) {
          loginReadyNotified = true;
          _service.onLoginSuccess(
            finalToken,
            forceBrowserSessionSync: !browserSessionSynced,
          );
        },
      ).finalize(token: token, pageHtml: pageHtml).timeout(finalizeTimeout);

      final jarToken = await _cookieJar.getTToken();
      final tokenMatch = jarToken == token;
      final jarAuthCookies = await _cookieJar
          .getAuthCookieDiagnosticsForRequest(
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
        'reusedPreloaded': reusedPreloaded,
        'jarAuthCookies': jarAuthCookies,
      });
    } on TimeoutException {
      debugPrint('[Login] 登录态收尾超时（${finalizeTimeout.inSeconds}s），走兜底广播');
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'warning',
        'type': 'auth',
        'event': 'login_bootstrap_timeout',
        'message': '登录态收尾超时，已兜底广播登录成功',
        'currentUrl': currentUrl,
        'timeoutSeconds': finalizeTimeout.inSeconds,
      });
    } catch (e) {
      debugPrint('[Login] 登录态收尾失败: $e');
    } finally {
      if (!loginReadyNotified) {
        _service.onLoginSuccess(
          token,
          forceBrowserSessionSync: !browserSessionSynced,
        );
      }
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

  void _injectFingerprintHook(InAppWebViewController controller) {
    controller.evaluateJavascript(
      source: '''
      (function() {
        if (window.__fpHooked) return;
        window.__fpHooked = true;
        function notify() {
          try { window.flutter_inappwebview.callHandler('onFingerprintDone'); } catch(e) {}
        }
        var _f = window.fetch;
        window.fetch = function(input, init) {
          var result = _f.apply(this, arguments);
          if (init && init.method && init.method.toUpperCase() === 'POST' &&
              typeof init.body === 'string' && init.body.indexOf('visitor_id=') !== -1) {
            result.then(notify, notify);
          }
          return result;
        };
        var _o = XMLHttpRequest.prototype.open, _s = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(m, u) { this._m = m; return _o.apply(this, arguments); };
        XMLHttpRequest.prototype.send = function(body) {
          if (this._m === 'POST' && typeof body === 'string' && body.indexOf('visitor_id=') !== -1) {
            this.addEventListener('loadend', notify);
          }
          return _s.apply(this, arguments);
        };
      })();
    ''',
    );
  }

  Future<bool> _waitForFingerprintPost({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (_fingerprintDone) return true;
    final existing = _fingerprintCompleter;
    final completer = existing != null && !existing.isCompleted
        ? existing
        : Completer<void>();
    _fingerprintCompleter = completer;
    try {
      await completer.future.timeout(timeout);
      return true;
    } on TimeoutException {
      debugPrint('[Login] 等待指纹上报超时(${timeout.inMilliseconds}ms)，继续登录流程');
      return _fingerprintDone;
    }
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
