import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../network_logger.dart';

/// 网络核心的降级管理。
///
/// 核心是常规网络栈；它整体不可用时（动态库加载失败、启动失败、反复出错）
/// dio 切到 Dart IO 应急路径——指纹差但能用，不至于断网。
class CoreFallbackService extends ChangeNotifier {
  CoreFallbackService._();

  static final instance = CoreFallbackService._();

  static const _hasFallenBackKey = 'net_core_has_fallen_back';
  static const _fallbackReasonKey = 'net_core_fallback_reason';

  SharedPreferences? _prefs;
  bool _hasFallenBack = false;
  String? _fallbackReason;

  Future<void> initialize(SharedPreferences prefs) async {
    _prefs = prefs;

    // 冷启动清掉上次的自动降级：让核心每次启动都有新机会。
    // 核心确实有问题的话，本次会话内会再次触发降级。
    if (prefs.getBool(_hasFallenBackKey) ?? false) {
      NetworkLogger.log(
        '[NetCore] 冷启动清除上次的自动降级'
        '（原因: ${prefs.getString(_fallbackReasonKey)}）',
      );
      await prefs.remove(_hasFallenBackKey);
      await prefs.remove(_fallbackReasonKey);
    }
    _hasFallenBack = false;
    _fallbackReason = null;
  }

  /// 当前是否走应急路径。
  bool get hasFallenBack => _hasFallenBack;

  String? get fallbackReason => _fallbackReason;

  Future<void> triggerFallback(String reason) async {
    if (_hasFallenBack) return;
    _hasFallenBack = true;
    _fallbackReason = reason;
    await _prefs?.setBool(_hasFallenBackKey, true);
    await _prefs?.setString(_fallbackReasonKey, reason);
    NetworkLogger.log('[NetCore] 已降级到应急路径（Dart IO）: $reason', level: 'error');
    notifyListeners();
  }

  Future<void> reset() async {
    _hasFallenBack = false;
    _fallbackReason = null;
    await _prefs?.remove(_hasFallenBackKey);
    await _prefs?.remove(_fallbackReasonKey);
    NetworkLogger.log('[NetCore] 降级状态已重置，恢复网络核心');
    notifyListeners();
  }

  /// 判断错误是否说明核心本身坏了（而不是某个请求失败）。
  ///
  /// 只认「核心起不来 / 装不上」这类结构性故障；单次请求的连接错误、超时
  /// 都是正常网络问题，交给重试策略，不该拖整个栈降级。
  /// 「未就绪」也不算：重启配置的瞬间或冷启动早期会短暂出现，降级就回不来了。
  static bool isCoreUnavailable(dynamic error) {
    if (error == null) return false;
    final message = error.toString().toLowerCase();
    const signatures = [
      '网络核心不可用',
      '网络核心启动失败',
      '加载网络核心失败',
      '网络核心符号缺失',
      'failed to load dynamic library',
      'invalid argument(s): failed to lookup symbol',
    ];
    for (final signature in signatures) {
      if (message.contains(signature.toLowerCase())) {
        NetworkLogger.log('[NetCore] 判定为核心不可用: $signature', level: 'warning');
        return true;
      }
    }
    return false;
  }
}
