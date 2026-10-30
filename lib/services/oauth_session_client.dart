import 'package:dio/dio.dart';

import 'auth_session.dart';
import 'network/exceptions/oauth_exception.dart';

/// 读取 LDC/CDK 的现有业务会话。
///
/// 响应中的 Set-Cookie 由 DiscourseDio 的 AppCookieManager 保存，包括服务端
/// 轮换 Cookie 值或更新有效期的情况。客户端不能自行延长有效期，也不应把
/// OAuth 重新授权当成普通读取的后台续期步骤；401 交给卡片提示重新登录。
class OAuthSessionClient {
  OAuthSessionClient({
    required this.dio,
    required this.baseUrl,
    required this.serviceName,
    OAuthSessionState? state,
  }) : state = state ?? _states.putIfAbsent(baseUrl, OAuthSessionState.new);

  static final _states = <String, OAuthSessionState>{};
  final Dio dio;
  final String baseUrl;
  final String serviceName;
  final OAuthSessionState state;

  /// 手动授权、停用或退出时取消旧请求。
  void cancel() => state.cancel();

  Future<Map<String, dynamic>> getUserInfo({String? expectedUsername}) async {
    final revision = state.revision;
    final generation = AuthSession().generation;
    final token = state.token;
    void check() {
      if (revision != state.revision || !AuthSession().isValid(generation)) {
        throw DioException(
          requestOptions: RequestOptions(path: baseUrl),
          type: DioExceptionType.cancel,
          error: '业务会话已变更，取消旧请求',
        );
      }
    }

    final Response<dynamic> response;
    try {
      response = await dio.get<dynamic>(
        '$baseUrl/api/v1/oauth/user-info',
        cancelToken: token,
        options: Options(
          followRedirects: false,
          validateStatus: (status) => status != null && status == 200,
          extra: {
            'skipCsrf': true,
            'showErrorToast': false,
            'skipRedirect': true,
          },
        ),
      );
    } on DioException catch (error) {
      check();
      throw OAuthErrorPolicy.classify(error, serviceName: serviceName);
    }
    check();
    final body = response.data;
    final data = body is Map ? body['data'] : null;
    if (data is! Map<String, dynamic>) {
      throw const FormatException('OAuth 用户信息响应缺少 data 对象');
    }
    if (expectedUsername != null && data['username'] != expectedUsername) {
      // 不允许其他账号的业务会话覆盖主站当前账号的余额缓存。
      throw OAuthExpiredException(serviceName: serviceName);
    }
    return data;
  }
}

/// 同一业务域共享取消状态，阻止手动授权前或停用前的旧请求继续生效。
class OAuthSessionState {
  int revision = 0;
  CancelToken token = CancelToken();

  void cancel() {
    revision++;
    token.cancel('业务服务已停用或开始新的授权');
    token = CancelToken();
  }
}
