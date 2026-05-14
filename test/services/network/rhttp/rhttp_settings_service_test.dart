import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/services/network/rhttp/rhttp_settings_service.dart';
import 'package:fluxdo/services/network/doh/network_settings_service.dart';
import 'package:fluxdo/services/network/proxy/proxy_settings_service.dart';

/// RhttpSettingsService 单例的单元测试
///
/// 注意：RhttpSettingsService 是单例，initialize() 首次后因 _prefs != null
/// 守卫不再更新。每条测试都需要 resetForTest()，避免吃到上一条测试留下的内存状态。
void main() {
  group('RhttpSettingsService forceDisable', () {
    late SharedPreferences prefs;
    late RhttpSettingsService rhttp;

    setUp(() async {
      rhttp = RhttpSettingsService.instance;
      rhttp.resetForTest();

      // 使用固定初始值确保每条测试都有独立的 SharedPreferences mock。
      SharedPreferences.setMockInitialValues({
        'rhttp_enabled': true,
        'rhttp_mode': 0,
      });
      prefs = await SharedPreferences.getInstance();
    });

    test('forceDisable 不修改 SharedPreferences', () async {
      await rhttp.initialize(prefs);
      expect(prefs.getBool('rhttp_enabled'), true);

      await rhttp.forceDisable();

      expect(
        prefs.getBool('rhttp_enabled'),
        true,
        reason: 'forceDisable 不应覆盖用户的偏好设置',
      );
    });

    test('forceDisable 后 enabled 保持 true', () async {
      await rhttp.initialize(prefs);
      await rhttp.forceDisable();

      expect(rhttp.current.enabled, true, reason: '用户偏好不受 forceDisable 影响');
    });

    test('forceDisable 后 forceDisabled 为 true', () async {
      await rhttp.initialize(prefs);
      await rhttp.forceDisable();

      expect(rhttp.current.forceDisabled, true);
    });

    test('forceDisable 后 shouldUseRhttp 返回 false', () async {
      await rhttp.initialize(prefs);
      await rhttp.forceDisable();

      expect(
        rhttp.shouldUseRhttp(_networkSettings(), const ProxySettings()),
        false,
        reason: 'forceDisable 后应阻止使用 rhttp',
      );
    });

    test('setEnabled 不改变 forceDisabled', () async {
      await rhttp.initialize(prefs);
      await rhttp.forceDisable();
      expect(rhttp.current.forceDisabled, true);

      await rhttp.setEnabled(false);
      expect(rhttp.current.forceDisabled, true);

      await rhttp.setEnabled(true);
      expect(rhttp.current.forceDisabled, true);
    });

    test('setMode 不改变 forceDisabled', () async {
      await rhttp.initialize(prefs);
      await rhttp.forceDisable();
      expect(rhttp.current.forceDisabled, true);

      await rhttp.setMode(RhttpMode.proxyOnly);
      expect(rhttp.current.forceDisabled, true);
    });

    test(
      'resetForTest 后重新 initialize 恢复 forceDisabled 为 false（模拟重启）',
      () async {
        // 首次初始化并 forceDisable
        await rhttp.initialize(prefs);
        await rhttp.forceDisable();
        expect(rhttp.current.forceDisabled, true);

        // 模拟重启：重置单例 + 新建 SharedPreferences
        rhttp.resetForTest();
        SharedPreferences.setMockInitialValues({
          'rhttp_enabled': true,
          'rhttp_mode': 0,
        });
        final freshPrefs = await SharedPreferences.getInstance();

        // 重新 initialize → 走完整路径，forceDisabled 应为默认值 false
        await rhttp.initialize(freshPrefs);

        expect(rhttp.current.enabled, true, reason: '重启后用户偏好 enabled 应保留');
        expect(
          rhttp.current.forceDisabled,
          false,
          reason: '重启后 forceDisabled 恢复为 false，允许重新尝试 rhttp',
        );
      },
    );
  });
}

NetworkSettings _networkSettings({bool dohEnabled = false}) {
  return NetworkSettings(
    dohEnabled: dohEnabled,
    selectedServerUrl: 'https://dns.google/dns-query',
    customServers: const [],
    proxyPort: null,
  );
}
