import 'package:dio/dio.dart';
import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter/foundation.dart';

import '../cookie/cookie_jar_service.dart';
import '../cookie/cookie_logger.dart';
import '../cookie/session_cookie_sentinel.dart';
import 'recovery_action.dart';
import 'recovery_policy.dart';

/// 会话 cookie 修复动作:Sentinel sweep,失败后升级为 Nuclear Reset。
///
/// 修复的是"jar 与 WebView 之间 cookie 变体不一致导致服务端拒绝"这个全局
/// 环境问题,因此并发失败请求共享一次执行(基类提供单飞)。
class SessionSweepAction extends RecoveryAction {
  SessionSweepAction({
    required this.origin,
    this.nuclear = false,
    SessionCookieSentinel? sentinel,
  }) : _sentinel = sentinel ?? SessionCookieSentinel.instance;

  /// 目标源(scheme://host)。
  final String origin;

  /// true 时执行 Nuclear Reset(清空并重灌),用于 sweep 已失败的场景。
  final bool nuclear;

  final SessionCookieSentinel _sentinel;

  @override
  String get name => nuclear ? 'session-nuclear-reset' : 'session-sweep';

  @override
  Future<bool> perform() async {
    try {
      if (nuclear) {
        await _sentinel.nuclearReset(origin);
        // Nuclear Reset 后给 WebView 网络栈一点时间观察新 cookie
        await Future<void>.delayed(const Duration(milliseconds: 200));
      } else {
        await _sentinel.sweepAll(origin);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      return true;
    } catch (e) {
      debugPrint('[Recovery] $name failed: $e');
      // sweep 失败不阻止重放:cookie 可能本来就是好的,值得试一次
      return !nuclear;
    }
  }
}

/// 会话自愈策略:401 / 419 / `discourse-logged-out` 的透明恢复。
///
/// 迁移自 SelfHealingInterceptor,保留其全部判定语义:
/// - 只对主站生效(CDK/LDC 子域的 401 是各自 OAuth 过期,重试主站 session
///   无意义,还会把一次过期放大成多次请求);
/// - `error_type: 'not_logged_in'` 是真登出,不自愈;
/// - jar 中 `_t` 已失效 = 真登出,不自愈;
/// - 前两次 sweep 重试,仍失败则升级 Nuclear Reset 再试一次。
///
/// 关键时序(M0 修过的坑):判定读 jar 必须发生在本次响应的 Set-Cookie
/// **落库之前**。恢复层在错误链上先于 AppCookieManager 执行,天然满足;
/// 契约见 self_heal_cookie_order_test.dart。
class SessionSelfHealPolicy implements RecoveryPolicy {
  SessionSelfHealPolicy({
    Future<CanonicalCookie?> Function()? readSessionToken,
    SessionCookieSentinel? sentinel,
  }) : _readSessionToken =
           readSessionToken ??
           (() => CookieJarService().getCanonicalCookie('_t')),
       _sentinel = sentinel;

  final Future<CanonicalCookie?> Function() _readSessionToken;
  final SessionCookieSentinel? _sentinel;

  /// sweep 重试次数上限,之后升级 Nuclear Reset。
  static const _sweepAttempts = 2;

  @override
  String get name => 'session-self-heal';

  @override
  bool canHandle(AttemptOutcome outcome) {
    final options = outcome.error?.requestOptions ??
        outcome.response!.requestOptions;

    // 只修主站会话
    if (options.uri.host.toLowerCase() != CookieJarService.appBaseHost) {
      return false;
    }

    // 登出请求的 401 / discourse-logged-out 是**预期结果**而非故障。
    // 登出时 jar 里的 _t 往往还没清(流程后面才清),自愈会据此判定"会话
    // 值得修"而去 sweep + 重放——纯属白做一次 WebView cookie 操作,还会
    // 拖慢登出。
    if (_isLogoutRequest(options)) return false;

    final response = outcome.error?.response ?? outcome.response;
    if (response == null) return false;

    final status = response.statusCode ?? 0;
    final hasLoggedOutHeader =
        response.headers.value('discourse-logged-out')?.isNotEmpty == true;
    if (status != 401 && status != 419 && !hasLoggedOutHeader) return false;

    // 真登出不自愈
    final body = response.data;
    if (body is Map && body['error_type'] == 'not_logged_in') return false;

    return true;
  }

  /// 是否是登出请求(`DELETE /session/:username`)。
  static bool _isLogoutRequest(RequestOptions options) {
    return options.method.toUpperCase() == 'DELETE' &&
        options.uri.path.startsWith('/session/');
  }

  @override
  Future<RecoveryDecision> decide(AttemptOutcome outcome) async {
    final options = outcome.error?.requestOptions ??
        outcome.response!.requestOptions;
    final origin = '${options.uri.scheme}://${options.uri.host}';

    // jar 中 _t 已失效 → 真登出,自愈没有意义
    final jarToken = await _readSessionToken();
    final jarValid = jarToken != null &&
        jarToken.value.isNotEmpty &&
        (jarToken.expiresAt == null ||
            jarToken.expiresAt!.isAfter(DateTime.now()));

    if (!jarValid) {
      debugPrint('[Recovery] 自愈跳过:jar 无有效 _t (${options.uri})');
      CookieLogger.selfHealing(
        event: 'triggered',
        url: origin,
        status: outcome.statusCode,
        jarHasValidToken: false,
      );
      return const RecoveryDecision.complete();
    }

    CookieLogger.selfHealing(
      event: 'triggered',
      url: origin,
      status: outcome.statusCode,
      jarHasValidToken: true,
    );

    // 前 N 次用常规 sweep,之后升级 Nuclear Reset
    final useNuclear = outcome.attemptIndex >= _sweepAttempts;
    CookieLogger.selfHealing(
      event: 'retry',
      url: origin,
      attempt: outcome.attemptIndex + 1,
    );

    return RecoveryDecision.recoverThenRetry(
      SessionSweepAction(
        origin: origin,
        nuclear: useNuclear,
        sentinel: _sentinel,
      ),
    );
  }
}
