import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/cf_clearance_refresh_service.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';

import '../support/cf_test_platform.dart';

class _HeadlessTestPlatform extends CfTestPlatform {
  final List<_FakeHeadlessWebView> headlessViews = [];
  final List<String> loadedHtmls = [];

  @override
  PlatformHeadlessInAppWebView createPlatformHeadlessInAppWebView(
    PlatformHeadlessInAppWebViewCreationParams params,
  ) {
    final view = _FakeHeadlessWebView(params, this);
    headlessViews.add(view);
    return view;
  }
}

class _FakeHeadlessWebView extends PlatformHeadlessInAppWebView {
  _FakeHeadlessWebView(super.params, this.platform) : super.implementation();

  final _HeadlessTestPlatform platform;
  bool _running = false;
  bool disposed = false;
  late final _FakeHeadlessController _controller = _FakeHeadlessController(
    platform,
  );

  @override
  String get id => 'fake-headless';

  @override
  PlatformInAppWebViewController? get webViewController =>
      _running ? _controller : null;

  @override
  Future<void> run() async {
    _running = true;
    params.onWebViewCreated?.call(
      InAppWebViewController.fromPlatform(platform: _controller),
    );
  }

  @override
  bool isRunning() => _running;

  @override
  Future<void> dispose() async {
    _running = false;
    disposed = true;
  }
}

class _FakeHeadlessController extends CfTestController {
  _FakeHeadlessController(this.platform) : super(platform.cookies);

  final _HeadlessTestPlatform platform;

  @override
  Future<void> loadData({
    required String data,
    String mimeType = 'text/html',
    String encoding = 'utf8',
    WebUri? baseUrl,
    @Deprecated('Use historyUrl instead') Uri? androidHistoryUrl,
    WebUri? historyUrl,
    @Deprecated('Use allowingReadAccessTo instead')
    Uri? iosAllowingReadAccessTo,
    WebUri? allowingReadAccessTo,
  }) async {
    platform.loadedHtmls.add(data);
  }

  @override
  Function? removeJavaScriptHandler({required String handlerName}) {
    return handlers.remove(handlerName);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CfClearanceRefreshService', () {
    late _HeadlessTestPlatform platform;
    late Directory cookieDir;

    setUpAll(() async {
      cookieDir = await Directory.systemTemp.createTemp('cf-refresh-test-');
      platform = _HeadlessTestPlatform();
      await platform.initialize(cookieDirectory: cookieDir.path);
    });

    setUp(() async {
      await CfClearanceRefreshService().resetForTest();
      await platform.reset();
      platform.headlessViews.clear();
      platform.loadedHtmls.clear();
    });

    tearDownAll(() async {
      await CfClearanceRefreshService().resetForTest();
      if (cookieDir.existsSync()) {
        await cookieDir.delete(recursive: true);
      }
    });

    test('isClearanceSnapshotAdvanced 允许从无到有铸造首枚 cf_clearance', () {
      expect(
        CfClearanceRefreshService.isClearanceSnapshotAdvanced(
          previousValue: null,
          previousExpires: null,
          currentValue: 'minted-first-value',
          currentExpires: null,
        ),
        isTrue,
      );
      expect(
        CfClearanceRefreshService.isClearanceSnapshotAdvanced(
          previousValue: 'old-value',
          previousExpires: null,
          currentValue: 'old-value',
          currentExpires: null,
        ),
        isFalse,
      );
      final base = DateTime(2026, 11, 26, 10, 0, 0);
      expect(
        CfClearanceRefreshService.isClearanceSnapshotAdvanced(
          previousValue: 'same-value',
          previousExpires: base,
          currentValue: 'same-value',
          currentExpires: base.add(const Duration(seconds: 60)),
        ),
        isTrue,
      );
    });

    test('无现存 cf_clearance 时只要有 sitekey 即可从 0 启动 Turnstile 预热', () async {
      if (Platform.isWindows) return;

      final service = CfClearanceRefreshService();
      service.updateSitekey('0x4AAAAAAAc2BQjPEms9tKlM');
      service.start();

      // 等待异步 _startWebView 启动完成
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(service.shouldBeRunningForTest, isTrue);
      expect(service.isRunningForTest, isTrue);
      expect(platform.headlessViews, hasLength(1));
      expect(platform.loadedHtmls, hasLength(1));
      expect(platform.loadedHtmls.single, contains('0x4AAAAAAAc2BQjPEms9tKlM'));

      // 模拟 Turnstile 从 0 铸造出 cf_clearance 并触发 token 回调，验证落库到 jar
      platform.cookies.values = [cfTestCookie('minted-from-zero')];
      final controller = platform.headlessViews.single._controller;
      controller.handlers['onTurnstileToken']?.call([
        {'length': 128},
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final synced = await CookieJarService().getCfClearance();
      expect(synced, 'minted-from-zero');
    });

    test('健康在位值被 Authority 保护跳过覆盖时，token 回调与 WebView 新值仍推进活跃锚点', () async {
      if (Platform.isWindows) return;

      await CookieJarService().setCookie(
        'cf_clearance',
        'healthy-incumbent',
        expires: DateTime.now().toUtc().add(const Duration(days: 7)),
      );
      final service = CfClearanceRefreshService();
      service.updateSitekey('0x4AAAAAAAc2BQjPEms9tKlM');
      service.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final initialAnchor = service.latestActivityAnchorForTest;
      expect(initialAnchor, isNotNull);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      platform.cookies.values = [cfTestCookie('turnstile-rotated-value')];
      final controller = platform.headlessViews.single._controller;
      controller.handlers['onTurnstileToken']?.call([
        {'length': 256},
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // jar 仍保留健康在位值（未被异值顶替），但活跃锚点已推进，不会 8 分钟后误判 stale。
      expect(await CookieJarService().getCfClearance(), 'healthy-incumbent');
      expect(
        service.latestActivityAnchorForTest!.isAfter(initialAnchor!),
        isTrue,
      );
    });
  });
}
