import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/cf_clearance_authority.dart';
import 'package:fluxdo/services/network/cookie/cookie_value_codec.dart';

/// 「在位值粘性」的契约。
///
/// 定稿规则:jar 里的当前 clearance 只要"还能用"(未过期、未临期、未被撞),
/// 任何同步来源不得用不同的值替换它;允许替换的条件:jar 空 / 过期 /
/// 临期 / 刚被撞。不判候选值死活(判不了),只看在位值死没死(判得出)。
///
/// 两类事故在该口径下同时消失:
/// - 2026-08-19「过一次盾只管一次」:过盾后的新值是在位值,残留旧副本
///   (CHIPS 分区,删不掉)再也无法顶替;
/// - 2026-08-22「每次启动弹盾」:jar 空时一切 sync 放行,恢复路径与
///   0.2.26 同样畅通,不存在被堵的可能。
void main() {
  late CfClearanceAuthority authority;

  CanonicalCookie clearance(String value, {DateTime? expiresAt}) =>
      CanonicalCookie(
        name: 'cf_clearance',
        value: value,
        expiresAt: expiresAt,
      );

  void jarWith(CanonicalCookie? cookie) {
    authority.debugCookieReader =
        cookie == null ? () async => null : () async => cookie;
  }

  setUp(() {
    authority = CfClearanceAuthority.instance..reset();
    authority.debugCookieReader = null;
  });

  tearDown(() {
    authority.debugCookieReader = null;
    authority.reset();
  });

  group('evaluateReplacement 放行条件', () {
    test('jar 空 → 放行(恢复路径全开,与 0.2.26 一致)', () async {
      jarWith(null);
      expect(
        await authority.evaluateReplacement('any-candidate'),
        CfClearanceReplaceDecision.allow,
      );
    });

    test('候选值与在位值相同 → 幂等跳过', () async {
      jarWith(clearance('v1', expiresAt: DateTime.now().add(const Duration(days: 7))));
      expect(
        await authority.evaluateReplacement('v1'),
        CfClearanceReplaceDecision.skipSameValue,
      );
    });

    test('在位值已过期 → 放行(自然换届)', () async {
      jarWith(clearance('old', expiresAt: DateTime.now().subtract(const Duration(minutes: 1))));
      expect(
        await authority.evaluateReplacement('new-mint'),
        CfClearanceReplaceDecision.allow,
      );
    });

    test('在位值临期(<30 分钟) → 放行(新铸值无缝继位,零弹盾)', () async {
      jarWith(clearance('old', expiresAt: DateTime.now().add(const Duration(minutes: 10))));
      expect(
        await authority.evaluateReplacement('new-mint'),
        CfClearanceReplaceDecision.allow,
      );
    });

    test('在位值刚被撞(已死) → 放行(过盾新值继位/新铸值补位)', () async {
      final expires = DateTime.now().add(const Duration(days: 7));
      jarWith(clearance('dead-value', expiresAt: expires));
      authority.noteIncumbentChallenged('dead-value');

      expect(
        await authority.evaluateReplacement('fresh-from-verify'),
        CfClearanceReplaceDecision.allow,
      );
    });
  });

  group('evaluateReplacement 保护条件(核心)', () {
    test('在位值健康 + 异值候选 → 拒绝顶替(2026-08-19 残留旧值场景)', () async {
      // jar 里是刚过盾的新值(597 字符形态,有效期 7 天)
      jarWith(clearance('fresh-597', expiresAt: DateTime.now().add(const Duration(days: 7))));

      // Turnstile WebView load_stop 带回 14:21 签发的残留旧值(533 字符形态):
      // 即便它的 expires 更晚也不许顶替——判定不看候选值,只看在位值活着。
      expect(
        await authority.evaluateReplacement('stale-533-residue'),
        CfClearanceReplaceDecision.skipHealthyIncumbent,
      );
      // 新铸的 Turnstile 值同样不许顶替(在位值能用就不换)
      expect(
        await authority.evaluateReplacement('new-turnstile-mint'),
        CfClearanceReplaceDecision.skipHealthyIncumbent,
      );
    });

    test('在位值无 expires(session 形态)且未被撞 → 同样受保护', () async {
      jarWith(clearance('session-form-value'));
      expect(
        await authority.evaluateReplacement('other-value'),
        CfClearanceReplaceDecision.skipHealthyIncumbent,
      );
    });
  });

  group('2026-08-19 事故时间线重放', () {
    test('过盾 → 残留值多次试图顶替 → 全部被挡 → 不再二次撞盾', () async {
      // 16:04:54 旧值被撞
      jarWith(clearance('old-533-15_55', expiresAt: DateTime.now().add(const Duration(days: 7))));
      authority.noteIncumbentChallenged('old-533-15_55');

      // 过盾:验证流程删空 jar → 新值(597)经 acceptValues 写入(jar 空,放行)
      jarWith(null);
      expect(await authority.evaluateReplacement('fresh-597'),
          CfClearanceReplaceDecision.allow);
      jarWith(clearance('fresh-597', expiresAt: DateTime.now().add(const Duration(days: 7))));

      // 16:05:00 / 16:05:09 / 16:05:16 三次 load_stop 带回同一枚残留 533:
      // 原日志里每次都盖掉新值、1 秒后再 403;现在全部跳过
      for (var i = 0; i < 3; i++) {
        expect(
          await authority.evaluateReplacement('stale-533-14_21'),
          CfClearanceReplaceDecision.skipHealthyIncumbent,
          reason: '残留旧值第 ${i + 1} 次顶替必须被挡',
        );
      }
      // jar 里始终是 597,后续 timings 带 597 → 200,循环不存在
    });
  });

  group('编码归一化与标记管理', () {
    test('编码形态与解码形态互相命中(在位比较/被撞标记)', () async {
      const raw = 'clear{"ace}';
      final encoded = CookieValueCodec.encode(raw);
      jarWith(clearance(encoded, expiresAt: DateTime.now().add(const Duration(days: 7))));

      // 候选为解码形态 → 命中同值幂等
      expect(
        await authority.evaluateReplacement(raw),
        CfClearanceReplaceDecision.skipSameValue,
      );

      // 以解码形态登记被撞 → 在位(编码形态)判定为已死
      authority.noteIncumbentChallenged(raw);
      expect(
        await authority.evaluateReplacement('another-value'),
        CfClearanceReplaceDecision.allow,
      );
    });

    test('reset 清空被撞标记(登出换账号)', () async {
      jarWith(clearance('v1', expiresAt: DateTime.now().add(const Duration(days: 7))));
      authority.noteIncumbentChallenged('v1');
      authority.reset();

      // reset 后 v1 不再视为已死:异值候选被拒绝
      expect(
        await authority.evaluateReplacement('other'),
        CfClearanceReplaceDecision.skipHealthyIncumbent,
      );
    });

    test('null/空值登记为 no-op', () {
      authority.noteIncumbentChallenged(null);
      authority.noteIncumbentChallenged('');
      // 无异常即通过
    });
  });

  group('extractFromCookieHeader', () {
    test('提取与误匹配', () {
      expect(
        CfClearanceAuthority.extractFromCookieHeader(
          '_t=token; cf_clearance=abc.def-_123; _forum_session=s',
        ),
        'abc.def-_123',
      );
      expect(
        CfClearanceAuthority.extractFromCookieHeader('my_cf_clearance=bad; _t=x'),
        isNull,
      );
      expect(CfClearanceAuthority.extractFromCookieHeader(''), isNull);
      expect(CfClearanceAuthority.extractFromCookieHeader(null), isNull);
    });
  });
}
