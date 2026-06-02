import 'dart:async';
import 'dart:convert';

import 'package:devtools_extensions/devtools_extensions.dart';
import 'package:flutter/foundation.dart';
import 'package:vm_service/vm_service.dart';

/// 封装与主 app 的 `ext.fluxdo.cookie.*` service extensions 交互。
///
/// 通过 [serviceManager] 调用主 isolate 的 service extension,
/// 通过 `service.onExtensionEvent` 订阅 `fluxdo.cookie.sweepEvent`。
class CookieService {
  CookieService._();
  static final CookieService instance = CookieService._();

  static const String _prefix = 'ext.fluxdo.cookie';

  VmService? get _vmService => serviceManager.service;

  // ---------------------------------------------------------------------------
  // service extension 调用
  // ---------------------------------------------------------------------------

  /// 完整 dump (jar + WV cookie + Priming 状态)。
  Future<Map<String, dynamic>?> dump({String? url}) async {
    return _callJsonExtension(
      '$_prefix.dump',
      url != null ? {'url': url} : null,
    );
  }

  /// 手动触发 sweep。
  Future<Map<String, dynamic>?> sweep({
    required String url,
    required String name,
    String intent = 'ensureUnique',
  }) async {
    return _callJsonExtension('$_prefix.sweep', {
      'url': url,
      'name': name,
      'intent': intent,
    });
  }

  /// 手动触发 Nuclear Reset。
  Future<Map<String, dynamic>?> nuclearReset({String? url}) async {
    return _callJsonExtension(
      '$_prefix.nuclearReset',
      url != null ? {'url': url} : null,
    );
  }

  /// 强制 Priming 重新执行。
  Future<Map<String, dynamic>?> invalidatePriming() async {
    return _callJsonExtension('$_prefix.invalidatePriming', null);
  }

  /// 当前配置 / 状态。
  Future<Map<String, dynamic>?> config() async {
    return _callJsonExtension('$_prefix.config', null);
  }

  /// critical cookie names。
  Future<List<String>?> criticalNames() async {
    final result = await _callJsonExtension('$_prefix.criticalNames', null);
    final names = result?['criticalNames'];
    if (names is List) {
      return names.cast<String>();
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 事件订阅
  // ---------------------------------------------------------------------------

  /// 订阅主 app postEvent 推送的 SweepEvent (stream name: `Extension`)。
  ///
  /// 过滤 `fluxdo.cookie.sweepEvent` 事件,返回 payload Map。
  ///
  /// 注意: 调用方需先 `await ensureStreamListening()`,
  /// 否则可能错过早期事件。
  Stream<Map<String, dynamic>> sweepEvents() {
    final svc = _vmService;
    if (svc == null) return const Stream.empty();
    return svc.onExtensionEvent.where((event) {
      return event.extensionKind == 'fluxdo.cookie.sweepEvent';
    }).map((event) {
      final data = event.extensionData?.data;
      if (data is Map<String, dynamic>) return data;
      return <String, dynamic>{};
    });
  }

  /// 确保 Extension stream 已开始监听。
  Future<void> ensureStreamListening() async {
    final svc = _vmService;
    if (svc == null) return;
    try {
      await svc.streamListen(EventStreams.kExtension);
    } catch (e) {
      // 已经监听过会抛 'Stream already subscribed', 可以忽略
      if (!e.toString().contains('already subscribed')) {
        debugPrint('[CookieService] streamListen failed: $e');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  /// 通用 service extension 调用,解析返回的 JSON。
  Future<Map<String, dynamic>?> _callJsonExtension(
    String method,
    Map<String, dynamic>? args,
  ) async {
    try {
      final response = await serviceManager.callServiceExtensionOnMainIsolate(
        method,
        args: args,
      );
      // 主 app 端用 ServiceExtensionResponse.result(jsonEncode({...})) 返回
      // 这里收到的是 Response, 字段 result 在 json 中
      final json = response.json;
      if (json == null) return null;
      // ServiceExtensionResponse.result 把字符串包在 json['result'] 或直接展开
      // 实际行为: vm_service 返回 Response, json 是完整 map
      // 取 'result' 字段如果是字符串再解析,否则直接返回
      final result = json['result'];
      if (result is String) {
        try {
          final decoded = jsonDecode(result);
          if (decoded is Map<String, dynamic>) return decoded;
        } catch (_) {}
      } else if (result is Map<String, dynamic>) {
        return result;
      }
      return Map<String, dynamic>.from(json);
    } catch (e, s) {
      debugPrint('[CookieService] $method failed: $e\n$s');
      return null;
    }
  }
}
