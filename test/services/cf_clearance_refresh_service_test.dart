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

    test('Turnstile 现场新铸的 cf_clearance 立即替换健康在位值并忽略旧残留', () async {
      if (Platform.isWindows) return;

      await CookieJarService().setCookie(
        'cf_clearance',
        'healthy-incumbent',
        expires: DateTime.now().toUtc().add(const Duration(days: 7)),
      );
      // 启动前 WebView 里已存在的旧残留必须被记入基线，不能借同步覆盖在位值。
      platform.cookies.values = [cfTestCookie('preexisting-stale-residue')];
      final service = CfClearanceRefreshService();
      service.updateSitekey('0x4AAAAAAAc2BQjPEms9tKlM');
      service.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final initialAnchor = service.latestActivityAnchorForTest;
      expect(initialAnchor, isNotNull);

      // 仅旧残留存在时，即使触发 token 回调也不得覆盖健康在位值。
      final controller = platform.headlessViews.single._controller;
      controller.handlers['onTurnstileToken']?.call([
        {'length': 256},
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await CookieJarService().getCfClearance(), 'healthy-incumbent');

      // Turnstile 现场铸出全新 cf_clearance（与旧残留并存），应立即替换 jar 在位值。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      platform.cookies.values = [
        cfTestCookie('preexisting-stale-residue'),
        cfTestCookie('turnstile-rotated-value'),
      ];
      controller.handlers['onTurnstileToken']?.call([
        {'length': 256},
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        await CookieJarService().getCfClearance(),
        'turnstile-rotated-value',
      );
      expect(
        service.latestActivityAnchorForTest!.isAfter(initialAnchor!),
        isTrue,
      );
    });

    test('pickFreshlyMintedClearance 仅接受不在基线中的唯一新值', () {
      expect(
        CfClearanceRefreshService.pickFreshlyMintedClearance(
          knownValues: {'old-a', 'incumbent'},
          currentWebViewValues: {'old-a', 'fresh-b'},
        ),
        'fresh-b',
      );
      expect(
        CfClearanceRefreshService.pickFreshlyMintedClearance(
          knownValues: {'old-a'},
          currentWebViewValues: {'old-a'},
        ),
        isNull,
      );
      expect(
        CfClearanceRefreshService.pickFreshlyMintedClearance(
          knownValues: {'old-a'},
          currentWebViewValues: {'fresh-1', 'fresh-2'},
        ),
        isNull,
      );
    });
  });
}
