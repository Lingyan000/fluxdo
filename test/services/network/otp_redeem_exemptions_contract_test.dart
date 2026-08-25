import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/csrf_token_service.dart';
import 'package:fluxdo/services/network/interceptors/redirect_interceptor.dart';
import 'package:fluxdo/services/network/interceptors/request_header_interceptor.dart';

/// UserApiKey 的 OTP 兑换(`user_api_key_service.dart` 的 redeemOtp)对拦截器
/// 链的两条豁免语义。两者都是事故驱动的设计,却一直没有测试保护。
///
/// 1. `skipRedirect`:兑换成功的响应是 `302 → /`,调用方只要这一跳的
///    `Set-Cookie: _t`。若让 RedirectInterceptor 跟随,它会用原 method
///    重发 `POST /` → 404,把已经成功的兑换误判成失败。
/// 2. `skipCsrf`:CSRF token 由调用方手动放进 `X-CSRF-Token` 头
///    (经主 dio 取得)。若 RequestHeaderInterceptor 介入,会在 token 为空时
///    回落到 CsrfTokenService 的独立 dio 刷新——后者在后台/会话失效窗口撞
///    CF 会静默失败。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('skipRedirect:302 不被跟随', () {
    test('带 skipRedirect 时只发一次请求，调用方直接拿到 302', () async {
      final adapter = _RecordingAdapter();
      final dio = _buildDio(adapter);

      final response = await dio.post<dynamic>(
        '/session/otp/deadbeef',
        options: _redeemOptions(skipRedirect: true),
      );

      expect(response.statusCode, 302);
      expect(adapter.requestedPaths, ['/session/otp/deadbeef']);
    });

    test('不带 skipRedirect 会跟随 302 并用原 method 重发，命中事故形态', () async {
      final adapter = _RecordingAdapter();
      final dio = _buildDio(adapter);

      await dio.post<dynamic>(
        '/session/otp/deadbeef',
        options: _redeemOptions(skipRedirect: false),
      );

      // 回归护栏:证明豁免确有必要 —— 第二跳是 POST /
      expect(adapter.requestedPaths, hasLength(2));
      expect(adapter.requestedPaths.last, '/');
      expect(adapter.requestedMethods.last, 'POST');
    });
  });

  group('skipCsrf:不触发拦截器的 CSRF 刷新', () {
    test('POST 带 skipCsrf 时，手动设置的 X-CSRF-Token 原样发出', () async {
      final adapter = _RecordingAdapter();
      final dio = _buildDio(adapter, withRequestHeader: true);

      await dio.post<dynamic>(
        '/session/otp/deadbeef',
        options: _redeemOptions(skipRedirect: true),
      );

      // 手动 token 未被拦截器覆盖
      expect(adapter.lastCsrfHeader, 'manual-csrf-token');
      // 只发了业务请求本身,没有额外的 /session/csrf 刷新请求
      expect(adapter.requestedPaths, ['/session/otp/deadbeef']);
    });

    test('同样的 POST 若不豁免 CSRF，请求会被拦截器取消(证明豁免有意义)', () async {
      final adapter = _RecordingAdapter();
      final dio = _buildDio(adapter, withRequestHeader: true);

      // 不带 skipCsrf、也不手动给 token:RequestHeaderInterceptor 会先去
      // CsrfTokenService 的**独立 dio** 刷新 CSRF(不受本测试注入的 adapter
      // 控制),拿不到 token 后直接 reject,业务请求根本发不出去。
      // 这正是 redeemOtp 必须 skipCsrf 的原因:会话失效窗口里那个独立 dio
      // 撞 CF 会静默失败,把兑换请求一起拖死。
      await expectLater(
        dio.post<dynamic>(
          '/session/otp/deadbeef',
          options: Options(
            followRedirects: false,
            validateStatus: (status) =>
                status != null && (status < 400 || status == 302),
            extra: const {'skipRedirect': true, 'skipAuthCheck': true},
          ),
        ),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );

      // 业务请求一次都没发出
      expect(adapter.requestedPaths, isEmpty);
    });
  });
}

Options _redeemOptions({required bool skipRedirect}) {
  return Options(
    followRedirects: false,
    validateStatus: (status) =>
        status != null && (status < 400 || status == 302),
    headers: const {
      'X-CSRF-Token': 'manual-csrf-token',
      'X-Requested-With': 'XMLHttpRequest',
    },
    extra: {
      'skipCsrf': true,
      'skipAuthCheck': true,
      if (skipRedirect) 'skipRedirect': true,
    },
  );
}

Dio _buildDio(_RecordingAdapter adapter, {bool withRequestHeader = false}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://linux.do',
      followRedirects: false,
      validateStatus: (status) => status != null && status >= 200 && status < 400,
    ),
  )..httpClientAdapter = adapter;
  if (withRequestHeader) {
    dio.interceptors.add(RequestHeaderInterceptor(CsrfTokenService()));
  }
  dio.interceptors.add(RedirectInterceptor(dio));
  return dio;
}

/// `/session/otp/...` 返回 302 → `/`;其余路径返回 200。
class _RecordingAdapter implements HttpClientAdapter {
  final List<String> requestedPaths = [];
  final List<String> requestedMethods = [];
  String? lastCsrfHeader;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestedPaths.add(options.uri.path);
    requestedMethods.add(options.method.toUpperCase());
    lastCsrfHeader = options.headers['X-CSRF-Token']?.toString();

    if (options.uri.path.startsWith('/session/otp/')) {
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': ['https://linux.do/'],
          'set-cookie': ['_t=new-token-from-otp; Path=/; HttpOnly'],
        },
      );
    }
    return ResponseBody.fromString(
      '{"ok":true}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
