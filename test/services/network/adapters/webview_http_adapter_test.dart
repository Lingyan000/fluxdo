import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/adapters/webview_http_adapter.dart';

void main() {
  for (final immutable in [false, true]) {
    test('字符串日志映射可安全追加耗时和布尔字段 immutable=$immutable', () {
      final original = immutable
          ? Map<String, String>.unmodifiable({'uploadTraceId': 'upload-test'})
          : <String, String>{'uploadTraceId': 'upload-test'};
      final options = RequestOptions(
        path: '/uploads/create-multipart.json',
        extra: {'_networkLogFields': original},
      );
      WebViewHttpAdapter.setNetworkLogField(options, 'webViewTotalMs', 547);
      WebViewHttpAdapter.setNetworkLogField(
        options,
        'webViewBinaryStream',
        true,
      );
      expect(options.extra['_networkLogFields'], {
        'uploadTraceId': 'upload-test',
        'webViewTotalMs': 547,
        'webViewBinaryStream': true,
      });
      expect(original, {'uploadTraceId': 'upload-test'});
    });
  }

  group('WebViewHttpAdapter.resolveFetchCacheMode', () {
    RequestOptions buildOptions(String method, {Map<String, dynamic>? extra}) {
      return RequestOptions(
        path: '/latest.json',
        baseUrl: 'https://linux.do',
        method: method,
        extra: extra ?? <String, dynamic>{},
      );
    }

    test('GET 请求默认禁用浏览器缓存', () {
      final options = buildOptions('GET');

      expect(
        WebViewHttpAdapter.resolveFetchCacheMode(options),
        WebViewHttpAdapter.defaultApiFetchCacheMode,
      );
    });

    test('HEAD 请求默认禁用浏览器缓存', () {
      final options = buildOptions('HEAD');

      expect(
        WebViewHttpAdapter.resolveFetchCacheMode(options),
        WebViewHttpAdapter.defaultApiFetchCacheMode,
      );
    });

    test('非 GET/HEAD 请求默认不设置 cache 模式', () {
      final options = buildOptions('POST');

      expect(WebViewHttpAdapter.resolveFetchCacheMode(options), isNull);
    });

    test('支持通过 extra 覆盖 fetch cache 模式', () {
      final options = buildOptions(
        'GET',
        extra: {WebViewHttpAdapter.fetchCacheModeExtraKey: 'reload'},
      );

      expect(WebViewHttpAdapter.resolveFetchCacheMode(options), 'reload');
    });

    test('不支持的 cache 模式会回退到默认策略', () {
      final options = buildOptions(
        'GET',
        extra: {WebViewHttpAdapter.fetchCacheModeExtraKey: 'invalid-mode'},
      );

      expect(
        WebViewHttpAdapter.resolveFetchCacheMode(options),
        WebViewHttpAdapter.defaultApiFetchCacheMode,
      );
    });
  });
}
