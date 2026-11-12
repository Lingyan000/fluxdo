import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_checkout_types.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_payment.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_service_session.dart';
import 'package:fluxdo/services/ldc_payment_service.dart';

class _Store implements MetaversePluginStore {
  _Store(this.session);
  MetaverseServiceSession? session;
  @override
  Future<MetaverseServiceSession?> readServiceSession(String id) async =>
      session;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TransactionApi implements HttpClientAdapter {
  _TransactionApi({
    required this.host,
    required this.prefix,
    required this.orderFormat,
  });
  final String host, prefix;
  final String orderFormat;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    final Map<String, Object?> response;
    if (options.uri.host == host) {
      expect(options.headers['Authorization'], 'Bearer fixture-session');
      final data = switch (options.uri.path.substring(prefix.length)) {
        '/orders/order-1' => {
          'order': {
            if (orderFormat == 'mixed') 'order_no': 'wrong-order',
            orderFormat == 'snake' ? 'order_no' : 'orderNo': 'order-1',
            'status': 'pending',
            orderFormat == 'snake' ? 'total_price' : 'totalPrice': '12.50',
            if (orderFormat == 'mixed') 'total_price': '999.00',
          },
        },
        '/orders/order-1/payment-url' => {
          orderFormat == 'snake' ? 'payment_url' : 'paymentUrl':
              'https://credit.linux.do/epay/submit.php?sign=fixture',
          if (orderFormat == 'mixed')
            'payment_url': 'https://wrong.example.org/',
        },
        '/orders/order-1/refresh' => {'status': 'completed'},
        '/orders/order-1/cancel' => null,
        _ => throw StateError('意外请求'),
      };
      response = {'success': true, 'data': data};
    } else {
      expect(options.uri.host, 'credit.linux.do');
      expect(options.headers.containsKey('Authorization'), isFalse);
      if (options.uri.path == '/epay/submit.php') {
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['/paying?order_no=encrypted'],
          },
        );
      }
      response = {
        'error_msg': '',
        'data': options.method == 'POST'
            ? null
            : {
                'order': {
                  'merchant_order_no': 'order-1',
                  'order_name': '模拟商品',
                  'payer_username': 'tester',
                  'payee_username': 'seller',
                  'amount': '12.50',
                  'status': 'pending',
                  'expires_at': DateTime.now()
                      .toUtc()
                      .add(const Duration(hours: 1))
                      .toIso8601String(),
                },
                'merchant': {'app_name': '士多'},
              },
      };
    }
    return ResponseBody.fromString(
      jsonEncode(response),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  for (final (host, prefix) in [
    ('api2.ldspro.qzz.io', '/api/shop'),
    ('shop.example.org', '/v2/catalog'),
  ]) {
    for (final format in ['snake', 'camel', 'mixed']) {
      test('$host $format 订单按清单衔接 LDC 并核对金额', () async {
        final manifest = MetaversePluginManifest.parse(
          jsonDecode(
            File('test/fixtures/metaverse/api1_shop.json')
                .readAsStringSync()
                .replaceAll('api2.ldspro.qzz.io', host)
                .replaceAll('/api/shop', prefix),
          ),
        );
        final api = _TransactionApi(
          host: host,
          prefix: prefix,
          orderFormat: format,
        );
        final store = _Store(
          MetaverseServiceSession(
            'fixture-session',
            accountId: 42,
            checkout: MetaverseCheckoutGrant(
              manifest.auth.checkout!,
              subject: 'tester',
              unit: 'LDC',
            ),
          ),
        );
        final network = MetaversePluginNetwork(
          dio: Dio()..httpClientAdapter = api,
          lookup: (_) async => [InternetAddress('198.18.0.6')],
        );
        final credit = LdcPaymentService(dio: Dio()..httpClientAdapter = api);
        addTearDown(network.dispose);
        addTearDown(credit.dispose);
        final payment = MetaversePayment(
          manifest,
          store,
          network,
          credit,
          accountId: 42,
          isActive: () => true,
        );
        final order = await payment.prepare('order-1', 'tester');
        expect(order.amount, '12.50');
        expect(api.requests.every((r) => r.method == 'GET'), isTrue);
        await payment.pay(order, '123456');
        await payment.request('order-1', 'refresh');
        expect(
          api.requests.where((r) => r.method == 'POST').map((r) => r.uri.path),
          ['/api/v1/merchant/payment', '$prefix/orders/order-1/refresh'],
        );
        expect(await payment.request('order-1', 'cancel'), isEmpty);
        store.session = null;
        final count = api.requests.length;
        await expectLater(
          payment.request('order-1', 'cancel'),
          throwsException,
        );
        expect(api.requests.length, count);
      });
    }
  }
}
