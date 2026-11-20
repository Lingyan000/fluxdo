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
                  .copyWith(textScaler: TextScaler.linear(scale)),
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
