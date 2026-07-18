import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:fluxdo/services/storage/system_secret_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('系统安全存储支持读写和删除', () async {
    final store = SystemSecretStore();
    const key = SecretKey(namespace: 'test', name: 'secret');

    await store.write(key, 'value');
    expect(await store.read(key), 'value');

    await store.delete(key);
    expect(await store.read(key), isNull);
  });

  test('读取时自动迁移旧 SecureStorage Key', () async {
    FlutterSecureStorage.setMockInitialValues({'legacy_key': 'legacy-value'});
    final store = SystemSecretStore();
    const key = SecretKey(
      namespace: 'test',
      name: 'secret',
      legacyKeys: ['legacy_key'],
    );

    expect(await store.read(key), 'legacy-value');

    const storage = FlutterSecureStorage();
    expect(await storage.read(key: key.storageKey), 'legacy-value');
    expect(await storage.read(key: 'legacy_key'), isNull);
  });

  test('作用域清理不会影响其它账号', () async {
    final store = SystemSecretStore();
    const alice = SecretKey(
      namespace: 'auth',
      name: 'token',
      accountId: 'alice',
    );
    const bob = SecretKey(namespace: 'auth', name: 'token', accountId: 'bob');
    await store.write(alice, 'a');
    await store.write(bob, 'b');

    await store.deleteScope(
      const SecretScope(namespace: 'auth', accountId: 'alice'),
    );

    expect(await store.read(alice), isNull);
    expect(await store.read(bob), 'b');
  });
}
