import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'cf_test_platform.dart' show CfTestCookieManager;

class BrowserTestPlatform extends InAppWebViewPlatform {
  final controller = BrowserTestController();
  BrowserTestView? view;
  BrowserTestFindController? findController;
  final cookies = CfTestCookieManager();
  Widget content = const SizedBox.expand();
  int mounts = 0;
  int unmounts = 0;

  @override
  PlatformCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) => cookies;

  @override
  PlatformFindInteractionController createPlatformFindInteractionController(
    PlatformFindInteractionControllerCreationParams params,
  ) => findController = BrowserTestFindController(params);

  @override
  PlatformInAppWebViewController createPlatformInAppWebViewControllerStatic() =>
      controller;

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => view = BrowserTestView(
    params,
    child: _MountProbe(platform: this, child: content),
  );

  @override
  PlatformInAppWebViewController createPlatformInAppWebViewController(
    PlatformInAppWebViewControllerCreationParams params,
  ) => controller;
}

class BrowserTestView extends PlatformInAppWebViewWidget {
  BrowserTestView(super.params, {required this.child}) : super.implementation();
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      InAppWebViewController.fromPlatform(platform: controller) as T;
  @override
  void dispose() {}
}

class BrowserTestController extends PlatformInAppWebViewController {
  BrowserTestController()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 'browser-test'),
      );
  final released = <InAppWebViewKeepAlive>[];
  final loadRequests = <String>[];
  int loads = 0;
  int defaultDisposals = 0;
  int reloads = 0;
  int stops = 0;
  int backs = 0;
  int forwards = 0;
  Uint8List? screenshot;
  Future<Uint8List?> Function()? screenshotCallback;
  Future<String?> Function()? titleCallback;
  String currentUrl = 'https://example.com/current';
  String title = '恢复后的标题';
  InAppWebViewController get wrapped =>
      InAppWebViewController.fromPlatform(platform: this);
  @override
  void addJavaScriptHandler({
    required String handlerName,
    required Function callback,
  }) {}
  @override
  Future<Uint8List?> takeScreenshot({
    ScreenshotConfiguration? screenshotConfiguration,
  }) async =>
      screenshotCallback != null ? await screenshotCallback!() : screenshot;
  @override
  Future<WebUri?> getUrl() async => WebUri(currentUrl);
  @override
  Future<String?> getTitle() async =>
      titleCallback != null ? await titleCallback!() : title;
  @override
  Future<bool> canGoBack() async => true;
  @override
  Future<bool> canGoForward() async => false;
  @override
  Future<int?> getProgress() async => 100;
  @override
  Future<void> loadUrl({
    required URLRequest urlRequest,
    WebUri? allowingReadAccessTo,
    Uri? iosAllowingReadAccessTo,
  }) async {
    loads++;
    currentUrl = urlRequest.url.toString();
    loadRequests.add(currentUrl);
  }

  @override
  Future<void> reload() async {
    reloads++;
  }

  @override
  Future<void> stopLoading() async {
    stops++;
  }

  @override
  Future<void> goBack() async {
    backs++;
  }

  @override
  Future<void> goForward() async {
    forwards++;
  }

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async => null;

  @override
  Future<void> disposeKeepAlive(InAppWebViewKeepAlive keepAlive) async {
    released.add(keepAlive);
  }

  @override
  void dispose({bool isKeepAlive = false}) {
    if (!isKeepAlive) defaultDisposals++;
  }
}

class _MountProbe extends StatefulWidget {
  const _MountProbe({required this.platform, required this.child});
  final BrowserTestPlatform platform;
  final Widget child;
  @override
  State<_MountProbe> createState() => _MountProbeState();
}

class _MountProbeState extends State<_MountProbe> {
  @override
  void initState() {
    super.initState();
    widget.platform.mounts++;
  }

  @override
  void dispose() {
    widget.platform.unmounts++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class BrowserTestFindController extends PlatformFindInteractionController {
  BrowserTestFindController(super.params) : super.implementation();
  final queries = <String?>[];
  final directions = <bool>[];
  int clears = 0;
  @override
  Future<void> findAll({String? find}) async {
    queries.add(find);
  }

  @override
  Future<void> findNext({bool forward = true}) async {
    directions.add(forward);
  }

  @override
  Future<void> clearMatches() async {
    clears++;
  }

  @override
  void dispose({bool isKeepAlive = false}) {}
  void result(int index, int count) =>
      onFindResultReceived?.call(this, index, count, true);
}
