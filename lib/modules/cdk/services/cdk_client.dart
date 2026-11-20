import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../services/auth_session.dart';
import '../../../services/network/discourse_dio.dart';
import '../../../services/network/exceptions/oauth_exception.dart';
import '../models/cdk_models.dart';

class CdkApiException implements Exception {
  const CdkApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// CDK 业务接口，复用应用 Cookie 与网络出口，不向插件暴露业务会话。
class CdkClient {
  CdkClient({required this.checkSession, required this.verifyAccount, Dio? dio})
    : _dio =
          dio ??
          DiscourseDio.create(
            enableRetry: false,
            enableCfChallenge: false,
            enableNetworkLog: false,
          ) {
    AuthSession().generationChanges.addListener(_sessionChanged);
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          // 通用论坛客户端会补主站 XHR 头，此处按业务会话恢复准确来源。
          request.headers['Origin'] = origin;
          request.headers['Referer'] = '$origin/';
          request.headers.remove('Discourse-Present');
          handler.next(request);
        },
      ),
    );
  }
  static const origin = 'https://cdk.linux.do';
  final Dio _dio;
  final Future<void> Function() checkSession, verifyAccount;
  final _cancel = CancelToken();
  final int _generation = AuthSession().generation;
  final _receiving = <String>{};
  final ValueNotifier<bool> active = ValueNotifier(true);

  void _sessionChanged() {
    if (!AuthSession().isValid(_generation)) dispose();
  }

  Future<void> check() async {
    if (_cancel.isCancelled || !AuthSession().isValid(_generation)) {
      throw const CdkApiException('cdk_session_changed');
    }
    await checkSession();
  }

  static String projectPath(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id)) {
      throw const FormatException('CDK 项目标识无效');
    }
    return '/projects/$id';
  }

  Future<Object?> _request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? query,
    Object? body,
  }) async {
    await check();
    try {
      final response = await _dio.request<dynamic>(
        '$origin/api/v1$path',
        queryParameters: query,
        data: body,
        cancelToken: _cancel,
        options: Options(
          method: method,
          followRedirects: false,
          headers: {
            'Origin': origin,
            'Referer': '$origin/',
            'X-Requested-With': 'XMLHttpRequest',
          },
          extra: {
            'skipCsrf': true,
            'skipRedirect': true,
            'showErrorToast': false,
            'isSilent': true,
          },
        ),
      );
      await check();
      final data = cdkObject(response.data);
      if (data['error_msg'] is! String || !data.containsKey('data')) {
        throw const FormatException('CDK 响应格式无效');
      }
      if (data['error_msg'] != '') {
        throw CdkApiException(data['error_msg'] as String);
      }
      return data['data'];
    } on DioException catch (error) {
      await check();
      final classified = OAuthErrorPolicy.classify(error, serviceName: 'CDK');
      if (!identical(classified, error)) throw classified;
      final message = error.response?.data;
      if (message is Map &&
          message['error_msg'] is String &&
          (message['error_msg'] as String).isNotEmpty &&
          (error.response?.statusCode ?? 500) < 500) {
        throw CdkApiException(message['error_msg'] as String);
      }
      rethrow;
    }
  }

  Future<CdkPage<CdkProject>> projects({int page = 1, String? tag}) async =>
      CdkPage.parse(
        await _request(
          '/projects',
          query: {'current': page, 'size': 20, 'tags': ?tag},
        ),
        CdkProject.fromJson,
      );
  Future<List<String>> tags() async =>
      (await _request('/tags') as List? ?? []).cast<String>();
  Future<CdkProject> project(String id) async =>
      CdkProject.fromJson(cdkObject(await _request(projectPath(id))));
  Future<CdkPage<CdkReceipt>> receipts({
    int page = 1,
    String search = '',
  }) async => CdkPage.parse(
    await _request(
      '/projects/received',
      query: {'current': page, 'size': 20, 'search': search},
    ),
    CdkReceipt.fromJson,
  );
  Future<CdkDashboard> dashboard({int days = 7}) async => CdkDashboard.parse(
    await _request('/dashboard/stats/all', query: {'days': days}),
  );
  Future<List<Map<String, dynamic>>> history({int days = 7}) async =>
      (await _request('/projects/received/chart', query: {'day': days})
                  as List? ??
              [])
          .map(cdkObject)
          .toList();
  Future<CdkPaymentIntent?> pending(String id) async {
    final data = cdkObject(
      await _request('${projectPath(id)}/pending-payment'),
    );
    if (data['has_pending'] is! bool) {
      throw const FormatException('CDK 待付款状态无效');
    }
    return data['has_pending'] == true ? CdkPaymentIntent.fromJson(data) : null;
  }

  Future<CdkReceiveResult> receive(String id, String captchaToken) async {
    projectPath(id);
    if (captchaToken.isEmpty || captchaToken.length > 16384) {
      throw const CdkApiException('cdk_verification_required');
    }
    if (!_receiving.add(id)) throw const CdkApiException('cdk_busy');
    try {
      await check();
      await verifyAccount();
      // 领取可能已占库存或交付。超时后只能查原项目，不能自动重放 POST。
      return CdkReceiveResult.parse(
        await _request(
          '${projectPath(id)}/receive',
          method: 'POST',
          body: {'captcha_token': captchaToken},
        ),
      );
    } finally {
      _receiving.remove(id);
    }
  }

  void dispose() {
    if (!active.value) return;
    AuthSession().generationChanges.removeListener(_sessionChanged);
    active.value = false;
    _cancel.cancel('CDK 页面已关闭或账号变更');
    _dio.close(force: true);
  }
}
