import 'dart:convert';

import '../../../services/ldc_payment_service.dart';
import 'metaverse_plugin_manifest.dart';
import 'metaverse_plugin_network.dart';
import 'metaverse_plugin_store.dart';
import 'metaverse_service_session.dart';
import 'runtime/metaverse_plugin_runtime.dart';

/// 业务订单与 LDC 收银台的衔接。支付 URL 和密码留在宿主内。
class MetaversePayment {
  MetaversePayment(
    this.manifest,
    this.store,
    this.network,
    this.credit, {
    required this.accountId,
    required this.isActive,
  });
  final MetaversePluginManifest manifest;
  final MetaversePluginStore store;
  final MetaversePluginNetwork network;
  final LdcPaymentService credit;
  final int accountId;
  final bool Function() isActive;
  MetaverseServiceSession? _session;

  Future<void> checkSession() async {
    final current = await store.readServiceSession(manifest.id);
    if (!isActive() ||
        current == null ||
        current.accountId != accountId ||
        (_session != null && current.token != _session!.token)) {
      throw const MetaversePluginCallException('payment_session_changed');
    }
    _session ??= current;
  }

  Future<Map> request(String no, String action) async {
    await checkSession();
    final response = await network.paymentOrderRequest(
      manifest,
      _session!,
      no,
      action,
      checkSession: checkSession,
    );
    final data = jsonDecode(response['body'] as String);
    if (response['status'] != 200 || data is! Map || data['success'] != true) {
      throw const MetaversePluginCallException('payment_order_unavailable');
    }
    if (action == 'cancel' && data['data'] == null) return const {};
    if (data['data'] is! Map) {
      throw const MetaversePluginCallException('payment_order_unavailable');
    }
    return data['data'] as Map;
  }

  Future<LdcPaymentOrder> prepare(String no, String username) async {
    final details = await request(no, 'details');
    final order = details['order'];
    if (order is! Map ||
        (order['order_no'] ?? order['orderNo']) != no ||
        order['status'] != 'pending') {
      throw const MetaversePluginCallException('payment_order_unavailable');
    }
    final payment = await request(no, 'payment');
    final uri = Uri.tryParse('${payment['paymentUrl']}');
    if (uri == null) {
      throw const MetaversePluginCallException('payment_invalid_url');
    }
    return credit.prepare(
      uri,
      orderNo: no,
      amount: order['amount'] ?? order['totalPrice'],
      username: username,
      checkSession: checkSession,
    );
  }

  Future<void> pay(LdcPaymentOrder order, String password) =>
      credit.pay(order, password, checkSession: checkSession);

  Future<void> setInitialPassword(String password, String username) =>
      credit.setInitialPassword(password, username, checkSession: checkSession);
}
