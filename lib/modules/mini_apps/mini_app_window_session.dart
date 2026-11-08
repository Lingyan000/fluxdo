import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import 'mini_app.dart';
import 'mini_app_service.dart';

typedef MiniAppWindowRequest = Future<Object?> Function(
  String method,
  Map<String, dynamic> args,
);

/// 仅客户端 Dart 引擎持有此通道，绝不向应用脚本注册通用 HTTP 或宿主桥。
class MiniAppWindowSession {
  MiniAppWindowSession(this.request);
  final MiniAppWindowRequest request;
  static MiniAppWindowSession? current;
  String? userAgent;
  Future<void> prime() async {
    await request('prime', {});
  }

  Future<void> record() async {
    await request('record', {});
  }

  Future<void> community(String path) async {
    await request('community', {'path': path});
  }
}

Map<String, dynamic> miniAppWindowMap(Object? value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

/// 子窗口的反馈面板复用原 UI；服务实现通过主窗口的认证网络栈执行。
class MiniAppWindowService extends MiniAppService {
  MiniAppWindowService(this.session) : super(dio: Dio());
  final MiniAppWindowSession session;
  Future<Object?> _call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    final reply = miniAppWindowMap(await session.request(method, args));
    if (reply['error'] != null) {
      final error = miniAppWindowMap(reply['error']);
      final options = RequestOptions(path: 'mini-app-window/$method');
      throw DioException(
        requestOptions: options,
        message: error['message'] as String?,
        response: Response(
          requestOptions: options,
          statusCode: error['status'] as int?,
          data: error['data'],
        ),
      );
    }
    return reply['value'];
  }

  @override
  Future<MiniAppDetails> details(String appId) async => MiniAppDetails.fromJson(
    miniAppWindowMap(await _call('details', {'id': appId})),
  );
  @override
  Future<bool> favorite(MiniAppDetails details, bool value) async =>
      (await _call('favorite', {'value': value})) as bool;
  @override
  Future<void> rate(MiniAppDetails details, int score) async {
    await _call('rate', {'score': score});
  }

  @override
  Future<Map<String, dynamic>> tipStatus(MiniAppDetails details) async =>
      miniAppWindowMap(await _call('tipStatus'));
  @override
  Future<Map<String, dynamic>> tip(
    MiniAppDetails details,
    int amount,
    String requestId,
  ) async => miniAppWindowMap(
    await _call('tip', {'amount': amount, 'requestId': requestId}),
  );
  @override
  Future<List<Map<String, dynamic>>> reportTypes() async =>
      (await _call('reportTypes') as List).map(miniAppWindowMap).toList();
  @override
  Future<void> report(
    MiniAppDetails details,
    int flagType,
    String message,
  ) async {
    await _call('report', {
      'flagType': flagType,
      'message': message,
      'releaseId': details.feedback['release_id'],
    });
  }

  @override
  Future<MiniAppDirectory> directory({
    required String sort,
    required String query,
    required bool favorites,
    required int page,
  }) => Future.error(PlatformException(code: 'UNSUPPORTED_WINDOW_ACTION'));
}
