import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/adapters/platform_adapter.dart';

void main() {
  group('requestAllowsRhttpAdapter', () {
    RequestOptions buildOptions({
      ResponseType? responseType,
      Map<String, dynamic>? extra,
    }) {
      return RequestOptions(
        path: '/latest.json',
        baseUrl: 'https://linux.do',
        responseType: responseType,
        extra: extra ?? <String, dynamic>{},
      );
    }

    test('普通 API 请求允许走 rhttp', () {
      expect(requestAllowsRhttpAdapter(buildOptions()), isTrue);
    });

    test('stream 响应默认允许走 rhttp', () {
      expect(
        requestAllowsRhttpAdapter(
          buildOptions(responseType: ResponseType.stream),
        ),
        isTrue,
      );
    });

    test('bytes 响应默认允许走 rhttp', () {
      expect(
        requestAllowsRhttpAdapter(
          buildOptions(responseType: ResponseType.bytes),
        ),
        isTrue,
      );
    });

    test('显式 skipRhttpAdapter 时旁路 rhttp', () {
      expect(
        requestAllowsRhttpAdapter(
          buildOptions(extra: {'skipRhttpAdapter': true}),
        ),
        isFalse,
      );
    });
  });

  group('requestCanUseWebViewAdapter', () {
    RequestOptions options(
      String path, {
      String method = 'GET',
      String baseUrl = 'https://linux.do',
      ResponseType? responseType,
      Map<String, dynamic>? headers,
    }) {
      return RequestOptions(
        path: path,
        baseUrl: baseUrl,
        method: method,
        responseType: responseType,
        headers: headers,
      );
    }

    test('主站 JSON API 可以由 WebView 接管', () {
      expect(requestCanUseWebViewAdapter(options('/latest.json')), isTrue);
    });

    test('主站写操作可以由 WebView 接管', () {
      expect(
        requestCanUseWebViewAdapter(options('/posts', method: 'POST')),
        isTrue,
      );
    });

    test('MessageBus、子域和二进制请求不进入兼容提示', () {
      expect(
        requestCanUseWebViewAdapter(options('/message-bus/abc/poll')),
        isFalse,
      );
      expect(
        requestCanUseWebViewAdapter(
          options('/api/v1/user', baseUrl: 'https://cdk.linux.do'),
        ),
        isFalse,
      );
      expect(
        requestCanUseWebViewAdapter(
          options('/download.json', responseType: ResponseType.bytes),
        ),
        isFalse,
      );
    });

    test('明确 HTML 请求不进入兼容提示', () {
      expect(
        requestCanUseWebViewAdapter(
          options('/', headers: {'Accept': 'text/html'}),
        ),
        isFalse,
      );
    });
  });
}
