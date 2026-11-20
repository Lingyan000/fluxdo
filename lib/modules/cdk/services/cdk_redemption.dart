import 'package:flutter/foundation.dart';

import '../models/cdk_models.dart';
import 'cdk_client.dart';

/// 兑换状态与收银台分离：只以 CDK 的交付响应决定是否能展示兑换内容。
class CdkRedemption extends ChangeNotifier {
  CdkRedemption(this.client, this.id);
  final CdkClient client;
  final String id;
  CdkProject? project;
  CdkPaymentIntent? payment;
  String? content;
  Object? error;
  bool loading = false, submitting = false, pendingKnown = false;
  bool paymentSubmitted = false, uncertain = false;
  bool _disposed = false;
  int _revision = 0;

  bool get delivered => content != null || project?.received == true;
  bool get canReceive =>
      !loading &&
      !submitting &&
      !uncertain &&
      !paymentSubmitted &&
      !delivered &&
      pendingKnown &&
      payment == null &&
      project?.openNow == true &&
      (project?.available ?? 0) > 0;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    if (_disposed || loading || submitting) return;
    final revision = ++_revision;
    loading = true;
    pendingKnown = false;
    error = null;
    _notify();
    try {
      final detail = await client.project(id);
      if (_disposed || revision != _revision) return;
      project = detail;
      if (detail.received) {
        content = detail.content;
        payment = null;
        pendingKnown = true;
        uncertain = false;
      } else {
        pendingKnown = false;
        final pending = detail.paid ? await client.pending(id) : null;
        if (_disposed || revision != _revision) return;
        payment = pending;
        pendingKnown = true;
        if (pending != null) uncertain = false;
      }
    } catch (e) {
      if (!_disposed && revision == _revision) error = e;
    } finally {
      if (!_disposed && revision == _revision) {
        loading = false;
        _notify();
      }
    }
  }

  Future<void> receive(String token) async {
    if (!canReceive || token.isEmpty) return;
    submitting = true;
    error = null;
    _notify();
    try {
      final result = await client.receive(id, token);
      if (_disposed) return;
      payment = result.payment;
      content = result.content;
    } catch (e) {
      if (_disposed) return;
      error = e;
      // 业务明确拒绝可以重新验证；网络/格式错误不能证明领取没有成功。
      uncertain = e is! CdkApiException;
    } finally {
      if (!_disposed) {
        submitting = false;
        _notify();
      }
    }
  }

  void markPaymentSubmitted() {
    paymentSubmitted = true;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    content = null;
    project = null;
    payment = null;
    super.dispose();
  }
}
