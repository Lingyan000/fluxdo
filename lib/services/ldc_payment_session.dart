import 'ldc_payment_service.dart';

/// 应用公共 LDC 收银台会话，按支付服务自身的协议准备、支付与核验。
class LdcPaymentSession implements LdcPaymentDelegate {
  LdcPaymentSession({
    required this.service,
    required this.paymentUrl,
    required this.reference,
    required this.amount,
    required this.checkSession,
  });
  final LdcPaymentService service;
  final Uri paymentUrl;
  final String reference;
  final Object amount;
  final Future<void> Function() checkSession;
  LdcPaymentOrder? _order;

  @override
  Future<LdcPaymentOrder> prepare(String orderNo, String username) async {
    if (orderNo != reference) {
      throw const LdcPaymentException('payment_order_mismatch');
    }
    final order = await service.prepare(
      paymentUrl,
      orderNo: reference,
      amount: amount,
      username: username,
      checkSession: checkSession,
    );
    if (order.transactionId == null) {
      throw const LdcPaymentException('payment_order_mismatch');
    }
    _order = order;
    return order;
  }

  @override
  Future<void> pay(LdcPaymentOrder order, String password) async {
    if (!identical(order, _order)) {
      throw const LdcPaymentException('payment_order_mismatch');
    }
    await service.pay(order, password, checkSession: checkSession);
  }

  @override
  Future<bool> refreshPayment(String orderNo) async {
    final order = _order;
    if (order == null || orderNo != reference) {
      throw const LdcPaymentException('payment_order_mismatch');
    }
    return service.isPaid(order, checkSession: checkSession);
  }

  @override
  Future<void> setInitialPassword(String password, String username) => service
      .setInitialPassword(password, username, checkSession: checkSession);
}
