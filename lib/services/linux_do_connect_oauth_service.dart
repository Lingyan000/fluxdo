import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'linux_do_connect_navigator.dart';

import '../l10n/s.dart';
import '../utils/dialog_utils.dart';
import 'network/discourse_dio.dart';
import 'oauth_flow_helper.dart';
import 'oauth_session_client.dart';
import 'toast_service.dart';

/// linux.do Connect 的授权流程：业务站发起登录 → 主站同意页 → 回调业务站。
///
/// LDC（credit.linux.do）和 CDK（cdk.linux.do）走的是同一套流程，因此只实现
/// 一次，站点差异（域名、确认框文案）由子类给出。
///
/// 此类适配 LDC、CDK 的业务接口，授权导航复用公共 Connect 服务。
abstract class LinuxDoConnectOAuthService {
  LinuxDoConnectOAuthService({
    required String baseUrl,
    required String serviceName,
    required this.confirmTitle,
    required this.confirmMessage,
    Dio? dio,
    OAuthSessionClient? sessionClient,
  }) : _baseUrl = baseUrl {
    // 会话客户端与授权流程必须共用同一个 Dio（同一份 Cookie 与拦截器）。
    _dio = dio ?? sessionClient?.dio ?? DiscourseDio.create();
    _session =
        sessionClient ??
        OAuthSessionClient(
          dio: _dio,
          baseUrl: baseUrl,
          serviceName: serviceName,
        );
  }

  final String _baseUrl;
  late final Dio _dio;
  late final OAuthSessionClient _session;

  /// 同意前的确认框文案。
  final String Function(BuildContext context) confirmTitle;
  final String Function(BuildContext context) confirmMessage;

  /// 重新签发业务会话，不预先登出；取消授权时仍保留原会话。
  Future<bool> reauthorize(BuildContext context) => authorize(context);

  Future<Map<String, dynamic>> getUserInfoData({String? expectedUsername}) =>
      _session.getUserInfo(expectedUsername: expectedUsername);

  /// 手动授权、停用或退出时取消旧请求。
  void cancelPendingRequests() => _session.cancel();

  Future<String> getAuthUrl() async {
    final response = await _dio.get(
      '$_baseUrl/api/v1/oauth/login',
      options: Options(extra: {'skipCsrf': true}),
    );
    return response.data['data'] as String;
  }

  Future<void> callback(String code, String state) async {
    // X-Requested-With: XMLHttpRequest 是业务站 CSRF 校验的唯一依据，
    // 缺这个头服务端直接 403 "CSRF 验证失败"。
    await _dio.post(
      '$_baseUrl/api/v1/oauth/callback',
      data: {'code': code, 'state': state},
      options: Options(
        headers: {'X-Requested-With': 'XMLHttpRequest'},
        extra: {'skipCsrf': true},
      ),
    );
  }

  Future<void> logout() async {
    cancelPendingRequests();
    await _dio.get(
      '$_baseUrl/api/v1/oauth/logout',
      options: Options(extra: {'skipCsrf': true}),
    );
  }

  Future<bool> authorize(BuildContext context) async {
    cancelPendingRequests();
    final String authUrl;
    try {
      authUrl = await getAuthUrl();
    } on DioException {
      throw Exception(S.current.oauth_getAuthUrlFailed);
    }

    // step1 → step2: 模拟"业务页加载完成 → 跳转到 OAuth 同意页"的导航延迟
    await OAuthFlowHelper.humanGap(minMs: 800, maxMs: 1500);

    if (!context.mounted) return false;
    final confirmed = await showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => LinuxDoConnectAuthDialog(
        title: confirmTitle(dialogContext),
        message: confirmMessage(dialogContext),
        onApprove: () async {
          final result = await LinuxDoConnectNavigator(_dio)
              .authorize(Uri.parse(authUrl), active: () => context.mounted);
          final code = result.queryParameters['code'];
          final state = result.queryParameters['state'];
          if (code == null || state == null) {
            throw Exception(S.current.oauth_missingParams);
          }
          await callback(code, state);
          return true;
        },
      ),
    );
    return confirmed ?? false;
  }
}

/// linux.do Connect 授权确认框。
class LinuxDoConnectAuthDialog extends StatefulWidget {
  const LinuxDoConnectAuthDialog({
    super.key,
    required this.title,
    required this.message,
    required this.onApprove,
  });

  final String title;
  final String message;
  final Future<bool> Function() onApprove;

  @override
  State<LinuxDoConnectAuthDialog> createState() =>
      _LinuxDoConnectAuthDialogState();
}

class _LinuxDoConnectAuthDialogState extends State<LinuxDoConnectAuthDialog> {
  bool _isLoading = false;

  Future<void> _handleApprove() async {
    setState(() => _isLoading = true);
    try {
      final result = await widget.onApprove();
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ToastService.showError('${S.current.reward_authFailed}: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Text(widget.message),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context, false),
          child: Text(context.l10n.common_deny),
        ),
        FilledButton(
          onPressed: _isLoading ? null : _handleApprove,
          child: _isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(context.l10n.common_allow),
        ),
      ],
    );
  }
}
