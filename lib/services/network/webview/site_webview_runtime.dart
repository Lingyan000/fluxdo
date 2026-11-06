import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../constants.dart';
import '../../../utils/frame_jank_monitor.dart';
import '../../auth_session.dart';
import '../../webview_settings.dart';
import '../../windows_webview_environment_service.dart';
import '../cookie/webview_cookie_priming.dart';
import 'shared_browser_resource.dart';

/// 同源后台任务的唯一实例所有者。业务服务仅持有任务租约。
class SiteWebViewRuntime {
  SiteWebViewRuntime._() {
    _resources = SharedBrowserResource<SiteWebView>(
      create: _create,
      destroy: (view) => view.dispose(),
    );
    AuthSession().generationChanges.addListener(_resources.invalidate);
  }

  static final instance = SiteWebViewRuntime._();
  late final SharedBrowserResource<SiteWebView> _resources;
  final _responses = <String, void Function(String)>{};
  int _nextRequestId = 0;
  int _created = 0;
  Completer<void> _interrupted = Completer<void>();

  Future<void> get interrupted => _interrupted.future;

  Future<void> suspendAndDrain() {
    if (!_interrupted.isCompleted) _interrupted.complete();
    return _resources.suspendAndDrain();
  }

  void resume() {
    _interrupted = Completer<void>();
    _resources.resume();
  }

  String nextRequestId() => 'site_${++_nextRequestId}';

  void registerResponse(String id, void Function(String) callback) {
    _responses[id] = callback;
  }

  void removeResponse(String id) => _responses.remove(id);

  Future<BrowserResourceLease<SiteWebView>> acquire({
    bool exclusive = false,
    Future<void>? cancelled,
  }) => _resources.acquire(exclusive: exclusive, cancelled: cancelled);

  Future<SiteWebView> _create() async {
    final view = SiteWebView();
    view.webView = HeadlessInAppWebView(
      webViewEnvironment: Platform.isWindows
          ? WindowsWebViewEnvironmentService.instance.environment
          : null,
      initialSettings: WebViewSettings.headless,
      initialUserScripts: WebViewSettings.compatPolyfillScripts,
      onReceivedServerTrustAuthRequest: (_, challenge) =>
          WebViewSettings.handleServerTrustAuthRequest(challenge),
      onWebViewCreated: (controller) {
        view.controller = controller;
        WebViewSettings.applyWindowsHeadlessMemoryTarget(controller);
        WebViewSettings.registerJsErrorReporter(controller);
        controller.addJavaScriptHandler(
          handlerName: 'fetchResult',
          callback: (args) {
            if (args.isNotEmpty && args.first is Map) {
              final data = args.first as Map;
              final id = data['requestId']?.toString();
              if (id != null) {
                _responses[id]?.call(data['result']?.toString() ?? '');
              }
            }
          },
        );
      },
      onLoadStop: (_, url) => view.didLoad(url),
      onReceivedError: (_, request, error) {
        if (request.isForMainFrame == true) {
          view.didFail(StateError('后台页面加载失败: ${error.type}'));
        }
      },
    );
    try {
      FrameJankMonitor.logEvent('WEBVIEW', 'SiteRuntime create #${++_created}');
      await view.webView.run();
      try {
        await WebViewCookiePriming.instance.prime(AppConstants.baseUrl);
      } catch (error) {
        debugPrint('[SiteRuntime] Cookie priming 失败，继续初始化: $error');
      }
      await view.resetDocument();
      return view;
    } catch (_) {
      await view.dispose();
      rethrow;
    }
  }
}

/// 仅独占租约可以导航；共享租约只允许在既有文档内执行脚本。
class SiteWebView {
  late final HeadlessInAppWebView webView;
  late final InAppWebViewController controller;
  Completer<void>? _load;

  void didLoad(WebUri? url) {
    // run() 的初始 about:blank 事件不能完成后续同源页面的加载等待。
    if (url == null || url.host != Uri.parse(AppConstants.baseUrl).host) return;
    final load = _load;
    if (load != null && !load.isCompleted) load.complete();
  }

  void didFail(Object error) {
    final load = _load;
    if (load != null && !load.isCompleted) load.completeError(error);
  }

  Future<void> load(Future<void> Function() navigate) async {
    final load = Completer<void>();
    _load = load;
    unawaited(load.future.then<void>((_) {}, onError: (Object _) {}));
    try {
      await navigate();
      await load.future.timeout(const Duration(seconds: 30));
    } finally {
      if (identical(_load, load)) _load = null;
    }
  }

  /// 建立新的同源文档，清掉旧定时器、脚本和桥状态，保留原生实例与 Cookie。
  Future<void> resetDocument() async {
    const html =
        '<!DOCTYPE html><html><head><meta charset="utf-8"></head>'
        '<body></body></html>';
    if (Platform.isWindows) {
      await load(
        () => controller.loadUrl(
          urlRequest: URLRequest(
            url: WebUri('${AppConstants.baseUrl}/robots.txt'),
          ),
        ),
      );
      await controller.evaluateJavascript(
        source:
            'document.open();document.write(${jsonEncode(html)});document.close();',
      );
    } else {
      await load(
        () => controller.loadData(
          data: html,
          baseUrl: WebUri(AppConstants.baseUrl),
          mimeType: 'text/html',
          encoding: 'utf-8',
        ),
      );
    }
  }

  Future<void> dispose() async {
    try {
      await webView.dispose();
    } finally {
      if (Platform.isWindows) {
        await Future<void>.delayed(const Duration(milliseconds: 1200));
      }
      FrameJankMonitor.logEvent('WEBVIEW', 'SiteRuntime dispose');
      debugPrint('[SiteRuntime] 后台实例已回收');
    }
  }
}
