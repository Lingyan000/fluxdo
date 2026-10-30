import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/cf_clearance_authority.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';

/// 用内存 Cookie 与可控的平台回调重放验证时序，不访问网站或本机 Cookie。
class CfTestPlatform extends InAppWebViewPlatform {
  final cookies = CfTestCookieManager();
  late final controller = CfTestController(cookies);
  CfTestWebView? webView;

  Future<void> initialize({String? cookieDirectory}) async {
    InAppWebViewPlatform.instance = this;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => cookieDirectory,
        );
    await CookieJarService().initialize();
  }

  Future<void> reset() async {
    cookies.values = [];
    cookies.singleValue = null;
    cookies.readSnapshot = null;
    cookies.readValue = null;
    controller.handlers.clear();
    controller.partitionKey = null;
    controller.documentHtml = '';
    controller.documentComplete = true;
    webView = null;
    CfClearanceAuthority.instance
      ..debugCookieReader = null
      ..reset();
    await CookieJarService().cookieJar.deleteAll();
  }

  @override
  PlatformCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) => cookies;

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => webView = CfTestWebView(params);
}

Cookie cfTestCookie(String value) => Cookie(
  name: 'cf_clearance',
  value: value,
  domain: '.linux.do',
  path: '/',
  isSecure: true,
  isHttpOnly: true,
  expiresDate: DateTime.now()
      .add(const Duration(days: 7))
      .millisecondsSinceEpoch,
);

class CfTestCookieManager extends PlatformCookieManager {
  CfTestCookieManager()
    : super.implementation(const PlatformCookieManagerCreationParams());

  List<Cookie> values = [];
  String? singleValue;
  Future<List<Cookie>> Function()? readSnapshot;
  Future<Cookie?> Function(String name)? readValue;

  Future<List<Cookie>> snapshot() async =>
      readSnapshot != null ? await readSnapshot!() : [...values];

  @override
  Future<Cookie?> getCookie({
    required WebUri url,
    required String name,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    if (readValue != null) return readValue!(name);
    if (name == 'cf_clearance' && singleValue != null) {
      return cfTestCookie(singleValue!);
    }
    for (final cookie in values) {
      if (cookie.name == name) return cookie;
    }
    return null;
  }

  @override
  Future<List<Cookie>> getCookies({
    required WebUri url,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) => snapshot();

  @override
  Future<List<Cookie>> getAllCookies() => snapshot();

  @override
  Future<bool> deleteCookie({
    required WebUri url,
    required String name,
    String path = '/',
    String? domain,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    values.removeWhere((cookie) => cookie.name == name);
    return true;
  }
}

class CfTestController extends PlatformInAppWebViewController {
  CfTestController(this.cookies)
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 'cf-test'),
      );

  final CfTestCookieManager cookies;
  final handlers = <String, Function>{};
  String? partitionKey;
  String documentHtml = '';
  bool documentComplete = true;

  InAppWebViewController get wrapped =>
      InAppWebViewController.fromPlatform(platform: this);

  @override
  void addJavaScriptHandler({
    required String handlerName,
    required Function callback,
  }) {
    handlers[handlerName] = callback;
  }

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    if (source.contains('document.readyState')) {
      return documentComplete ? documentHtml : '';
    }
    if (source.startsWith('document.documentElement') ||
        source.startsWith('document.body')) {
      return documentHtml;
    }
    return '';
  }

  @override
  Future<WebUri?> getUrl() async => WebUri('https://linux.do/challenge');

  @override
  Future<dynamic> callDevToolsProtocolMethod({
    required String methodName,
    Map<String, dynamic>? parameters,
  }) async {
    if (methodName != 'Network.getCookies') return <String, dynamic>{};
    return <String, dynamic>{
      'cookies': [
        for (final cookie in await cookies.snapshot())
          {
            'name': cookie.name,
            'value': cookie.value,
            'domain': cookie.domain,
            'path': cookie.path,
            'secure': cookie.isSecure,
            'httpOnly': cookie.isHttpOnly,
            'expires': cookie.expiresDate! / 1000,
            if (partitionKey != null) 'partitionKey': partitionKey,
          },
      ],
    };
  }

  @override
  void dispose({bool isKeepAlive = false}) {}
}

class CfTestWebView extends PlatformInAppWebViewWidget {
  CfTestWebView(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      InAppWebViewController.fromPlatform(platform: controller) as T;

  @override
  void dispose() {}
}
