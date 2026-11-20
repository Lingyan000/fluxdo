import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../constants.dart';
import '../../l10n/s.dart';
import '../../services/auth_session.dart';
import '../../services/cf_challenge_service.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/network/cookie/boundary_sync_service.dart';
import '../../services/network/cookie/cookie_jar_service.dart';
import '../../services/network/cookie/webview_cookie_priming.dart';
import '../../services/preloaded_data_service.dart';
import '../../services/toast_service.dart';
import '../../services/webview_session_cookie_refresh_service.dart';
import '../../services/webview_settings.dart';
import '../../services/windows_webview_environment_service.dart';
import '../common/captcha_panel.dart';
import '../common/hcaptcha_layout_script.dart';

/// 登录对话框结果状态。
enum WebViewLoginStatus { success, failure, canceled }

/// [showWebViewLoginDialog] 的返回结果。
class WebViewLoginDialogResult {
  const WebViewLoginDialogResult.success()
    : status = WebViewLoginStatus.success,
      loginErrorKind = null,
      errorMessage = null;

  const WebViewLoginDialogResult.canceled()
    : status = WebViewLoginStatus.canceled,
      loginErrorKind = null,
      errorMessage = null;

  const WebViewLoginDialogResult.failure(this.loginErrorKind, this.errorMessage)
    : status = WebViewLoginStatus.failure;

  final WebViewLoginStatus status;
  final LoginErrorKind? loginErrorKind;
  final String? errorMessage;
}

/// dialog 检测到需要二步验证时, 回调给 caller 的信息。
class WebViewLoginNeed2FA {
  const WebViewLoginNeed2FA({
    this.totpEnabled = false,
    this.backupEnabled = false,
    this.securityKeyEnabled = false,
    this.message,
  });

  final bool totpEnabled;
  final bool backupEnabled;
  final bool securityKeyEnabled;
  final String? message;
}

/// 显示 WebView 内 JS 全流程登录对话框。
///
/// 在一个**与 CF 验证共享 WebView 环境**的 mini WebView 里, 用 data:url
/// (baseUrl=linux.do, **不加载 Discourse Ember bundle**) 渲染 hcaptcha, 并在
/// 同一个 WebView 内核里用 JS 同源 `fetch` 跑完整个登录:
/// `GET /session/csrf` → `POST /hcaptcha/create.json` → `POST /session.json`。
///
/// 这样三个请求都由 WebView 内核发出, TLS/JA3 指纹与 CF 签发 `cf_clearance`
/// 时一致, 避开 dio 与 WebView 指纹不一致导致的 403 (BAD CSRF)。
///
/// 返回结构化结果; 取消返回 [WebViewLoginStatus.canceled]。
/// [onNeedSecondFactor] 在检测到 2FA 时回调出去 (由 caller 弹 TOTP 对话框),
/// 返回 6 位 code (null=取消)。
Future<WebViewLoginDialogResult?> showWebViewLoginDialog(
  BuildContext context, {
  required String siteKey,
  required String identifier,
  required String password,
  required Future<String?> Function(WebViewLoginNeed2FA need)
  onNeedSecondFactor,
  String? hcaptchaCreateEndpoint,
}) async {
  final result = await showCaptchaSheet<WebViewLoginDialogResult>(
    context: context,
    title: context.l10n.login_captchaTitle,
    useRootNavigator: true,
    barrierDismissible: false,
    builder: (_) => _WebViewLoginDialog(
      siteKey: siteKey,
      identifier: identifier,
      password: password,
      onNeedSecondFactor: onNeedSecondFactor,
      hcaptchaCreateEndpoint: hcaptchaCreateEndpoint,
    ),
  );
  return result ?? const WebViewLoginDialogResult.canceled();
}

class _WebViewLoginDialog extends StatefulWidget {
  const _WebViewLoginDialog({
    required this.siteKey,
    required this.identifier,
    required this.password,
    required this.onNeedSecondFactor,
    this.hcaptchaCreateEndpoint,
  });

  final String siteKey;
  final String identifier;
  final String password;
  final Future<String?> Function(WebViewLoginNeed2FA need) onNeedSecondFactor;
  final String? hcaptchaCreateEndpoint;

  @override
  State<_WebViewLoginDialog> createState() => _WebViewLoginDialogState();
}

class _WebViewLoginDialogState extends State<_WebViewLoginDialog> {
  InAppWebViewController? _controller;
  Widget? _attemptWebView;
  CaptchaPanelPhase _phase = CaptchaPanelPhase.loading;
  double? _checkboxHeight;
  double? _challengeHeight;
  Timer? _loadTimeout;
  int _attempt = 0;
  bool _expired = false;
  bool _routeClosed = false;
  bool _finished = false; // 防止重复 pop / 回调重入
  bool _cookiesPrimed = false; // 方案 A: 是否已从 jar 预灌 cookie
  bool _windowsInlineHtmlInjected = false;
  bool _cfRetryUsed = false; // CSRF 403 自动重验证只做一次, 避免死循环
  final int _flowGeneration = AuthSession().generation;
  // 最近一次 _runLogin 的参数, CSRF 403 重新过 CF 后用同样参数重跑。
  // CSRF 失败发生在 JS __fluxdoLogin 第一步 (fetch /session/csrf), 此时
  // hcaptchaToken 还没被 hcaptcha/create 消费, 可直接重用; secondFactorToken
  // 也未用过。
  String? _lastHcaptchaToken;
  String? _lastSecondFactorToken;

  @override
  void initState() {
    super.initState();
    _startLoadTimeout();
  }

  void _startLoadTimeout() {
    _loadTimeout?.cancel();
    _loadTimeout = Timer(const Duration(seconds: 45), () {
      if (_phase == CaptchaPanelPhase.loading) _failVerification();
    });
  }

  bool get _verifying =>
      mounted &&
      !_finished &&
      _phase != CaptchaPanelPhase.failed &&
      _phase != CaptchaPanelPhase.submitting;

  void _failVerification({bool expired = false}) {
    if (!_verifying) return;
    _loadTimeout?.cancel();
    setState(() {
      _expired = expired;
      _phase = CaptchaPanelPhase.failed;
      _attemptWebView = null;
      _controller = null;
    });
  }

  void _retryVerification() {
    if (_finished || _phase != CaptchaPanelPhase.failed) return;
    setState(() {
      _attempt++;
      _checkboxHeight = null;
      _challengeHeight = null;
      _controller = null;
      _windowsInlineHtmlInjected = false;
      _phase = CaptchaPanelPhase.loading;
    });
    _startLoadTimeout();
  }

  @override
  void dispose() {
    _finished = true;
    _loadTimeout?.cancel();
    // 对话框关闭后立即释放 WebView2 原生控制器，避免不可见的平台视图
    // 继续参与外部视图合成并长期占用资源。
    _controller?.dispose();
    super.dispose();
  }

  /// data:url 内嵌页面: hcaptcha widget + 登录全流程 JS。
  /// baseUrl=linux.do 让文档 origin 为 linux.do, JS fetch 相对路径同源,
  /// `credentials:'include'` 自动带共享 store 里的 cf_clearance/_forum_session。
  /// hcaptcha verify endpoint 候选: caller (从 Preferences) 优先, 然后
  /// `/captcha/hcaptcha/create.json` (linux.do 当前路径), 最后
  /// `/hcaptcha/create.json` (Discourse plugin 原生路径)。
  /// 按顺序尝试, 第一个非 404/network-error 的就用。站长改 mount 时只需要
  /// 在 fluxdo 设置里填新 endpoint, 不用发版。
  List<String> get _hcaptchaCreateEndpoints {
    final configured = widget.hcaptchaCreateEndpoint?.trim();
    final list = <String>[
      if (configured != null && configured.isNotEmpty) configured,
      '/captcha/hcaptcha/create.json',
      '/hcaptcha/create.json',
    ];
    return list.toSet().toList(); // 去重保序
  }

  WebUri get _windowsBootstrapUrl =>
      WebUri('${AppConstants.baseUrl}/robots.txt');

  String _inlineHtml({required bool compact}) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = Theme.of(context).colorScheme.surface
        .toARGB32()
        .toRadixString(16)
        .padLeft(8, '0')
        .substring(2);
    final locale = Localizations.localeOf(context);
    final language =
        locale.languageCode == 'zh' &&
            (locale.scriptCode == 'Hant' ||
                locale.countryCode == 'HK' ||
                locale.countryCode == 'TW')
        ? 'zh-TW'
        : locale.languageCode;
    final endpointsJson = jsonEncode(_hcaptchaCreateEndpoints);
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    html, body { margin: 0; min-height: 100%; background: #$surface; color-scheme: ${dark ? 'dark' : 'light'}; }
    main { min-height: 100vh; display: grid; align-items: center; justify-content: center; justify-content: safe center; }
  </style>
</head>
<body>
  <main><div id="cap" data-sitekey="${const HtmlEscape().convert(widget.siteKey)}"></div></main>
  <script>
    $hCaptchaLayoutScript
    function call(name, payload) {
      const send = () => window.flutter_inappwebview.callHandler(name, payload);
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) send();
      else window.addEventListener('flutterInAppWebViewPlatformReady', send, { once: true });
    }
    function renderCheckbox() {
      try {
        const container = document.getElementById('cap');
        let stopLayout;
        function finish(name, value) {
          stopLayout?.();
          stopLayout = null;
          call(name, value);
        }
        hcaptcha.render(container, {
          sitekey: container.dataset.sitekey,
          theme: '${dark ? 'dark' : 'light'}',
          hl: ${jsonEncode(language)},
          size: '${compact ? 'compact' : 'normal'}',
          callback: token => finish('hcaptcha_pass', token),
          'open-callback': () => {
            call('hcaptcha_open', null);
            stopLayout?.();
            stopLayout = watchHCaptchaLayout(container, height => call('hcaptcha_height', height));
          },
          'close-callback': () => finish('hcaptcha_close', null),
          'expired-callback': () => finish('hcaptcha_expired', null),
          'chalexpired-callback': () => finish('hcaptcha_expired', null),
          'error-callback': () => finish('hcaptcha_error', null)
        });
        const ready = () => call('hcaptcha_ready', Math.ceil(container.getBoundingClientRect().height));
        if (typeof ResizeObserver === 'function') new ResizeObserver(ready).observe(container);
        ready();
      } catch (e) {
        call('hcaptcha_error', null);
      }
    }

    // WebView 内核同源全流程登录。所有请求 credentials:'include' 带 store cookie。
    // 只设 X-CSRF-Token / X-Requested-With / Content-Type / Accept;
    // Cookie / User-Agent / Origin / Referer / sec-* 由内核自管, 不手设。
    window.__fluxdoLogin = async function(identifier, password, hcaptchaToken, secondFactorToken) {
      function done(p) {
        try { window.flutter_inappwebview.callHandler('login_result', JSON.stringify(p)); } catch (e) {}
      }
      try {
        // 1. CSRF token (与 WebView 的 _forum_session 天然绑定一致)
        var c = await fetch('/session/csrf', {
          method: 'GET',
          headers: { 'X-Requested-With': 'XMLHttpRequest', 'Accept': 'application/json' },
          credentials: 'include',
          cache: 'no-store'
        });
        if (c.status !== 200) { return done({ phase: 'csrf', status: c.status, body: await c.text() }); }
        var csrf = (await c.json()).csrf;

        // 2. hcaptcha/create — 仅首次 (有 token) 调; 2FA 重试 token=null 跳过。
        //    按 endpoint 列表顺序尝试: caller 配置 → /captcha/hcaptcha/create.json → /hcaptcha/create.json
        //    任意一个返 200 即成功, 其他 (404 / 网络错误) 继续 fallback。
        if (hcaptchaToken) {
          var hcaptchaEndpoints = $endpointsJson;
          var hcaptchaOk = false;
          var hcaptchaLast = null;
          for (var i = 0; i < hcaptchaEndpoints.length; i++) {
            var ep = hcaptchaEndpoints[i];
            try {
              var h = await fetch(ep, {
                method: 'POST',
                credentials: 'include',
                headers: {
                  'Content-Type': 'application/x-www-form-urlencoded',
                  'X-CSRF-Token': csrf,
                  'X-Requested-With': 'XMLHttpRequest'
                },
                body: 'token=' + encodeURIComponent(hcaptchaToken)
              });
              hcaptchaLast = { endpoint: ep, status: h.status, body: await h.text() };
              if (h.status === 200) { hcaptchaOk = true; break; }
              // 404 视为路径不对, 继续 fallback
              if (h.status !== 404) break;
            } catch (e) {
              hcaptchaLast = { endpoint: ep, status: 0, body: String(e) };
            }
          }
          if (!hcaptchaOk) {
            return done({ phase: 'hcaptcha', status: hcaptchaLast ? hcaptchaLast.status : 0, body: 'tried=' + JSON.stringify(hcaptchaEndpoints) + ' last=' + JSON.stringify(hcaptchaLast) });
          }
        }

        // 3. session.json — 真正登录
        var form = 'login=' + encodeURIComponent(identifier) + '&password=' + encodeURIComponent(password);
        if (secondFactorToken) {
          form += '&second_factor_token=' + encodeURIComponent(secondFactorToken) + '&second_factor_method=1';
        }
        var s = await fetch('/session.json', {
          method: 'POST',
          credentials: 'include',
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            'X-CSRF-Token': csrf,
            'X-Requested-With': 'XMLHttpRequest',
            'Accept': 'application/json'
          },
          body: form
        });
        return done({ phase: 'session', status: s.status, body: await s.text() });
      } catch (e) {
        return done({ phase: 'exception', status: 0, body: String(e) });
      }
    };
  </script>
  <script src="https://js.hcaptcha.com/1/api.js?onload=renderCheckbox&amp;render=explicit"
    onerror="call('hcaptcha_error', null)" async defer></script>
</body>
</html>
''';
  }

  void _setupHandlers(InAppWebViewController controller, int attempt) {
    bool current() => attempt == _attempt && _verifying;
    void onCaptcha(String name, VoidCallback accept) {
      controller.addJavaScriptHandler(
        handlerName: name,
        callback: (args) {
          if (current()) accept();
          return null;
        },
      );
    }

    void show(CaptchaPanelPhase phase) {
      _loadTimeout?.cancel();
      setState(() {
        if (_phase != phase) _challengeHeight = null;
        _phase = phase;
      });
    }

    controller.addJavaScriptHandler(
      handlerName: 'hcaptcha_ready',
      callback: (args) {
        if (!current() ||
            (_phase != CaptchaPanelPhase.loading &&
                _phase != CaptchaPanelPhase.checkbox)) {
          return null;
        }
        final height = args is List && args.isNotEmpty ? args.first : null;
        final measured = height is num && height.isFinite && height > 0
            ? height.toDouble()
            : null;
        if (_phase == CaptchaPanelPhase.loading ||
            (measured != null && measured != _checkboxHeight)) {
          _loadTimeout?.cancel();
          setState(() {
            _phase = CaptchaPanelPhase.checkbox;
            _checkboxHeight = measured ?? _checkboxHeight;
          });
        }
        return null;
      },
    );
    onCaptcha('hcaptcha_open', () => show(CaptchaPanelPhase.challenge));
    controller.addJavaScriptHandler(
      handlerName: 'hcaptcha_height',
      callback: (args) {
        final height = args is List && args.isNotEmpty ? args.first : null;
        if (current() &&
            _phase == CaptchaPanelPhase.challenge &&
            height is num &&
            height.isFinite &&
            height > 0 &&
            height != _challengeHeight) {
          setState(() => _challengeHeight = height.toDouble());
        }
        return null;
      },
    );
    onCaptcha('hcaptcha_close', () => show(CaptchaPanelPhase.checkbox));
    onCaptcha('hcaptcha_error', _failVerification);
    onCaptcha('hcaptcha_expired', () => _failVerification(expired: true));
    // hcaptcha 通过 → 首次驱动登录 (带 hcaptcha token)
    controller.addJavaScriptHandler(
      handlerName: 'hcaptcha_pass',
      callback: (args) {
        final token = args.isNotEmpty ? args.first : null;
        if (current() && token is String && token.isNotEmpty) {
          show(CaptchaPanelPhase.submitting);
          unawaited(_runLogin(hcaptchaToken: token, secondFactorToken: null));
        }
        return null;
      },
    );
    // JS 全流程登录结果
    controller.addJavaScriptHandler(
      handlerName: 'login_result',
      callback: (args) {
        if (attempt != _attempt || _phase != CaptchaPanelPhase.submitting) {
          return null;
        }
        final raw = args.isNotEmpty ? args.first?.toString() : null;
        if (raw != null) _onLoginResult(raw);
        return null;
      },
    );
  }

  /// 方案 A: 把 jar 里的会话 / CF cookie 灌进登录 WebView 的 store。
  ///
  /// 不依赖各平台 WebView 间 cookie store 自动共享 —— Windows 靠共享同一个
  /// WebViewEnvironment 才物理同 store, iOS/Android/Linux 的共享行为不一致。
  /// [LoginPage._ensureCfClearance] 已保证 jar 有 cf_clearance, 这里以 jar 为准
  /// 灌进 store, 确保同源 fetch 能带上 cf_clearance 过 CF。
  /// 必须走 canonical Set-Cookie 写入，不能把 Cookie header 拆成 name/value，
  /// 否则会丢 Domain/Path 并制造 host-only 副本。
  Future<void> _primeCookiesFromJar() async {
    if (_cookiesPrimed) return;
    _cookiesPrimed = true;
    try {
      await WebViewCookiePriming.instance.prime(AppConstants.baseUrl);
      debugPrint('[WebViewLogin] 已从 jar 预灌 cookie 到登录 WebView store');
    } catch (e) {
      debugPrint('[WebViewLogin] 预灌 cookie 失败 (继续, 依赖共享 store): $e');
    }
  }

  /// Windows flutter_inappwebview 0.7.x 会用 WebView2 NavigateToString()
  /// 加载 initialData, 原生层忽略 baseUrl, 导致文档不是 linux.do origin。
  /// hCaptcha 会把 about:blank/opaque origin 判成 invalid-data。这里先导航到
  /// linux.do 的轻量静态资源拿真实 origin, 再写入同一份内嵌登录页。
  Future<void> _injectWindowsInlineHtml(
    InAppWebViewController controller,
    int attempt,
    String document,
  ) async {
    if (!_verifying || attempt != _attempt || _windowsInlineHtmlInjected) {
      return;
    }
    try {
      final probe = await controller.evaluateJavascript(
        source: '''
({
  href: window.location.href,
  origin: window.location.origin,
  contentType: document.contentType,
  readyState: document.readyState
})
''',
      );
      final origin = probe is Map ? probe['origin']?.toString() : null;
      if (!_verifying || attempt != _attempt || _windowsInlineHtmlInjected) {
        return;
      }
      if (origin != AppConstants.baseUrl) {
        debugPrint('[WebViewLogin] Windows bootstrap origin not ready: $probe');
        return;
      }

      final html = jsonEncode(document);
      _windowsInlineHtmlInjected = true;
      await controller.evaluateJavascript(
        source:
            '''
document.open();
document.write($html);
document.close();
''',
      );
    } catch (e) {
      debugPrint('[WebViewLogin] Windows hcaptcha bootstrap 失败: $e');
      if (attempt == _attempt) _failVerification();
    }
  }

  /// 调 WebView 里的 __fluxdoLogin。id/pwd/token 用 jsonEncode 安全注入 (防 JS 注入)。
  Future<void> _runLogin({
    required String? hcaptchaToken,
    required String? secondFactorToken,
  }) async {
    final controller = _controller;
    if (controller == null || _finished) return;

    // 记录参数, CSRF 403 自动重验证后用同样参数重跑
    _lastHcaptchaToken = hcaptchaToken;
    _lastSecondFactorToken = secondFactorToken;

    // 方案 A: fetch 发出前确保登录 WebView store 有 cf_clearance (只灌一次)
    await _primeCookiesFromJar();
    if (_finished) return;
    if (!AuthSession().isValid(_flowGeneration)) {
      _finishCanceled();
      return;
    }

    final id = jsonEncode(widget.identifier);
    final pwd = jsonEncode(widget.password);
    final tok = hcaptchaToken == null ? 'null' : jsonEncode(hcaptchaToken);
    final sf = secondFactorToken == null
        ? 'null'
        : jsonEncode(secondFactorToken);
    try {
      await controller.evaluateJavascript(
        source: 'window.__fluxdoLogin($id, $pwd, $tok, $sf);',
      );
    } catch (e) {
      debugPrint('[WebViewLogin] evaluate __fluxdoLogin 失败: $e');
      _finishFailure(LoginErrorKind.unknown, '登录脚本执行失败');
    }
  }

  Future<void> _onLoginResult(String raw) async {
    if (_finished) return;

    Map<String, dynamic> payload;
    try {
      payload = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      _finishFailure(LoginErrorKind.unknown, '登录响应解析失败');
      return;
    }

    final phase = payload['phase']?.toString();
    final status = (payload['status'] as num?)?.toInt() ?? 0;
    final body = payload['body']?.toString() ?? '';

    switch (phase) {
      case 'csrf':
        // CF 在 fetch 时拦截 (store 里 cf_clearance 失效 / IP 漂移 / TLS 指纹
        // 不一致)。第一次自动重过一次 CF 再试; 仍失败才报错给用户。
        await _handleCsrfFailure(status);
        return;
      case 'hcaptcha':
        _finishFailure(
          LoginErrorKind.unknown,
          '人机验证失败, 请重试 (hcaptcha $status)',
        );
        return;
      case 'exception':
        _finishFailure(LoginErrorKind.network, '登录请求异常: $body');
        return;
      case 'session':
        break;
      default:
        _finishFailure(LoginErrorKind.unknown, '未知登录阶段: $phase');
        return;
    }

    // 复用 _LoginMixin 的响应解析 (错误 reason 映射)
    final result = DiscourseService().parseSessionJsonBody(status, body);
    if (result is LoginSuccess) {
      await _finishSuccess();
      return;
    }
    final failure = result as LoginFailure;
    if (failure.kind == LoginErrorKind.secondFactorRequired) {
      await _handleSecondFactor(failure);
      return;
    }
    _finishFailure(failure.kind, failure.message);
  }

  /// CSRF 阶段 403 处理: 自动重过一次 CF 验证, 再用同样参数重跑登录。
  ///
  /// 触发场景:
  /// - jar 里的 cf_clearance 已被 CF 拒 (IP 漂移 / TLS 指纹不一致 / 自然过期)
  /// - 普通 toast "请重试" 没用 — cookie 已废, 再点登录还是同样的 403
  ///
  /// 策略: 重过一次 CF, 把新 cf_clearance 同步到 jar, 重新灌进 dialog WV
  /// 的 cookie store, 再调一次 __fluxdoLogin。只重试一次, 仍失败 toast 原错。
  Future<void> _handleCsrfFailure(int status) async {
    if (_finished) return;
    if (_cfRetryUsed) {
      _finishFailure(
        LoginErrorKind.network,
        'Cloudflare 验证已失效, 请重试 (CSRF $status)',
      );
      return;
    }
    _cfRetryUsed = true;

    if (mounted) {
      ToastService.showInfo('Cloudflare 验证已失效, 正在重新验证...');
    }

    // 1. 拉起 CF 手动验证页, 用户过完后 sync cookie 到 jar
    final ok = await CfChallengeService().showManualVerify(context, true);
    if (_finished) return;
    if (ok != true) {
      _finishFailure(
        LoginErrorKind.network,
        'Cloudflare 验证已失效, 请重试 (CSRF $status)',
      );
      return;
    }

    // 2. 等 WV 网络栈把 Set-Cookie 写完, 再同步 CF/验证码相关 cookie。
    //    session cookie 只在登录成功收口时同步，避免旧会话回写。
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (_finished) return;
    for (var i = 0; i < 3; i++) {
      await BoundarySyncService.instance.syncFromWebView(
        cookieNames: null,
        excludeCookieNames: CookieJarService.authCookieNames,
        requestGeneration: _flowGeneration,
      );
      final clearance = await CookieJarService().getCfClearance();
      if (clearance != null && clearance.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (_finished) return;

    // 3. 把 jar 里的新 cookie 重新灌进 dialog WV (清掉一次锁, 否则跳过)
    _cookiesPrimed = false;

    // 4. 重跑登录: hcaptcha token 还没被 hcaptcha/create 消费 (上次卡在
    //    csrf 阶段, 是 hcaptcha 之前的步骤), 直接复用即可。
    await _runLogin(
      hcaptchaToken: _lastHcaptchaToken,
      secondFactorToken: _lastSecondFactorToken,
    );
  }

  Future<void> _handleSecondFactor(LoginFailure failure) async {
    if (_finished || !mounted) return;
    final code = await widget.onNeedSecondFactor(
      WebViewLoginNeed2FA(
        totpEnabled: failure.totpEnabled,
        backupEnabled: failure.backupEnabled,
        securityKeyEnabled: failure.securityKeyEnabled,
        message: failure.message,
      ),
    );
    if (_finished || !mounted) return;
    if (code == null || code.isEmpty) {
      // 用户取消 2FA (或选了备用码/安全密钥, 已由 caller 跳 WebViewLoginPage 兜底)
      _finishCanceled();
      return;
    }
    // 同一存活 controller 重试, 第二次 hcaptchaToken=null (h_captcha_temp_id 已写)。
    // 注意: h_captcha_temp_id 仅 2 分钟 TTL, 若 2FA 输入超时, 第二次 session 会
    // 因 hcaptcha 过期失败 → 走 _finishFailure, caller 提示重新登录。
    await _runLogin(hcaptchaToken: null, secondFactorToken: code);
  }

  Future<void> _finishSuccess() async {
    if (_finished) return;
    _finished = true;
    if (!AuthSession().isValid(_flowGeneration)) {
      debugPrint('[WebViewLogin] 登录对话框流程已过期，跳过会话同步');
      _returnResult(const WebViewLoginDialogResult.canceled());
      return;
    }
    // pop 前在同源轻量页里跑站点 session bootstrap，再把 cookie 落 jar。
    // 不能加载完整 Discourse 前端，低版本 iOS/WKWebView 兼容性不够稳定。
    try {
      final controller = _controller;
      var bootstrapped = false;
      if (controller != null) {
        final bootstrapResult = await WebViewSessionCookieRefreshService
            .instance
            .runOnController(
              controller,
              reason: 'native_login_success',
              pluginCandidates: PreloadedDataService().pluginCandidatesSync,
            );
        bootstrapped = bootstrapResult.ok;
      }
      await BoundarySyncService.instance.syncFromWebView(
        controller: controller,
        currentUrl: 'https://linux.do/',
        cookieNames: null,
        allowLowConfidenceSessionCookies: true,
        requestGeneration: _flowGeneration,
        trusted: true,
      );
      final runtimeDetails = await CookieJarService()
          .getCookieDiagnosticsForRequest(
            Uri.parse(AppConstants.baseUrl),
            names: const {'_rt'},
          );
      final hasRuntimeCookie = runtimeDetails.any(
        (cookie) => (cookie['valueLength'] as int? ?? 0) > 0,
      );
      final tToken = await CookieJarService().getTToken();
      if (hasRuntimeCookie) {
        WebViewSessionCookieRefreshService.instance.markSynced(
          reason: 'native_login_success',
          tToken: tToken,
          hasRuntimeCookie: hasRuntimeCookie,
        );
      }
      await WebViewSessionCookieRefreshService.instance.logCookieSummary(
        reason: 'native_login_success',
        bootstrapOk: bootstrapped,
      );
    } catch (e) {
      debugPrint('[WebViewLogin] syncFromWebView 失败: $e');
    }
    _returnResult(const WebViewLoginDialogResult.success());
  }

  void _finishFailure(LoginErrorKind kind, String? message) {
    if (_finished) return;
    _finished = true;
    _returnResult(WebViewLoginDialogResult.failure(kind, message));
  }

  void _finishCanceled() {
    if (_finished) return;
    _finished = true;
    _returnResult(const WebViewLoginDialogResult.canceled());
  }

  void _returnResult(WebViewLoginDialogResult result) {
    if (!mounted || _routeClosed) return;
    final route = ModalRoute.of<WebViewLoginDialogResult>(context);
    if (route == null || !route.isActive) return;
    if (route.isCurrent) {
      route.navigator!.pop(result);
    } else {
      route.navigator!.removeRoute(route, result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final message = switch (_phase) {
      CaptchaPanelPhase.loading => l.captcha_loading,
      CaptchaPanelPhase.checkbox => l.login_captchaCheckbox,
      CaptchaPanelPhase.challenge => l.captcha_challengeHint,
      CaptchaPanelPhase.submitting => l.login_captchaSubmitting,
      CaptchaPanelPhase.failed =>
        _expired ? l.captcha_expired : l.captcha_unavailable,
    };
    return PopScope<WebViewLoginDialogResult>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _routeClosed = true;
          _finished = true;
          _loadTimeout?.cancel();
        }
      },
      child: CaptchaPanel(
        phase: _phase,
        contentHeight: _phase == CaptchaPanelPhase.checkbox
            ? _checkboxHeight
            : _challengeHeight,
        message: message,
        onRetry: _retryVerification,
        child: _phase == CaptchaPanelPhase.failed
            ? null
            : LayoutBuilder(
                builder: (context, bounds) {
                  if (bounds.maxWidth <= 0) return const SizedBox.shrink();
                  return _attemptWebView ??= _webView(
                    _attempt,
                    _inlineHtml(
                      compact:
                          bounds.maxWidth < CaptchaPanel.normalCheckboxWidth,
                    ),
                  );
                },
              ),
      ),
    );
  }

  Widget _webView(int attempt, String document) => InAppWebView(
    key: ValueKey(attempt),
    webViewEnvironment: Platform.isWindows
        ? WindowsWebViewEnvironmentService.instance.environment
        : null,
    initialUrlRequest: Platform.isWindows
        ? URLRequest(url: _windowsBootstrapUrl)
        : null,
    initialData: Platform.isWindows
        ? null
        : InAppWebViewInitialData(
            data: document,
            baseUrl: WebUri(AppConstants.baseUrl),
            mimeType: 'text/html',
            encoding: 'utf-8',
          ),
    initialSettings: InAppWebViewSettings(
      javaScriptEnabled: true,
      transparentBackground: true,
      supportZoom: false,
      sharedCookiesEnabled: true,
      thirdPartyCookiesEnabled: true,
      userAgent: AppConstants.webViewUserAgentOverride,
      javaScriptHandlersForMainFrameOnly: true,
      javaScriptHandlersOriginAllowList: {
        '^${RegExp.escape(AppConstants.baseUrl)}\$',
      },
    ),
    initialUserScripts: WebViewSettings.compatPolyfillScripts,
    onReceivedServerTrustAuthRequest: (_, challenge) =>
        WebViewSettings.handleServerTrustAuthRequest(challenge),
    onWebViewCreated: (controller) {
      if (attempt != _attempt || !_verifying) return;
      _controller = controller;
      WebViewSettings.registerJsErrorReporter(controller);
      _setupHandlers(controller, attempt);
    },
    onLoadStop: (controller, _) async {
      if (Platform.isWindows) {
        await _injectWindowsInlineHtml(controller, attempt, document);
      }
    },
    onProgressChanged: (controller, progress) async {
      if (Platform.isWindows && progress >= 100) {
        await _injectWindowsInlineHtml(controller, attempt, document);
      }
    },
    onReceivedError: (controller, request, _) async {
      if (request.isForMainFrame != true || attempt != _attempt) return;
      if (Platform.isWindows) {
        await _injectWindowsInlineHtml(controller, attempt, document);
      } else {
        _failVerification();
      }
    },
    onReceivedHttpError: (controller, request, _) {
      if (request.isForMainFrame == true && attempt == _attempt) {
        _failVerification();
      }
    },
  );
}
