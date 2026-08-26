part of 'discourse_service.dart';

/// 原生用户名/密码登录 — linux.do 流程对齐网页:
/// 1. (UI 层) 弹 hcaptcha mini webview, 让用户人机验证拿 hcaptcha token
/// 2. GET /session/csrf (由 RequestHeaderInterceptor 在 POST 前自动触发)
/// 3. POST /hcaptcha/create.json {token: hcaptchaToken}
///    → server 写一个 2 分钟 TTL 的 encrypted cookie `h_captcha_temp_id`
/// 4. POST /session.json {login, password, second_factor_token?}
///    → server 见 h_captcha_temp_id cookie + verify hcaptcha → 真正登录
///
/// 主要解决 iOS 15.7 用户卡 splash 的 Discourse `static {}` (ES2022) 兼容问题:
/// 不再加载 Discourse Ember bundle, 直接走 native JSON API。
mixin _LoginMixin on _DiscourseServiceBase, _AuthMixin {
  /// 用 hcaptcha token 换 h_captcha_temp_id cookie。
  /// caller 必须先通过 hcaptcha mini webview 让用户人机交互拿到 token。
  @Deprecated(
    '改用 WebView 内 JS 全流程登录 (showWebViewLoginDialog); '
    'dio GET /session/csrf 实测被 CF 当 bot 403 (TLS 指纹), 仅留兜底',
  )
  Future<bool> verifyHcaptchaToken(String hcaptchaToken) async {
    try {
      await _dio.post<dynamic>(
        '/hcaptcha/create.json',
        data: {'token': hcaptchaToken},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      return true;
    } on DioException catch (e) {
      debugPrint(
        '[DiscourseLogin] hcaptcha verify 失败: ${e.type} ${e.response?.statusCode} ${e.message}',
      );
      return false;
    }
  }

  /// 用户名/邮箱 + 密码登录。
  ///
  /// 调用约定:
  /// - 调用前必须先 [verifyHcaptchaToken] 让 server 写 h_captcha_temp_id cookie
  /// - 首次返 [LoginErrorKind.secondFactorRequired] 时由 caller 弹 TOTP 对话框
  ///   拿 6 位 code, 再次调本方法带 [secondFactorToken]
  @Deprecated(
    '改用 WebView 内 JS 全流程登录 (showWebViewLoginDialog); '
    'dio CSRF 依赖 GET /session/csrf, 而它被 CF 403, 仅留兜底',
  )
  Future<LoginResult> loginWithPassword({
    required String identifier,
    required String password,
    String? secondFactorToken,
  }) async {
    final data = <String, String>{'login': identifier, 'password': password};
    if (secondFactorToken != null && secondFactorToken.isNotEmpty) {
      data['second_factor_token'] = secondFactorToken;
      // 1=TOTP, 2=backup code, 3=security key. 第一版只支持 TOTP, backup/key
      // 引导用户跳 webview 登录兜底。
      data['second_factor_method'] = '1';
    }

    final Response<dynamic> resp;
    try {
      resp = await _dio.post<dynamic>(
        '/session.json',
        data: data,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
    } on DioException catch (e) {
      debugPrint(
        '[DiscourseLogin] session POST 失败: ${e.type} ${e.response?.statusCode}',
      );
      return LoginResult.error(
        LoginErrorKind.network,
        message: e.message ?? '网络异常',
      );
    }

    final body = resp.data is Map
        ? Map<String, dynamic>.from(resp.data as Map)
        : null;
    if (body == null) {
      return LoginResult.error(
        LoginErrorKind.unknown,
        message: 'Discourse 返回非 JSON: HTTP ${resp.statusCode}',
      );
    }

    // 服务端把所有失败都用 200 + {error, reason} 表达
    final reason = body['reason']?.toString();
    if (reason != null) return _parseLoginError(reason, body);
    if (body['error'] != null && body['user'] == null) {
      return LoginResult.error(
        LoginErrorKind.unknown,
        message: body['error']?.toString(),
      );
    }

    // 成功路径 — 收口
    await finalizeNativeLoginSuccess(identifier);
    return const LoginResult.success();
  }

  LoginResult _parseLoginError(String reason, Map<String, dynamic> body) {
    switch (reason) {
      case 'invalid_second_factor':
      case 'second_factor':
        return LoginResult.error(
          LoginErrorKind.secondFactorRequired,
          message: body['error']?.toString(),
          totpEnabled: body['totp_enabled'] == true,
          securityKeyEnabled: body['security_key_enabled'] == true,
          backupEnabled: body['backup_enabled'] == true,
        );
      case 'invalid_credentials':
        return LoginResult.error(
          LoginErrorKind.invalidCredentials,
          message: body['error']?.toString(),
        );
      case 'not_activated':
        return LoginResult.error(
          LoginErrorKind.notActivated,
          message: body['error']?.toString(),
          sentToEmail: body['sent_to_email']?.toString(),
          currentEmail: body['current_email']?.toString(),
        );
      case 'not_approved':
        return LoginResult.error(
          LoginErrorKind.notApproved,
          message: body['error']?.toString(),
        );
      case 'expired':
        return LoginResult.error(
          LoginErrorKind.passwordExpired,
          message: body['error']?.toString(),
        );
      default:
        return LoginResult.error(
          LoginErrorKind.unknown,
          message: body['error']?.toString() ?? 'reason=$reason',
        );
    }
  }

  /// 解析 WebView 内 JS 全流程登录 POST /session.json 的响应体 (字符串)。
  ///
  /// 与 [loginWithPassword] 的响应解析逻辑一致, 但**不发 dio、不做收尾** ——
  /// 收尾由调用方在 cookie 同步落 jar 后显式调 [finalizeNativeLoginSuccess]。
  /// Discourse 把成功/失败都用 HTTP 200 + JSON body 表达 ([status] 仅用于
  /// 非 JSON 时的错误消息)。
  LoginResult parseSessionJsonBody(int status, String body) {
    Map<String, dynamic>? map;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) map = Map<String, dynamic>.from(decoded);
    } catch (_) {
      map = null;
    }
    if (map == null) {
      return LoginResult.error(
        LoginErrorKind.unknown,
        message: 'Discourse 返回非 JSON: HTTP $status',
      );
    }

    final reason = map['reason']?.toString();
    if (reason != null) return _parseLoginError(reason, map);
    if (map['error'] != null && map['user'] == null) {
      return LoginResult.error(
        LoginErrorKind.unknown,
        message: map['error']?.toString(),
      );
    }
    return const LoginResult.success();
  }

  /// 收口对齐 webview_login_page 的 _finalizeLoginBeforeExit + _finalizeLoginBootstrap:
  /// AuthSession.advance → 从 jar 拿 _t → saveUsername/setToken → LoginReadyCoordinator
  ///
  /// WebView JS 全流程登录成功后, 由 login_page 在 dialog 已把会话 cookie
  /// syncFromWebView 落 jar 之后显式调用 (public)。dio 版 [loginWithPassword]
  /// 成功路径也复用它。
  @override
  Future<void> finalizeNativeLoginSuccess(String identifier) async {
    final loginGeneration = AuthSession().advance();

    final token = await _cookieJar.getTToken() ?? '';
    if (token.isEmpty) {
      debugPrint('[DiscourseLogin] 警告: 登录成功但 jar 没拿到 _t');
    }

    await saveUsername(identifier, requestGeneration: loginGeneration);
    if (!AuthSession().isValid(loginGeneration)) {
      debugPrint('[DiscourseLogin] 登录收尾期间会话已切换，丢弃旧收尾: $identifier');
      return;
    }
    if (token.isNotEmpty) setToken(token);
    final forceBrowserSessionSync = !WebViewSessionCookieRefreshService.instance
        .hasFreshSyncForToken(token);

    var loginReadyNotified = false;
    try {
      await LoginReadyCoordinator(
            hydrateFromHtml: PreloadedDataService().hydrateFromHtml,
            refreshPreloadedData: PreloadedDataService().refresh,
            notifyLoginReady: (t) {
              if (!AuthSession().isValid(loginGeneration)) return;
              loginReadyNotified = true;
              onLoginSuccess(
                t,
                forceBrowserSessionSync: forceBrowserSessionSync,
              );
            },
          )
          .finalize(token: token, pageHtml: null)
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('[DiscourseLogin] PreloadedData 收尾失败/超时: $e');
    } finally {
      // 兜底广播, 避免 UI 卡在"同步登录中"
      if (!loginReadyNotified && AuthSession().isValid(loginGeneration)) {
        onLoginSuccess(token, forceBrowserSessionSync: forceBrowserSessionSync);
      }
    }
  }
}

enum LoginErrorKind {
  invalidCredentials,
  secondFactorRequired,
  notActivated,
  notApproved,
  passwordExpired,
  network,
  unknown,
}

/// sealed 风格的登录结果
sealed class LoginResult {
  const LoginResult();

  const factory LoginResult.success() = LoginSuccess;

  const factory LoginResult.error(
    LoginErrorKind kind, {
    String? message,
    bool totpEnabled,
    bool securityKeyEnabled,
    bool backupEnabled,
    String? sentToEmail,
    String? currentEmail,
  }) = LoginFailure;
}

class LoginSuccess extends LoginResult {
  const LoginSuccess();
}

class LoginFailure extends LoginResult {
  const LoginFailure(
    this.kind, {
    this.message,
    this.totpEnabled = false,
    this.securityKeyEnabled = false,
    this.backupEnabled = false,
    this.sentToEmail,
    this.currentEmail,
  });

  final LoginErrorKind kind;
  final String? message;
  final bool totpEnabled;
  final bool securityKeyEnabled;
  final bool backupEnabled;
  final String? sentToEmail;
  final String? currentEmail;
}
