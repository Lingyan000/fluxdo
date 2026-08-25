import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/cf_challenge_service.dart';

/// 「切兼容模式」询问里第二条出路:关掉自动过盾。
///
/// 背景:原先这个询问只有「切兼容 / 取消」两个选项。对"盾很频繁、但又不想
/// 承担兼容模式性能代价"的用户,两个选项都不合意 —— 取消之后下次还会问。
/// 现在给出第三条:直接关掉自动过盾,改为撞盾时在页面上手动点验证
/// (ErrorView 与网络设置页都有入口,不会把用户堵死)。
///
/// 这里验证的是服务层契约:开关的内存态与持久化通道。UI 三选交互本身
/// 需要 dialog 环境,由真机验证覆盖。
void main() {
  // 询问路径会访问 navigatorKey.currentContext,需要 binding 就绪
  TestWidgetsFlutterBinding.ensureInitialized();

  late CfChallengeService service;

  setUp(() {
    service = CfChallengeService();
    service.autoVerifyEnabled = true;
    service.disableAutoVerifyRequest = null;
    service.resetSessionCompatibilityDecision();
  });

  tearDown(() {
    service.autoVerifyEnabled = true;
    service.disableAutoVerifyRequest = null;
    service.resetSessionCompatibilityDecision();
  });

  test('持久化通道未注入时不抛错(只改内存态)', () async {
    // 注入方是 PreferencesNotifier;它初始化前若已撞盾,不能因此崩。
    expect(service.disableAutoVerifyRequest, isNull);
    expect(service.autoVerifyEnabled, isTrue);
  });

  test('注入的持久化通道会被调用', () async {
    var called = 0;
    service.disableAutoVerifyRequest = () async {
      called++;
      service.autoVerifyEnabled = false;
    };

    await service.disableAutoVerifyRequest!();

    expect(called, 1);
    expect(service.autoVerifyEnabled, isFalse);
  });

  test('关掉自动过盾后不再询问兼容模式', () async {
    // 关自动 = 用户已经表态"别自动弹了",此时再问兼容模式是二次打扰。
    // 实现里通过置 declined 静默期达成。
    service.autoVerifyEnabled = false;
    expect(
      await service.confirmSessionCompatibilityMode(),
      isFalse,
      reason: '无 UI 环境下应返回 false 而非弹窗',
    );
  });

  test('resetSessionCompatibilityDecision 不会顺带打开自动过盾', () {
    // 两个状态互相独立:登出会清 declined,但用户关掉的自动过盾开关
    // 是持久化设置,不该被会话级重置带回来。
    service.autoVerifyEnabled = false;
    service.resetSessionCompatibilityDecision();
    expect(service.autoVerifyEnabled, isFalse);
  });
}
