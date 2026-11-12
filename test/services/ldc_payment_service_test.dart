import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/ldc_payment_service.dart';
import 'package:fluxdo/services/ldc_payment_session.dart';

class _Cashier implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  String merchantNo = 'store-order', payer = 'tester', amount = '12.50';
  bool timeout = false;
  bool hasPassword = false;
  String transactionStatus = 'success';
  String transactionPayee = 'seller';
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    if (options.uri.path == '/api/v1/order/transactions') {
      expect(options.data, {
        'id': '9000000000000000001',
        'page': 1,
        'page_size': 1,
      });
      return ResponseBody.fromString(
        jsonEncode({
          'error_msg': '',
          'data': {
            'orders': [
              {
                'id': '9000000000000000001',
                'merchant_order_no': merchantNo,
                'amount': amount,
                'payer_username': payer,
                'payee_username': transactionPayee,
                'status': transactionStatus,
              },
            ],
          },
        }),
        200,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }
    if (options.uri.path == '/api/v1/oauth/user-info') {
      return ResponseBody.fromString(
        jsonEncode({
          'error_msg': '',
          'data': {'username': payer, 'is_pay_key': hasPassword},
        }),
        200,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }
    if (options.uri.path == '/api/v1/user/pay-key') {
      expect(options.method, 'PUT');
      expect(options.data, {'pay_key': '123456'});
      hasPassword = true;
      return ResponseBody.fromString(
        jsonEncode({'error_msg': '', 'data': null}),
        200,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }
    if (options.method == 'POST') {
      expect(options.data, {'order_no': 'encrypted', 'pay_key': '123456'});
      if (timeout) {
        throw DioException.receiveTimeout(
          timeout: const Duration(seconds: 1),
          requestOptions: options,
        );
      }
      return ResponseBody.fromString(
        jsonEncode({'error_msg': '', 'data': null}),
        200,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }
    expect(options.uri.path, '/api/v1/merchant/payment/order');
    expect(options.queryParameters, {'order_no': 'encrypted'});
    return ResponseBody.fromString(
      jsonEncode({
        'error_msg': '',
        'data': {
          'order': {
            'id': '9000000000000000001',
            'merchant_order_no': merchantNo,
            'payer_username': payer,
            'payee_username': 'seller',
            'amount': amount,
            'order_name': '商品',
            'status': 'pending',
            'expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(hours: 1))
                .toIso8601String(),
          },
          'merchant': {'app_name': '商城'},
        },
      }),
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
  late _Cashier api;
  late LdcPaymentService service;
  final url = Uri.parse('https://credit.linux.do/paying?order_no=encrypted');
  Future<LdcPaymentOrder> prepare() => service.prepare(
    url,
    orderNo: 'store-order',
    amount: '12.50',
    username: 'tester',
    checkSession: () async {},
  );
  setUp(() {
    api = _Cashier();
    service = LdcPaymentService(dio: Dio()..httpClientAdapter = api);
  });
  tearDown(() => service.dispose());
  test('公共支付会话独立从 LDC 核验结果，核对收付款账号和金额', () async {
    final payment = LdcPaymentSession(
      service: service,
      paymentUrl: url,
      reference: 'store-order',
      amount: '12.50',
      checkSession: () async {},
    );
    await payment.prepare('store-order', 'tester');
    expect(await payment.refreshPayment('store-order'), isTrue);
    api.transactionStatus = 'pending';
    expect(await payment.refreshPayment('store-order'), isFalse);
    api.transactionStatus = 'success';
    api.transactionPayee = 'someone-else';
    await expectLater(
      payment.refreshPayment('store-order'),
      throwsA(isA<LdcPaymentException>()),
    );
    expect(
      api.requests.where(
        (request) => request.uri.path == '/api/v1/merchant/payment',
      ),
      isEmpty,
    );
  });
  test('首次设置密码单独提交，已有密码时保留原设置', () async {
    await service.setInitialPassword(
      '123456',
      'tester',
      checkSession: () async {},
    );
    expect(api.requests.where((r) => r.method == 'PUT'), hasLength(1));
    await service.setInitialPassword(
      '123456',
      'tester',
      checkSession: () async {},
    );
    expect(api.requests.where((r) => r.method == 'PUT'), hasLength(1));
    expect(api.requests.where((r) => r.method == 'POST'), isEmpty);
  });
  test('准备只读取收银台，显式确认才提交一次买家支付', () async {
    final order = await prepare();
    expect(api.requests.every((r) => r.method == 'GET'), isTrue);
    expect(order.payee, 'seller');
    await service.pay(order, '123456', checkSession: () async {});
    expect(api.requests.where((r) => r.method == 'POST'), hasLength(1));
    expect(api.requests.last.uri.path, '/api/v1/merchant/payment');
  });
  for (final mismatch in ['order', 'amount', 'account']) {
    test('收银台 $mismatch 与原单不符时拒绝支付', () async {
      if (mismatch == 'order') api.merchantNo = 'other';
      if (mismatch == 'amount') api.amount = '12.51';
      if (mismatch == 'account') api.payer = 'other';
      await expectLater(prepare(), throwsA(isA<LdcPaymentException>()));
      expect(api.requests.where((r) => r.method == 'POST'), isEmpty);
    });
  }
  test('跨域支付链接在请求前拒绝', () async {
    await expectLater(
      service.prepare(
        Uri.parse('https://evil.example/paying?order_no=x'),
        orderNo: 'store-order',
        amount: '12.50',
        username: 'tester',
        checkSession: () async {},
      ),
      throwsA(isA<LdcPaymentException>()),
    );
    expect(api.requests, isEmpty);
  });
  test('支付响应超时不重放，账号变化时不提交', () async {
    final order = await prepare();
    await expectLater(
      service.pay(
        order,
        '123456',
        checkSession: () async => throw StateError('changed'),
      ),
      throwsStateError,
    );
    expect(api.requests.where((r) => r.method == 'POST'), isEmpty);
    api.timeout = true;
    await expectLater(
      service.pay(order, '123456', checkSession: () async {}),
      throwsA(isA<DioException>()),
    );
    expect(api.requests.where((r) => r.method == 'POST'), hasLength(1));
  });
}
