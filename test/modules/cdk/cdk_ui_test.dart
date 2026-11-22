import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/cdk_user_info.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/modules/cdk/ui/cdk_home_page.dart';
import 'package:fluxdo/modules/cdk/ui/cdk_project_page.dart';
import 'package:fluxdo/modules/cdk/ui/cdk_widgets.dart';
import 'package:fluxdo/modules/cdk/ui/cdk_verification_sheet.dart';
import 'package:fluxdo/modules/cdk/models/cdk_models.dart';
import 'package:fluxdo/widgets/common/captcha_panel.dart';
import 'package:fluxdo/providers/cdk_providers.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/theme/app_colors.dart';
import 'package:fluxdo/theme/app_theme.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;

import '../../support/material_ui_finders.dart';
import 'cdk_fixture.dart';

class _Account extends CurrentUserNotifier {
  @override
  User? build() => null;
}

class _Score extends CdkUserInfoNotifier {
  @override
  Future<CdkUserInfo?> build() async => CdkUserInfo(
    id: 42,
    username: 'tester',
    nickname: '测试账号',
    trustLevel: 3,
    avatarUrl: '',
    score: 96,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final capture = GlobalKey();
  final snapshots = Platform.environment['CDK_SNAPSHOTS'] == '1';
  late SharedPreferences preferences;
  late CdkFixture api;
  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.en);
    await LocaleSettings.setLocale(AppLocale.zh);
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    await (FontLoader('packages/material_symbols_icons/MaterialSymbolsRounded')
          ..addFont(
            rootBundle.load(
              'packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf',
            ),
          ))
        .load();
    if (snapshots) {
      await (FontLoader('ReviewFont')..addFont(
            File('C:/Windows/Fonts/msyh.ttc')
                .readAsBytes()
                .then(ByteData.sublistView),
          ))
          .load();
    }
  });
  setUp(() => api = CdkFixture());
  tearDown(() => api.client.dispose());

  Widget app(
    Widget child, {
    Brightness brightness = Brightness.light,
    double scale = 1,
    bool reduceMotion = false,
    VisualDensity? density,
  }) {
    const seed = Colors.indigo;
    var theme = buildAppTheme(
      ColorScheme.fromSeed(seedColor: seed, brightness: brightness),
      AppColors.material(brightness),
      UiShapes.standard,
      const ThemeState(mode: ThemeMode.system, seedColor: seed),
      fullscreenSwipeBack: false,
      pageBackground: false,
    );
    if (density != null) theme = theme.copyWith(visualDensity: density);
    if (snapshots) {
      theme = theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'ReviewFont'),
      );
    }
    return ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentUserProvider.overrideWith(_Account.new),
        cdkUserInfoProvider.overrideWith(_Score.new),
      ],
      child: RepaintBoundary(
        key: capture,
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            debugShowCheckedModeBanner: false,
            theme: theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(
                    textScaler: TextScaler.linear(scale),
                    reduceMotion: reduceMotion,
                  ),
              child: child!,
            ),
            home: Scaffold(
              appBar: AppBar(title: const Text('LINUX DO CDK')),
              body: child,
            ),
          ),
        ),
      ),
    );
  }

  void size(WidgetTester tester, double width, {double height = 820}) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
  }

  Future<void> snapshot(WidgetTester tester, String name) async {
    if (!snapshots) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(capture),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      Directory('build/cdk-ui').createSync(recursive: true);
      File('build/cdk-ui/$name.png')
          .writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  // Dio 通过异步拦截器和响应流交付，请等标签真正到达页面后再测画面中间帧。
  Future<void> pumpUntil(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 60 && !ready(); i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(ready(), isTrue);
  }

  // 取实际着色的轮廓；Chip 的可点击范围有额外留白，不能用它来判断骨架是否等高。
  Future<List<Rect>> paintedTags(WidgetTester tester, Finder bar) async {
    final page = find.byKey(capture);
    final area = tester.getRect(bar).shift(-tester.getTopLeft(page));
    final layer = tester.renderObject<RenderRepaintBoundary>(page);
    return (await tester.runAsync(() async {
      final image = await layer.toImage();
      try {
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final pixels = data.buffer.asUint32List(
          data.offsetInBytes,
          data.lengthInBytes ~/ 4,
        );
        final shapes = <Rect>[];
        final left = area.left.ceil();
        for (var x = left + 1; x < area.right.floor(); x++) {
          int? top;
          var bottom = 0;
          for (var y = area.top.ceil(); y < area.bottom.floor(); y++) {
            final row = y * image.width;
            if (pixels[row + x] == pixels[row + left]) continue;
            top ??= y;
            bottom = y + 1;
          }
          if (top == null) continue;
          final column = Rect.fromLTRB(
            x.toDouble(),
            top.toDouble(),
            x + 1.0,
            bottom.toDouble(),
          );
          if (shapes.isNotEmpty && shapes.last.right == x) {
            shapes.last = shapes.last.expandToInclude(column);
          } else {
            shapes.add(column);
          }
        }
        return shapes;
      } finally {
        image.dispose();
      }
    }))!;
  }

  for (final (scale, compact) in const [
    (1.0, false),
    (1.4, false),
    (2.0, true),
  ]) {
    testWidgets('筛选骨架和标签的可见上下边缘对齐：字号 $scale / 紧凑 $compact', (tester) async {
      size(tester, compact ? 800 : 390);
      final pending = api.pendingTags = Completer<List<String>>();
      await tester.pumpWidget(
        app(
          CdkHomeContent(client: api.client),
          scale: scale,
          brightness: compact ? Brightness.dark : Brightness.light,
          density: compact ? VisualDensity.compact : VisualDensity.standard,
        ),
      );
      await tester.pumpAndSettle();
      final all = find
          .widgetWithText(ChoiceChip, S.current.common_all)
          .hitTestable();
      final bar = find
          .ancestor(of: all, matching: find.byType(SingleChildScrollView))
          .first;
      final before = await paintedTags(tester, bar);
      pending.complete(['工具', '体验']);
      await pumpUntil(tester, () => find.text('工具').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      final after = await paintedTags(tester, bar);
      expect(before, hasLength(3));
      expect(after, hasLength(3));
      for (final shape in [...before, ...after]) {
        expect(shape.top, after.first.top, reason: '加载前 $before，加载后 $after');
        expect(
          shape.bottom,
          after.first.bottom,
          reason: '加载前 $before，加载后 $after',
        );
      }
    });
  }

  testWidgets('筛选标签晚到时在原位淡入，滚动中的项目不移动也不重载', (tester) async {
    size(tester, 320);
    final pending = api.pendingTags = Completer<List<String>>();
    await tester.pumpWidget(
      app(CdkHomeContent(client: api.client), scale: 1.4),
    );
    await tester.pumpAndSettle();
    final all = find
        .widgetWithText(ChoiceChip, S.current.common_all)
        .hitTestable();
    final tag = find.widgetWithText(ChoiceChip, '工具');
    expect(all, findsOneWidget);
    expect(tag, findsNothing);
    final list = find.byType(ListView).first;
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        )
        .position;
    position.jumpTo(110);
    await tester.pumpAndSettle();
    final item = find.text('社区工具体验码 2');
    final readingY = tester.getTopLeft(item).dy;
    await snapshot(tester, 'filter-pending');
    pending.complete(['工具', '体验']);
    await pumpUntil(tester, () => tag.evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 45));
    final fades = tester
        .widgetList<FadeTransition>(
          find.ancestor(of: tag, matching: find.byType(FadeTransition)),
        )
        .map((w) => w.opacity.value);
    expect(fades.any((value) => value > 0 && value < 1), isTrue);
    expect(tester.getTopLeft(item).dy, closeTo(readingY, 0.1));
    await snapshot(tester, 'filter-revealing');
    await tester.pumpAndSettle();
    expect(position.pixels, 110);
    expect(tester.getTopLeft(item).dy, closeTo(readingY, 0.1));
    expect(
      api.requests.where((r) => r.path.endsWith('/projects')),
      hasLength(1),
    );
    await snapshot(tester, 'filter-ready');
    await tester.tap(tag);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(tag).selected, isTrue);
    expect(
      api.requests.where((r) => r.uri.queryParameters['tags'] == '工具'),
      hasLength(1),
    );
    await tester.tap(find.text(S.current.cdk_myReceipts));
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.current.cdk_explore));
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(tag).selected, isTrue);
    expect(api.requests.where((r) => r.path.endsWith('/tags')), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  for (final failed in [false, true]) {
    testWidgets('筛选无结果时收回占位，不遮住项目：${failed ? '请求失败' : '空标签'}', (tester) async {
      size(tester, 390);
      final pending = api.pendingTags = Completer<List<String>>();
      await tester.pumpWidget(
        app(CdkHomeContent(client: api.client), reduceMotion: failed),
      );
      await tester.pumpAndSettle();
      final tabs = tester.getBottomLeft(find.byType(TabBar)).dy;
      final list = find.byType(ListView).first;
      final before = tester.getTopLeft(list).dy;
      expect(before, greaterThan(tabs));
      if (failed) {
        pending.completeError(StateError('offline'));
      } else {
        pending.complete([]);
      }
      await pumpUntil(tester, () => tester.getTopLeft(list).dy < before);
      if (!failed) {
        await tester.pump(const Duration(milliseconds: 90));
        expect(
          tester.getTopLeft(list).dy,
          allOf(greaterThan(tabs), lessThan(before)),
        );
        await tester.pumpAndSettle();
      }
      expect(tester.getTopLeft(list).dy, closeTo(tabs, 0.1));
      expect(
        find.widgetWithText(ChoiceChip, S.current.common_all).hitTestable(),
        findsNothing,
      );
      expect(find.text('社区工具体验码 1').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('项目、记录和统计 ${brightness.name} 小屏与大字', (tester) async {
      size(tester, brightness == Brightness.dark ? 320 : 390);
      await tester.pumpWidget(
        app(
          CdkHomeContent(client: api.client),
          brightness: brightness,
          scale: brightness == Brightness.dark ? 1.4 : 1,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('社区工具体验码 1'), findsOneWidget);
      await snapshot(tester, 'explore-${brightness.name}');
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text(S.current.cdk_myReceipts));
      await tester.tap(find.text(S.current.cdk_myReceipts));
      await tester.pumpAndSettle();
      expect(find.text('SAMPLE-ONLY-1234'), findsNothing);
      await snapshot(tester, 'receipts-${brightness.name}');
      await tester.ensureVisible(find.text(S.current.cdk_overview));
      await tester.tap(find.text(S.current.cdk_overview));
      await tester.pumpAndSettle();
      expect(find.text(S.current.cdk_balance), findsOneWidget);
      await snapshot(tester, 'overview-${brightness.name}');
      expect(tester.takeException(), isNull);
      expect(api.requests.every((r) => r.method == 'GET'), isTrue);
    });
    testWidgets('领取详情 ${brightness.name} 底部操作与内容遮蔽', (tester) async {
      size(tester, brightness == Brightness.dark ? 320 : 390);
      api.paid = true;
      await tester.pumpWidget(
        app(
          CdkProjectContent(client: api.client, projectId: 'project-1'),
          brightness: brightness,
          scale: brightness == Brightness.dark ? 1.4 : 1,
        ),
      );
      await tester.pumpAndSettle();
      final action = find.widgetWithText(
        FilledButton,
        S.current.cdk_verifyAndContinue,
      );
      expect(tester.widget<FilledButton>(action).onPressed, isNotNull);
      expect(
        tester.getRect(action).right,
        closeTo(tester.view.physicalSize.width - 16, 1),
      );
      await snapshot(tester, 'detail-${brightness.name}');
      expect(tester.takeException(), isNull);
      await tester.tap(action);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await snapshot(tester, 'confirm-${brightness.name}');
      expect(tester.takeException(), isNull);
      expect(api.requests.every((r) => r.method == 'GET'), isTrue);
      await tester.tap(find.text(S.current.common_cancel));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('取消确认与验证都不领取，免费结果不触发收银台', (tester) async {
    size(tester, 390);
    String? token;
    var verification = 0, payments = 0;
    await tester.pumpWidget(
      app(
        CdkProjectContent(
          client: api.client,
          projectId: 'project-1',
          verify: () async {
            verification++;
            return token;
          },
          pay: (_) async {
            payments++;
            return null;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, S.current.cdk_receive));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text(S.current.common_cancel));
    await tester.pumpAndSettle();
    expect(verification, 0);
    for (final accepted in [false, true]) {
      token = accepted ? 'fixture' : null;
      await tester.tap(
        find.widgetWithText(FilledButton, S.current.cdk_receive),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text(S.current.common_confirm));
      await tester.pumpAndSettle();
      expect(
        api.requests.where((r) => r.method == 'POST'),
        hasLength(accepted ? 1 : 0),
      );
    }
    expect(payments, 0);
    expect(find.text('SAMPLE-ONLY-1234'), findsNothing);
    await tester.scrollUntilVisible(
      findMaterialTooltip(S.current.cdk_showContent),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(findMaterialTooltip(S.current.cdk_showContent));
    await tester.pumpAndSettle();
    expect(find.text('SAMPLE-ONLY-1234'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.text('SAMPLE-ONLY-1234'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('恢复待付款仅查原单，付款返回后按 CDK 交付确认', (tester) async {
    size(tester, 390);
    api.paid = true;
    api.hasPending = true;
    api.stock = 0;
    var payments = 0;
    await tester.pumpWidget(
      app(
        CdkProjectContent(
          client: api.client,
          projectId: 'project-1',
          verify: () async => throw StateError('must not verify again'),
          pay: (intent) async {
            expect(intent.reference, 'CDK20260101');
            payments++;
            api.received = true;
            return {'state': 'paid'};
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.current.cdk_continuePayment));
    await tester.pumpAndSettle();
    expect(payments, 1);
    expect(find.text(S.current.cdk_received), findsWidgets);
    expect(api.requests.every((r) => r.method == 'GET'), isTrue);
  });

  testWidgets('滚动接近底部自动分页，重复滚动不并发加载', (tester) async {
    size(tester, 390);
    await tester.pumpWidget(app(CdkHomeContent(client: api.client)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('社区工具体验码 21'),
      600,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 15,
    );
    await tester.pumpAndSettle();
    expect(find.text('社区工具体验码 21'), findsOneWidget);
    expect(
      api.requests.where((r) => r.queryParameters['current'] == 2),
      hasLength(1),
    );
  });

  testWidgets('会话结束立即移除根弹层内的领取内容', (tester) async {
    size(tester, 390);
    await tester.pumpWidget(
      app(
        CdkSessionContent(
          client: api.client,
          builder: (_) => const CdkSecretContent(content: 'SAMPLE-ONLY-1234'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(findMaterialTooltip(S.current.cdk_showContent));
    await tester.pumpAndSettle();
    expect(find.text('SAMPLE-ONLY-1234'), findsOneWidget);
    api.client.dispose();
    await tester.pumpAndSettle();
    expect(find.text('SAMPLE-ONLY-1234'), findsNothing);
    expect(find.text(S.current.common_authExpired), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets('同一原生面板完成确认、做题、过期重试与取消 ${brightness.name}', (tester) async {
      size(tester, brightness == Brightness.dark ? 320 : 390);
      final callbacks = <ValueChanged<CdkVerificationEvent>>[];
      String? result;
      var closed = 0;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showCaptchaSheet<String>(
                  context: context,
                  title: S.current.cdk_confirmReceive,
                  builder: (_) => CdkSessionContent(
                    client: api.client,
                    builder: (_) => CdkClaimContent(
                      client: api.client,
                      project: CdkProject.fromJson(cdkProject()),
                      challengeBuilder: (context, onEvent) {
                        callbacks.add(onEvent);
                        return const Center(child: Text('模拟验证码区域'));
                      },
                    ),
                  ),
                );
                closed++;
              },
              child: const Text('打开领取'),
            ),
          ),
          brightness: brightness,
          scale: brightness == Brightness.dark ? 1.4 : 1,
        ),
      );
      await tester.tap(find.text('打开领取'));
      await tester.pumpAndSettle();
      expect(callbacks, isEmpty);
      await tester.tap(find.text(S.current.common_confirm));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(S.current.cdk_verifyPreparing), findsOneWidget);
      await snapshot(tester, 'verification-loading-${brightness.name}');
      final old = callbacks.last;
      final panel = find.byType(CaptchaPanel);
      final loadingHeight = tester.getSize(panel).height;
      old(const CdkVerificationEvent('challenge'));
      await tester.pumpAndSettle();
      expect(tester.getSize(panel).height, greaterThan(loadingHeight));
      expect(find.bySemanticsLabel(S.current.cdk_verifyHint), findsOneWidget);
      old(const CdkVerificationEvent('height', '360'));
      await tester.pump();
      final measured = tester.getSize(panel).height;
      old(const CdkVerificationEvent('height', '392'));
      await tester.pump();
      expect(tester.getSize(panel).height, measured + 32);
      await snapshot(tester, 'verification-challenge-${brightness.name}');
      old(const CdkVerificationEvent('error', 'expired'));
      await tester.pumpAndSettle();
      expect(find.text(S.current.captcha_expired), findsOneWidget);
      await snapshot(tester, 'verification-expired-${brightness.name}');
      await tester.tap(find.text(S.current.common_retry));
      await tester.pump();
      old(const CdkVerificationEvent('token', 'stale'));
      await tester.pump();
      expect(closed, 0);
      final current = callbacks.last;
      // 系统返回/外壳关闭也应立即废弃结果，不能在退场动画中误关详情页。
      Navigator.of(tester.element(find.text(S.current.common_cancel))).pop();
      current(const CdkVerificationEvent('token', 'late'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(closed, 1);
      expect(find.text('打开领取'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(api.requests, isEmpty);
    });
  }

  testWidgets('验证加载超时可原地重试，后台回调失效，会话结束移除挑战', (tester) async {
    size(tester, 390);
    late ValueChanged<CdkVerificationEvent> event;
    await tester.pumpWidget(
      app(
        CdkSessionContent(
          client: api.client,
          builder: (_) => CdkClaimContent(
            client: api.client,
            project: CdkProject.fromJson(cdkProject()),
            challengeBuilder: (_, onEvent) {
              event = onEvent;
              return const Text('模拟验证码区域');
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text(S.current.common_confirm));
    await tester.pump();
    await tester.pump(const Duration(seconds: 46));
    await tester.pumpAndSettle();
    expect(find.text(S.current.cdk_verifyFailed), findsOneWidget);
    await tester.tap(find.text(S.current.common_retry));
    await tester.pump();
    event(const CdkVerificationEvent('challenge'));
    await tester.pumpAndSettle();
    final stale = event;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    stale(const CdkVerificationEvent('token', 'background'));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text(S.current.cdk_verifyInterrupted), findsOneWidget);
    await tester.tap(find.text(S.current.common_retry));
    await tester.pump();
    api.client.dispose();
    await tester.pumpAndSettle();
    expect(find.text(S.current.common_authExpired), findsOneWidget);
    expect(find.text('模拟验证码区域'), findsNothing);
    expect(api.requests, isEmpty);
  });

  for (final viewport in [
    (320.0, 820.0, 2.0),
    (800.0, 420.0, 1.0),
    (1200.0, 850.0, 1.0),
  ]) {
    testWidgets('英文领取与确认适配 ${viewport.$1} / ${viewport.$3}', (tester) async {
      LocaleSettings.setLocaleSync(AppLocale.en);
      addTearDown(() => LocaleSettings.setLocaleSync(AppLocale.zh));
      size(tester, viewport.$1, height: viewport.$2);
      api.paid = true;
      await tester.pumpWidget(
        app(
          CdkProjectContent(client: api.client, projectId: 'project-1'),
          scale: viewport.$3,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await snapshot(tester, 'detail-en-${viewport.$1.toInt()}');
      await tester.tap(
        find.widgetWithText(FilledButton, S.current.cdk_verifyAndContinue),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final confirm = find.widgetWithText(
        FilledButton,
        S.current.common_confirm,
      );
      expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(viewport.$2));
      await snapshot(tester, 'confirm-en-${viewport.$1.toInt()}');
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(S.current.common_cancel));
      await tester.pumpAndSettle();
      expect(api.requests.every((r) => r.method == 'GET'), isTrue);
    });
  }
}
