import 'dart:async';
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
import 'package:fluxdo/modules/metaverse/plugin/metaverse_payment.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_payment_sheet.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_widget_library.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/ldc_payment_service.dart';
import 'package:fluxdo/theme/app_colors.dart';
import 'package:fluxdo/theme/app_theme.dart';
import 'package:rfw/rfw.dart';
import 'package:rfw/formats.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Payment implements MetaversePayment {
  int payments = 0, refreshes = 0;
  int passwords = 0;
  bool timeout = false, refreshFails = false;
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
  Future<Map> request(String no, String action) async {
    expect(action, 'refresh');
    refreshes++;
    if (refreshFails) throw StateError('offline');
    return {'status': 'completed'};
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
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      child: RepaintBoundary(
        key: captureKey,
        child: TranslationProvider(
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: snapshots
                ? theme.copyWith(
                    textTheme: theme.textTheme.apply(fontFamily: 'ReviewFont'),
                  )
                : theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
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
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => showMetaversePaymentSheet(
                context,
                payment: payment,
                orderNo: payment.order.orderNo,
                username: 'tester',
                needsPassword: needsPassword,
              ),
              child: const Text('支付入口'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('支付入口'));
    await tester.pumpAndSettle();
  }

  testWidgets('首次设置密码须二次输入，保存后回到付款确认且不自动扣款', (tester) async {
    final payment = _Payment();
    await openPayment(tester, payment, needsPassword: true);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
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
    await snapshot(tester, 'payment');
    await tester.tap(
      find.text(tester.element(find.byType(Scaffold).first).l10n.common_cancel),
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
  });

  final data = <String, Object?>{
    'loading': false,
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
          'Market',
          'Product',
          'Review',
          'BuyerOrders',
          'BuyerOrder',
        ]) {
          await tester.pumpWidget(
            app(
              RemoteWidget(
                runtime: runtime,
                widget: FullyQualifiedWidgetName(
                  metaversePluginLibraryName,
                  name,
                ),
                data: DynamicContent(data),
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
