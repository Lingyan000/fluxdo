import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../cf_challenge_service.dart';
import '../../local_notification_service.dart' show navigatorKey;
import '../../log/log_writer.dart';
import '../adapters/cronet_fallback_service.dart';
import '../adapters/platform_adapter.dart';
import '../cookie/csrf_token_service.dart';
import '../request_scheduler_config.dart';
import '../webview/webview_adapter_settings_service.dart';

/// 网络通道健康度的**只读聚合**。
///
/// 描述"当前网络通道处于什么状态"的事实此前散落在五处单例里:CF 盾态在
/// [CfChallengeService]、会话级兼容通道在 [WebViewAdapterSettingsService]、
/// 引擎降级在 [CronetFallbackService]、凭证新鲜度在 [CsrfTokenService]、
/// 引擎选择在 platform_adapter。排查一次"为什么请求过不去"要跨五个文件
/// 拼时序,而用户日志里只有结果没有状态。
///
/// 本类不持有任何状态、不做任何判定——只在被调用时把各源的当前值拍一张
/// 快照,并能一行日志导出([dumpToLog])。判定逻辑仍归各源所有,避免出现
/// 第二个真相源。
///
/// 后续(设计文档 M5)盾态会升级为显式状态机并迁入此处,那时本类才开始
/// 持有状态;当前阶段刻意保持纯投影,零行为影响。
class NetworkHealthController {
  NetworkHealthController._();

  static final NetworkHealthController instance = NetworkHealthController._();

  /// 拍一张当前健康快照。
  NetworkHealthSnapshot snapshot() {
    final cf = CfChallengeService();
    final webView = WebViewAdapterSettingsService.instance;
    final cronet = CronetFallbackService.instance;
    final csrf = CsrfTokenService();
    final engine = resolveEffectiveAdapter();

    return NetworkHealthSnapshot(
      engine: engine.type,
      engineReason: engine.reason,
      cronetFallenBack: cronet.hasFallenBack,
      cronetForceFallback: cronet.forceFallback,
      cronetFallbackReason: cronet.fallbackReason,
      webViewCompatPersistent: webView.persistentEnabled,
      webViewCompatSession: webView.sessionFallbackEnabled,
      shield: _resolveShieldState(cf),
      cfAutoVerifyEnabled: cf.autoVerifyEnabled,
      cfCooldownUntil: cf.cooldownUntil,
      cfConsecutiveFailures: cf.consecutiveFailures,
      cfClearanceResolvedAt: cf.clearanceResolvedAt.value,
      sessionCompatPromptDeclined: cf.sessionCompatPromptDeclined,
      hasCsrfToken: (csrf.csrfToken ?? '').isNotEmpty,
      csrfInFailureCooldown: csrf.isInFailureCooldown,
      csrfLastFailureAt: csrf.lastFailureAt,
      hasForegroundUi: _hasForegroundUi,
      maxConcurrent: RequestSchedulerConfig.maxConcurrent,
      maxPerWindow: RequestSchedulerConfig.maxPerWindow,
      windowSeconds: RequestSchedulerConfig.windowSeconds,
    );
  }

  /// 把快照写入应用日志。
  ///
  /// [reason] 说明触发时机(如 `csrf_refresh_failed` / `shield_cooldown`),
  /// 便于在用户日志里把快照与前后事件对齐。
  void dumpToLog(String reason) {
    final snapshot = this.snapshot();
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'info',
      'type': 'network_health',
      'event': 'network_health_snapshot',
      'reason': reason,
      'message': snapshot.summary(),
      ...snapshot.toJson(),
    });
  }

  /// 当前是否存在可用的前台 UI(**仅供诊断,不要用于判定**)。
  ///
  /// 判据是 `navigatorKey.currentContext`,它在两种完全不同的情况下都为 null:
  /// 后台 isolate(永远不会有 UI)与主 isolate 启动早期(context 马上就到)。
  /// 二者无法区分,所以**不能**拿它去提前拒绝 CF 验证——那会毁掉"启动时撞盾、
  /// 等 context 就绪后补弹"这条路径。无 UI 环境由
  /// CfChallengeService.showManualVerify 内部的 context 等待上限收口。
  ///
  /// 它在快照里的价值是事后归因:日志显示 `ui=headless` 且验证没弹出来,
  /// 就能确认是环境问题而非逻辑问题。
  static bool get _hasForegroundUi {
    try {
      final context = navigatorKey.currentContext;
      return context != null && context.mounted;
    } catch (_) {
      // 后台 isolate 里访问 binding 会抛
      return false;
    }
  }

  static ShieldState _resolveShieldState(CfChallengeService cf) {
    if (cf.isVerifying) return ShieldState.verifying;
    if (cf.isInCooldown) return ShieldState.cooldown;
    return ShieldState.ok;
  }
}

/// CF 盾的当前状态(M2 阶段为投影;M5 升级为显式状态机)。
enum ShieldState {
  /// 通行:未在验证、未在冷却。
  ok,

  /// 验证进行中:业务请求被调度器冻结。
  verifying,

  /// 冷却中:撞盾请求直接失败,不再拉起验证。
  cooldown,
}

/// 网络健康快照(不可变)。
@immutable
class NetworkHealthSnapshot {
  const NetworkHealthSnapshot({
    required this.engine,
    required this.engineReason,
    required this.cronetFallenBack,
    required this.cronetForceFallback,
    required this.cronetFallbackReason,
    required this.webViewCompatPersistent,
    required this.webViewCompatSession,
    required this.shield,
    required this.cfAutoVerifyEnabled,
    required this.cfCooldownUntil,
    required this.cfConsecutiveFailures,
    required this.cfClearanceResolvedAt,
    required this.sessionCompatPromptDeclined,
    required this.hasCsrfToken,
    required this.csrfInFailureCooldown,
    required this.csrfLastFailureAt,
    required this.hasForegroundUi,
    required this.maxConcurrent,
    required this.maxPerWindow,
    required this.windowSeconds,
  });

  // --- 引擎 ---
  final AdapterType engine;
  final AdapterReason engineReason;
  final bool cronetFallenBack;
  final bool cronetForceFallback;
  final String? cronetFallbackReason;

  // --- 兼容通道(WebView 网络栈)---
  final bool webViewCompatPersistent;
  final bool webViewCompatSession;

  // --- CF 盾 ---
  final ShieldState shield;
  final bool cfAutoVerifyEnabled;
  final DateTime? cfCooldownUntil;
  final int cfConsecutiveFailures;
  final DateTime? cfClearanceResolvedAt;
  final bool sessionCompatPromptDeclined;

  // --- 凭证 ---
  final bool hasCsrfToken;
  final bool csrfInFailureCooldown;
  final DateTime? csrfLastFailureAt;

  // --- 环境与调度 ---
  final bool hasForegroundUi;
  final int maxConcurrent;
  final int maxPerWindow;
  final int windowSeconds;

  /// 是否有任何降级/异常在生效(供 UI 或日志快速判断)。
  bool get isDegraded =>
      shield != ShieldState.ok ||
      cronetFallenBack ||
      webViewCompatSession ||
      csrfInFailureCooldown;

  /// 一行人类可读摘要,进日志 message 字段。
  String summary() {
    final parts = <String>[
      'engine=${engine.name}(${engineReason.name})',
      'shield=${shield.name}',
    ];
    if (cronetFallenBack) {
      parts.add(cronetForceFallback ? 'cronet=forced' : 'cronet=fallen');
    }
    if (webViewCompatSession || webViewCompatPersistent) {
      parts.add(
        'compat=${webViewCompatPersistent ? "persistent" : "session"}',
      );
    }
    if (!cfAutoVerifyEnabled) parts.add('autoVerify=off');
    if (cfConsecutiveFailures > 0) {
      parts.add('cfFails=$cfConsecutiveFailures');
    }
    if (sessionCompatPromptDeclined) parts.add('compatPrompt=declined');
    parts.add('csrf=${hasCsrfToken ? "present" : "missing"}');
    if (csrfInFailureCooldown) parts.add('csrfCooldown=on');
    if (!hasForegroundUi) parts.add('ui=headless');
    parts.add('sched=$maxConcurrent/$maxPerWindow per ${windowSeconds}s');
    return parts.join(' ');
  }

  Map<String, dynamic> toJson() => {
    'engine': engine.name,
    'engineReason': engineReason.name,
    'cronetFallenBack': cronetFallenBack,
    'cronetForceFallback': cronetForceFallback,
    if (cronetFallbackReason != null)
      'cronetFallbackReason': _truncate(cronetFallbackReason!),
    'webViewCompatPersistent': webViewCompatPersistent,
    'webViewCompatSession': webViewCompatSession,
    'shield': shield.name,
    'cfAutoVerifyEnabled': cfAutoVerifyEnabled,
    if (cfCooldownUntil != null)
      'cfCooldownUntil': cfCooldownUntil!.toIso8601String(),
    'cfConsecutiveFailures': cfConsecutiveFailures,
    if (cfClearanceResolvedAt != null)
      'cfClearanceResolvedAt': cfClearanceResolvedAt!.toIso8601String(),
    'sessionCompatPromptDeclined': sessionCompatPromptDeclined,
    'hasCsrfToken': hasCsrfToken,
    'csrfInFailureCooldown': csrfInFailureCooldown,
    if (csrfLastFailureAt != null)
      'csrfLastFailureAt': csrfLastFailureAt!.toIso8601String(),
    'hasForegroundUi': hasForegroundUi,
    'maxConcurrent': maxConcurrent,
    'maxPerWindow': maxPerWindow,
    'windowSeconds': windowSeconds,
    'isDegraded': isDegraded,
  };

  @override
  String toString() => 'NetworkHealthSnapshot(${jsonEncode(toJson())})';

  static String _truncate(String value, [int max = 160]) =>
      value.length <= max ? value : '${value.substring(0, max)}…';
}
