import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/metaverse_page.dart';
import 'package:fluxdo/modules/metaverse/metaverse_registry.dart';
import 'package:fluxdo/modules/metaverse/core/metaverse_service.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/models/ldc_user_info.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/ldc_providers.dart';
import 'package:fluxdo/widgets/ldc_balance_card.dart';
import 'package:fluxdo/modules/ldc_reward/models/ldc_reward_credentials.dart';
import 'package:fluxdo/modules/ldc_reward/providers/ldc_reward_provider.dart';
import 'package:fluxdo/modules/ldc_reward/widgets/ldc_reward_config_tile.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_installer.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_plugin_dialogs.dart';
import 'package:fluxdo/modules/metaverse/plugin/providers/metaverse_plugin_providers.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_plugin_page.dart';
import 'package:fluxdo/modules/ldc_payment/ldc_payment_sheet.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_widget_library.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/ldc_payment_service.dart';
import 'package:fluxdo/services/ldc_biometric_payment.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:fluxdo/theme/app_colors.dart';
import 'package:fluxdo/theme/app_theme.dart';
import 'package:rfw/rfw.dart';
import 'package:rfw/formats.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:m3e_ui/m3e_ui.dart';

class _FixtureUser extends CurrentUserNotifier {
  @override
  User? build() => null;
}

class _FixtureBalance extends LdcUserInfoNotifier {
  _FixtureBalance(this.mode);
  final String mode;
  @override
  Future<LdcUserInfo?> build() async {
    if (mode == 'loading') return Completer<LdcUserInfo?>().future;
    if (mode == 'error') throw StateError('offline');
    return LdcUserInfo.fromJson({
      'id': 42,
      'username': 'tester',
      'nickname': 'tester',
      'trust_level': 2,
      'avatar_url': '',
      'total_receive': '0',
      'total_payment': '0',
      'total_transfer': '0',
      'total_community': '8000',
      'community_balance': '7940.98',
      'available_balance': '7950.98',
      'pay_score': 0,
      'is_pay_key': true,
      'is_admin': false,
      'remain_quota': '5000',
      'pay_level': 1,
      'daily_limit': null,
    });
  }
}

class _NoReward extends LdcRewardCredentialsNotifier {
  @override
  Future<LdcRewardCredentials?> build() async => null;
}

class _MemoryCodeStore extends MetaversePluginStore {
  _MemoryCodeStore(SharedPreferences preferences)
    : super(
        preferences: preferences,
        secretStore: InMemorySecretStore(),
        rootDirectory: () => throw StateError('测试不读写文件'),
      );
  MetaversePluginCode? written;
  @override
  Future<void> writeCode(String id, MetaversePluginCode code) async {
    written = code;
  }

  @override
  Future<MetaversePluginCode> readCode(String id) async => written!;
  @override
  Future<Map<String, Object?>> readStorage(String id) async => {};
}

class _EmptyPlugins extends MetaversePluginsController {
  @override
  List<InstalledMetaversePlugin> build() => [];
}

class _Payment implements LdcPaymentDelegate {
  int payments = 0, refreshes = 0;
  int passwords = 0;
  bool timeout = false, refreshFails = false;
  String status = 'completed';
  Completer<void>? pending;
  final order = LdcPaymentOrder(
    token: 'fixture',
    orderNo: 'LD202611120042',
    name: '开发者工具包',
    amount: '12.50',
    payer: 'tester',
    payee: 'seller',
    merchant: 'LD士多',
    expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  );
  @override
  Future<LdcPaymentOrder> prepare(String no, String username) async => order;
  @override
  Future<void> setInitialPassword(String password, String username) async {
    expect(password, '123456');
    passwords++;
  }

  @override
  Future<void> pay(LdcPaymentOrder order, String password) async {
    payments++;
    expect(password, '123456');
    if (pending != null) await pending!.future;
    if (timeout) {
      throw DioException.receiveTimeout(
        timeout: const Duration(seconds: 1),
        requestOptions: RequestOptions(),
      );
    }
  }

  @override
  Future<bool> refreshPayment(String no) async {
    refreshes++;
    if (refreshFails) throw StateError('offline');
    return status == 'completed';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final snapshots = Platform.environment['LD_STORE_SNAPSHOTS'] == '1';
  final captureKey = GlobalKey();
  late SharedPreferences preferences;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    final icons =
        FontLoader('packages/material_symbols_icons/MaterialSymbolsRounded')
          ..addFont(
            rootBundle.load(
              'packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf',
            ),
          );
    await icons.load();
    final materialIcons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await materialIcons.load();
    if (snapshots) {
      final font = File('C:/Windows/Fonts/msyh.ttc');
      final loader = FontLoader('ReviewFont')
        ..addFont(font.readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });

  Widget app(
    Widget child, {
    Brightness brightness = Brightness.light,
    double scale = 1,
    bool reducedMotion = false,
    MetaversePluginStore? pluginStore,
    List<MetaversePluginPackage>? bundled,
  }) {
    const seed = Colors.indigo;
    final theme = buildAppTheme(
      ColorScheme.fromSeed(seedColor: seed, brightness: brightness),
      AppColors.material(brightness),
      UiShapes.standard,
      const ThemeState(mode: ThemeMode.system, seedColor: seed),
      fullscreenSwipeBack: false,
      pageBackground: false,
    );
    return ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        metaversePluginsProvider.overrideWith(
          pluginStore == null
              ? _EmptyPlugins.new
              : MetaversePluginsController.new,
        ),
        if (pluginStore != null) ...[
          metaversePluginStoreProvider.overrideWithValue(pluginStore),
          metaverseServicesProvider.overrideWith(
            (ref) => [
              for (final plugin in ref.watch(metaversePluginsProvider))
                MetaversePluginService(plugin),
            ],
          ),
        ],
        if (bundled != null)
          metaverseBundledPluginsProvider.overrideWith((ref) async => bundled),
      ],
      child: RepaintBoundary(
        key: captureKey,
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            debugShowCheckedModeBanner: false,
            theme: snapshots
                ? theme.copyWith(
                    textTheme: theme.textTheme.apply(fontFamily: 'ReviewFont'),
                  )
                : theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: reducedMotion,
              ),
              child: child!,
            ),
            home: Scaffold(
              appBar: AppBar(title: const Text('LD士多')),
              body: child,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> snapshot(WidgetTester tester, String name) async {
    if (!snapshots) return;
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(captureKey),
      );
      final picture = await boundary.toImage(pixelRatio: 2);
      final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
      picture.dispose();
      final dir = Directory('build/ld-store-ui');
      await dir.create(recursive: true);
      await File('${dir.path}/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  Future<void> openPayment(
    WidgetTester tester,
    _Payment payment, {
    bool needsPassword = false,
    bool reducedMotion = false,
    Size size = const Size(390, 844),
    double scale = 1,
    LdcBiometricPayment? biometrics,
    Brightness brightness = Brightness.light,
    ValueChanged<Map<String, Object?>?>? onResult,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () async {
                final result = await showLdcPaymentSheet(
                  context,
                  payment: payment,
                  orderNo: payment.order.orderNo,
                  username: 'tester',
                  needsPassword: needsPassword,
                  biometrics: biometrics,
                );
                onResult?.call(result);
              },
              child: const Text('支付入口'),
            ),
          ),
        ),
        reducedMotion: reducedMotion,
        scale: scale,
        brightness: brightness,
      ),
    );
    await tester.tap(find.text('支付入口'));
    await tester.pumpAndSettle();
  }

  testWidgets('首次设置密码须二次输入，保存后回到付款确认且不自动扣款', (tester) async {
    final payment = _Payment();
    await openPayment(tester, payment, needsPassword: true);
    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.enterText(find.byType(TextField).last, '123456');
    await tester.pumpAndSettle();
    final save = find.text(
      tester
          .element(find.byType(Scaffold).first)
          .l10n
          .metaverse_nativePasswordSave,
    );
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(payment.passwords, 1);
    expect(payment.payments, 0);
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('原生付款展示商户与实际金额，取消不扣款', (tester) async {
    final payment = _Payment();
    await openPayment(tester, payment);
    expect(find.text('12.50 LDC'), findsOneWidget);
    expect(find.text('LD士多 · seller'), findsOneWidget);
    expect(payment.payments, 0);
    expect(
      tester
          .widget<AppSheetScaffold>(find.byType(AppSheetScaffold))
          .showDragHandle,
      isTrue,
    );
    expect(find.byType(PinInput), findsOneWidget);
    await snapshot(tester, 'payment');
    await tester.tap(
      find.byTooltip(
        tester.element(find.byType(Scaffold).first).l10n.common_cancel,
      ),
    );
    await tester.pumpAndSettle();
    expect(payment.payments, 0);
    expect(payment.refreshes, 0);
  });

  testWidgets('密码输入不提交，显式确认后只扣一次并回查原单', (tester) async {
    final payment = _Payment()..pending = Completer<void>();
    await openPayment(tester, payment);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    expect(payment.payments, 0);
    final confirm = find.text(
      tester
          .element(find.byType(Scaffold).first)
          .l10n
          .metaverse_nativePayConfirm('12.50'),
    );
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pump();
    expect(payment.payments, 1);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.ancestor(of: confirm, matching: find.byType(FilledButton)),
          )
          .onPressed,
      isNull,
    );
    payment.pending!.complete();
    await tester.pumpAndSettle();
    expect(payment.refreshes, 1);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(M3eSuccessIndicator), findsOneWidget);
    await snapshot(tester, 'payment-success');
    await tester.tap(
      find.text(
        tester
            .element(find.byType(Scaffold).first)
            .l10n
            .metaverse_nativePayViewOrder,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(M3eSuccessIndicator), findsNothing);
  });

  testWidgets('付款响应丢失后仅提供查单，查单恢复也不重放扣款', (tester) async {
    final payment = _Payment()
      ..timeout = true
      ..refreshFails = true;
    await openPayment(tester, payment);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    final confirm = find.text(
      tester
          .element(find.byType(Scaffold).first)
          .l10n
          .metaverse_nativePayConfirm('12.50'),
    );
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(payment.payments, 1);
    expect(find.byType(TextField), findsNothing);
    expect(
      find.text(
        tester
            .element(find.byType(Scaffold).first)
            .l10n
            .metaverse_nativePayPending,
      ),
      findsOneWidget,
    );
    payment.refreshFails = false;
    await tester.tap(
      find.text(
        tester
            .element(find.byType(Scaffold).first)
            .l10n
            .metaverse_nativePayCheck,
      ),
    );
    await tester.pumpAndSettle();
    expect(payment.payments, 1);
    expect(payment.refreshes, 2);
    expect(find.byType(M3eSuccessIndicator), findsOneWidget);
  });

  testWidgets('超时后订单仍待支付时保留查单，成功态由服务端状态确认', (tester) async {
    final payment = _Payment()
      ..timeout = true
      ..status = 'pending';
    await openPayment(tester, payment);
    final l = tester.element(find.byType(Scaffold).first).l10n;
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    await tester.tap(find.text(l.metaverse_nativePayConfirm('12.50')));
    await tester.pumpAndSettle();
    expect(find.byType(M3eSuccessIndicator), findsNothing);
    expect(find.byType(PinInput), findsNothing);
    expect(find.text(l.metaverse_nativePayPending), findsOneWidget);
    payment.status = 'completed';
    await tester.tap(find.text(l.metaverse_nativePayCheck));
    await tester.pumpAndSettle();
    expect(find.byType(M3eSuccessIndicator), findsOneWidget);
    expect(payment.payments, 1);
  });

  testWidgets('减少动态效果时直接完成，商户刷新失败保留收银台成功结果', (tester) async {
    final payment = _Payment()..refreshFails = true;
    await openPayment(tester, payment, reducedMotion: true);
    final l = tester.element(find.byType(Scaffold).first).l10n;
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    await tester.tap(find.text(l.metaverse_nativePayConfirm('12.50')));
    await tester.pumpAndSettle();
    expect(find.text(l.metaverse_nativePaySuccess), findsOneWidget);
    expect(find.text(l.metaverse_nativePayPending), findsNothing);
    expect(payment.payments, 1);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('内置支付键盘输入与删除，六位输入完成不自动付款 $brightness', (tester) async {
      final payment = _Payment();
      await openPayment(tester, payment, brightness: brightness);
      for (final digit in '1234567'.split('')) {
        await tester.tap(find.byKey(ValueKey('ldc-key-$digit')));
        await tester.pump();
      }
      final input = tester.widget<TextField>(find.byType(TextField));
      expect(input.controller!.text, '123456');
      expect(input.keyboardType, TextInputType.none);
      expect(
        tester.testTextInput.setClientArgs?['inputType'],
        TextInputType.none.toJson(),
      );
      expect(payment.payments, 0);
      await tester.tap(find.byKey(const ValueKey('ldc-key-delete')));
      await tester.pump();
      expect(input.controller!.text, '12345');
      await snapshot(tester, 'payment-keypad-${brightness.name}');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('内置键盘设置密码可切换两次输入，保存后等待明确付款', (tester) async {
    final payment = _Payment();
    await openPayment(tester, payment, needsPassword: true);
    for (final digit in '123456123456'.split('')) {
      await tester.tap(find.byKey(ValueKey('ldc-key-$digit')));
      await tester.pump();
    }
    expect(
      tester.testTextInput.setClientArgs?['inputType'],
      TextInputType.none.toJson(),
    );
    expect(payment.payments, 0);
    for (final input in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(input.controller!.text, '123456');
    }
    final l = tester.element(find.byType(Scaffold).first).l10n;
    await tester.tap(find.text(l.metaverse_nativePasswordSave));
    await tester.pumpAndSettle();
    expect(payment.passwords, 1);
    expect(payment.payments, 0);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('支付结果待确认时系统返回也向订单页传递状态', (tester) async {
    final payment = _Payment()
      ..timeout = true
      ..status = 'pending';
    Map<String, Object?>? result;
    await openPayment(tester, payment, onResult: (value) => result = value);
    final l = tester.element(find.byType(Scaffold).first).l10n;
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    await tester.tap(find.text(l.metaverse_nativePayConfirm('12.50')));
    await tester.pumpAndSettle();
    await navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(result, {'state': 'pending'});
    expect(payment.payments, 1);
    expect(payment.refreshes, 1);
  });

  testWidgets('密码输入仅保留六位数字，删除与清空同步格子，读屏隐藏原文', (tester) async {
    await openPayment(tester, _Payment());
    await tester.enterText(find.byType(TextField), '1a23456789');
    await tester.pump();
    final input = tester.widget<TextField>(find.byType(TextField));
    expect(input.controller!.text, '123456');
    expect(input.obscureText, isTrue);
    expect(find.text('•'), findsNWidgets(6));
    await tester.enterText(find.byType(TextField), '123');
    await tester.pump();
    expect(find.text('•'), findsNWidgets(3));
    input.controller!.clear();
    await tester.pump();
    expect(find.text('•'), findsNothing);
  });

  for (final width in [390.0, 800.0]) {
    testWidgets('插件弹层复用统一外壳 $width', (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(
          const MetaversePluginPage(
            pluginId: 'test.missing',
            page: 'details',
            modal: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final shell = tester.widget<AppSheetScaffold>(
        find.byType(AppSheetScaffold),
      );
      expect(shell.showDragHandle, width < 600);
      expect(shell.expandToFill, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  for (final failure in ['network', 'decode']) {
    testWidgets('插件图片 $failure 失败可点击重试', (tester) async {
      var requests = 0;
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      final runtime = Runtime()
        ..update(
          metaverseWidgetLibraryName,
          createMetaverseWidgetLibrary(
            loadImage: (_) async {
              requests++;
              if (requests == 1) {
                if (failure == 'network') throw StateError('offline');
                return Uint8List(2);
              }
              return png;
            },
          ),
        )
        ..update(
          metaversePluginLibraryName,
          parseLibraryFile('''
import fluxdo;
widget Thumbnail = Image(url: "https://images.example.org/product.png", width: 96.0, height: 96.0);
'''),
        );
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        app(
          RemoteWidget(
            runtime: runtime,
            widget: const FullyQualifiedWidgetName(
              metaversePluginLibraryName,
              'Thumbnail',
            ),
            data: DynamicContent(),
            onEvent: (_, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final retry = find.byTooltip(S.current.common_retry);
      expect(retry, findsOneWidget);
      expect(requests, 1);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(requests, 2);
      expect(retry, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('通用搜索组件提交、清空与脚本更新保留标准输入行为', (tester) async {
    final runtime = Runtime()
      ..update(
        metaverseWidgetLibraryName,
        createMetaverseWidgetLibrary(loadImage: (_) async => Uint8List(0)),
      )
      ..update(
        metaversePluginLibraryName,
        parseLibraryFile('''
import fluxdo;
widget Search = SearchInput(hint: "搜索", value: data.query,
  onChanged: event "change" {}, onSubmitted: event "submit" {});
'''),
      );
    addTearDown(runtime.dispose);
    final content = DynamicContent({'query': ''});
    final events = <String>[];
    await tester.pumpWidget(
      app(
        RemoteWidget(
          runtime: runtime,
          widget: const FullyQualifiedWidgetName(
            metaversePluginLibraryName,
            'Search',
          ),
          data: content,
          onEvent: (name, arguments) =>
              events.add('$name:${arguments['value']}'),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '卡密');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(find.byType(InputFieldShell), findsOneWidget);
    expect(events, ['change:卡密', 'submit:卡密']);
    await tester.tap(
      find.byTooltip(
        tester.element(find.byType(Scaffold).first).l10n.common_clear,
      ),
    );
    await tester.pump();
    expect(events.sublist(2), ['change:', 'submit:']);
    content.update('query', '新查询');
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '新查询',
    );
  });

  for (final width in [320.0, 390.0, 800.0]) {
    testWidgets('安装权限可滚动且底部确认始终可点击 $width', (tester) async {
      tester.view.physicalSize = Size(width, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final manifest = MetaversePluginManifest.parse(
        jsonDecode(File('plugins/ld-store/plugin.json').readAsStringSync()),
      );
      bool? result;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showMetaversePluginInstallSheet(
                    context,
                    manifest,
                    isUpdate: true,
                  ),
              child: const Text('安装入口'),
            ),
          ),
          scale: width == 320 ? 1.6 : 1,
        ),
      );
      await tester.tap(find.text('安装入口'));
      await tester.pumpAndSettle();
      final l = tester.element(find.byType(Scaffold).first).l10n;
      final update = find.widgetWithText(
        FilledButton,
        l.metaverse_pluginUpdate,
      );
      expect(update.hitTestable(), findsOneWidget);
      final list = find.byType(ListView);
      final controller = tester.widget<ListView>(list).controller!;
      await tester.drag(list, const Offset(0, -900));
      await tester.pumpAndSettle();
      await tester.drag(list, const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
      expect(update.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (width == 390) {
        controller.jumpTo(0);
        await snapshot(tester, 'install-review');
      }
      await tester.tap(update);
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(find.text('安装入口'), findsOneWidget);
    });
  }

  for (final mode in ['data', 'error', 'loading']) {
    testWidgets('打赏入口并入余额卡片并在 $mode 状态保留', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(
          ProviderScope(
            overrides: [
              ldcUserInfoProvider.overrideWith(() => _FixtureBalance(mode)),
              currentUserProvider.overrideWith(_FixtureUser.new),
              ldcRewardCredentialsProvider.overrideWith(_NoReward.new),
            ],
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: LdcBalanceCard(
                footer: LdcRewardConfigTile(embedded: true),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      if (mode != 'loading') await tester.pumpAndSettle();
      expect(find.byType(Card), findsOneWidget);
      final l = tester.element(find.byType(Scaffold).first).l10n;
      expect(find.text(l.reward_title), findsOneWidget);
      if (mode == 'data') await snapshot(tester, 'ldc-reward-merged');
      await tester.tap(find.text(l.reward_title));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  }

  for (final choice in ['bundled', 'file', 'url']) {
    testWidgets('添加插件分组选择 $choice，小屏大字可操作', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final manifest = MetaversePluginManifest.parse(
        jsonDecode(File('plugins/ld-store/plugin.json').readAsStringSync()),
      );
      final package = MetaversePluginPackage(
        manifest: manifest,
        source: 'asset:plugins/ld-store/plugin.json',
        code: (script: '', ui: ''),
      );
      PluginInstallChoice? result;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showMetaversePluginPicker(
                context,
                [package],
                installedIds: {manifest.id},
              ),
              child: const Text('添加入口'),
            ),
          ),
          scale: 1.4,
        ),
      );
      await tester.tap(find.text('添加入口'));
      await tester.pumpAndSettle();
      final l = tester.element(find.byType(Scaffold).first).l10n;
      expect(
        tester
            .widget<AppSheetScaffold>(find.byType(AppSheetScaffold))
            .showDragHandle,
        isTrue,
      );
      if (choice == 'bundled') {
        await snapshot(tester, 'plugin-picker');
        await tester.tap(find.widgetWithText(ListTile, manifest.name));
        await tester.pumpAndSettle();
        expect(result?.bundled, same(package));
      } else if (choice == 'file') {
        await tester.ensureVisible(find.text(l.metaverse_importFile));
        await tester.tap(find.text(l.metaverse_importFile));
        await tester.pumpAndSettle();
        expect(result, (url: null, bundled: null));
      } else {
        await tester.ensureVisible(find.text(l.metaverse_installFromUrl));
        await tester.tap(find.text(l.metaverse_installFromUrl));
        await tester.pumpAndSettle();
        tester.view.viewInsets = const FakeViewPadding(bottom: 240);
        addTearDown(tester.view.resetViewInsets);
        await tester.enterText(
          find.byType(TextField),
          'http://example.com/plugin.json',
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, l.common_continue),
              )
              .onPressed,
          isNull,
        );
        await tester.enterText(
          find.byType(TextField),
          'https://example.com/plugin.json',
        );
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pumpAndSettle();
        expect(result?.url, 'https://example.com/plugin.json');
      }
      expect(find.text('添加入口'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final scale in [1.0, 1.4]) {
    testWidgets('实际插件卡片的登录错误完整显示 scale=$scale', (tester) async {
      await preferences.clear();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const error = '登录在「服务回调」阶段收到异常响应（HTTP 403），请重试。';
      final store = _MemoryCodeStore(preferences)
        ..written = (
          ui: File('plugins/ld-store/ui.rfwtxt').readAsStringSync(),
          script:
              '''
            fluxdo.on('card.load', ctx => {
              ctx.setData('loginLabel', '登录士多');
              ctx.setData('loginError', ${jsonEncode(error)});
              ctx.setData('authorized', false);
              ctx.setData('authBusy', false);
            });
          ''',
        );
      final plugin = InstalledMetaversePlugin(
        manifest: MetaversePluginManifest.parse(
          jsonDecode(File('plugins/ld-store/plugin.json').readAsStringSync()),
        ),
        source: 'asset:plugins/ld-store/plugin.json',
        enabled: true,
      );
      await store.saveIndex([plugin]);
      await tester.pumpWidget(
        app(
          SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: MetaversePluginCard(
                service: MetaversePluginService(plugin),
                host: MetaverseCardHost(
                  isProcessing: false,
                  onDisable: () {},
                  onReauthorize: () {},
                ),
              ),
            ),
          ),
          pluginStore: store,
          scale: scale,
        ),
      );
      final errorText = find.text(error);
      // QuickJS 运行在真实 isolate；允许其消息进入测试的虚拟时钟。
      for (
        var attempt = 0;
        attempt < 40 && errorText.evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(errorText, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(errorText);
      // 检查所有文字落在祖先真正的裁切区域内，能复现内层圆角削字问题。
      RenderObject? child = paragraph;
      RenderObject? parent = child.parent;
      while (parent != null) {
        if (parent is RenderClipRRect) {
          final rect = MatrixUtils.transformRect(
            paragraph.getTransformTo(parent),
            paragraph.paintBounds,
          );
          final clip = parent.borderRadius
              .resolve(TextDirection.ltr)
              .toRRect(Offset.zero & parent.size);
          for (final point in [
            rect.topLeft,
            rect.bottomLeft,
            rect.topRight,
            rect.bottomRight,
          ]) {
            expect(clip.contains(point), isTrue, reason: '文字边缘被圆角裁掉');
          }
        }
        child = parent;
        parent = child.parent;
      }
      expect(tester.takeException(), isNull);
      await snapshot(tester, 'login-error-$scale');
      await tester.pumpWidget(const SizedBox());
      // 脚本引擎退出消息未返回时，宿主在两秒后兜底释放 isolate。
      await tester.pump(const Duration(seconds: 2));
    });
  }

  for (final enabled in [true, false]) {
    for (final confirm in [true, false]) {
      testWidgets('服务卡片直接更新旧清单 enabled=$enabled confirm=$confirm', (
        tester,
      ) async {
        await preferences.clear();
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final newJson = jsonDecode(
          File('plugins/ld-store/plugin.json').readAsStringSync(),
        ) as Map<String, dynamic>;
        final latest = MetaversePluginPackage(
          manifest: MetaversePluginManifest.parse(newJson),
          source: 'asset:plugins/ld-store/plugin.json',
          code: (script: '', ui: ''),
        );
        final oldJson = jsonDecode(jsonEncode(newJson)) as Map<String, dynamic>;
        oldJson['version'] = '1.6.0';
        (oldJson['permissions']['network'] as List).remove('api.ldspro.qzz.io');
        (oldJson['permissions']['connect'] as List).remove('https://api.ldspro.qzz.io/api/auth/callback');
        final store = _MemoryCodeStore(preferences);
        await store.saveIndex([
          InstalledMetaversePlugin(
            manifest: MetaversePluginManifest.parse(oldJson),
            source: latest.source,
            enabled: enabled,
            suspendedReason: enabled ? '测试暂停运行' : null,
          ),
        ]);
        await tester.pumpWidget(
          app(const MetaversePage(), pluginStore: store, bundled: [latest]),
        );
        await tester.pumpAndSettle();
        final l = tester.element(find.byType(Scaffold).first).l10n;
        final update = find.text(
          l.metaverse_pluginUpdateTo(latest.manifest.version),
        );
        await tester.ensureVisible(update);
        expect(update.hitTestable(), findsOneWidget);
        expect(store.written, isNull);
        await tester.tap(update);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(AppSheetScaffold), findsOneWidget);
        expect(store.loadIndex().single.manifest.version, '1.6.0');
        await tester.tap(
          confirm
              ? find.widgetWithText(FilledButton, l.metaverse_pluginUpdate)
              : find.widgetWithText(TextButton, l.common_cancel),
        );
        await tester.pumpAndSettle();
        expect(
          store.loadIndex().single.manifest.version,
          confirm ? latest.manifest.version : '1.6.0',
        );
        expect(store.written != null, confirm);
        expect(update, confirm ? findsNothing : findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final confirm in [true, false]) {
    testWidgets('生物识别付款确认 $confirm，取消保留密码入口', (tester) async {
      var confirmed = true;
      var authentications = 0;
      final biometric = LdcBiometricPayment(
        accountId: 501,
        store: InMemorySecretStore(),
        preferences: preferences,
        checkSession: () async {},
        available: () async => true,
        authenticate: (_) async {
          authentications++;
          return confirmed;
        },
      );
      await biometric.enable('123456', 'setup');
      confirmed = confirm;
      final payment = _Payment();
      await openPayment(tester, payment, biometrics: biometric);
      expect(payment.payments, 0);
      expect(authentications, 1);
      final l = tester.element(find.byType(Scaffold).first).l10n;
      final pay = find.widgetWithText(FilledButton, l.ldc_biometricPay);
      final switchMode = find.byKey(
        const ValueKey('ldc-switch-authentication'),
      );
      final title = find.text(l.metaverse_nativePayTitle);
      expect(
        tester.getCenter(switchMode).dx,
        greaterThan(tester.getCenter(title).dx),
      );
      expect(
        (tester.getCenter(switchMode).dy - tester.getCenter(title).dy).abs(),
        lessThan(1),
      );
      await tester.tap(switchMode);
      await tester.pumpAndSettle();
      expect(find.byType(PinInput), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ldc-key-1')));
      await tester.pump();
      await tester.tap(switchMode);
      await tester.pumpAndSettle();
      expect(find.byType(PinInput), findsNothing);
      expect(authentications, 1);
      expect(payment.payments, 0);
      if (confirm) await snapshot(tester, 'payment-biometric');
      await tester.ensureVisible(pay);
      await tester.tap(pay);
      await tester.pumpAndSettle();
      expect(authentications, 2);
      expect(payment.payments, confirm ? 1 : 0);
      expect(payment.refreshes, confirm ? 1 : 0);
      if (confirm) {
        expect(find.byType(M3eSuccessIndicator), findsOneWidget);
      } else {
        expect(find.byType(PinInput), findsOneWidget);
        expect(find.text(l.ldc_biometricFailed), findsOneWidget);
      }
    });
  }

  for (final setupAllowed in [true, false]) {
    testWidgets('主动开启生物识别 $setupAllowed，仅在密码付款确认后保存', (tester) async {
      await preferences.clear();
      var authentications = 0;
      final payment = _Payment()..pending = Completer<void>();
      final biometric = LdcBiometricPayment(
        accountId: 601,
        store: InMemorySecretStore(),
        preferences: preferences,
        checkSession: () async {},
        available: () async => true,
        authenticate: (_) async {
          expect(payment.payments, 1);
          expect(payment.pending!.isCompleted, isTrue);
          authentications++;
          return setupAllowed;
        },
      );
      await openPayment(tester, payment, biometrics: biometric);
      final l = tester.element(find.byType(Scaffold).first).l10n;
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
      await tester.tap(find.byType(CheckboxListTile));
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pump();
      final pay = find.text(l.metaverse_nativePayConfirm('12.50'));
      await tester.ensureVisible(pay);
      await tester.tap(pay);
      await tester.pump();
      expect(authentications, 0);
      expect(biometric.enabled, isFalse);
      payment.pending!.complete();
      await tester.pumpAndSettle();
      expect(authentications, 1);
      expect(biometric.enabled, setupAllowed);
      expect(find.byType(M3eSuccessIndicator), findsOneWidget);
      expect(
        find.text(
          setupAllowed ? l.ldc_biometricEnabled : l.ldc_biometricSaveFailed,
        ),
        findsOneWidget,
      );
    });
  }

  testWidgets('付款响应丢失时只查单，不开启生物识别或重放付款', (tester) async {
    await preferences.clear();
    var authentications = 0;
    final payment = _Payment()..timeout = true;
    final biometric = LdcBiometricPayment(
      accountId: 602,
      store: InMemorySecretStore(),
      preferences: preferences,
      checkSession: () async {},
      available: () async => true,
      authenticate: (_) async {
        authentications++;
        return true;
      },
    );
    await openPayment(tester, payment, biometrics: biometric);
    final l = tester.element(find.byType(Scaffold).first).l10n;
    await tester.tap(find.byType(CheckboxListTile));
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    final pay = find.text(l.metaverse_nativePayConfirm('12.50'));
    await tester.ensureVisible(pay);
    await tester.tap(pay);
    await tester.pumpAndSettle();
    expect(payment.payments, 1);
    expect(payment.refreshes, 1);
    expect(authentications, 0);
    expect(biometric.enabled, isFalse);
    expect(find.byType(M3eSuccessIndicator), findsOneWidget);
  });

  testWidgets('窄屏大字体下内置键盘、付款和关闭入口可见', (tester) async {
    await preferences.clear();
    final payment = _Payment();
    final biometric = LdcBiometricPayment(
      accountId: 603,
      store: InMemorySecretStore(),
      preferences: preferences,
      checkSession: () async {},
      available: () async => true,
      authenticate: (_) async => true,
    );
    await openPayment(
      tester,
      payment,
      biometrics: biometric,
      size: const Size(320, 640),
      scale: 1.6,
    );
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pumpAndSettle();
    final l = tester.element(find.byType(Scaffold).first).l10n;
    final pay = find.text(l.metaverse_nativePayConfirm('12.50'));
    await tester.ensureVisible(pay);
    await tester.pumpAndSettle();
    expect(pay.hitTestable(), findsOneWidget);
    final cancel = find.byTooltip(l.common_cancel);
    await tester.ensureVisible(cancel);
    await tester.pumpAndSettle();
    expect(cancel.hitTestable(), findsOneWidget);
    expect(
      find.byKey(const ValueKey('ldc-key-0')).hitTestable(),
      findsOneWidget,
    );
    expect(
      tester.testTextInput.setClientArgs?['inputType'],
      TextInputType.none.toJson(),
    );
    await snapshot(tester, 'payment-large-text');
    expect(tester.takeException(), isNull);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(payment.payments, 0);
  });

  final data = <String, Object?>{
    'loading': false,
    'loginLabel': '登录士多',
    'loginError': '',
    'authBusy': false,
    'ready': true,
    'error': '',
    'message': '',
    'filters': false,
    'filterLabel': '筛选与排序',
    'selection': '全部 · 默认排序',
    'title': '开发者工具包',
    'seller': '卖家 · tester',
    'price': '12.50 LDC',
    'image': '',
    'buy': true,
    'description': '包含开发工具使用说明。兑换后可在订单中查看交付内容。',
    'details': '工具 · 库存 18 · 已售 32',
    'conditions': '等级要求 TL1 · 自动交付',
    'quantity': '1',
    'estimate': '12.50 LDC',
    'canRemove': false,
    'canAdd': true,
    'nativeOrder': true,
    'orderState': 'idle',
    'canSubmit': true,
    'quoteReady': true,
    'canQuote': true,
    'quoteNote': '',
    'orderNote': '',
    'payable': '12.50 LDC',
    'couponRows': [
      {'id': '1', 'label': '新人券 · 12.50 LDC', 'selected': true},
    ],
    'noCoupon': false,
    'state': '待支付',
    'amount': '12.50 LDC',
    'orderTitle': '开发者工具包',
    'orderNo': 'LD202611120042',
    'delivery': '自动发货',
    'canPay': true,
    'paymentAvailable': true,
    'paymentNote': '',
    'orderFilters': [
      {'status': '', 'label': '全部', 'selected': true},
      {'status': 'pending', 'label': '待支付', 'selected': false},
    ],
    'rows': [
      {
        'id': '1',
        'title': '开发者工具包',
        'price': '12.50 LDC',
        'stock': '库存 18',
        'image': '',
        'no': 'LD202611120042',
        'state': '待支付',
        'amount': '12.50 LDC',
      },
      {
        'id': '2',
        'title': '社区数字纪念卡',
        'price': '3.00 LDC',
        'stock': '库存 不限',
        'image': '',
        'no': 'LD202611110039',
        'state': '已完成',
        'amount': '3.00 LDC',
      },
    ],
  };
  for (final brightness in Brightness.values) {
    for (final width in [320.0, 390.0, 800.0]) {
      testWidgets('士多页面 ${brightness.name} $width 布局与底部操作区', (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final runtime = Runtime()
          ..update(
            metaverseWidgetLibraryName,
            createMetaverseWidgetLibrary(loadImage: (_) async => Uint8List(0)),
          )
          ..update(
            metaversePluginLibraryName,
            parseLibraryFile(
              File('plugins/ld-store/ui.rfwtxt')
                  .readAsStringSync()
                  .replaceAll('\r\n', '\n'),
            ),
          );
        addTearDown(runtime.dispose);
        for (final name in [
          'Card',
          'Market',
          'Product',
          'Review',
          'BuyerOrders',
          'BuyerOrder',
        ]) {
          await tester.pumpWidget(
            app(
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: name == 'Card' ? 32 : 0,
                ),
                child: RemoteWidget(
                  runtime: runtime,
                  widget: FullyQualifiedWidgetName(
                    metaversePluginLibraryName,
                    name,
                  ),
                  data: DynamicContent(data),
                ),
              ),
              brightness: brightness,
              scale: width == 320 ? 1.4 : 1,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: name);
          if (width == 390) {
            await snapshot(tester, '${name.toLowerCase()}-${brightness.name}');
          }
        }
      });
    }
  }
}
