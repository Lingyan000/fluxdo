import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_session.dart';
import 'browser_safe_area.dart';

/// 一个网页拥有一个原生实例；路由只是临时挂载它的宿主。
class BrowserTabSession {
  BrowserTabSession({
    required this.url,
    this.title = '',
    this.injectCss,
    this.accountGeneration,
    Future<void> Function(InAppWebViewKeepAlive)? release,
  }) : _release = release ?? InAppWebViewController.disposeKeepAlive;

  var keepAlive = InAppWebViewKeepAlive();
  final String? injectCss;

  /// 普通网页不绑定账号；带身份的小程序在账号变化时立即关闭。
  final int? accountGeneration;
  final Future<void> Function(InAppWebViewKeepAlive) _release;
  String url;
  String title;
  Uint8List? preview;

  /// 最近一次网页上报的安全区声明；恢复时先按它布局，避免接回后跳动。
  BrowserPageSafeArea? safeArea;
  bool initialLoadRequested = false;
  bool hasWebView = false;
  bool _closed = false;
  Completer<void>? _detached;
  Future<void>? _closing;

  bool get isClosed => _closed;
  bool get supportsDragRestore => true;
  Future<void> get whenDetached => _detached?.future ?? Future.value();

  void attach() {
    if (_closed || _detached != null) {
      throw StateError('网页实例尚未卸载或已经关闭');
    }
    _detached = Completer<void>();
  }

  /// 必须在旧路由的 WebView 从组件树卸载之后调用。
  void detach() {
    _detached?.complete();
    _detached = null;
  }

  Future<void> close() {
    _closed = true;
    preview = null;
    return _closing ??= _closeAfterDetach();
  }

  Future<void> _closeAfterDetach() async {
    await whenDetached;
    await discardWebView();
  }

  /// 只在旧平台视图已经卸载后调用；重试引擎时不能重用旧原生实例。
  Future<void> discardWebView() async {
    if (hasWebView) {
      final token = keepAlive;
      hasWebView = false;
      initialLoadRequested = false;
      keepAlive = InAppWebViewKeepAlive();
      try {
        await _release(token);
      } catch (error, stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'browser tabs',
            context: ErrorDescription('释放已关闭的浏览器页面'),
          ),
        );
      }
    }
  }
}

/// 仅保存本次应用运行期间收起的网页，不写入收藏或稍后阅读。
class BrowserTabsController extends ChangeNotifier {
  BrowserTabsController() {
    AuthSession().generationChanges.addListener(_accountChanged);
  }

  void _accountChanged() {
    for (final tab in List<BrowserTabSession>.of(_tabs)) {
      if (tab.accountGeneration case final generation?) {
        if (!AuthSession().isValid(generation)) close(tab);
      }
    }
  }

  final List<BrowserTabSession> _tabs = [];
  final Set<BrowserTabSession> _restoring = {};
  List<BrowserTabSession> get tabs => List.unmodifiable(_tabs);

  void minimize(BrowserTabSession tab) {
    if (tab.isClosed || _tabs.contains(tab)) return;
    _tabs.add(tab);
    notifyListeners();
  }

  /// 快速连点只允许一次恢复，且不能与旧路由退场同时挂载。
  Future<BrowserTabSession?> take(BrowserTabSession tab) async {
    if (!_tabs.contains(tab) || !_restoring.add(tab)) return null;
    try {
      await tab.whenDetached;
      if (tab.isClosed || !_tabs.remove(tab)) return null;
      notifyListeners();
      return tab;
    } finally {
      _restoring.remove(tab);
    }
  }

  void close(BrowserTabSession tab) {
    if (!_tabs.remove(tab)) return;
    unawaited(tab.close());
    notifyListeners();
  }

  void closeAll() {
    final tabs = List<BrowserTabSession>.of(_tabs);
    _tabs.clear();
    for (final tab in tabs) {
      unawaited(tab.close());
    }
    notifyListeners();
  }

  @override
  void dispose() {
    AuthSession().generationChanges.removeListener(_accountChanged);
    for (final tab in _tabs) {
      unawaited(tab.close());
    }
    _tabs.clear();
    super.dispose();
  }
}

final browserTabsProvider = Provider<BrowserTabsController>((ref) {
  final controller = BrowserTabsController();
  ref.onDispose(controller.dispose);
  return controller;
});
