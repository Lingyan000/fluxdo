import 'package:common_ui/common_ui.dart';
import 'package:flutter/rendering.dart'
    show PlatformViewLayer, PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/browser_trust_coordinator.dart';
import 'package:fluxdo/services/cf_challenge_service.dart';
import 'package:fluxdo/services/launch_splash_handoff.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/widgets/preheat_gate.dart';
import 'package:fluxdo/widgets/common/cf_startup_verification.dart';
import 'package:fluxdo/widgets/common/cf_verification_dialog.dart';
import 'package:fluxdo/widgets/preheat_logo.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cf_test_platform.dart';

class _SurfaceController extends Fake implements PlatformViewController {
  @override
  int get viewId => 87;
}

class _HomeProbe extends StatefulWidget {
  const _HomeProbe();

  @override
  State<_HomeProbe> createState() => _HomeProbeState();
}

class _HomeProbeState extends State<_HomeProbe> {
  int paints = 0;
  bool moving = false;

  @override
  Widget build(BuildContext context) {
    moving = PageMotionScope.of(context);
    return CustomPaint(painter: _CountPaint(() => paints++));
  }
}

class _CountPaint extends CustomPainter {
  _CountPaint(this.onPaint);

  final VoidCallback onPaint;

  @override
  void paint(Canvas canvas, Size size) {
    onPaint();
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.blue);
  }

  @override
  bool shouldRepaint(covariant _CountPaint oldDelegate) => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'FluxDO',
      packageName: 'fluxdo',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    PreloadedDataService().debugSeed(loaded: true);
    LaunchSplashHandoff.nativeLogo.value = false;
    LaunchSplashHandoff.nativeSplashVisible.value = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['wifi'],
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
      (_) async => null,
    );
  });

  tearDown(() => PreloadedDataService().reset());

  Future<CfTestPlatform> installWebView() async {
    final platform = CfTestPlatform();
    final previous = InAppWebViewPlatform.instance;
    await platform.initialize();
    addTearDown(() async {
      await platform.reset();
      if (previous != null) InAppWebViewPlatform.instance = previous;
    });
    return platform;
  }

  Future<void> pumpGate(
    WidgetTester tester, {
    double width = 390,
    Widget? home,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 844);
    addTearDown(tester.view.reset);
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: home ?? const PreheatGate(child: _HomeProbe()),
          ),
        ),
      ),
    );
    await tester.pump();
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  }

  testWidgets('加载背景遮住网页时依然绘制原生视图，人工操作使用同一图层', (tester) async {
    final controller = _SurfaceController();
    final host = CfStartupVerificationHost()
      ..loadingBackground = Colors.white
      ..layoutViewport(const Size(300, 360), coveredTop: 140);
    addTearDown(host.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            Positioned(
              top: 50,
              left: 20,
              width: 300,
              height: 360,
              child: CompositedTransformTarget(link: host.viewportLink),
            ),
            Positioned.fill(
              child: CfStartupVerificationViewport(
                host: host,
                child: PlatformViewSurface(
                  controller: controller,
                  hitTestBehavior: PlatformViewHitTestBehavior.opaque,
                  gestureRecognizers: const {},
                ),
              ),
            ),
          ],
        ),
      ),
    );
    final surface = find.byType(PlatformViewSurface);
    final bounds = tester.getRect(surface);
    expect(
      tester.layers.whereType<PlatformViewLayer>().single.viewId,
      controller.viewId,
    );
    expect(surface.hitTestable(), findsNothing);
    final element = tester.element(surface);
    host.present(pageVisible: true);
    await tester.pump();
    expect(tester.getRect(surface), bounds);
    expect(
      tester.layers.whereType<PlatformViewLayer>().single.viewId,
      controller.viewId,
    );
    expect(tester.element(surface.hitTestable()), same(element));
  });

  testWidgets('启动页收到交互信号立即显示整页，读屏用户可直接操作和重新加载', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final platform = await installWebView();
    await pumpGate(tester);
    final gate = tester.element(find.byType(PreheatGate));
    final verification = CfChallengeService().verifyPage(
      context: gate,
      presentation: CfVerifyPresentation.blocking,
    );
    await tester.pump();
    await tester.pump();
    final browser = find.byType(InAppWebView, skipOffstage: false);
    final original = tester.state(browser);
    final waitingBounds = tester.getRect(browser);
    final controller = platform.controller;
    final page = platform.webView!.params;
    page.onWebViewCreated!(controller.wrapped);
    controller.documentHtml = '<html><body id="challenge-stage"></body></html>';
    expect(browser.hitTestable(), findsNothing);
    expect(find.byType(PreheatLogo), findsOneWidget);
    final skip = find.text(gate.l10n.common_skip);
    expect(skip.hitTestable(), findsNothing);
    await controller.widgetEvent('interactiveBegin');
    await tester.pump();
    final area = tester.getRect(browser.hitTestable());
    final status = find.text(gate.l10n.cf_startupNeedsAction);
    expect(area, waitingBounds);
    expect(area.top, closeTo(tester.getBottomLeft(status).dy + 12, 1));
    expect(skip.hitTestable(), findsOneWidget);
    expect(find.semantics.byLabel(gate.l10n.common_skip), findsOne);
    final skipPosition = tester.getRect(skip);
    expect(
      area.bottom,
      lessThan(tester.getTopLeft(find.text(gate.l10n.common_skip)).dy),
    );
    expect(area.height, greaterThan(400));
    expect(find.byType(PreheatLogo), findsNothing);
    expect(find.byType(CfVerificationDialog), findsNothing);
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.getRect(browser.hitTestable()), area);
    expect(tester.getRect(skip), skipPosition);
    await tester.tapAt(area.topLeft + const Offset(16, 30));
    expect(controller.pointers, [const Offset(16, 30)]);
    final reload = find.semantics.byLabel(gate.l10n.cf_retryVerify);
    expect(reload, findsOne);
    tester.semantics.tap(reload);
    await tester.pump();
    expect(browser.hitTestable(), findsNothing);
    expect(skip.hitTestable(), findsOneWidget);
    expect(find.byType(PreheatLogo), findsOneWidget);
    expect(tester.state(browser), same(original));

    await controller.widgetEvent('interactiveBegin');
    await tester.pump();
    expect(tester.getRect(browser.hitTestable()), area);
    await controller.widgetEvent('interactiveEnd');
    page.onLoadStart!(controller.wrapped, WebUri(controller.documentUrl));
    await tester.pump();
    final checking = find.text(gate.l10n.cf_panelCheckingResult);
    final logo = find.byType(PreheatLogo);
    expect(browser.hitTestable(), findsNothing);
    expect(logo, findsOneWidget);
    expect(
      tester.getTopLeft(checking).dy,
      greaterThan(tester.getBottomLeft(logo).dy),
    );
    expect(tester.getRect(skip), skipPosition);
    expect(tester.state(browser), same(original));

    page.onReceivedHttpError!(
      controller.wrapped,
      WebResourceRequest(
        url: WebUri(controller.documentUrl),
        isForMainFrame: true,
      ),
      WebResourceResponse(
        statusCode: 404,
        headers: {'content-type': 'text/html'},
      ),
    );
    await tester.pump();
    expect((await verification)?.reachedOrigin, isTrue);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
  });

  testWidgets('启动屏进入人工验证的首帧就能跳过并结束本轮', (tester) async {
    final platform = await installWebView();
    await pumpGate(tester);
    final gate = tester.element(find.byType(PreheatGate));
    final cf = CfChallengeService();
    final result = cf.verifyPage(
      context: gate,
      presentation: CfVerifyPresentation.blocking,
    );
    await tester.pump();
    await tester.pump();
    final controller = platform.controller;
    platform.webView!.params.onWebViewCreated!(controller.wrapped);
    await controller.widgetEvent('interactiveBegin');
    await tester.pump();
    expect(find.text(gate.l10n.common_skip).hitTestable(), findsOneWidget);
    await tester.tap(find.text(gate.l10n.common_skip));
    await tester.pump();
    expect((await result)?.stage, CfVerificationStage.cancelled);
    expect(find.byType(InAppWebView).hitTestable(), findsNothing);
    cf.resetCooldown();
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('首页已预热，后台验证被提到前台且交互信号迟到，始终在启动屏内操作', (tester) async {
    final platform = await installWebView();
    await pumpGate(tester);
    final gate = tester.element(find.byType(PreheatGate));
    final cf = CfChallengeService();
    final first = cf.verifyPage(
      context: gate,
      presentation: CfVerifyPresentation.pill,
    );
    await tester.pump();
    await tester.pump();
    final browser = find.byType(InAppWebView, skipOffstage: false);
    final original = tester.state(browser);
    final controller = platform.controller;
    final page = platform.webView!.params;
    final url = WebUri('https://linux.do/challenge');
    page.onWebViewCreated!(controller.wrapped);
    controller.documentHtml = '<html><body id="challenge-stage"></body></html>';
    page.onPageCommitVisible!(controller.wrapped, url);
    for (var seconds = 0; seconds < 3; seconds++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.byType(PreheatLogo), findsOneWidget);
    expect(find.byType(CfVerificationDialog), findsNothing);
    final foreground = cf.verifyPage(context: gate, userInitiated: true);
    await tester.pump();
    expect(cf.presentationNotifier.value, CfVerifyPresentation.foreground);
    expect(find.byType(CfVerificationDialog), findsNothing);
    await controller.widgetEvent('interactiveBegin');
    await tester.pump();
    await tester.pump();
    final full = tester.getRect(browser.hitTestable());
    final status = find.text(gate.l10n.cf_startupNeedsAction);
    expect(full.top, greaterThan(tester.getBottomLeft(status).dy));
    expect(
      full.bottom,
      lessThan(tester.getTopLeft(find.text(gate.l10n.common_skip)).dy),
    );
    expect(find.text('FluxDO'), findsOneWidget);
    expect(find.byType(CfVerificationDialog), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.state(browser), same(original));
    await tester.tapAt(full.topLeft + const Offset(20, 32));
    expect(controller.pointers, [const Offset(20, 32)]);
    page.onReceivedHttpError!(
      controller.wrapped,
      WebResourceRequest(url: url, isForMainFrame: true),
      WebResourceResponse(
        statusCode: 404,
        headers: {'content-type': 'text/html'},
      ),
    );
    await tester.pump();
    expect((await first)?.stage, CfVerificationStage.challengeCleared);
    expect((await foreground)?.stage, CfVerificationStage.challengeCleared);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.byType(CfChallengePage), findsNothing);
    expect(find.byType(PreheatLogo), findsNothing);
    expect(find.byType(_HomeProbe), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('启动屏接管已打开的前台验证，点跳过关闭本轮且可正常返回', (tester) async {
    await installWebView();
    final launching = ValueNotifier(false);
    await pumpGate(
      tester,
      home: ValueListenableBuilder<bool>(
        valueListenable: launching,
        builder: (_, value, _) => value
            ? const PreheatGate(child: _HomeProbe())
            : const Scaffold(body: SizedBox.shrink()),
      ),
    );
    final cf = CfChallengeService();
    final result = cf.verifyPage(
      context: tester.element(find.byType(Scaffold)),
      userInitiated: true,
    );
    await tester.pump();
    await tester.pump();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(find.byType(CfVerificationDialog), findsOneWidget);
    expect(navigator.canPop(), isTrue);
    final original = tester.state(
      find.byType(InAppWebView, skipOffstage: false),
    );

    launching.value = true;
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CfVerificationDialog), findsNothing);
    expect(navigator.canPop(), isFalse);
    expect(
      tester.state(find.byType(InAppWebView, skipOffstage: false)),
      same(original),
    );
    await tester.pump(const Duration(seconds: 11));
    await tester.pump(const Duration(milliseconds: 500));
    final gate = tester.element(find.byType(PreheatGate));
    await tester.tap(find.text(gate.l10n.common_skip));
    await tester.pump();
    expect((await result)?.stage, CfVerificationStage.cancelled);
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(CfVerificationDialog), findsNothing);
    expect(navigator.canPop(), isFalse);
    cf.resetCooldown();
    await tester.pumpWidget(const SizedBox.shrink());
    launching.dispose();
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('启动屏移除时前台验证沿用同一个网页', (tester) async {
    final platform = await installWebView();
    final launching = ValueNotifier(true);
    await pumpGate(
      tester,
      home: ValueListenableBuilder<bool>(
        valueListenable: launching,
        builder: (_, value, _) => value
            ? const PreheatGate(child: _HomeProbe())
            : const Scaffold(body: SizedBox.shrink()),
      ),
    );
    final cf = CfChallengeService();
    final result = cf.verifyPage(
      context: tester.element(find.byType(PreheatGate)),
      userInitiated: true,
    );
    await tester.pump();
    await tester.pump();
    final controller = platform.controller;
    platform.webView!.params.onWebViewCreated!(controller.wrapped);
    await controller.widgetEvent('interactiveBegin');
    await tester.pump();
    final browser = find.byType(InAppWebView).hitTestable();
    final original = tester.state(browser);
    launching.value = false;
    await tester.pump();
    await tester.pump();
    expect(find.byType(CfVerificationDialog), findsOneWidget);
    expect(tester.state(browser), same(original));
    platform.webView!.params.onReceivedHttpError!(
      controller.wrapped,
      WebResourceRequest(
        url: WebUri(controller.documentUrl),
        isForMainFrame: true,
      ),
      WebResourceResponse(
        statusCode: 404,
        headers: {'content-type': 'text/html'},
      ),
    );
    await tester.pump();
    expect((await result)?.reachedOrigin, isTrue);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox.shrink());
    launching.dispose();
    await tester.pump(const Duration(seconds: 5));
  });

  for (final width in [390.0, 1024.0]) {
    testWidgets('退场在半秒内结束，首页状态与绘制结果复用 width=$width', (tester) async {
      await pumpGate(tester, width: width);
      final home = tester.state<_HomeProbeState>(find.byType(_HomeProbe));
      expect(home.moving, isFalse);
      expect(find.byType(PreheatLogo), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1016));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(home.moving, isTrue);
      expect(
        TickerMode.valuesOf(tester.element(find.byType(PreheatLogo))).enabled,
        isFalse,
        reason: '退场时光晕停止刷新',
      );

      // 亚克力窗口里的首页此时已开始淡入，先完成首次绘制。
      await tester.pump(const Duration(milliseconds: 160));
      final paints = home.paints;
      expect(paints, greaterThan(0));
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(home.paints, paints, reason: '缩放和淡入不能导致首页逐帧重绘');
      expect(find.byType(PreheatLogo), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 244));
      await tester.pump();
      expect(find.byType(PreheatLogo), findsNothing);
      expect(tester.state(find.byType(_HomeProbe)), same(home));
      expect(home.moving, isFalse);
      expect(
        tester
            .renderObject(find.byType(_HomeProbe))
            .getTransformTo(null)
            .getMaxScaleOnAxis(),
        closeTo(1, 0.0001),
      );
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.all());
  }

  testWidgets('启动状态显示最新验证文案，切换阶段时淡入淡出', (tester) async {
    final cf = CfChallengeService();
    final pageState = cf.pageState as ValueNotifier<CfVerificationState?>;
    final previousPage = pageState.value;
    final previousPresentation = cf.presentationNotifier.value;
    final preloadStage = BrowserTrustCoordinator.instance.preloadStage;
    final previousStage = preloadStage.value;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      pageState.value = previousPage;
      cf.presentationNotifier.value = previousPresentation;
      preloadStage.value = previousStage;
      LaunchSplashHandoff.nativeSplashVisible.value = false;
    });
    await pumpGate(tester);
    // 保留启动屏接管等待，使真实入口有时间展示状态切换。
    LaunchSplashHandoff.nativeSplashVisible.value = true;
    pageState.value = const CfVerificationState.opening(1);
    cf.presentationNotifier.value = CfVerifyPresentation.pill;
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));
    final l10n = tester.element(find.byType(PreheatGate)).l10n;
    expect(find.text('FluxDO'), findsOneWidget);
    expect(find.text(l10n.cf_verifyOpeningTitle), findsOneWidget);

    pageState.value = pageState.value!.withStage(CfVerificationStage.checking);
    await tester.pump();
    await tester.pump();
    expect(find.text(l10n.cf_verifyOpeningTitle), findsNothing);
    expect(find.text(l10n.cf_challengeDetectedTitle), findsOneWidget);
    pageState.value = pageState.value!.withStage(
      CfVerificationStage.widgetError,
      observed: CfChallengeEvidence.widgetError,
      widgetErrorCode: '200500',
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));
    expect(find.text(l10n.cf_widgetErrorWithCode('200500')), findsOneWidget);

    preloadStage.value = BrowserTrustPreloadStage.webView;
    cf.presentationNotifier.value = null;
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 125));
    expect(find.text(l10n.cf_widgetErrorWithCode('200500')), findsOneWidget);
    expect(find.text(l10n.preheat_statusBrowser), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 141));
    expect(find.text(l10n.cf_widgetErrorWithCode('200500')), findsNothing);
    expect(find.text(l10n.preheat_statusBrowser), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final features in [
    const FakeAccessibilityFeatures(disableAnimations: true),
    const FakeAccessibilityFeatures(reduceMotion: true),
  ]) {
    testWidgets('减少动态效果时直接结束启动页 $features', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = features;
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await pumpGate(tester);
      await tester.pump();
      await tester.pump();
      expect(find.byType(PreheatLogo), findsNothing);
      expect(find.byType(_HomeProbe), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
