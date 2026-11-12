import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'metaverse_checkout_types.dart';
import 'metaverse_plugin_manifest.dart';
import 'metaverse_plugin_network.dart';
import 'metaverse_plugin_store.dart';
import 'metaverse_service_session.dart';
import 'runtime/metaverse_plugin_runtime.dart';

typedef _Session = ({
  MetaverseServiceSession session,
  MetaverseCheckoutGrant grant,
  String scope,
});
typedef MetaverseConfirmOrder = Future<bool> Function(
  MetaverseCheckoutGrant grant,
  MetaverseOrderIntent intent,
);

class _Submission {
  const _Submission(
    this.intent,
    this.token, {
    this.state = 'pending',
    this.orderNo,
  });
  final MetaverseOrderIntent intent;
  final String token;
  final String state;
  final String? orderNo;
  Map<String, Object?> get view => {
    ...intent.toJson(),
    'state': state,
    if (orderNo != null) 'orderNo': orderNo,
  };
  String get encoded => jsonEncode({...view, 'token': token});
  static _Submission? restore(String? text) {
    if (text == null) return null;
    final raw = jsonDecode(text);
    if (raw is Map &&
        raw['token'] is String &&
        RegExp(r'^ord_[0-9a-f]{32}$').hasMatch(raw['token']) &&
        (raw['state'] == 'pending' ||
            raw['state'] == 'missing' ||
            (raw['state'] == 'created' &&
                MetaverseOrderIntent.validId(raw['orderNo'])))) {
      final intent = MetaverseOrderIntent.parse(raw);
      if (intent != null) {
        return _Submission(
          intent,
          raw['token'],
          state: raw['state'],
          orderNo: raw['orderNo'],
        );
      }
    }
    // 不能因本地记录损坏而重置提交号。
    throw const MetaversePluginCallException('checkout_record_invalid');
  }
}

/// 负责一次确认、一次建单及结果恢复。脚本既不能设置提交号，也接触不到收银台参数。
class MetaverseCheckout {
  MetaverseCheckout(this.manifest, this.store, this.network);
  final MetaversePluginManifest manifest;
  final MetaversePluginStore store;
  final MetaversePluginNetwork network;
  String get _id => manifest.id;

  Future<_Session> _session() async {
    final session = await store.readServiceSession(_id);
    final grant = session?.checkout;
    if (session == null ||
        grant == null ||
        grant.endpoints != manifest.auth.checkout) {
      throw const MetaversePluginCallException('checkout_not_granted');
    }
    final scope = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              grant.endpoints.create,
              grant.endpoints.lookup,
              grant.subject,
              grant.unit,
            ]),
          ),
        )
        .toString();
    return (session: session, grant: grant, scope: scope);
  }

  Future<void> _check(_Session original, bool Function() active) async {
    final now = await _session();
    if (!active() ||
        now.scope != original.scope ||
        now.session.token != original.session.token) {
      throw const MetaversePluginCallException('checkout_session_changed');
    }
  }

  Future<_Submission?> _read(String scope) async =>
      _Submission.restore(await store.readOrder(_id, scope));

  Future<Map<String, Object?>> status(bool Function() active) async {
    final s = await _session();
    final submission = await _read(s.scope);
    await _check(s, active);
    return submission?.view ?? {'state': 'idle'};
  }

  /// 新建与重试都必须重新经过宿主确认。只有查到明确的“不存在”才可重发原意图。
  Future<Map<String, Object?>> submit(
    MetaverseOrderIntent? intent,
    MetaverseConfirmOrder confirm,
    bool Function() active, {
    required bool retry,
  }) => store.withOrderLock(_id, () async {
    final s = await _session();
    final previous = await _read(s.scope);
    await _check(s, active);
    if (!retry && previous != null) return previous.view;
    if (retry && previous?.state != 'missing') {
      throw const MetaversePluginCallException('checkout_lookup_required');
    }
    final selected = retry ? previous!.intent : intent!;
    if (!await confirm(s.grant, selected)) {
      return previous?.view ?? {'state': 'idle'};
    }
    await _check(s, active);
    final token =
        previous?.token ?? 'ord_${const Uuid().v4().replaceAll('-', '')}';
    final pending = _Submission(selected, token);
    // 先持久化，再发送：哪怕应用在下一行后崩溃也只会回到同一笔订单。
    await store.writeOrder(_id, s.scope, pending.encoded);
    await _check(s, active);
    return _request(s, pending, active, create: true);
  });

  Future<Map<String, Object?>> recover(bool Function() active) =>
      store.withOrderLock(_id, () async {
        final s = await _session();
        final pending = await _read(s.scope);
        await _check(s, active);
        if (pending == null || pending.state == 'created') {
          return pending?.view ?? {'state': 'idle'};
        }
        return _request(s, pending, active, create: false);
      });

  Future<Map<String, Object?>> _request(
    _Session s,
    _Submission pending,
    bool Function() active, {
    required bool create,
  }) async {
    Map<String, Object?>? response;
    Object? data;
    try {
      response = await network.orderRequest(
        manifest,
        s.session,
        pending.token,
        create: create ? pending.intent : null,
        checkSession: () => _check(s, active),
      );
      data = jsonDecode(response['body'] as String);
    } on Exception {
      // 超时、非 JSON 或响应中断：订单可能已创建，不能抛弃记录。
    }
    await _check(s, active);
    final http = response?['status'];
    final ok = http is int && http >= 200 && http < 300;
    var state = 'pending';
    String? no;
    if (data case {'success': true, 'data': final Map result} when ok) {
      final order = create
          ? result
          : result['exists'] == true
          ? result['order']
          : null;
      final orderNo = order is Map
          ? (order.containsKey('orderNo')
                ? order['orderNo']
                : order['order_no'])
          : null;
      if (MetaverseOrderIntent.validId(orderNo)) {
        no = orderNo as String;
        state = 'created';
      } else if (!create &&
          result['exists'] == false &&
          result['order'] == null) {
        state = 'missing';
      }
    } else if (create &&
        (http == 400 || http == 409 || http == 422) &&
        data is Map &&
        data['success'] == false) {
      final error = data['error'];
      final code = error is Map
          ? error['code']
          : data['errorCode'] ?? data['code'];
      if (code is String &&
          code.isNotEmpty &&
          code != 'ORDER_SUBMISSION_CONFLICT' &&
          code != 'PUBLIC_ID_REQUIRED') {
        await store.forgetOrder(_id, s.scope);
        return {'state': 'rejected'};
      }
    }
    final next = _Submission(
      pending.intent,
      pending.token,
      state: state,
      orderNo: no,
    );
    await store.writeOrder(_id, s.scope, next.encoded);
    await _check(s, active);
    return {
      ...next.view,
      if (http == 401 || http == 403) 'issue': 'authorization',
    };
  }

  /// 用户看过已建订单后才能开始下一单；不能丢弃仍待确认的提交。
  Future<Object?> finish(String no, bool Function() active) =>
      store.withOrderLock(_id, () async {
        final s = await _session();
        final previous = await _read(s.scope);
        await _check(s, active);
        if (previous?.state != 'created' || previous?.orderNo != no) {
          throw const MetaversePluginCallException('checkout_lookup_required');
        }
        await store.forgetOrder(_id, s.scope);
        return null;
      });
}
