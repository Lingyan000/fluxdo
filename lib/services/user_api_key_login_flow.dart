import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'discourse/discourse_service.dart';
import 'local_notification_service.dart' show navigatorKey;
import 'network/cookie/cookie_jar_service.dart';
import 'toast_service.dart';
import 'user_api_key_service.dart';
import 'package:m3e_ui/m3e_ui.dart';

/// 浏览器授权登录流程编排
///
/// 发起:登录页按钮 → [start] 拉起系统浏览器打开 /user-api-key/new。
/// 回程:系统浏览器授权后 302 到 discourse://auth_redirect,OS 深链拉回 App,
/// DeepLinkService 分发到 [handleCallback]:
/// 1. 解密 payload,持久化 User API Key(供开了 write scope 的站点做 _t 自愈)
/// 2. App 无登录态时,用随行 OTP 兑换 _t(纯 dio,走主 dio 的 rhttp 通道过 CF),
///    再走 finalizeNativeLoginSuccess 完成与密码登录一致的收口(预加载 → 广播)
///
/// 全程无可见 WebView / WebView 适配器:OTP 兑换的 CSRF 与 POST 都走主 dio,
/// 过 CF 靠 rhttp 的 Chrome TLS 指纹 + CfChallengeInterceptor 失效兜底。
///
/// 冷启动回调(App 被杀后从浏览器深链拉起)同样成立——流程不依赖登录页存活。
class UserApiKeyLoginFlow {
  UserApiKeyLoginFlow._();
  static final UserApiKeyLoginFlow instance = UserApiKeyLoginFlow._();

  /// 流程完成回调(仅 UI 用途:登录页借此 pop 自己),参数=是否成功
  ValueChanged<bool>? onFlowFinished;

  bool _handling = false;
  OverlayEntry? _loadingEntry;

  /// 深链回到 App 后,兑换+收口这段有网络耗时(可能还含 CF 验证),
  /// 用全局 overlay 给用户一个"正在完成登录"的反馈,避免看起来卡死。
  void _showLoading(String message) {
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) return;
    _loadingEntry?.remove();
    _loadingEntry = OverlayEntry(
      builder: (_) => _AuthLoadingOverlay(message: message),
    );
    overlay.insert(_loadingEntry!);
  }

  void _hideLoading() {
    _loadingEntry?.remove();
    _loadingEntry = null;
  }

  /// 构建授权 URL 并拉起系统浏览器。返回是否成功拉起。
  /// 首次调用会懒生成 RSA 密钥对(isolate,可能耗时数秒)。
  Future<bool> start() async {
    final authorizeUrl = await UserApiKeyService().buildAuthorizeUrl();
    try {
      // Android 用 Custom Tabs(inAppBrowserView),不用 externalApplication:
      // Chrome 对已建立 App Links 关联的域名(fluxdo 已 autoVerify linux.do)会把
      // externalApplication 打开的链接直接弹回本 app,表现为"浏览器一闪就跳回"
      // (仅 Chrome 有此行为,换其他浏览器正常)。Custom Tabs 在 app 上下文内打开,
      // 不触发该回弹,且共享 Chrome cookie 复用浏览器登录态(OAuth 标准做法)。
      // 其他平台 externalApplication 已验证正常,保持不变。
      final mode = Platform.isAndroid
          ? LaunchMode.inAppBrowserView
          : LaunchMode.externalApplication;
      return await launchUrl(authorizeUrl, mode: mode);
    } catch (e) {
      debugPrint('[UserApiKeyLoginFlow] 拉起浏览器失败: $e');
      return false;
    }
  }

  /// 处理 discourse://auth_redirect 深链回调(由 DeepLinkService 分发)
  Future<void> handleCallback(Uri uri) async {
    if (_handling) return;
    _handling = true;
    try {
      final userApiKeyService = UserApiKeyService();
      final result = await userApiKeyService.handleAuthRedirect(uri);
      // 冷启动 getInitialLink 会重放上次的 auth_redirect 深链;非本次授权流程
      // (nonce 已消费/不匹配)静默忽略,不弹 toast、不通知登录页。
      if (result.stale) {
        debugPrint('[UserApiKeyLoginFlow] 忽略残留授权回调');
        return;
      }
      if (!result.ok) {
        ToastService.showError('授权回调解析失败,请重新授权');
        onFlowFinished?.call(false);
        return;
      }

      // 已有登录态:只是补授权(存 key,供支持的站点自愈),不动现有会话
      final existingToken = await CookieJarService().getTToken();
      if (existingToken != null && existingToken.isNotEmpty) {
        ToastService.showSuccess('授权成功');
        onFlowFinished?.call(true);
        return;
      }

      // 无登录态:用随行 OTP 兑换 _t 完成登录(纯 dio)
      final otp = result.otp;
      if (otp == null) {
        ToastService.showError('授权成功,但未收到登录令牌,请重试');
        onFlowFinished?.call(false);
        return;
      }

      // 兑换 + 收口有网络耗时,显示全局 loading 反馈
      _showLoading('正在完成登录…');
      try {
        final service = DiscourseService();
        final token = await userApiKeyService.redeemOtp(service.dio, otp);
        if (token == null) {
          ToastService.showError('登录令牌兑换失败,请重试');
          onFlowFinished?.call(false);
          return;
        }

        // 新 _t 已落 jar;取 username 后走与密码登录同一套收口
        var username = '';
        try {
          final response = await service.dio.get(
            '/session/current.json',
            options: Options(
              extra: const {'skipAuthCheck': true, 'skipCsrf': true},
            ),
          );
          final data = response.data;
          final currentUser = data is Map<String, dynamic>
              ? data['current_user']
              : null;
          if (currentUser is Map<String, dynamic>) {
            username = currentUser['username']?.toString() ?? '';
          }
        } catch (e) {
          debugPrint('[UserApiKeyLoginFlow] 取 current_user 失败: $e');
        }

        if (username.isEmpty) {
          // _t 已落 jar 但确认请求失败;不带空用户名走收口(会写坏本地状态)
          ToastService.showError('登录状态确认失败,请重试');
          onFlowFinished?.call(false);
          return;
        }

        await service.finalizeNativeLoginSuccess(username);
        ToastService.showSuccess('登录成功');
        onFlowFinished?.call(true);
      } finally {
        _hideLoading();
      }
    } finally {
      _handling = false;
    }
  }
}

/// 授权收口期间的全局 loading 遮罩(经 navigatorKey overlay 插入)
class _AuthLoadingOverlay extends StatelessWidget {
  const _AuthLoadingOverlay({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.45),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const LoadingSpinner(),
                const SizedBox(height: 16),
                Text(message, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
