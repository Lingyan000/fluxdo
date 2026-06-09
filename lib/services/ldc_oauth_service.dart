import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../models/ldc_user_info.dart';
import '../pages/ldc_oauth_webview_page.dart';
import '../l10n/s.dart';
import 'network/discourse_dio.dart';
import 'network/exceptions/oauth_exception.dart';

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
        options: Options(extra: {'skipCsrf': true, 'showErrorToast': false}),
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
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      if (statusCode == 401 || statusCode == 403) {
        throw OAuthExpiredException(serviceName: 'LDC', statusCode: statusCode);
      }
      rethrow;
    }
  }

  Future<bool> authorize(BuildContext context) async {
    final String authUrl;
    try {
      authUrl = await getAuthUrl();
    } on DioException {
      throw Exception(S.current.oauth_getAuthUrlFailed);
    }

    if (!context.mounted) return false;

    return await LdcOAuthWebViewPage.open(
          context,
          authUrl: authUrl,
          checkAuthorized: hasAuthorizedSession,
        ) ??
        false;
  }

  Future<bool> hasAuthorizedSession() async {
    try {
      final response = await _dio.get(
        '$baseUrl/api/v1/oauth/user-info',
        options: Options(extra: {'skipCsrf': true, 'showErrorToast': false}),
      );
      return response.statusCode == 200;
    } on DioException catch (e) {
      debugPrint('[LDC OAuth] 检查授权状态失败: $e');
      return false;
    }
  }
}
