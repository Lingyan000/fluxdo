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

  void size(WidgetTester tester, double width) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 820);
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
        S.current.cdk_payAndReceive('12.50'),
      );
      expect(tester.widget<FilledButton>(action).onPressed, isNotNull);
      expect(
        tester.getRect(action).right,
        closeTo(tester.view.physicalSize.width - 16, 1),
      );
      await snapshot(tester, 'detail-${brightness.name}');
      expect(tester.takeException(), isNull);
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
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text(S.current.common_cancel));
    await tester.pumpAndSettle();
    expect(verification, 0);
    for (final accepted in [false, true]) {
      token = accepted ? 'fixture' : null;
      await tester.tap(
        find.widgetWithText(FilledButton, S.current.cdk_receive),
      );
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
}
