import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/cf_challenge_service.dart';

/// CF 失败计数必须按**验证轮次**去重,不能按请求个数累加。
///
/// 实测事故(2026-08-18 09:24 日志):启动时五个首屏请求
/// (latest.json / summary.json / chat channels ×2 / u.json)几乎同时撞 403 盾。
/// 它们合流到**同一轮**验证,验证成功后各自去同步 cookie —— 但那一刻
/// bootstrap 刚完成、cookie 还没同步齐,五个请求各自记一次失败,
/// `_consecutiveFailures` 瞬间从 0 打到 3(阈值),于是:
///   → 进 30s 冷却
///   → 弹「切换到临时兼容模式?」询问
/// 而 9 秒后 cf_clearance 重新签发,`/latest.json` 200 成功,一切自愈。
/// 用户全程无感,却被一个要求他决策的弹窗打断。
///
/// 正确口径:五个请求共享一轮验证,失败也只算一轮。
void main() {
  late CfChallengeService service;

  setUp(() {
    service = CfChallengeService();
    service.resetCooldown();
  });

  tearDown(() => service.resetCooldown());

  test('同一轮验证的多个等待者只记一次失败', () {
    final round = service.verifyRound;

    // 模拟五个并发请求各自走到"sync 失败"分支
    for (var i = 0; i < 5; i++) {
      service.startCooldown(round: round);
    }

    expect(
      service.consecutiveFailures,
      1,
      reason: '五个并发请求共享一轮验证,失败只应记一次',
    );
    expect(
      service.isInCooldown,
      isFalse,
      reason: '一次失败远未到阈值,不该进冷却',
    );
  });

  test('不同轮次各自记账,累积到阈值仍会熔断', () {
    // 这是熔断机制存在的理由:环境真有问题时(如 Dio 与 WebView 出口 IP
    // 不一致),必须进冷却阻断"删 cookie → 验证 → 再 403"的无限循环。
    // 去重不能把这个能力弄没了。
    service.startCooldown(round: 100);
    expect(service.isInCooldown, isFalse);

    service.startCooldown(round: 101);
    expect(service.isInCooldown, isFalse);

    service.startCooldown(round: 102);
    expect(
      service.isInCooldown,
      isTrue,
      reason: '连续三轮(非三个并发请求)失败才该熔断',
    );
    expect(service.consecutiveFailures, greaterThanOrEqualTo(3));
  });

  test('不传轮次号时按独立失败计数(验证被取消等与并发无关的场景)', () {
    service.startCooldown();
    service.startCooldown();
    expect(service.consecutiveFailures, 2);
  });

  test('resetCooldown 清掉去重标记,同一轮号之后仍能重新记账', () {
    service.startCooldown(round: 7);
    expect(service.consecutiveFailures, 1);

    // 验证成功 → 计数归零
    service.resetCooldown();
    expect(service.consecutiveFailures, 0);

    // 轮次号复用(实际不会,但标记必须已清,否则这次会被误跳过)
    service.startCooldown(round: 7);
    expect(
      service.consecutiveFailures,
      1,
      reason: 'resetCooldown 未清去重标记会导致后续失败被静默吞掉',
    );
  });

  test('验证轮次号在每轮验证开始时递增', () {
    // verifyRound 是去重的依据,它必须真的随验证轮次变化。
    // 这里只验证它是单调不减的只读视图(递增发生在 _setVerifying(true),
    // 那需要完整 UI 环境,由真机/集成测试覆盖)。
    final first = service.verifyRound;
    expect(first, greaterThanOrEqualTo(0));
    expect(service.verifyRound, first, reason: '未起新验证时不应变化');
  });
}
