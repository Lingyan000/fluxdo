import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/services/ldc_biometric_payment.dart';
import 'package:fluxdo/services/storage/secret_store.dart';

class _Secrets extends InMemorySecretStore {
  int reads = 0, writes = 0;
  @override
  Future<String?> read(SecretKey key) {
    reads++;
    return super.read(key);
  }

  @override
  Future<void> write(SecretKey key, String value) {
    expect(key.fallbackPolicy, SecretFallbackPolicy.deny);
    writes++;
    return super.write(key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;
  late _Secrets store;
  late LdcBiometricPayment biometric;
  var allowed = true, active = true;
  var checks = 0;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    store = _Secrets();
    allowed = true;
    active = true;
    checks = 0;
    biometric = LdcBiometricPayment(
      accountId: 42,
      store: store,
      preferences: preferences,
      available: () async => true,
      authenticate: (_) async {
        checks++;
        return allowed;
      },
      checkSession: () async {
        if (!active) throw StateError('账号已切换');
      },
    );
  });
  test('主动启用后每次读取都需认证，安全存储禁止明文降级', () async {
    expect(biometric.enabled, isFalse);
    expect(await biometric.available(), isTrue);
    expect(checks, 0);
    await biometric.enable('123456', 'enable');
    expect(biometric.enabled, isTrue);
    expect(store.writes, 1);
    expect(await biometric.unlock('payment 1'), '123456');
    expect(await biometric.unlock('payment 2'), '123456');
    expect(checks, 3);
    expect(store.reads, 2);
  });
  test('取消认证不保存、不读取密码，账号变化立即停止', () async {
    allowed = false;
    await expectLater(biometric.enable('123456', 'enable'), throwsException);
    expect(store.writes, 0);
    allowed = true;
    await biometric.enable('123456', 'enable');
    allowed = false;
    await expectLater(biometric.unlock('payment'), throwsException);
    expect(store.reads, 0);
    active = false;
    final before = checks;
    await expectLater(biometric.unlock('payment'), throwsStateError);
    expect(checks, before);
  });
  test('账号隔离与关闭后清除密码', () async {
    await biometric.enable('123456', 'enable');
    final other = LdcBiometricPayment(
      accountId: 43,
      store: store,
      preferences: preferences,
      available: () async => true,
      authenticate: (_) async => true,
      checkSession: () async {},
    );
    expect(other.enabled, isFalse);
    await expectLater(other.unlock('payment'), throwsException);
    expect(store.reads, 0);
    await biometric.disable();
    expect(biometric.enabled, isFalse);
    expect(
      await store.read(
        const SecretKey(
          namespace: 'ldc.payment',
          accountId: '42',
          name: 'biometric_pin',
        ),
      ),
      isNull,
    );
    await expectLater(biometric.unlock('payment'), throwsException);
  });
  test('认证期间切换账号不读取保存的密码', () async {
    await biometric.enable('123456', 'enable');
    final switching = LdcBiometricPayment(
      accountId: 42,
      store: store,
      preferences: preferences,
      available: () async => true,
      authenticate: (_) async {
        active = false;
        return true;
      },
      checkSession: () async {
        if (!active) throw StateError('账号已切换');
      },
    );
    await expectLater(switching.unlock('payment'), throwsStateError);
    expect(store.reads, 0);
  });
}
