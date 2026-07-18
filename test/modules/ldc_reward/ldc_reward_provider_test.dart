import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/ldc_reward/providers/ldc_reward_provider.dart';
import 'package:fluxdo/providers/secret_store_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<ProviderContainer> createContainer() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    return ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        secretStoreProvider.overrideWithValue(InMemorySecretStore()),
      ],
    );
  }

  test('用户连续修改凭证后 Provider 保持最后一次值', () async {
    final container = await createContainer();
    addTearDown(container.dispose);
    await container.read(ldcRewardCredentialsProvider.future);
    final notifier = container.read(ldcRewardCredentialsProvider.notifier);

    await notifier.save('id-1', 'secret-1');
    await notifier.save('id-2', 'secret-2');

    final current = container.read(ldcRewardCredentialsProvider).requireValue;
    expect(current?.clientId, 'id-2');
    expect(current?.clientSecret, 'secret-2');
  });

  test('清除凭证后状态与持久化内容同时清空', () async {
    final container = await createContainer();
    addTearDown(container.dispose);
    await container.read(ldcRewardCredentialsProvider.future);
    final notifier = container.read(ldcRewardCredentialsProvider.notifier);

    await notifier.save('id', 'secret');
    await notifier.clear();

    expect(container.read(ldcRewardCredentialsProvider).requireValue, isNull);

    container.invalidate(ldcRewardCredentialsProvider);
    expect(await container.read(ldcRewardCredentialsProvider.future), isNull);
  });
}
