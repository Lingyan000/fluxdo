import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/adapters/platform_adapter.dart';
import 'package:fluxdo/services/network/adapters/webview_http_adapter.dart';
import 'package:fluxdo/services/network/flux_request_spec.dart';

void main() {
  group('requestCanUseWebViewAdapter', () {
    RequestOptions options(
      String path, {
      String method = 'GET',
      String baseUrl = 'https://linux.do',
      ResponseType? responseType,
      Map<String, dynamic>? headers,
      Map<String, dynamic>? extra,
    }) {
      return RequestOptions(
        path: path,
        baseUrl: baseUrl,
        method: method,
        responseType: responseType,
        headers: headers,
        extra: extra,
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

    test('明确 HTML 请求默认不进入兼容提示，显式标注的主站 HTML 可由 WebView 接管', () {
      expect(
        requestCanUseWebViewAdapter(
          options('/', headers: {'Accept': 'text/html'}),
        ),
        isFalse,
      );
      expect(
        requestCanUseWebViewAdapter(
          options(
            '/',
            headers: {'Accept': 'text/html'},
            extra: {
              WebViewHttpAdapter.resourceKindExtraKey:
                  WebViewHttpAdapter.resourceKindHtml,
            },
          ),
        ),
        isTrue,
      );
      expect(
        requestCanUseWebViewAdapter(
          options(
            '/',
            headers: {'Accept': 'text/html'},
            extra: {
              WebViewHttpAdapter.resourceKindExtraKey:
                  WebViewHttpAdapter.resourceKindHtml,
              FluxRequestKeys.skipWebViewAdapter: true,
            },
          ),
        ),
        isFalse,
      );
      expect(
        requestCanUseWebViewAdapter(
          options(
            '/',
            baseUrl: 'https://cdk.linux.do',
            headers: {'Accept': 'text/html'},
            extra: {
              WebViewHttpAdapter.resourceKindExtraKey:
                  WebViewHttpAdapter.resourceKindHtml,
            },
          ),
        ),
        isFalse,
      );
    });
  });
}
