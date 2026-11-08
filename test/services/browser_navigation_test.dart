import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/browser_navigation.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('网址保留路径、端口和查询参数，关键词正确编码', () {
    for (final input in [
      'example.com/a?q=1#b',
      'localhost:8080/demo',
      '127.0.0.1:3000',
      '[::1]:8080/test',
    ]) {
      final result = BrowserNavigationTarget.parse(
        input,
        BrowserSearchEngine.google,
      )!;
      expect(result.isSearch, isFalse);
      expect(result.uri.scheme, 'https');
      expect(result.uri.toString(), 'https://$input');
    }
    final secure = BrowserNavigationTarget.parse(
      ' HTTPS://Example.COM/a ',
      BrowserSearchEngine.google,
    )!;
    expect(secure.uri.toString(), 'https://example.com/a');
    for (final query in [
      'Flutter 动画',
      'a & b + c',
      'hello',
      '你好🌍',
      'site:flutter.dev 动画',
    ]) {
      final result = BrowserNavigationTarget.parse(
        query,
        BrowserSearchEngine.google,
      )!;
      expect(result.isSearch, isTrue);
      expect(result.uri.host, 'www.google.com');
      expect(result.uri.queryParameters['q'], query);
    }
  });

  test('地址编辑拒绝可执行协议和畸形 URL', () {
    for (final input in [
      '',
      ' ',
      'javascript:alert(1)',
      'data:text/html,x',
      'file:///etc/passwd',
      'intent://example',
      'https://',
      'https://user@example.com',
      'https://example.com:99999',
    ]) {
      expect(
        BrowserNavigationTarget.parse(input, BrowserSearchEngine.google),
        isNull,
        reason: input,
      );
    }
    expect(
      browserDisplayHost('http://www.example.com:8080/a'),
      'example.com:8080',
    );
  });

  test('默认 Google，只有主动选择后才持久化切换', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final scope = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    expect(scope.read(browserSearchEngineProvider), BrowserSearchEngine.google);
    scope
        .read(browserSearchEngineProvider.notifier)
        .select(BrowserSearchEngine.bing);
    expect(scope.read(browserSearchEngineProvider), BrowserSearchEngine.bing);
    scope.dispose();
    final reopened = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    expect(
      reopened.read(browserSearchEngineProvider),
      BrowserSearchEngine.bing,
    );
    reopened.dispose();
  });
}
