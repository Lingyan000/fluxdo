import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;

import 'network/discourse_dio.dart';
import 'oauth_session_client.dart';
import '../l10n/s.dart';
import '../utils/dialog_utils.dart';
import 'oauth_flow_helper.dart';
import 'toast_service.dart';
import '../models/cdk_user_info.dart';

class CdkOAuthService {
  static const String baseUrl = 'https://cdk.linux.do';

  late final Dio _dio;

  late final OAuthSessionClient _session;

  CdkOAuthService({Dio? dio, OAuthSessionClient? sessionClient}) {
    _dio = dio ?? sessionClient?.dio ?? DiscourseDio.create();
    _session =
        sessionClient ??
        OAuthSessionClient(dio: _dio, baseUrl: baseUrl, serviceName: 'CDK');
  }

  void cancelPendingRequests() => _session.cancel();

  Future<String> getAuthUrl() async {
    final response = await _dio.get(
      '$baseUrl/api/v1/oauth/login',
      options: Options(extra: {'skipCsrf': true}),
    );
    return response.data['data'] as String;
  }

  Future<void> callback(String code, String state) async {
    // X-Requested-With: XMLHttpRequest 是 cdk.linux.do CSRF 校验的唯一依据,
    // 缺这个头服务端直接 403 "CSRF 验证失败"。
    // 实测最小集 = cookie + UA + content-type + X-Requested-With。
    await _dio.post(
      '$baseUrl/api/v1/oauth/callback',
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
      '$baseUrl/api/v1/oauth/logout',
      options: Options(extra: {'skipCsrf': true}),
    );
  }

  /// 重新签发业务会话，不预先登出；取消授权时仍保留原会话。
  Future<bool> reauthorize(BuildContext context) => authorize(context);

  Future<CdkUserInfo?> getUserInfo({String? expectedUsername}) async {
    final data = await _session.getUserInfo(expectedUsername: expectedUsername);
    return CdkUserInfo.fromJson(data);
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

    final Response response;
    try {
      response = await _dio.get(
        authUrl,
        options: Options(
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
          extra: {'skipCsrf': true, 'allowRedirectSetCookie': true},
        ),
      );
    } on DioException {
      throw Exception(S.current.oauth_networkError);
    }

    final document = html_parser.parse(response.data);
    final approveLink = document
        .querySelector('a[href*="/oauth2/approve/"]')
        ?.attributes['href'];

    if (!context.mounted) return false;
    if (approveLink == null) {
      throw Exception(S.current.oauth_approvePageParseFailed);
    }

    final confirmed = await showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _AuthDialog(
        onApprove: () async {
          // 用户点击同意 → 浏览器发起 approve 请求, 模拟手指反应 + 浏览器导航延迟
          await OAuthFlowHelper.humanGap(minMs: 600, maxMs: 1200);

          final approveResponse = await _dio.get(
            'https://connect.linux.do$approveLink',
            options: Options(
              followRedirects: false,
              validateStatus: (status) => status != null && status < 500,
              extra: {
                'skipCsrf': true,
                'skipRedirect': true,
                'allowRedirectSetCookie': true,
              },
            ),
          );

          final location = approveResponse.headers.value('location');
          if (location == null) {
            throw Exception(S.current.oauth_noRedirectResponse);
          }

          final uri = Uri.parse(location);
          final code = uri.queryParameters['code'];
          final state = uri.queryParameters['state'];

          if (code == null || state == null) {
            throw Exception(S.current.oauth_missingParams);
          }

          // approve → callback: 浏览器跳回业务方 + 业务方 JS 提交 code 的延迟
          await OAuthFlowHelper.humanGap(minMs: 400, maxMs: 900);

          await callback(code, state);
          return true;
        },
      ),
    );

    return confirmed ?? false;
  }
}

class _AuthDialog extends StatefulWidget {
  final Future<bool> Function() onApprove;

  const _AuthDialog({required this.onApprove});

  @override
  State<_AuthDialog> createState() => _AuthDialogState();
}

class _AuthDialogState extends State<_AuthDialog> {
  bool _isLoading = false;

  Future<void> _handleApprove() async {
    setState(() => _isLoading = true);
    try {
      final result = await widget.onApprove();
      if (mounted) {
        Navigator.pop(context, result);
      }
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
      title: Text(context.l10n.auth_cdkConfirmTitle),
      content: Text(context.l10n.auth_cdkConfirmMessage),
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
