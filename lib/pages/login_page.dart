import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/s.dart';
import '../services/auth_session.dart';
import '../services/cf_challenge_service.dart';
import '../services/credential_store_service.dart';
import '../services/discourse/discourse_service.dart';
import '../services/network/cookie/boundary_sync_service.dart';
import '../services/network/cookie/cookie_jar_service.dart';
import '../services/toast_service.dart';
import '../services/user_api_key_login_flow.dart';
import '../utils/blur_config.dart';
import '../widgets/auth/webview_login_dialog.dart';
import '../widgets/auth/login_form.dart';
import '../widgets/auth/two_factor_dialog.dart';
import '../widgets/common/ambient_background.dart';
import '../widgets/common/floating_logo.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'qr_login_scan_page.dart';
import 'webview_login_page.dart';

/// linux.do 原生登录页。
///
/// 主路径走 [DiscourseService.loginWithPassword] (在 `_LoginMixin` 里),
/// 不加载 Discourse Ember bundle, 绕开 iOS 15 的 ES2022 `static{}` 兼容问题。
///
/// 流程对齐 linux.do 网页:
/// 1. 弹 hcaptcha 人机验证 (mini WebView, 只加载几 KB hcaptcha widget)
/// 2. POST /hcaptcha/create.json 用 token 换 h_captcha_temp_id cookie
/// 3. POST /session.json 真正登录
/// 4. 2FA 用户弹 TOTP dialog 再次提交
///
/// 失败 / 高级场景 (OAuth / 注册 / 找回密码 / 2FA 走 backup code 等) 兜底跳
/// [WebViewLoginPage]。
///
/// linux.do 的 hcaptcha sitekey 写死, 后续可从 PreloadedDataService 动态拿。
const String _kLinuxDoHcaptchaSiteKey = 'a776b4ac-8c4c-441e-986a-c6ee9ed8cf08';
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with TickerProviderStateMixin {
  String? _savedUsername;
  String? _savedPassword;
  bool _credentialsLoaded = false;
  bool _browserAuthLaunching = false;

  late final AnimationController _entryController;
  final List<Animation<double>> _fade = [];
  final List<Animation<Offset>> _slide = [];

  @override
  void initState() {
    super.initState();
    _setupEntryAnimations();
    _loadSavedCredentials();
  }

  /// staggered 入场动画 (对齐 onboarding 的节奏)
  void _setupEntryAnimations() {
    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    for (var i = 0; i < 5; i++) {
      final start = i * 0.12;
      final end = (start + 0.6).clamp(0.0, 1.0);
      _fade.add(
        Tween<double>(begin: 0, end: 1).animate(
          CurvedAnimation(
            parent: _entryController,
            curve: Interval(start, end, curve: Curves.easeOut),
          ),
        ),
      );
      _slide.add(
        Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _entryController,
            curve: Interval(start, end, curve: Curves.easeOutCubic),
          ),
        ),
      );
    }
    _entryController.forward();
  }

  @override
  void dispose() {
    if (identical(UserApiKeyLoginFlow.instance.onFlowFinished, _onBrowserAuthFinished)) {
      UserApiKeyLoginFlow.instance.onFlowFinished = null;
    }
    _entryController.dispose();
    super.dispose();
  }

  /// 浏览器授权登录:拉起系统浏览器打开 /user-api-key/new,授权后
  /// 深链 fluxdo://auth_redirect 回 App,由 UserApiKeyLoginFlow 完成
  /// OTP 兑换与登录收口,这里只负责发起和成功后 pop。
  Future<void> _loginWithBrowserAuth() async {
    if (_browserAuthLaunching) return;
    setState(() => _browserAuthLaunching = true);
    UserApiKeyLoginFlow.instance.onFlowFinished = _onBrowserAuthFinished;
    try {
      // 首次会懒生成 RSA 密钥对(isolate),可能耗时数秒
      final launched = await UserApiKeyLoginFlow.instance.start();
      if (!launched && mounted) {
        ToastService.showError('无法打开浏览器,请重试');
      }
    } finally {
      if (mounted) setState(() => _browserAuthLaunching = false);
    }
  }

  void _onBrowserAuthFinished(bool success) {
    if (success && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _loadSavedCredentials() async {
    try {
      final saved = await CredentialStoreService().load();
      if (!mounted) return;
      setState(() {
        _savedUsername = saved.username;
        _savedPassword = saved.password;
        _credentialsLoaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _credentialsLoaded = true);
    }
  }

  /// 确保 jar 里有 cf_clearance。没有 → 弹 fluxdo 现有的 CF 手动验证页让用户
  /// 人机交互拿 cookie, 然后**显式 sync** 从 WebView cookie store 到 dart jar
  /// (这步 [CfChallengeService.showManualVerify] 本身不做, sync 一般是
  /// [CfChallengeInterceptor._syncCookiesOnce] 触发, 我们直接调 showManualVerify
  /// 不经过 interceptor, 所以要手动 sync, 不然 jar 还是空)。
  Future<bool> _ensureCfClearance() async {
    final jar = CookieJarService();
    var clearance = await jar.getCfClearance();
    if (clearance != null && clearance.isNotEmpty) return true;
    if (!mounted) return false;

    final requestGeneration = AuthSession().generation;
    final ok = await CfChallengeService().showManualVerify(context, true);
    if (ok != true) return false;

    // 等 1.5s 让 WV 网络栈把 Set-Cookie 写完, 然后同步 CF/验证码相关 cookie。
    // 这里明确排除 Discourse session cookie，登录成功收口流程会单独同步它们。
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    for (var i = 0; i < 3; i++) {
      await BoundarySyncService.instance.syncFromWebView(
        cookieNames: null,
        excludeCookieNames: CookieJarService.authCookieNames,
        requestGeneration: requestGeneration,
      );
      clearance = await jar.getCfClearance();
      if (clearance != null && clearance.isNotEmpty) return true;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  /// 表单提交回调。返 true 表示走完成功路径并已 pop, false 留在表单。
  Future<bool> _handleSubmit({
    required String identifier,
    required String password,
    required bool rememberCredentials,
  }) async {
    final service = DiscourseService();

    // Step 0: jar 必须有 cf_clearance, 否则 native dio 任何请求都被 CF 当 bot
    // 直接 403 (TLS 指纹不对). 没有就弹 CF 手动验证页让用户人机过一次。
    if (!await _ensureCfClearance()) {
      if (mounted) {
        ToastService.showError('Cloudflare 验证未完成,请重试');
      }
      return false;
    }
    if (!mounted) return false;

    // hcaptcha endpoint: 从 SharedPreferences 拿 (站长改 mount 时填到设置里);
    // 没配就让 dialog 用内置 fallback 列表 (/captcha/hcaptcha/create.json →
    // /hcaptcha/create.json)。读 prefs 直接走 SharedPreferences (不依赖
    // riverpod, LoginPage 是普通 StatefulWidget)。
    final prefs = await SharedPreferences.getInstance();
    final hcaptchaEndpoint = prefs.getString('pref_hcaptcha_create_endpoint');
    if (!mounted) return false;

    // Step 1-3: WebView 内 JS 全流程登录 (csrf → hcaptcha/create → session)。
    // 三个请求都由 WebView 内核发出, TLS/JA3 指纹与 CF 签发 cf_clearance 时一致,
    // 避开 dio (IO/rhttp 适配器) 指纹不匹配导致的 403 (BAD CSRF)。
    // 2FA 通过 onNeedSecondFactor 回调弹 TOTP, 由 dialog 内同一 WebView 重试。
    final result = await showWebViewLoginDialog(
      context,
      siteKey: _kLinuxDoHcaptchaSiteKey,
      identifier: identifier,
      password: password,
      hcaptchaCreateEndpoint: hcaptchaEndpoint,
      onNeedSecondFactor: (need) => showTwoFactorDialog(
        context,
        hint: need.totpEnabled
            ? '请输入身份验证器 App 显示的 6 位验证码'
            : '此账号需要二步验证',
        onUseBackupCode: () => _loginWithWebView(),
      ),
    );
    if (!mounted) return false;
    if (result == null || result.status == WebViewLoginStatus.canceled) {
      return false;
    }

    if (result.status == WebViewLoginStatus.success) {
      // dialog 已把会话 cookie (_t/_forum_session) 同步落 jar,
      // 这里复用收尾: AuthSession.advance → setToken → 预加载数据 → 登录广播。
      await service.finalizeNativeLoginSuccess(identifier);
      // 保存账号密码 (可选)
      if (rememberCredentials) {
        try {
          await CredentialStoreService().save(identifier, password);
        } catch (e) {
          debugPrint('[LoginPage] 保存账号失败,不影响登录: $e');
        }
      }
      if (!mounted) return true;
      ToastService.showSuccess(S.current.webviewLogin_loginSuccess);
      Navigator.of(context).pop(true);
      return true;
    }

    // 失败 — toast 出来
    _showFailureToast(
      LoginFailure(
        result.loginErrorKind ?? LoginErrorKind.unknown,
        message: result.errorMessage,
      ),
    );
    return false;
  }

  void _showFailureToast(LoginFailure f) {
    final msg = switch (f.kind) {
      LoginErrorKind.invalidCredentials => '用户名或密码错误',
      LoginErrorKind.secondFactorRequired => f.message ?? '二步验证失败',
      LoginErrorKind.notActivated =>
        '账号未激活,请到邮箱 ${f.sentToEmail ?? ''} 完成激活',
      LoginErrorKind.notApproved => '账号尚未通过审核',
      LoginErrorKind.passwordExpired => '密码已过期,请用浏览器登录重设密码',
      LoginErrorKind.network => f.message ?? '网络异常',
      LoginErrorKind.unknown => f.message ?? '登录失败',
    };
    ToastService.showError(msg);
  }

  Future<void> _loginWithWebView([String? initialUrl]) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WebViewLoginPage(initialUrl: initialUrl),
      ),
    );
    if (result == true && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _clearSavedCredentials() async {
    await CredentialStoreService().clear();
    if (!mounted) return;
    setState(() {
      _savedUsername = null;
      _savedPassword = null;
    });
    ToastService.showSuccess('已清除保存的账号密码');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      body: Stack(
        children: [
          const AmbientBackground(),
          SafeArea(
            child: Stack(
              children: [
                // 左上返回
                Positioned(
                  top: 4,
                  left: 4,
                  child: _entry(
                    0,
                    AmbientIconButton(
                      icon: Symbols.arrow_back_rounded,
                      tooltip: '返回',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                ),
                // 右上清除保存的账号
                if (_credentialsLoaded && _savedUsername != null)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: _entry(
                      0,
                      AmbientIconButton(
                        icon: Symbols.delete_rounded,
                        tooltip: '清除保存的账号',
                        onPressed: _clearSavedCredentials,
                      ),
                    ),
                  ),
                // 主内容
                Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 32,
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _entry(
                            0,
                            const Center(
                              child: FloatingLogo(size: 88, glowSize: 80),
                            ),
                          ),
                          const SizedBox(height: 28),
                          _entry(
                            1,
                            Text(
                              'LINUX.DO',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.5,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          _entry(
                            2,
                            Text(
                              context.l10n.login_slogan,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: scheme.onSurfaceVariant.withValues(
                                  alpha: 0.85,
                                ),
                                letterSpacing: 2,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ),
                          const SizedBox(height: 32),
                          _entry(3, _buildFormCard(theme, scheme)),
                          const SizedBox(height: 24),
                          _entry(4, _buildAltLogin(context, scheme)),
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

  /// staggered 入场包装 (index 对应 _fade/_slide)
  Widget _entry(int i, Widget child) {
    return FadeTransition(
      opacity: _fade[i],
      child: SlideTransition(position: _slide[i], child: child),
    );
  }

  /// 磨砂玻璃表单卡片
  Widget _buildFormCard(ThemeData theme, ColorScheme scheme) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: theme.brightness == Brightness.dark ? 0.4 : 0.1,
            ),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: createBlurFilter(blurSigma),
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            decoration: BoxDecoration(
              color: scheme.surfaceContainer.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
            child: !_credentialsLoaded
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(child: LoadingSpinner(size: 40)),
                  )
                : LoginForm(
                    onSubmit: _handleSubmit,
                    onForgotPassword: () =>
                        _loginWithWebView('https://linux.do/password-reset'),
                    savedUsername: _savedUsername,
                    savedPassword: _savedPassword,
                  ),
          ),
        ),
      ),
    );
  }

  /// 分割线 + 其他方式登录 (扫码 / 浏览器授权 / OAuth 等)
  Widget _buildAltLogin(BuildContext context, ColorScheme scheme) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _DividerWithLabel(label: '或'),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _loginWithQrScan,
          icon: const Icon(Symbols.qr_code_scanner_rounded, size: 20),
          label: Text(context.l10n.login_scanToLogin),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(double.infinity, 52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
            side: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _browserAuthLaunching ? null : _loginWithBrowserAuth,
          icon: _browserAuthLaunching
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: LoadingSpinner(size: 20),
                )
              : const Icon(Symbols.verified_user_rounded, size: 20),
          label: const Text('浏览器授权登录'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(double.infinity, 52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
            side: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => _loginWithWebView(),
          icon: const Icon(Symbols.open_in_browser_rounded, size: 20),
          label: const Text('其他方式登录 (OAuth / Passkey / 注册)'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(double.infinity, 52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
            side: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          context.l10n.login_browserHint,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }

  /// 扫码登录:跳转扫码页,成功后 pop 登录页
  Future<void> _loginWithQrScan() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const QrLoginScanPage()),
    );
    if (result == true && mounted) {
      Navigator.of(context).pop(true);
    }
  }
}

class _DividerWithLabel extends StatelessWidget {
  const _DividerWithLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const Expanded(child: Divider()),
      ],
    );
  }
}
