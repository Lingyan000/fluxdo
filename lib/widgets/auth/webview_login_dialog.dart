import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../constants.dart';
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
/// 时一致, 避开 dio (IO / rhttp 适配器) 指纹不匹配导致的 403 (BAD CSRF)。
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
}) {
  return showDialog<WebViewLoginDialogResult>(
    context: context,
    barrierColor: Colors.black54,
    barrierDismissible: false,
    builder: (_) => _WebViewLoginDialog(
      siteKey: siteKey,
      identifier: identifier,
      password: password,
      onNeedSecondFactor: onNeedSecondFactor,
      hcaptchaCreateEndpoint: hcaptchaCreateEndpoint,
    ),
  );
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
  bool _loading = true;
  bool _processing = false; // hcaptcha 通过后登录请求进行中
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
  void dispose() {
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

  String get _inlineHtml {
    final scheme = Theme.of(context).colorScheme;
    String hex(Color c) =>
        '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    final titleColor = hex(scheme.onSurface);
    final subColor = hex(scheme.onSurfaceVariant);
    final accent = hex(scheme.primary);
    final endpointsJson = jsonEncode(_hcaptchaCreateEndpoints);
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
  <style>
    html, body { margin: 0; padding: 0; height: 100%; background: transparent;
      font-family: -apple-system, system-ui, sans-serif; -webkit-text-size-adjust: 100%; }
    body { overflow: hidden; }
    .wrap { box-sizing: border-box; min-height: 100vh; display: flex; flex-direction: column;
      align-items: center; justify-content: center; gap: 22px; padding: 24px; text-align: center; }
    .badge { width: 60px; height: 60px; border-radius: 50%; display: flex;
      align-items: center; justify-content: center; background: ${accent}1f; font-size: 30px; }
    .tip { font-size: 14px; line-height: 1.6; color: $subColor; margin: 0; max-width: 260px; }
    .tip b { color: $titleColor; font-weight: 600; }
    .h-captcha { min-height: 78px; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="badge">🛡️</div>
    <p class="tip">勾选下方方框，<b>确认你不是机器人</b>即可继续登录</p>
    <div id="cap" class="h-captcha"
      data-sitekey="${widget.siteKey}"
      data-callback="onPass"
      data-error-callback="onErr"
      data-expired-callback="onExp"
      data-size="normal"></div>
  </div>
  <script>
    function call(name, payload) {
      try { window.flutter_inappwebview.callHandler(name, payload); } catch (e) {}
    }
    function notifyPageReady() {
      try {
        requestAnimationFrame(function() {
          requestAnimationFrame(function() { call('hcaptcha_page_ready', null); });
        });
      } catch (e) {
        setTimeout(function() { call('hcaptcha_page_ready', null); }, 80);
      }
    }
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', notifyPageReady, { once: true });
    } else {
      notifyPageReady();
    }
    function onPass(token) { call('hcaptcha_pass', token); }
    function onErr(err)    { call('hcaptcha_error', String(err || 'unknown')); }
    function onExp()       { call('hcaptcha_expired', null); }

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
  <script src="https://js.hcaptcha.com/1/api.js" async defer></script>
</body>
</html>
''';
  }

  void _setupHandlers(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'hcaptcha_page_ready',
      callback: (args) {
        if (mounted && _loading) {
          setState(() => _loading = false);
        }
        return null;
      },
    );
    // hcaptcha 通过 → 首次驱动登录 (带 hcaptcha token)
    controller.addJavaScriptHandler(
      handlerName: 'hcaptcha_pass',
      callback: (args) {
        final token = args.isNotEmpty ? args.first?.toString() : null;
        if (token != null && token.isNotEmpty) {
          _runLogin(hcaptchaToken: token, secondFactorToken: null);
        }
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'hcaptcha_error',
      callback: (args) {
        debugPrint(
          '[WebViewLogin] hcaptcha error: ${args.isNotEmpty ? args.first : ""}',
        );
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'hcaptcha_expired',
      callback: (args) {
        debugPrint('[WebViewLogin] hcaptcha expired');
        return null;
      },
    );
    // JS 全流程登录结果
    controller.addJavaScriptHandler(
      handlerName: 'login_result',
      callback: (args) {
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
  ) async {
    if (_finished) return;
    if (_windowsInlineHtmlInjected) {
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
      if (origin != AppConstants.baseUrl) {
        debugPrint('[WebViewLogin] Windows bootstrap origin not ready: $probe');
        return;
      }

      final html = jsonEncode(_inlineHtml);
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
      _finishFailure(LoginErrorKind.unknown, '人机验证页面初始化失败');
    }
  }

  /// 调 WebView 里的 __fluxdoLogin。id/pwd/token 用 jsonEncode 安全注入 (防 JS 注入)。
  Future<void> _runLogin({
    required String? hcaptchaToken,
    required String? secondFactorToken,
  }) async {
    final controller = _controller;
    if (controller == null ||
        _finished ||
        !AuthSession().isValid(_flowGeneration)) {
      if (!_finished && !AuthSession().isValid(_flowGeneration)) {
        _finishCanceled();
      }
      return;
    }
    if (mounted) setState(() => _processing = true);

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
    if (!AuthSession().isValid(_flowGeneration)) {
      _finishCanceled();
      return;
    }
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
    if (!AuthSession().isValid(_flowGeneration)) {
      _finishCanceled();
      return;
    }
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
    if (!AuthSession().isValid(_flowGeneration)) {
      _finishCanceled();
      return;
    }
    for (var i = 0; i < 3; i++) {
      await BoundarySyncService.instance.syncFromWebView(
        cookieNames: null,
        excludeCookieNames: CookieJarService.authCookieNames,
        requestGeneration: _flowGeneration,
      );
      final clearance = await CookieJarService().getCfClearance();
      if (clearance != null && clearance.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!AuthSession().isValid(_flowGeneration)) {
        _finishCanceled();
        return;
      }
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
      if (mounted) {
        Navigator.of(context).pop(const WebViewLoginDialogResult.canceled());
      }
      return;
    }
    // pop 前在同源轻量页里跑站点 session bootstrap，再把 cookie 落 jar。
    // 不能加载完整 Discourse 前端，低版本 iOS/WKWebView 兼容性不够稳定。
    try {
      final controller = _controller;
      var bootstrapped = false;
      if (controller != null) {
        final cancellationSignal = AuthSession().cancelToken.whenCancel
            .then<void>((_) {});
        final bootstrapResult = await WebViewSessionCookieRefreshService
            .instance
            .runOnController(
              controller,
              reason: 'native_login_success',
              pluginCandidates: PreloadedDataService().pluginCandidatesSync,
              isCancelled: () => !AuthSession().isValid(_flowGeneration),
              cancellationSignal: cancellationSignal,
            );
        if (!AuthSession().isValid(_flowGeneration)) {
          if (mounted) {
            Navigator.of(
              context,
            ).pop(const WebViewLoginDialogResult.canceled());
          }
          return;
        }
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
      if (!AuthSession().isValid(_flowGeneration)) {
        if (mounted) {
          Navigator.of(context).pop(const WebViewLoginDialogResult.canceled());
        }
        return;
      }
      final runtimeDetails = await CookieJarService()
          .getCookieDiagnosticsForRequest(
            Uri.parse(AppConstants.baseUrl),
            names: const {'_rt'},
          );
      if (!AuthSession().isValid(_flowGeneration)) {
        if (mounted) {
          Navigator.of(context).pop(const WebViewLoginDialogResult.canceled());
        }
        return;
      }
      final hasRuntimeCookie = runtimeDetails.any(
        (cookie) => (cookie['valueLength'] as int? ?? 0) > 0,
      );
      final tToken = await CookieJarService().getTToken();
      if (hasRuntimeCookie && AuthSession().isValid(_flowGeneration)) {
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
      if (!AuthSession().isValid(_flowGeneration)) {
        if (mounted) {
          Navigator.of(context).pop(const WebViewLoginDialogResult.canceled());
        }
        return;
      }
    } catch (e) {
      debugPrint('[WebViewLogin] syncFromWebView 失败: $e');
    }
    if (mounted) {
      Navigator.of(context).pop(const WebViewLoginDialogResult.success());
    }
  }

  void _finishFailure(LoginErrorKind kind, String? message) {
    if (_finished) return;
    _finished = true;
    if (mounted) {
      Navigator.of(
        context,
      ).pop(WebViewLoginDialogResult.failure(kind, message));
    }
  }

  void _finishCanceled() {
    if (_finished) return;
    _finished = true;
    if (mounted) {
      Navigator.of(context).pop(const WebViewLoginDialogResult.canceled());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxWidth < 640;
            final horizontalMargin = isCompact ? 12.0 : 24.0;
            final verticalMargin = isCompact ? 12.0 : 24.0;
            final availableHeight = math.max(
              360.0,
              constraints.maxHeight - verticalMargin * 2,
            );
            // hcaptcha 的 challenge 九宫格弹层约需 ~600px 高, 面板给足高度避免
            // 出滚动条; 小屏则占满可用高度。
            final panelHeight = math.min(availableHeight, 640.0);

            return Align(
              alignment: isCompact ? Alignment.bottomCenter : Alignment.center,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: horizontalMargin,
                  vertical: verticalMargin,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: SizedBox(
                    width: double.infinity,
                    height: panelHeight,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.15),
                            blurRadius: 24,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: Column(
                          children: [
                            _Header(onClose: _finishCanceled, scheme: scheme),
                            Expanded(
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: InAppWebView(
                                      webViewEnvironment: Platform.isWindows
                                          ? WindowsWebViewEnvironmentService
                                                .instance
                                                .environment
                                          : null,
                                      initialUrlRequest: Platform.isWindows
                                          ? URLRequest(
                                              url: _windowsBootstrapUrl,
                                            )
                                          : null,
                                      initialData: Platform.isWindows
                                          ? null
                                          : InAppWebViewInitialData(
                                              data: _inlineHtml,
                                              baseUrl: WebUri(
                                                AppConstants.baseUrl,
                                              ),
                                              mimeType: 'text/html',
                                              encoding: 'utf-8',
                                            ),
                                      initialSettings: InAppWebViewSettings(
                                        javaScriptEnabled: true,
                                        transparentBackground: true,
                                        supportZoom: false,
                                        sharedCookiesEnabled: true,
                                        thirdPartyCookiesEnabled: true,
                                        userAgent: AppConstants
                                            .webViewUserAgentOverride,
                                      ),
                                      initialUserScripts:
                                          WebViewSettings.compatPolyfillScripts,
                                      onReceivedServerTrustAuthRequest:
                                          (_, challenge) =>
                                              WebViewSettings.handleServerTrustAuthRequest(
                                                challenge,
                                              ),
                                      onWebViewCreated: (controller) {
                                        _controller = controller;
                                        WebViewSettings.registerJsErrorReporter(
                                          controller,
                                        );
                                        _setupHandlers(controller);
                                      },
                                      onLoadStop: (controller, _) async {
                                        if (Platform.isWindows) {
                                          await _injectWindowsInlineHtml(
                                            controller,
                                          );
                                          return;
                                        }
                                        if (mounted) {
                                          setState(() => _loading = false);
                                        }
                                      },
                                      onProgressChanged:
                                          (controller, progress) async {
                                            if (Platform.isWindows &&
                                                progress >= 100) {
                                              await _injectWindowsInlineHtml(
                                                controller,
                                              );
                                            }
                                          },
                                      onReceivedError:
                                          (controller, request, error) async {
                                            if (Platform.isWindows &&
                                                request.isForMainFrame ==
                                                    true) {
                                              await _injectWindowsInlineHtml(
                                                controller,
                                              );
                                            }
                                          },
                                    ),
                                  ),
                                  if (_loading)
                                    Positioned.fill(
                                      child: ColoredBox(
                                        color: scheme.surface,
                                        child: const Center(
                                          child: CircularProgressIndicator(),
                                        ),
                                      ),
                                    ),
                                  if (_processing)
                                    Positioned.fill(
                                      child: ColoredBox(
                                        color: scheme.surface.withValues(
                                          alpha: 0.92,
                                        ),
                                        child: Center(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const CircularProgressIndicator(),
                                              const SizedBox(height: 16),
                                              Text(
                                                '正在登录…',
                                                style:
                                                    theme.textTheme.bodyMedium,
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
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose, required this.scheme});

  final VoidCallback onClose;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(Symbols.verified_user_rounded, size: 20, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '完成人机验证',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            icon: const Icon(Symbols.close_rounded, size: 22),
            tooltip: '取消',
            onPressed: onClose,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
