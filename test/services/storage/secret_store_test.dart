import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/storage/secret_store.dart';

void main() {
  test('SecretKey 使用稳定命名空间并编码账号与名称', () {
    const deviceKey = SecretKey(namespace: 'ldc_reward', name: 'credentials');
    const accountKey = SecretKey(
      namespace: 'auth/session',
      name: 'api:key',
      accountId: 'alice@example.com',
      version: 2,
    );

    expect(deviceKey.storageKey, 'fluxdo:ldc_reward:device:v1:credentials');
    expect(
      accountKey.storageKey,
      'fluxdo:auth%2Fsession:alice%40example.com:v2:api%3Akey',
    );
  });

  test('InMemorySecretStore 支持读写删除和作用域清理', () async {
    final store = InMemorySecretStore();
    const aliceKey = SecretKey(
      namespace: 'auth',
      name: 'token',
      accountId: 'alice',
    );
    const bobKey = SecretKey(
      namespace: 'auth',
      name: 'token',
      accountId: 'bob',
    );
    const deviceKey = SecretKey(namespace: 'ldc', name: 'credentials');

    await store.write(aliceKey, 'alice-token');
    await store.write(bobKey, 'bob-token');
    await store.write(deviceKey, 'ldc-secret');

    await store.deleteScope(
      const SecretScope(namespace: 'auth', accountId: 'alice'),
    );

    expect(await store.read(aliceKey), isNull);
    expect(await store.read(bobKey), 'bob-token');
    expect(await store.read(deviceKey), 'ldc-secret');

    await store.delete(deviceKey);
    expect(await store.read(deviceKey), isNull);
  });
}
