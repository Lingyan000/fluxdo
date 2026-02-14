import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;
import 'network/discourse_dio.dart';
import '../constants.dart';
import '../models/ldc_user_info.dart';

class LdcOAuthService {
  static String get baseUrl => AppConstants.creditUrl;
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

  Future<void> callback(String code, String state) async {
    await _dio.post(
      '$baseUrl/api/v1/oauth/callback',
      data: {'code': code, 'state': state},
      options: Options(extra: {'skipCsrf': true}),
    );
  }

  Future<void> logout() async {
    await _dio.get(
      '$baseUrl/api/v1/oauth/logout',
      options: Options(extra: {'skipCsrf': true}),
    );
  }

  Future<LdcUserInfo?> getUserInfo({int? gamificationScore}) async {
    try {
      final response = await _dio.get(
        '$baseUrl/api/v1/oauth/user-info',
        options: Options(extra: {'skipCsrf': true}),
      );
      final ldcData = response.data['data'];
      final userInfo = LdcUserInfo.fromJson(ldcData);

      return LdcUserInfo(
        id: userInfo.id,
        username: userInfo.username,
        nickname: userInfo.nickname,
        trustLevel: userInfo.trustLevel,
        avatarUrl: userInfo.avatarUrl,
        totalReceive: userInfo.totalReceive,
        totalPayment: userInfo.totalPayment,
        totalTransfer: userInfo.totalTransfer,
        totalCommunity: userInfo.totalCommunity,
        communityBalance: userInfo.communityBalance,
        availableBalance: userInfo.availableBalance,
        payScore: userInfo.payScore,
        isPayKey: userInfo.isPayKey,
        isAdmin: userInfo.isAdmin,
        remainQuota: userInfo.remainQuota,
        payLevel: userInfo.payLevel,
        dailyLimit: userInfo.dailyLimit,
        gamificationScore: gamificationScore,
      );
    } catch (e) {
      return null;
    }
  }

  Future<bool> authorize(BuildContext context) async {
    try {
      final authUrl = await getAuthUrl();
      final response = await _dio.get(
        authUrl,
        options: Options(
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
          extra: {'skipCsrf': true},
        ),
      );

      final document = html_parser.parse(response.data);
      final approveLink = document.querySelector('a[href*="/oauth2/approve/"]')?.attributes['href'];

      if (approveLink == null || !context.mounted) return false;

      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _AuthDialog(
          onApprove: () async {
            final approveResponse = await _dio.get(
              '${AppConstants.connectUrl}$approveLink',
              options: Options(
                followRedirects: false,
                validateStatus: (status) => status != null && status < 500,
                extra: {'skipCsrf': true, 'skipRedirect': true},
              ),
            );

            final location = approveResponse.headers.value('location');
            if (location == null) return false;

            final uri = Uri.parse(location);
            final code = uri.queryParameters['code'];
            final state = uri.queryParameters['state'];

            if (code == null || state == null) return false;

            await callback(code, state);
            return true;
          },
        ),
      );

      return confirmed ?? false;
    } catch (e) {
      return false;
    }
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('授权失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('授权确认'),
      content: const Text('Linux.do Credit 将获取你的基本信息，是否允许？'),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context, false),
          child: const Text('拒绝'),
        ),
        FilledButton(
          onPressed: _isLoading ? null : _handleApprove,
          child: _isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('允许'),
        ),
      ],
    );
  }
}
