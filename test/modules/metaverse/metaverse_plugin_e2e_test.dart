import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_host.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_checkout_types.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_plugin_dialogs.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_installer.dart';
import 'package:fluxdo/modules/metaverse/plugin/providers/metaverse_plugin_providers.dart';
import 'package:fluxdo/modules/metaverse/metaverse_link_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_service_session.dart';
import 'package:fluxdo/services/navigation/app_route_observer.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/flutter_js_script_engine.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/metaverse_plugin_runtime.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/metaverse_script_engine.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_plugin_surface_view.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用真实 JS 引擎跑 docs/examples/metaverse-plugin 里的示例插件。
///
/// 网络是假的（固定响应），其余——清单、界面描述、脚本、宿主桥、界面渲染
/// ——都是真实实现。宿主测试环境默认加载不到 QuickJS 动态库，那时整组跳过：
/// `PATH="build/windows/x64/runner/Debug:$PATH" flutter test <本文件>`
const _dir = 'docs/examples/metaverse-plugin';

class _MemorySecrets implements SecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(SecretKey key) async => values[key.storageKey];

  @override
  Future<void> write(SecretKey key, String value) async =>
      values[key.storageKey] = value;

  @override
  Future<void> delete(SecretKey key) async => values.remove(key.storageKey);

  @override
  Future<void> deleteScope(SecretScope scope) async {}

  @override
  Future<SecretStoreAvailability> checkAvailability() async =>
      SecretStoreAvailability.available;
}

class _Api implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int balance = 128;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body = options.uri.path.startsWith('/v1/orders/')
        ? {
            'status': '已发货',
            'items': [
              {'name': '机械键盘', 'price': '¥399'},
              {'name': '键帽', 'price': '¥59'},
            ],
          }
        : {'balance': balance};
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 从发布目录读取插件文件。商品接口返回固定数据，不创建订单。
class _ShopApi extends _Api {
  bool connectTimeout = false;
  bool expired = false;
  String orderStatus = 'completed';
  Map<String, Object?> productFields = {};
  bool includeBestCoupon = true;
  bool simulateCheckout = false;
  bool lookupExists = false;
  Completer<void>? waitQuote;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final uri = options.uri;
    if (connectTimeout) {
      throw DioException.connectionTimeout(
        timeout: const Duration(seconds: 5),
        requestOptions: options,
      );
    }
    if (uri.host == 'packages.example.org') {
      final file = File('plugins/ld-store/${uri.pathSegments.last}');
      return ResponseBody.fromString(file.readAsStringSync(), 200);
    }
    if (uri.path == '/api/shop/orders/quote') {
      expect(options.method, 'POST');
      expect(options.headers['Authorization'], 'Bearer fixture-session');
      final payload = jsonDecode(options.data as String);
      final q = payload['quantity'] as int;
      if (waitQuote != null) await waitQuote!.future;
      return ResponseBody.fromString(
        jsonEncode({
          'success': true,
          'data': {
            'productId': payload['productId'],
            'quantity': q,
            'productSubtotal': 12 * q,
            'payableAmount': 12 * q,
            'coupons': [
              {
                'claimId': 9,
                'eligible': true,
                'payableAmount': 5 * q,
                'campaign': {'name': '普通券'},
              },
              if (includeBestCoupon)
                {
                  'claimId': 8,
                  'eligible': true,
                  'payableAmount': q,
                  'campaign': {'name': '模拟券'},
                },
            ],
          },
        }),
        200,
      );
    }
    if (simulateCheckout &&
        uri.path == '/api/shop/orders' &&
        options.method == 'POST') {
      expect(options.headers['Authorization'], 'Bearer fixture-session');
      throw DioException.receiveTimeout(
        timeout: const Duration(seconds: 1),
        requestOptions: options,
      );
    }
    if (simulateCheckout &&
        uri.path.startsWith('/api/shop/order-submissions/')) {
      expect(options.method, 'GET');
      expect(options.headers['Authorization'], 'Bearer fixture-session');
      return ResponseBody.fromString(
        jsonEncode({
          'success': true,
          'data': {
            'exists': lookupExists,
            if (lookupExists) 'order': {'orderNo': 'FIX-1'},
          },
        }),
        200,
      );
    }
    if (uri.path.startsWith('/api/shop/orders')) {
      expect(options.method, 'GET');
      expect(options.headers['Authorization'], 'Bearer fixture-session');
      expect(uri.queryParameters['role'], 'buyer');
      if (expired) return ResponseBody.fromString('{}', 401);
      final page = int.tryParse(uri.queryParameters['page'] ?? '1') ?? 1;
      final row = {
        'orderNo': 'FIX-$page',
        'productName': '买家商品 $page',
        'status': orderStatus,
        'amount': 0,
        'deliveryType': 'auto',
        'deliveryContent': '仅用于离线测试的交付说明',
      };
      final data = uri.path == '/api/shop/orders'
          ? {
              'orders': [row],
              'pagination': {'totalPages': 2},
            }
          : {'order': row};
      return ResponseBody.fromString(
        jsonEncode({'success': true, 'data': data}),
        200,
      );
    }
    final product = {
      'id': 'd553779c-83ef-48e4-98c5-a8446c78d5ec',
      'name': '测试商品',
      'price': 12,
      'availableStock': 3,
      'category_name': '咨询',
      'description': '测试说明',
      'canPurchase': true,
      ...productFields,
    };
    final data = switch (uri.path) {
      '/api/shop/categories' => {
        'categories': [
          {'id': 4, 'name': '咨询'},
        ],
      },
      '/api/shop/products' => {
        'products': [product],
        'pagination': {'totalPages': 1},
      },
      '/api/shop/products/d553779c-83ef-48e4-98c5-a8446c78d5ec' => {
        'product': product,
      },
      _ => throw StateError('意外请求：${uri.path}'),
    };
    return ResponseBody.fromString(
      jsonEncode({'success': true, 'data': data}),
      200,
    );
  }
}

class _Delegate extends MetaversePluginHostDelegate {
  final opened = <String>[];
  final pages = <String>[];
  final suspended = <String>[];
  int authRequests = 0;
  int? accountId;
  @override
  int? currentAccountId() => accountId;
  final payments = <String>[];

  @override
  Future<Object?> payOrder(
    BuildContext context,
    String orderNo, {
    bool cancel = false,
  }) async {
    payments.add('${cancel ? 'cancel' : 'pay'}:$orderNo');
    return {'state': 'checking'};
  }

  @override
  String? currentUsername() => 'alice';

  @override
  Future<bool> confirmOrder(
    BuildContext context,
    MetaverseCheckoutGrant grant,
    MetaverseOrderIntent intent,
  ) => showMetaverseOrderConfirmation(context, grant, intent);

  @override
  Future<bool> requestAuth(BuildContext context, _) async {
    authRequests++;
    return true;
  }

  @override
  void openPage(BuildContext context, _, String page, Map<String, Object?> p) =>
      pages.add(page);

  @override
  Future<void> openUrl(BuildContext context, Uri url) async =>
      opened.add(url.toString());

  @override
  Future<void> openWebSession(BuildContext context, Uri url) async =>
      opened.add(url.toString());

  @override
  void toast(String message, String type) {}

  @override
  void onSuspended(String pluginId, String reason) => suspended.add(reason);
}

Future<void> main() async {
  String? skip;
  try {
    (await IsolateScriptEngine.spawn()).dispose();
  } on MetaverseScriptException catch (error) {
    skip = '脚本引擎原生库不可用: $error';
  }

  final manifest = MetaversePluginManifest.parse(
    jsonDecode(File('$_dir/plugin.json').readAsStringSync()),
    reservedHosts: const ['linux.do'],
  );
  final ui = File('$_dir/ui.rfwtxt').readAsStringSync();

  group('示例插件端到端', skip: skip, () {
    late Directory root;
    late MetaversePluginStore store;
    late _Api api;
    late _Delegate delegate;
    late MetaversePluginHost host;

    Future<void> install({String? script}) async {
      await store.writeCode(manifest.id, (
        ui: ui,
        script: script ?? File('$_dir/main.js').readAsStringSync(),
      ));
    }

    MetaversePluginHost createHost({
      Duration timeout = const Duration(seconds: 5),
    }) => MetaversePluginHost(
      manifest: manifest,
      store: store,
      network: MetaversePluginNetwork(
        dio: Dio(BaseOptions(validateStatus: (_) => true))
          ..httpClientAdapter = api,
        lookup: (_) async => [InternetAddress('93.184.216.34')],
      ),
      engineFactory: () => IsolateScriptEngine.spawn(timeout: timeout),
      delegate: delegate,
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      root = Directory.systemTemp.createTempSync('metaverse_plugin_test');
      store = MetaversePluginStore(
        preferences: await SharedPreferences.getInstance(),
        secretStore: _MemorySecrets(),
        rootDirectory: () async => root,
      );
      api = _Api();
      delegate = _Delegate();
      await install();
      await store.writeToken(manifest.id, 'k-123');
      host = createHost();
    });

    tearDown(() {
      host.shutdown();
      try {
        root.deleteSync(recursive: true);
      } catch (_) {
        // Windows 上刚关闭的文件偶尔仍被占用，临时目录交给系统清理。
      }
    });

    Widget app(Widget child) => TranslationProvider(
      child: MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

    /// 等插件界面到达某个状态。
    ///
    /// testWidgets 跑在假时钟里，而文件读写、引擎 isolate 的消息是真实事件：
    /// 每一跳都要先放真实事件循环跑一下（runAsync），再推进假时钟把它的后续
    /// 步骤冲出来（pump），所以这里交替进行。
    Future<void> settle(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 400 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 5));
      }
      await tester.pump();
      expect(done(), isTrue, reason: '等待插件界面就绪超时');
    }

    /// 测试体结束后卸载界面并停掉插件，再把看门狗、空闲释放等定时器走完——
    /// 框架不允许测试结束时还留着未触发的定时器。
    void pluginTest(String name, Future<void> Function(WidgetTester) body) {
      testWidgets(name, (tester) async {
        await body(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        host.shutdown();
        await tester.pump(const Duration(seconds: 3));
      });
    }

    pluginTest('卡片：脚本取数 → 原生组件渲染 → 点击事件回到脚本', (tester) async {
      await tester.pumpWidget(
        app(
          MetaversePluginSurfaceView(
            host: host,
            kind: MetaversePluginSurfaceKind.card,
          ),
        ),
      );
      await settle(tester, () => find.text('128').evaluate().isNotEmpty);

      // 界面是宿主的 Flutter 组件，不是 WebView。
      expect(find.text('当前积分'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '刷新'), findsOneWidget);
      // 凭证由宿主附带；脚本没有传任何请求头。
      final request = api.requests.single;
      expect(request.uri.toString(), 'https://api.example.com/v1/balance');
      expect(request.headers['Authorization'], 'Bearer k-123');

      api.balance = 256;
      await tester.tap(find.text('刷新'));
      await settle(tester, () => find.text('256').evaluate().isNotEmpty);
      expect(api.requests, hasLength(2));
    });

    pluginTest('页面：链接捕获的参数进入脚本，列表数据驱动循环渲染', (tester) async {
      await tester.pumpWidget(
        app(
          MetaversePluginSurfaceView(
            host: host,
            kind: MetaversePluginSurfaceKind.page,
            page: 'order',
            params: const {'id': '42'},
          ),
        ),
      );
      await settle(tester, () => find.text('机械键盘').evaluate().isNotEmpty);

      expect(find.text('订单 #42'), findsOneWidget);
      expect(find.text('已发货'), findsOneWidget);
      expect(find.text('¥59'), findsOneWidget);
      expect(api.requests.single.uri.path, '/v1/orders/42');
    });

    Future<void> openShop(
      MetaverseAddressLookup lookup, {
      _ShopApi? primary,
      MetaversePluginNetwork? alternate,
    }) async {
      final shop = MetaversePluginManifest.parse(
        jsonDecode(File('plugins/ld-store/plugin.json').readAsStringSync()),
        reservedHosts: const ['linux.do'],
      );
      await store.writeCode(shop.id, (
        ui: File('plugins/ld-store/ui.rfwtxt').readAsStringSync(),
        script: File('plugins/ld-store/main.js').readAsStringSync(),
      ));
      host = MetaversePluginHost(
        manifest: shop,
        store: store,
        network: MetaversePluginNetwork(
          dio: Dio(BaseOptions(validateStatus: (_) => true))
            ..httpClientAdapter = primary ?? _ShopApi(),
          lookup: lookup,
        ),
        dohNetwork: alternate,
        canSuggestDoh: () => true,
        engineFactory: () => IsolateScriptEngine.spawn(),
        delegate: delegate,
      );
    }

    test('仅 IPv6 超时后，手动切换只影响本插件该域名的公开读取', () async {
      final first = _ShopApi()..connectTimeout = true;
      final retry = _ShopApi();
      final alternate = MetaversePluginNetwork(
        dio: Dio()..httpClientAdapter = retry,
        lookup: (_) async => [InternetAddress('8.8.8.8')],
      );
      addTearDown(alternate.dispose);
      await openShop(
        (_) async => [InternetAddress('2606:4700:4700::1111')],
        primary: first,
        alternate: alternate,
      );
      const domain = 'api2.ldspro.qzz.io';
      const read = {'url': 'https://$domain/api/shop/products'};
      await expectLater(
        host.call('fetch', read),
        throwsA(isA<MetaverseIpv6ReadTimeout>()),
      );
      expect(host.dnsRetryHost.value, domain);
      host.enableDohForFailedHost('other.example');
      expect(host.dnsRetryHost.value, domain);
      host.enableDohForFailedHost(domain);
      expect(retry.requests, isEmpty);
      expect((await host.call('fetch', read) as Map)['status'], 200);
      await expectLater(
        host.call('fetch', {...read, 'method': 'POST'}),
        throwsA(isA<MetaversePluginCallException>()),
      );
      expect(first.requests, hasLength(2));
      expect(retry.requests.single.method, 'GET');
      host.shutdown();
      await expectLater(
        host.call('fetch', read),
        throwsA(isA<MetaverseIpv6ReadTimeout>()),
      );
    });

    pluginTest('Fake-IP 出口读取失败时，广场与商品详情均可手动转到官网', (tester) async {
      await tester.runAsync(
        () => openShop(
          (_) async => [InternetAddress('198.18.0.2')],
          primary: _ShopApi()..connectTimeout = true,
        ),
      );
      const id = 'd553779c-83ef-48e4-98c5-a8446c78d5ec';
      for (final (page, label, path) in [
        ('market', '在网页中浏览士多', '/'),
        ('product', '在网页中查看商品', '/product/$id'),
      ]) {
        final opened = delegate.opened.length;
        await tester.pumpWidget(
          app(
            MetaversePluginSurfaceView(
              key: ValueKey(page),
              host: host,
              kind: MetaversePluginSurfaceKind.page,
              page: page,
              params: const {'id': id},
            ),
          ),
        );
        final button = find.text(label);
        await settle(tester, () => button.evaluate().isNotEmpty);
        expect(delegate.opened, hasLength(opened));
        await tester.pumpAndSettle();
        await tester.ensureVisible(button);
        await tester.tap(button);
        await settle(tester, () => delegate.opened.length == opened + 1);
        expect(delegate.opened.last, 'https://ldcstore.com$path');
      }
    });

    test('切换论坛账号后旧士多会话不能读订单或恢复建单', () async {
      final service = _ShopApi();
      await openShop(
        (_) async => [InternetAddress('8.8.8.8')],
        primary: service,
      );
      await store.writeServiceSession(
        host.id,
        MetaverseServiceSession(
          'fixture-session',
          accountId: 42,
          checkout: MetaverseCheckoutGrant(
            host.manifest.auth.checkout!,
            subject: 'linux.do:42',
            unit: 'LDC',
          ),
        ),
      );
      delegate.accountId = 43;
      expect((await host.call('auth.status', {}) as Map)['authorized'], false);
      await expectLater(
        host.call('checkout.status', {}),
        throwsA(isA<MetaversePluginCallException>()),
      );
      await expectLater(
        host.call('checkout.recover', {}),
        throwsA(isA<MetaversePluginCallException>()),
      );
      await expectLater(
        host.call('fetch', {
          'url': 'https://api2.ldspro.qzz.io/api/shop/orders',
          'auth': true,
        }),
        throwsA(isA<MetaversePluginCallException>()),
      );
      expect(service.requests, isEmpty);
    });

    pluginTest('待支付订单仅在点击后调用宿主付款或取消，并回查原单', (tester) async {
      final service = _ShopApi()..orderStatus = 'pending';
      await tester.runAsync(() async {
        await openShop(
          (_) async => [InternetAddress('8.8.8.8')],
          primary: service,
        );
        await store.writeServiceSession(
          host.id,
          MetaverseServiceSession('fixture-session'),
        );
      });
      await tester.pumpWidget(
        app(
          MetaversePluginSurfaceView(
            host: host,
            kind: MetaversePluginSurfaceKind.page,
            page: 'order',
            params: const {'no': 'FIX-1'},
          ),
        ),
      );
      await settle(tester, () => find.text('立即支付').evaluate().isNotEmpty);
      expect(delegate.payments, isEmpty);
      await expectLater(
        host.call('checkout.pay', {'orderNo': 'FIX-1'}),
        throwsA(isA<MetaversePluginCallException>()),
      );
      await tester.ensureVisible(find.text('立即支付'));
      await tester.tap(find.text('立即支付'));
      await settle(
        tester,
        () => delegate.payments.length == 1 && service.requests.length == 2,
      );
      await settle(tester, () => find.text('取消订单').evaluate().isNotEmpty);
      await tester.ensureVisible(find.text('取消订单'));
      await tester.tap(find.text('取消订单'));
      await settle(tester, () => service.requests.length == 3);
      expect(delegate.payments, ['pay:FIX-1', 'cancel:FIX-1']);
      expect(delegate.opened, isEmpty);
    });

    pluginTest('未登录入口调用宿主原生授权，取消后保留页面并可重新授权', (tester) async {
      await tester.runAsync(
        () => openShop((_) async => [InternetAddress('8.8.8.8')]),
      );
      await tester.pumpWidget(
        app(
          MetaversePluginSurfaceView(
            host: host,
            kind: MetaversePluginSurfaceKind.card,
          ),
        ),
      );
      await settle(tester, () => find.text('登录士多').evaluate().isNotEmpty);
      await expectLater(
        host.call('auth.request', {}),
        throwsA(isA<MetaversePluginCallException>()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('登录士多'));
      await settle(tester, () => delegate.authRequests == 1);
      await tester.pumpWidget(
        app(
          MetaversePluginSurfaceView(
            key: const ValueKey('orders'),
            host: host,
            kind: MetaversePluginSurfaceKind.page,
            page: 'orders',
          ),
        ),
      );
      await settle(
        tester,
        () => find.text('登录士多后查看订单和交付内容').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('登录士多'));
      await settle(tester, () => delegate.authRequests == 2);
      expect(delegate.opened, isEmpty);
    });

    pluginTest('匿名兑换预览采用实际可用库存，零库存不会被原始不限库存覆盖', (tester) async {
      for (final stock in [-1, 0]) {
        final service = _ShopApi()
          ..productFields = {'stock': -1, 'availableStock': stock};
        await tester.runAsync(
          () => openShop(
            (_) async => [InternetAddress('8.8.8.8')],
            primary: service,
          ),
        );
        await tester.pumpWidget(
          app(
            MetaversePluginSurfaceView(
              key: ValueKey(stock),
              host: host,
              kind: MetaversePluginSurfaceKind.page,
              page: 'product',
              params: const {'id': 'd553779c-83ef-48e4-98c5-a8446c78d5ec'},
            ),
          ),
        );
        await settle(tester, () => find.text('立即兑换').evaluate().isNotEmpty);
        expect(
          tester
                  .widget<FilledButton>(
                    find.widgetWithText(FilledButton, '立即兑换'),
                  )
                  .onPressed !=
              null,
          stock == -1,
        );
        expect(service.requests.single.method, 'GET');
        expect(
          service.requests.single.headers.containsKey('Authorization'),
          isFalse,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        host.shutdown();
      }
    });

    pluginTest('不限库存按账号剩余额度限量，报价随数量失效且不会创建订单', (tester) async {
      final service = _ShopApi()
        ..productFields = {
          'availableStock': -1,
          'purchaseLimit': {
            'mode': 'per_user',
            'quantity': 5,
            'remainingQuantity': 2,
          },
        };
      await tester.runAsync(() async {
        await openShop(
          (_) async => [InternetAddress('8.8.8.8')],
          primary: service,
        );
        await store.writeServiceSession(
          host.id,
          MetaverseServiceSession(
            'fixture-session',
            queryUrls: const [
              'https://api2.ldspro.qzz.io/api/shop/orders/quote',
            ],
          ),
        );
      });
      await tester.pumpWidget(
        app(
          MetaversePluginSurfaceView(
            host: host,
            kind: MetaversePluginSurfaceKind.page,
            page: 'review',
            params: const {'id': 'd553779c-83ef-48e4-98c5-a8446c78d5ec'},
          ),
        ),
      );
      final quote = find.text('刷新报价');
      await settle(tester, () => quote.evaluate().isNotEmpty);
      expect(find.textContaining('当前可购 2 件'), findsOneWidget);
      await settle(tester, () => find.text('1.00 LDC').evaluate().isNotEmpty);
      final none = find.widgetWithText(ChoiceChip, '不使用优惠券');
      await tester.ensureVisible(none);
      await tester.tap(none);
      await settle(tester, () => find.text('1.00 LDC').evaluate().isEmpty);
      final delayed = Completer<void>();
      service.waitQuote = delayed;
      await tester.ensureVisible(quote);
      await tester.tap(quote);
      await settle(
        tester,
        () => service.requests.where((r) => r.method == 'POST').length == 2,
      );
      await tester.ensureVisible(find.text('+'));
      await tester.tap(find.text('+'));
      await settle(tester, () => find.text('24.00 LDC').evaluate().isNotEmpty);
      delayed.complete();
      // 改数量后重新查价，保留用户主动选择的「不用券」。
      await settle(
        tester,
        () =>
            find.widgetWithText(ChoiceChip, '不使用优惠券').evaluate().isNotEmpty &&
            tester
                .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '不使用优惠券'))
                .selected,
      );
      expect(find.text('2.00 LDC'), findsNothing);
      final best = find.text('模拟券 · 2.00 LDC');
      await tester.ensureVisible(best);
      await tester.tap(best);
      await settle(tester, () => find.text('2.00 LDC').evaluate().isNotEmpty);
      service.includeBestCoupon = false;
      await tester.ensureVisible(quote);
      await tester.tap(quote);
      await settle(
        tester,
        () => find.textContaining('优惠券已不可用').evaluate().isNotEmpty,
      );
      expect(find.widgetWithText(ChoiceChip, '不使用优惠券'), findsOneWidget);
      expect(find.text('24.00 LDC'), findsNWidgets(2));
      final posted = service.requests.where((r) => r.method == 'POST').toList();
      expect(posted.map((r) => jsonDecode(r.data)['quantity']), [1, 1, 2, 2]);
      expect(
        posted.every((r) => r.uri.path == '/api/shop/orders/quote'),
        isTrue,
      );
      expect(delegate.opened, isEmpty);
    });

    pluginTest('兑换预览返回时保留数量，库存减少时重新限量且不自动查价或下单', (tester) async {
      const id = 'd553779c-83ef-48e4-98c5-a8446c78d5ec';
      final service = _ShopApi();
      await tester.runAsync(
        () => openShop(
          (_) async => [InternetAddress('8.8.8.8')],
          primary: service,
        ),
      );
      await tester.pumpWidget(
        app(
          MetaversePluginSurfaceView(
            host: host,
            kind: MetaversePluginSurfaceKind.page,
            page: 'review',
            params: const {'id': id},
          ),
        ),
      );
      await settle(tester, () => find.text('+').evaluate().isNotEmpty);
      await tester.tap(find.text('+'));
      await settle(tester, () => find.text('24.00 LDC').evaluate().isNotEmpty);
      void resume() {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }

      service.productFields = {'price': 10};
      resume();
      await settle(tester, () => find.text('20.00 LDC').evaluate().isNotEmpty);
      await expectLater(
        host.call('session.login', {}),
        throwsA(isA<MetaversePluginCallException>()),
      );
      service.productFields = {'price': 8, 'availableStock': 1};
      resume();
      await settle(tester, () => find.text('8.00 LDC').evaluate().length == 2);
      expect(find.text('1'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '+'))
            .onPressed,
        isNull,
      );
      expect(service.requests, hasLength(3));
      expect(
        service.requests.every(
          (r) => r.method == 'GET' && r.uri.path == '/api/shop/products/$id',
        ),
        isTrue,
      );
      expect(delegate.opened, isEmpty);
    });

    pluginTest('原生建单取消不提交，超时重启后只查原单，手动重试沿用原号', (tester) async {
      const id = 'd553779c-83ef-48e4-98c5-a8446c78d5ec';
      final service = _ShopApi()..simulateCheckout = true;
      Future<void> start() =>
          openShop((_) async => [InternetAddress('8.8.8.8')], primary: service);
      await tester.runAsync(() async {
        await start();
        await store.writeServiceSession(
          host.id,
          MetaverseServiceSession(
            'fixture-session',
            queryUrls: host.manifest.auth.queries.values,
            checkout: MetaverseCheckoutGrant(
              host.manifest.auth.checkout!,
              subject: 'fixture-buyer',
              unit: 'LDC',
            ),
          ),
        );
      });
      final prefs = await SharedPreferences.getInstance();
      Future<void> mount() => tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
          child: app(
            MetaversePluginSurfaceView(
              host: host,
              kind: MetaversePluginSurfaceKind.page,
              page: 'review',
              params: const {'id': id},
            ),
          ),
        ),
      );
      Future<void> click(String label) async {
        final button = find.text(label);
        await settle(tester, () => button.evaluate().isNotEmpty);
        await tester.ensureVisible(button);
        await tester.tap(button);
      }

      final submit = service.requests.where(
        (r) => r.uri.path == '/api/shop/orders' && r.method == 'POST',
      );
      final lookups = service.requests.where(
        (r) => r.uri.path.startsWith('/api/shop/order-submissions/'),
      );
      await mount();
      await click('刷新报价');
      await settle(tester, () => find.text('1.00 LDC').evaluate().isNotEmpty);
      await click('核对并创建订单');
      await settle(
        tester,
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
      );
      expect(find.textContaining('fixture-buyer'), findsOneWidget);
      expect(find.textContaining('优惠券编号：8'), findsOneWidget);
      expect(submit, isEmpty);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await settle(
        tester,
        () =>
            find.byType(AlertDialog).evaluate().isEmpty &&
            find.text('刷新报价').evaluate().isNotEmpty,
      );
      expect(submit, isEmpty);
      await click('刷新报价');
      await settle(tester, () => find.text('1.00 LDC').evaluate().isNotEmpty);
      await click('核对并创建订单');
      await settle(
        tester,
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
      );
      await tester.tap(find.widgetWithText(FilledButton, '确认创建订单'));
      await settle(
        tester,
        () => find.text('查询提交结果').evaluate().isNotEmpty && submit.length == 1,
      );
      final first = jsonDecode(submit.single.data as String);
      expect(first['productId'], id);
      expect(first['couponClaimId'], '8');
      expect(first['expectedAmount'], 1);
      expect(first['quantity'], 1);
      expect(first['submissionToken'], matches(RegExp(r'^ord_[0-9a-f]{32}$')));
      await tester.pumpWidget(const SizedBox.shrink());
      host.shutdown();
      await tester.runAsync(start);
      await mount();
      await click('查询提交结果');
      await settle(tester, () => find.text('用原提交号重试').evaluate().isNotEmpty);
      expect(lookups.single.uri.pathSegments.last, first['submissionToken']);
      expect(submit, hasLength(1));
      await click('用原提交号重试');
      await settle(
        tester,
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
      );
      await tester.tap(find.widgetWithText(FilledButton, '确认创建订单'));
      await settle(
        tester,
        () => submit.length == 2 && find.text('查询提交结果').evaluate().isNotEmpty,
      );
      expect(jsonDecode(submit.last.data as String), first);
      service.lookupExists = true;
      await click('查询提交结果');
      await settle(tester, () => find.text('查看订单并支付').evaluate().isNotEmpty);
      expect(find.text('FIX-1'), findsOneWidget);
      await click('查看订单并支付');
      await settle(tester, () => delegate.pages.contains('order'));
      expect(submit, hasLength(2));
      expect(delegate.opened, isEmpty);
      expect(
        service.requests.any((r) => r.uri.path.contains('payment')),
        isFalse,
      );
    });

    pluginTest('内层订单被根路由覆盖时不查单，重新可见只读服务端状态', (tester) async {
      final service = _ShopApi()..orderStatus = 'pending';
      await tester.runAsync(() async {
        await openShop(
          (_) async => [InternetAddress('8.8.8.8')],
          primary: service,
        );
        await store.writeServiceSession(
          host.id,
          MetaverseServiceSession('fixture-session'),
        );
      });
      final root = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            navigatorKey: root,
            navigatorObservers: [appRouteObserver],
            home: Navigator(
              onGenerateRoute: (_) => InteractionPageRoute(
                builder: (_) => Scaffold(
                  body: SingleChildScrollView(
                    child: MetaversePluginSurfaceView(
                      host: host,
                      kind: MetaversePluginSurfaceKind.page,
                      page: 'order',
                      params: const {'no': 'FIX-1'},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await settle(tester, () => find.text('待支付').evaluate().isNotEmpty);
      final next = InteractionPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('离开订单页')),
      );
      unawaited(root.currentState!.push(next));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(service.requests, hasLength(1));
      root.currentState!.removeRoute(next);
      await settle(
        tester,
        () =>
            service.requests.length == 2 &&
            find.text('待支付').evaluate().isNotEmpty,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(service.requests, hasLength(2));
      service.orderStatus = 'delivered';
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester, () => find.text('已交付').evaluate().isNotEmpty);
      expect(service.requests, hasLength(3));
      expect(
        service.requests.every(
          (r) => r.method == 'GET' && r.uri.path == '/api/shop/orders/FIX-1',
        ),
        isTrue,
      );
      await expectLater(
        host.call('session.login', {}),
        throwsA(isA<MetaversePluginCallException>()),
      );
      expect(delegate.opened, isEmpty);
    });

    pluginTest('宿主保管模拟士多会话，原生列表分页、打开详情、过期后清除订单', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 780);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final service = _ShopApi();
      await tester.runAsync(() async {
        await openShop(
          (_) async => [InternetAddress('8.8.8.8')],
          primary: service,
        );
        await store.writeServiceSession(
          host.id,
          MetaverseServiceSession('fixture-session'),
        );
      });
      await tester.pumpWidget(
        app(
          MetaversePluginSurfaceView(
            host: host,
            kind: MetaversePluginSurfaceKind.page,
            page: 'orders',
          ),
        ),
      );
      await settle(tester, () => find.text('买家商品 1').evaluate().isNotEmpty);
      await tester.tap(find.text('加载更多订单'));
      await settle(tester, () => find.text('买家商品 2').evaluate().isNotEmpty);
      expect(find.text('买家商品 1'), findsOneWidget);
      await tester.tap(find.text('买家商品 1'));
      await settle(tester, () => delegate.pages.contains('order'));
      await tester.pumpWidget(
        app(
          MetaversePluginSurfaceView(
            key: const ValueKey('order'),
            host: host,
            kind: MetaversePluginSurfaceKind.page,
            page: 'order',
            params: const {'no': 'FIX-1'},
          ),
        ),
      );
      await settle(tester, () => find.text('自动发货').evaluate().isNotEmpty);
      expect(find.text('0.00 LDC'), findsOneWidget);
      expect(find.text('仅用于离线测试的交付说明'), findsNothing);
      await tester.tap(find.text('查看交付内容'));
      await settle(
        tester,
        () => find.text('仅用于离线测试的交付说明').evaluate().isNotEmpty,
      );
      service.expired = true;
      await tester.tap(find.text('刷新订单'));
      await settle(tester, () => find.text('士多会话已失效。').evaluate().isNotEmpty);
      expect(find.text('FIX-1'), findsNothing);
      expect(find.text('仅用于离线测试的交付说明'), findsNothing);
      expect(delegate.opened, isEmpty);
      expect(service.requests, hasLength(4));
    });

    pluginTest('双栈 Fake-IP 下远端安装士多、渲染广场并从帖子打开商品详情', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final shop = _ShopApi();
      final network = MetaversePluginNetwork(
        dio: Dio()..httpClientAdapter = shop,
        lookup: (_) async => [
          InternetAddress('2001:2::6'),
          InternetAddress('198.18.0.6'),
        ],
      );
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          metaversePluginStoreProvider.overrideWithValue(store),
          metaversePluginNetworkProvider.overrideWithValue(network),
        ],
      );
      final installed = await tester.runAsync(() async {
        final package = await MetaversePluginInstaller(network: network)
            .fetch('https://packages.example.org/plugin.json');
        final controller = container.read(metaversePluginsProvider.notifier);
        await controller.install(package);
        await controller.setEnabled(package.manifest.id, enabled: true);
        return controller.byId(package.manifest.id)!;
      });
      final pluginHost = container
          .read(metaversePluginHostsProvider)
          .hostFor(installed!);
      const link =
          'https://ldcstore.com/product/d553779c-83ef-48e4-98c5-a8446c78d5ec';
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: app(
            Builder(
              builder: (context) => Column(
                children: [
                  TextButton(
                    onPressed: () => openMetaverseLink(context, link),
                    child: const Text('帖子链接'),
                  ),
                  MetaversePluginSurfaceView(
                    host: pluginHost,
                    kind: MetaversePluginSurfaceKind.page,
                    page: 'market',
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await settle(tester, () => find.text('测试商品').evaluate().isNotEmpty);
      expect(
        shop.requests.where((r) => r.uri.host == 'packages.example.org'),
        hasLength(3),
      );
      await tester.tap(find.text('筛选与排序'));
      final low = find.text('低价');
      await settle(tester, () => low.evaluate().isNotEmpty);
      await tester.ensureVisible(low);
      await tester.tap(low);
      await settle(
        tester,
        () =>
            find.text('全部 · 低价').evaluate().isNotEmpty &&
            shop.requests.any(
              (r) => r.uri.queryParameters['sortOrder'] == 'ASC',
            ),
      );
      expect(find.widgetWithText(ChoiceChip, '低价'), findsOneWidget);
      await settle(tester, () => find.text('测试商品').evaluate().isNotEmpty);
      final productReads = shop.requests
          .where((r) => r.uri.path == '/api/shop/products')
          .length;
      for (final width in [390.0, 800.0]) {
        tester.view.physicalSize = Size(width, 844);
        await tester.pump();
        await tester.ensureVisible(find.text('帖子链接'));
        await tester.tap(find.text('帖子链接'));
        await settle(tester, () => find.text('测试说明').evaluate().isNotEmpty);
        expect(find.byType(width < 600 ? BottomSheet : Dialog), findsOneWidget);
        expect(find.text('立即兑换'), findsOneWidget);
        await tester.tap(find.byType(CloseButton));
        await tester.pumpAndSettle();
        expect(find.text('帖子链接'), findsOneWidget);
        expect(find.text('测试说明'), findsNothing);
      }
      expect(find.text('全部 · 低价'), findsOneWidget);
      expect(
        shop.requests.where((r) => r.uri.path == '/api/shop/products'),
        hasLength(productReads),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    });

    pluginTest('脚本不能自行跳转：没有用户点击时 openUrl / navigate / auth.request 被拒', (
      tester,
    ) async {
      await tester.runAsync(
        () => install(
          script: '''
        fluxdo.on('card.load', async (ctx) => {
          const tried = [];
          for (const run of [
            () => fluxdo.openUrl('https://evil.example.org/phish'),
            () => fluxdo.navigate('order', {id: '1'}),
            () => fluxdo.auth.request(),
          ]) {
            try { await run(); tried.push('ok'); } catch (e) { tried.push('denied'); }
          }
          ctx.setData('balance', tried.join(','));
        });
        fluxdo.on('refresh', async (ctx) => {
          await fluxdo.openUrl('https://example.com/a');
          try { await fluxdo.openUrl('https://example.com/b'); }
          catch (e) { ctx.setData('balance', 'second-denied'); }
        });
      ''',
        ),
      );
      await tester.pumpWidget(
        app(
          MetaversePluginSurfaceView(
            host: host,
            kind: MetaversePluginSurfaceKind.card,
          ),
        ),
      );
      await settle(
        tester,
        () => find.text('denied,denied,denied').evaluate().isNotEmpty,
      );
      expect(delegate.opened, isEmpty);
      expect(delegate.pages, isEmpty);
      expect(delegate.authRequests, 0);

      // 一次点击只换一次界面操作。
      await tester.tap(find.text('刷新'));
      await settle(
        tester,
        () => find.text('second-denied').evaluate().isNotEmpty,
      );
      expect(delegate.opened, ['https://example.com/a']);
    });

    pluginTest('脚本读不到清单外的能力：站点域名、未声明页面、他人存储', (tester) async {
      await tester.runAsync(
        () => install(
          script: '''
        fluxdo.on('card.load', async (ctx) => {
          const out = [];
          const attempt = async (label, run) => {
            try { await run(); out.push(label + ':ok'); }
            catch (e) { out.push(label + ':denied'); }
          };
          await attempt('site', () => fluxdo.fetch('https://linux.do/session/current.json'));
          await attempt('other', () => fluxdo.fetch('https://evil.example.org/x'));
          await attempt('cookie', () => fluxdo.fetch('https://api.example.com/x', {headers: {Cookie: '_t=1'}}));
          await attempt('user', () => fluxdo.user.get());
          await fluxdo.storage.set('k', {n: 1});
          out.push('stored:' + (await fluxdo.storage.get('k')).n);
          ctx.setData('balance', out.join(' '));
        });
      ''',
        ),
      );
      await tester.pumpWidget(
        app(
          MetaversePluginSurfaceView(
            host: host,
            kind: MetaversePluginSurfaceKind.card,
          ),
        ),
      );
      await settle(
        tester,
        () => find.textContaining('stored:1').evaluate().isNotEmpty,
      );
      expect(
        find.text('site:denied other:denied cookie:denied user:ok stored:1'),
        findsOneWidget,
      );
      expect(api.requests, isEmpty);
      expect(await tester.runAsync(() => store.readStorage(manifest.id)), {
        'k': {'n': 1},
      });
    });

    pluginTest('脚本死循环：界面不冻结，插件被挂起', (tester) async {
      await tester.runAsync(
        () => install(
          script: "fluxdo.on('card.load', () => { while (true) {} });",
        ),
      );
      host = createHost(timeout: const Duration(milliseconds: 500));
      await tester.pumpWidget(
        app(
          MetaversePluginSurfaceView(
            host: host,
            kind: MetaversePluginSurfaceKind.card,
          ),
        ),
      );
      await settle(tester, () => delegate.suspended.isNotEmpty);
      expect(delegate.suspended.single, contains('超时'));
      expect(host.isRunning, isFalse);
    });

    pluginTest('脚本塞入超大数据时被拒收，界面保持可用', (tester) async {
      await tester.runAsync(
        () => install(
          script: '''
        fluxdo.on('card.load', (ctx) => {
          ctx.setData('balance', 'ready');
          ctx.setData('items', new Array(200000).fill({a: 1}));
        });
      ''',
        ),
      );
      await tester.pumpWidget(
        app(
          MetaversePluginSurfaceView(
            host: host,
            kind: MetaversePluginSurfaceKind.card,
          ),
        ),
      );
      await settle(tester, () => find.text('ready').evaluate().isNotEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}
