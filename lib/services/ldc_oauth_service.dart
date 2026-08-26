import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;
import 'auth_session.dart';
import 'network/discourse_dio.dart';
import 'network/exceptions/oauth_exception.dart';
import '../l10n/s.dart';
import '../utils/dialog_utils.dart';
import 'oauth_flow_helper.dart';
import 'toast_service.dart';
import '../models/ldc_user_info.dart';

class LdcOAuthService {
  static const String baseUrl = 'https://credit.linux.do';

  late final Dio _dio;

  LdcOAuthService() {
    _dio = DiscourseDio.create();
  }

  Future<String> getAuthUrl() async {
    final response = await _dio.get(
      '$baseUrl/api/v1/oauth/login',
      options: Options(extra: {'skipCsrf': true}),
    );
    return response.data['data'] as String;
  }

  Future<void> callback(
    String code,
    String state, {
    int? requestGeneration,
  }) async {
    if (requestGeneration != null &&
        !AuthSession().isValid(requestGeneration)) {
      return;
    }
    // X-Requested-With: XMLHttpRequest 是 credit.linux.do CSRF 校验的唯一依据,
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
    if (requestGeneration != null &&
        !AuthSession().isValid(requestGeneration)) {
      return;
    }
  }

  Future<void> logout() async {
    await _dio.get(
      '$baseUrl/api/v1/oauth/logout',
      options: Options(extra: {'skipCsrf': true}),
    );
  }

  /// 重新授权 = logout + 长间隔 + authorize。
  ///
  /// 单独抽出, 是因为 logout + authorize 紧贴在一起会在 ~5 个请求内集中打
  /// 同一个限速窗口。中间插一个相对长的 gap, 让服务端限速窗口完全 reset,
  /// 也更像真人"先退出再重新登录"的操作节奏。
  Future<bool> reauthorize(BuildContext context) async {
    try {
      await logout();
    } catch (_) {
      // 忽略登出错误, 不阻塞后续重新授权
    }
    await OAuthFlowHelper.humanGap(minMs: 1000, maxMs: 1800);
    if (!context.mounted) return false;
    return authorize(context);
  }

  Future<LdcUserInfo?> getUserInfo() async {
    final generation = AuthSession().generation;
    try {
      final response = await _dio.get(
        '$baseUrl/api/v1/oauth/user-info',
        options: Options(extra: {'skipCsrf': true, 'showErrorToast': false}),
      );
      if (!AuthSession().isValid(generation)) return null;
      return LdcUserInfo.fromJson(response.data['data']);
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      if (statusCode == 401 || statusCode == 403) {
        throw OAuthExpiredException(serviceName: 'LDC', statusCode: statusCode);
      }
      rethrow;
    }
  }

  Future<bool> authorize(BuildContext context) async {
    final generation = AuthSession().generation;
    final String authUrl;
    try {
      authUrl = await getAuthUrl();
    } on DioException {
      throw Exception(S.current.oauth_getAuthUrlFailed);
    }
    if (!AuthSession().isValid(generation)) return false;

    // step1 → step2: 模拟"业务页加载完成 → 跳转到 OAuth 同意页"的导航延迟
    await OAuthFlowHelper.humanGap(minMs: 800, maxMs: 1500);
    if (!AuthSession().isValid(generation)) return false;

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
    if (!AuthSession().isValid(generation)) return false;

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
          if (!AuthSession().isValid(generation)) return false;
          // 用户点击同意 → 浏览器发起 approve 请求, 模拟手指反应 + 浏览器导航延迟
          await OAuthFlowHelper.humanGap(minMs: 600, maxMs: 1200);
          if (!AuthSession().isValid(generation)) return false;

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
          if (!AuthSession().isValid(generation)) return false;

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

          await callback(code, state, requestGeneration: generation);
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
      title: Text(context.l10n.auth_ldcConfirmTitle),
      content: Text(context.l10n.auth_ldcConfirmMessage),
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
