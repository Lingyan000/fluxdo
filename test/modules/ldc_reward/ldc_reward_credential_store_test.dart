import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/ldc_reward/models/ldc_reward_credentials.dart';
import 'package:fluxdo/modules/ldc_reward/services/ldc_reward_credential_store.dart';
import 'package:fluxdo/services/account_manager.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<SharedPreferences> createPreferences(
    Map<String, Object> values,
  ) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  test('安全存储中的凭证可以完整往返', () async {
    final store = InMemorySecretStore();
    final prefs = await createPreferences({});
    final credentialsStore = LdcRewardCredentialStore(
      secretStore: store,
      preferences: prefs,
    );
    const credentials = LdcRewardCredentials(
      clientId: 'client-id',
      clientSecret: 'client-secret',
    );

    await credentialsStore.save(credentials);
    final loaded = await credentialsStore.load();

    expect(loaded?.clientId, 'client-id');
    expect(loaded?.clientSecret, 'client-secret');
  });

  test('完整的旧 SharedPreferences 凭证会迁移并删除明文', () async {
    final store = InMemorySecretStore();
    final prefs = await createPreferences({
      'ldc_reward_client_id': 'legacy-id',
      'ldc_reward_client_secret': 'legacy-secret',
    });
    final credentialsStore = LdcRewardCredentialStore(
      secretStore: store,
      preferences: prefs,
    );

    final loaded = await credentialsStore.load();

    expect(loaded?.clientId, 'legacy-id');
    expect(loaded?.clientSecret, 'legacy-secret');
    expect(prefs.getString('ldc_reward_client_id'), isNull);
    expect(prefs.getString('ldc_reward_client_secret'), isNull);

    final reloaded = await credentialsStore.load();
    expect(reloaded?.clientSecret, 'legacy-secret');
  });

  test('安全存储已有新值时优先使用新值并清理残留明文', () async {
    final store = InMemorySecretStore();
    final prefs = await createPreferences({
      'ldc_reward_client_id': 'legacy-id',
      'ldc_reward_client_secret': 'legacy-secret',
    });
    final credentialsStore = LdcRewardCredentialStore(
      secretStore: store,
      preferences: prefs,
    );
    await credentialsStore.save(
      const LdcRewardCredentials(
        clientId: 'new-id',
        clientSecret: 'new-secret',
      ),
    );

    final loaded = await credentialsStore.load();

    expect(loaded?.clientId, 'new-id');
    expect(loaded?.clientSecret, 'new-secret');
    expect(prefs.getString('ldc_reward_client_id'), isNull);
    expect(prefs.getString('ldc_reward_client_secret'), isNull);
  });

  test('不同账号的打赏凭证互相隔离', () async {
    final store = InMemorySecretStore();
    final prefs = await createPreferences({});
    final accountA = LdcRewardCredentialStore(
      secretStore: store,
      preferences: prefs,
      accountId: 'alice@example',
    );
    final accountB = LdcRewardCredentialStore(
      secretStore: store,
      preferences: prefs,
      accountId: 'bob/example',
    );

    await accountA.save(
      const LdcRewardCredentials(clientId: 'a-id', clientSecret: 'a-secret'),
    );
    await accountB.save(
      const LdcRewardCredentials(clientId: 'b-id', clientSecret: 'b-secret'),
    );

    expect((await accountA.load())?.clientId, 'a-id');
    expect((await accountB.load())?.clientId, 'b-id');
    await accountA.clear();
    expect((await accountA.load()), isNull);
    expect((await accountB.load())?.clientSecret, 'b-secret');
    expect(
      AccountManager.accountScopedKey('ldc_enabled', 'bob/example'),
      'ldc_enabled::bob%2Fexample',
    );
  });

  test('旧凭证不完整时不会迁移', () async {
    final store = InMemorySecretStore();
    final prefs = await createPreferences({
      'ldc_reward_client_id': 'legacy-id',
    });
    final credentialsStore = LdcRewardCredentialStore(
      secretStore: store,
      preferences: prefs,
    );

    expect(await credentialsStore.load(), isNull);
    expect(prefs.getString('ldc_reward_client_id'), 'legacy-id');
  });

  test('安全写入失败时保留旧明文，避免迁移丢数据', () async {
    final prefs = await createPreferences({
      'ldc_reward_client_id': 'legacy-id',
      'ldc_reward_client_secret': 'legacy-secret',
    });
    final credentialsStore = LdcRewardCredentialStore(
      secretStore: _WriteFailingSecretStore(),
      preferences: prefs,
    );

    await expectLater(credentialsStore.load(), throwsStateError);
    expect(prefs.getString('ldc_reward_client_id'), 'legacy-id');
    expect(prefs.getString('ldc_reward_client_secret'), 'legacy-secret');
  });
}

class _WriteFailingSecretStore implements SecretStore {
  @override
  Future<String?> read(SecretKey key) async => null;

  @override
  Future<void> write(SecretKey key, String value) async {
    throw StateError('secure storage unavailable');
  }

  @override
  Future<void> delete(SecretKey key) async {}

  @override
  Future<void> deleteScope(SecretScope scope) async {}

  @override
  Future<SecretStoreAvailability> checkAvailability() async =>
      SecretStoreAvailability.unavailable;
}
