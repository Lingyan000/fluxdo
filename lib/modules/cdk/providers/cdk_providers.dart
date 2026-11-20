import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/cdk_providers.dart';
import '../../../providers/core_providers.dart';
import '../../../providers/theme_provider.dart';
import '../../../services/network/exceptions/oauth_exception.dart';
import '../services/cdk_client.dart';

final cdkClientProvider = FutureProvider.autoDispose<CdkClient>((ref) async {
  final username = ref.watch(
    currentUserProvider.select((v) => v.value?.username),
  );
  final enabledAccount = ref.watch(
    cdkUserInfoProvider.select((v) => v.value?.username),
  );
  final preferences = ref.watch(sharedPreferencesProvider);
  Future<void> check() async {
    if (!ref.mounted ||
        username == null ||
        enabledAccount != username ||
        preferences.getBool(CdkUserInfoNotifier.enabledKey) != true) {
      throw const OAuthExpiredException(serviceName: 'CDK');
    }
  }

  Future<void> verify() async {
    await check();
    await ref
        .read(cdkOAuthServiceProvider)
        .getUserInfo(expectedUsername: username);
    await check();
  }

  await verify();
  final client = CdkClient(checkSession: check, verifyAccount: verify);
  ref.onDispose(client.dispose);
  return client;
});
