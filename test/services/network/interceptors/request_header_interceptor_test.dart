import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/adapters/webview_http_adapter.dart';
import 'package:fluxdo/services/network/cookie/csrf_token_service.dart';
import 'package:fluxdo/services/network/interceptors/request_header_interceptor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RequestHeaderInterceptor 导航头与 XHR 头', () {
    late RequestHeaderInterceptor interceptor;

    setUp(() {
      interceptor = RequestHeaderInterceptor(CsrfTokenService());
    });

    Future<RequestOptions> runOnRequest(RequestOptions options) async {
      RequestOptions? captured;
      final handler = _CapturingRequestHandler((next) => captured = next);
      await interceptor.onRequest(options, handler);
      expect(captured, isNotNull);
      return captured!;
    }

    test('标注 resourceKindHtml 的主站 HTML 请求自动补齐浏览器导航头', () async {
      final options = RequestOptions(
        path: 'https://linux.do',
        method: 'GET',
        headers: {
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
        extra: {
          'skipCsrf': true,
          WebViewHttpAdapter.resourceKindExtraKey:
              WebViewHttpAdapter.resourceKindHtml,
        },
      );

      final result = await runOnRequest(options);
      expect(result.headers['Sec-Fetch-Dest'], 'document');
      expect(result.headers['Sec-Fetch-Mode'], 'navigate');
      expect(result.headers['Sec-Fetch-Site'], 'none');
      expect(result.headers['Sec-Fetch-User'], '?1');
      expect(result.headers['Upgrade-Insecure-Requests'], '1');
    });

    test('同源 GET XHR 请求注入 cors 语义头，不注入 Origin 与导航头', () async {
      final options = RequestOptions(
        path: 'https://linux.do/latest.json',
        method: 'GET',
        headers: {'X-Requested-With': 'XMLHttpRequest'},
        extra: {'skipCsrf': true},
      );

      final result = await runOnRequest(options);
      expect(result.headers['Sec-Fetch-Dest'], 'empty');
      expect(result.headers['Sec-Fetch-Mode'], 'cors');
      expect(result.headers['Sec-Fetch-Site'], 'same-origin');
      expect(result.headers.containsKey('Origin'), isFalse);
      expect(result.headers.containsKey('Sec-Fetch-User'), isFalse);
      expect(result.headers.containsKey('Upgrade-Insecure-Requests'), isFalse);
    });

    test('同源 POST XHR 请求注入 Origin 与 cors 语义头', () async {
      final options = RequestOptions(
        path: 'https://linux.do/posts',
        method: 'POST',
        headers: {'X-Requested-With': 'XMLHttpRequest'},
        extra: {'skipCsrf': true},
      );

      final result = await runOnRequest(options);
      expect(result.headers['Origin'], 'https://linux.do');
      expect(result.headers['Sec-Fetch-Dest'], 'empty');
      expect(result.headers['Sec-Fetch-Mode'], 'cors');
      expect(result.headers['Sec-Fetch-Site'], 'same-origin');
    });

    test('未标注 resourceKindHtml 的普通 GET 不注入导航头', () async {
      final options = RequestOptions(
        path: 'https://linux.do/site.json',
        method: 'GET',
        extra: {'skipCsrf': true},
      );

      final result = await runOnRequest(options);
      expect(result.headers.containsKey('Sec-Fetch-Dest'), isFalse);
      expect(result.headers.containsKey('Upgrade-Insecure-Requests'), isFalse);
    });
  });
}

class _CapturingRequestHandler extends RequestInterceptorHandler {
  _CapturingRequestHandler(this._onNext);

  final void Function(RequestOptions) _onNext;

  @override
  void next(RequestOptions requestOptions) {
    _onNext(requestOptions);
  }
}
