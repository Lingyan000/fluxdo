import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../../services/network/discourse_dio.dart';
import '../../../l10n/s.dart';
import '../models/reward_request.dart';
import '../models/reward_result.dart';

/// LDC 打赏 API 服务
/// 复用 DiscourseDio（含 CF 验证拦截器），通过 Basic Auth header 认证
class LdcRewardService {
  static const String _distributeUrl = 'https://credit.linux.do/epay/pay/distribute';

  /// 服务端错误消息可能的字段名（按优先级尝试）
  static const List<String> _errorMsgKeys = [
    'msg',
    'error_msg',
    'message',
    'errmsg',
    'error',
    'error_message',
    'detail',
  ];

  final String _authHeader;
  final String _clientIdPrefix;
  final int _clientSecretLen;
  final Dio _dio;

  LdcRewardService({required String clientId, required String clientSecret})
      : _authHeader = 'Basic ${base64Encode(utf8.encode('$clientId:$clientSecret'))}',
        _clientIdPrefix = clientId.substring(0, min(4, clientId.length)),
        _clientSecretLen = clientSecret.length,
        _dio = DiscourseDio.create();

  /// 执行打赏
  Future<LdcRewardResult> distribute(LdcRewardRequest request) async {
    try {
      final response = await _dio.post(
        _distributeUrl,
        data: request.toJson(),
        options: Options(
          headers: {
            'Authorization': _authHeader,
            'Content-Type': 'application/json',
          },
        ),
      );

      if (response.statusCode == 200 && response.data is Map<String, dynamic>) {
        return LdcRewardResult.fromResponse(response.data as Map<String, dynamic>);
      }

      _logFailure(
        status: response.statusCode,
        body: response.data,
        tradeNo: request.outTradeNo,
      );
      return LdcRewardResult.error(S.current.reward_httpError(response.statusCode ?? 0));
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final body = e.response?.data;
      final serverMsg = _extractServerMsg(body);

      _logFailure(
        status: status,
        body: body,
        tradeNo: request.outTradeNo,
        dioMessage: e.message,
      );

      // 优先使用服务端返回的真实错误消息（更具诊断价值），
      // 没有时再回退到状态码本地化文案
      if (serverMsg != null && serverMsg.isNotEmpty) {
        return LdcRewardResult.error(
          status != null ? '$serverMsg (HTTP $status)' : serverMsg,
        );
      }
      if (status == 401) {
        return LdcRewardResult.error(S.current.reward_authFailed);
      }
      return LdcRewardResult.error(S.current.reward_networkError(e.message ?? ''));
    } catch (e) {
      return LdcRewardResult.error(S.current.reward_unknownError(e.toString()));
    }
  }

  /// 尝试从响应 body 中提取服务端错误消息。
  /// 字段名未知时遍历常见命名；body 是字符串时直接截取使用。
  String? _extractServerMsg(dynamic body) {
    if (body is Map<String, dynamic>) {
      for (final key in _errorMsgKeys) {
        final v = body[key];
        if (v is String && v.isNotEmpty) return v;
      }
      // 兼容嵌套结构 {"error": {"message": "..."}}
      final err = body['error'];
      if (err is Map<String, dynamic>) {
        for (final key in _errorMsgKeys) {
          final v = err[key];
          if (v is String && v.isNotEmpty) return v;
        }
      }
      return null;
    }
    if (body is String && body.isNotEmpty) {
      // 非 JSON 响应（可能是 CF 拦截页 HTML），截断避免过长
      final s = body.trim();
      return s.length > 200 ? '${s.substring(0, 200)}…' : s;
    }
    return null;
  }

  void _logFailure({
    required int? status,
    required dynamic body,
    required String tradeNo,
    String? dioMessage,
  }) {
    final bodyStr = body is Map ? jsonEncode(body) : body?.toString() ?? '<null>';
    final truncated =
        bodyStr.length > 500 ? '${bodyStr.substring(0, 500)}…' : bodyStr;
    debugPrint(
      '[LdcReward] distribute failed | status=$status '
      'clientIdPrefix=$_clientIdPrefix*** secretLen=$_clientSecretLen '
      'tradeNo=$tradeNo dioMsg=$dioMessage body=$truncated',
    );
  }
}
