import 'package:dio/dio.dart';

import '../utils/time_utils.dart';
import 'network/discourse_dio.dart';

/// LDC 收银台的实际订单信息，界面只展示服务端返回的收款人与金额。
class LdcPaymentOrder {
  const LdcPaymentOrder({
    required this.token,
    required this.orderNo,
    required this.name,
    required this.amount,
    required this.payer,
    required this.payee,
    required this.merchant,
    required this.expiresAt,
  });
  final String token, orderNo, name, amount, payer, payee, merchant;
  final DateTime expiresAt;
}

class LdcPaymentException implements Exception {
  const LdcPaymentException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 复用 LDC 的业务会话，支付请求禁用自动重放和请求体日志。
class LdcPaymentService {
  LdcPaymentService({Dio? dio})
    : _dio =
          dio ??
          DiscourseDio.create(
            enableRetry: false,
            enableCfChallenge: false,
            enableNetworkLog: false,
          );
  final Dio _dio;
  static const _base = 'https://credit.linux.do';

  static int? amountCents(Object? value) {
    final text = '$value';
    if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(text)) return null;
    final parts = text.split('.');
    return int.parse(parts.first) * 100 +
        (parts.length == 1 ? 0 : int.parse(parts.last.padRight(2, '0')));
  }

  Future<LdcPaymentOrder> prepare(
    Uri paymentUrl, {
    required String orderNo,
    required Object amount,
    required String username,
    required Future<void> Function() checkSession,
  }) async {
    var uri = paymentUrl;
    String? token;
    for (var hop = 0; hop < 4; hop++) {
      if (uri.origin != _base || uri.userInfo.isNotEmpty) {
        throw const LdcPaymentException('payment_invalid_url');
      }
      if (uri.path == '/paying') {
        token = uri.queryParameters['order_no'];
        break;
      }
      if (uri.path != '/epay/submit.php') {
        throw const LdcPaymentException('payment_invalid_url');
      }
      await checkSession();
      final response = await _dio.get(uri.toString(), options: _options());
      final location = response.headers.value('location');
      if (location == null) {
        throw const LdcPaymentException('payment_invalid_url');
      }
      uri = uri.resolve(location);
    }
    if (token == null || token.isEmpty || token.length > 4096) {
      throw const LdcPaymentException('payment_invalid_url');
    }
    await checkSession();
    final response = await _dio.get(
      '$_base/api/v1/merchant/payment/order',
      queryParameters: {'order_no': token},
      options: _options(),
    );
    await checkSession();
    final data = _data(response);
    final order = data is Map ? data['order'] : null;
    final merchant = data is Map ? data['merchant'] : null;
    if (order is! Map ||
        merchant is! Map ||
        order['status'] != 'pending' ||
        order['merchant_order_no'] != orderNo ||
        order['payer_username'] != username ||
        amountCents(order['amount']) == null ||
        amountCents(order['amount']) != amountCents(amount)) {
      throw const LdcPaymentException('payment_order_mismatch');
    }
    final expires = TimeUtils.parseUtcTime('${order['expires_at']}');
    if (expires == null || !expires.isAfter(DateTime.now())) {
      throw const LdcPaymentException('payment_expired');
    }
    return LdcPaymentOrder(
      token: token,
      orderNo: orderNo,
      name: '${order['order_name']}',
      amount: '${order['amount']}',
      payer: '${order['payer_username']}',
      payee: '${order['payee_username']}',
      merchant: '${merchant['app_name']}',
      expiresAt: expires,
    );
  }

  Future<void> pay(
    LdcPaymentOrder order,
    String password, {
    required Future<void> Function() checkSession,
  }) async {
    if (!RegExp(r'^\d{6}$').hasMatch(password)) {
      throw const LdcPaymentException('payment_password_invalid');
    }
    if (!order.expiresAt.isAfter(DateTime.now())) {
      throw const LdcPaymentException('payment_expired');
    }
    await checkSession();
    _data(
      await _dio.post(
        '$_base/api/v1/merchant/payment',
        data: {'order_no': order.token, 'pay_key': password},
        options: _options(),
      ),
    );
    await checkSession();
  }

  Future<void> setInitialPassword(
    String password,
    String username, {
    required Future<void> Function() checkSession,
  }) async {
    if (!RegExp(r'^\d{6}$').hasMatch(password)) {
      throw const LdcPaymentException('payment_password_invalid');
    }
    await checkSession();
    final user = _data(
      await _dio.get('$_base/api/v1/oauth/user-info', options: _options()),
    );
    if (user is! Map ||
        user['username'] != username ||
        user['is_pay_key'] is! bool) {
      throw const LdcPaymentException('payment_order_mismatch');
    }
    // 已有密码时保留原设置，界面返回输入现有密码。
    if (user['is_pay_key'] == true) return;
    await checkSession();
    _data(
      await _dio.put(
        '$_base/api/v1/user/pay-key',
        data: {'pay_key': password},
        options: _options(),
      ),
    );
    await checkSession();
  }

  Options _options() => Options(
    followRedirects: false,
    validateStatus: (s) => s != null && s < 500,
    headers: {'X-Requested-With': 'XMLHttpRequest'},
    extra: {'skipCsrf': true, 'skipRedirect': true, 'isSilent': true},
  );

  Object? _data(Response response) {
    final body = response.data;
    if (body is! Map ||
        body['error_msg'] is! String ||
        !body.containsKey('data')) {
      // 无法识别的响应不能证明扣款失败，交由确认页查询原单。
      throw DioException.badResponse(
        statusCode: response.statusCode ?? 0,
        requestOptions: response.requestOptions,
        response: response,
      );
    }
    if (response.statusCode != 200 || body['error_msg'] != '') {
      final message = body['error_msg'];
      throw LdcPaymentException(
        message is String && message.isNotEmpty
            ? message
            : 'payment_service_error',
      );
    }
    return body['data'];
  }

  void dispose() => _dio.close(force: true);
}
