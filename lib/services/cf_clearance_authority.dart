import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter/foundation.dart';

import 'cf_challenge_logger.dart';
import 'network/cookie/cookie_jar_service.dart';

/// cf_clearance 在位值粘性判定（会话级）。
///
/// **唯一规则：jar 里的当前 clearance 只要"还能用"（未过期、未临期、
/// 未被撞），任何同步来源不得用不同的值替换它。** 允许替换的条件：
/// jar 空 / 在位值过期 / 临期 / 在位值刚被撞（已死）。
///
/// 为什么不判候选值（前三版的死穴）：
/// - 「撞一次就拉黑」：有效值在限流风暴里也会撞，误杀后恢复路径被堵，
///   2026-08-22 用户日志实锤为每次启动弹盾；
/// - 「同值撞两次才拉黑」：同一种误杀，只是概率低；
/// - 「按 expires 比新旧」：challenge page 与 Turnstile 两种签发渠道 TTL
///   形态不同，残留旧值的 expires 经常比新值更晚（2026-08-19 实锤），
///   该拦的时候放行。
/// 候选值死活客户端判不了；但「jar 里现在这枚值还活着吗」客户端判得出
/// （它自己刚被撞过，或即将过期）。判得了的才配做判定依据。
///
/// 行为口径（相对 0.2.26 的唯一区别是「sync 何时允许替换」）：
/// - 撞盾（403/429 不论）→ 及时过盾（用户的明确公理：过盾即恢复）；
/// - 过盾后新值自动成为在位值 → 残留旧副本/Turnstile pre-clearance 一律
///   无法顶替（2026-08-19「过一次盾只管一次」循环从机制上消失）；
/// - jar 空（验证取消/删除）→ 一切 sync 放行，恢复路径与 0.2.26 同样畅通；
/// - 在位值被撞 → 放开替换，Turnstile 最新铸值可无缝补位（无盾换届）。
class CfClearanceAuthority {
  CfClearanceAuthority._();
  static final CfClearanceAuthority instance = CfClearanceAuthority._();

  static const String cookieName = 'cf_clearance';

  /// 换届窗口：在位值剩余有效期小于该值时允许替换（自然换届，零弹盾）。
  static const Duration rotationWindow = Duration(minutes: 30);

  /// 最近一次撞盾时 jar 里的值（= 已死的在位值）。
  /// 只记这一个：撞了就过盾，没有语义要判，不需要计数/集合。
  String? _lastChallengedValue;

  /// 撞盾时登记：请求实际携带的 cf_clearance 已被 CF 挑战 = 在位值已死，
  /// 此后 sync 可以替换它（过盾新值继位，或 Turnstile 新铸值无缝补位）。
  void noteIncumbentChallenged(String? value) {
    final normalized = _normalize(value ?? '');
    if (normalized.isEmpty || normalized == _lastChallengedValue) return;
    _lastChallengedValue = normalized;
    debugPrint('[CfClearanceAuthority] 在位 cf_clearance 被撞，放开换届');
    CfChallengeLogger.log(
      '[AUTHORITY] incumbent challenged (${normalized.length} chars), '
      'rotation window open',
    );
  }

  /// sync 闸门判定：候选值 [candidateValue] 是否允许替换 jar 当前值。
  Future<CfClearanceReplaceDecision> evaluateReplacement(
    String candidateValue,
  ) async {
    final candidate = _normalize(candidateValue);
    if (candidate.isEmpty) return CfClearanceReplaceDecision.allow;

    final current = await _readCanonical();
    final currentValue = _normalize(current?.value ?? '');

    // 1. jar 空：恢复路径全开（验证取消/删除后的写回与 0.2.26 一致）。
    if (currentValue.isEmpty) return CfClearanceReplaceDecision.allow;

    // 2. 同值：幂等，无需写入。
    if (candidate == currentValue) {
      return CfClearanceReplaceDecision.skipSameValue;
    }

    // 3. 在位值过期/临期：自然换届窗口，放行（新铸值无缝继位）。
    final expires = current?.expiresAt?.toLocal();
    if (expires != null) {
      final now = DateTime.now();
      if (!expires.isAfter(now)) return CfClearanceReplaceDecision.allow;
      if (expires.difference(now) <= rotationWindow) {
        return CfClearanceReplaceDecision.allow;
      }
    }

    // 4. 在位值刚被撞（已死）：放开替换。
    final challenged = _lastChallengedValue;
    if (challenged != null && challenged == currentValue) {
      return CfClearanceReplaceDecision.allow;
    }

    // 5. 在位值健康：拒绝任何异值顶替。
    return CfClearanceReplaceDecision.skipHealthyIncumbent;
  }

  /// 从请求的 Cookie header 中提取 cf_clearance 值（可能为 null）。
  static String? extractFromCookieHeader(String? cookieHeader) {
    if (cookieHeader == null || cookieHeader.isEmpty) return null;
    final value = _clearancePattern.firstMatch(cookieHeader)?.group(1)?.trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  static final RegExp _clearancePattern = RegExp(
    r'(?:^|;\s*)cf_clearance=([^;]*)',
  );

  /// 归一化：请求头里的值是 [CookieValueCodec.decode] 后的形态（见
  /// AppCookieManager），WebView 回读的也是解码形态；jar 存储可能带编码。
  /// 两侧统一 decode 一次（cf_clearance 值是 URL-safe 字符，重复 decode 幂等）。
  static String _normalize(String value) => CookieValueCodec.decode(value);

  /// 登出/换账号时清空：标记随登录会话失效。
  void reset() {
    _lastChallengedValue = null;
  }

  // ---------------------------------------------------------------------------
  // jar 读取（测试可注入）
  // ---------------------------------------------------------------------------

  static Future<CanonicalCookie?> _defaultReader() =>
      CookieJarService().getCanonicalCookie(cookieName);

  /// 测试用：替换 jar 读取器。
  @visibleForTesting
  Future<CanonicalCookie?> Function()? debugCookieReader;

  Future<CanonicalCookie?> _readCanonical() =>
      (debugCookieReader ?? _defaultReader)();
}

/// sync 闸门判定结果（见 [CfClearanceAuthority.evaluateReplacement]）。
enum CfClearanceReplaceDecision {
  /// 放行：jar 空 / 在位值过期 / 临期 / 在位值刚被撞（换届窗口）。
  allow,

  /// 候选值与在位值相同：幂等，无需写入。
  skipSameValue,

  /// 在位值健康且未被撞：拒绝异值顶替（过盾成果保护）。
  skipHealthyIncumbent,
}
