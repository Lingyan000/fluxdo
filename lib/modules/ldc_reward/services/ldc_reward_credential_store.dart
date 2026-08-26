import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/account_manager.dart';
import '../../../services/storage/secret_store.dart';
import '../models/ldc_reward_credentials.dart';

/// LDC 凭证的类型化持久化边界。
///
/// clientId 与 clientSecret 作为一个 JSON 整体写入，避免双 Key 部分成功。
/// 首次读取会把历史 SharedPreferences 明文数据迁入系统安全存储，并仅在
/// 安全写入成功后删除旧值。
class LdcRewardCredentialStore {
  LdcRewardCredentialStore({
    required SecretStore secretStore,
    required SharedPreferences preferences,
    this.accountId,
  }) : _secretStore = secretStore,
       _preferences = preferences;

  static const _legacyClientIdKey = 'ldc_reward_client_id';
  static const _legacyClientSecretKey = 'ldc_reward_client_secret';
  static const _deviceSecretKey = SecretKey(
    namespace: 'ldc_reward',
    name: 'credentials',
    fallbackPolicy: SecretFallbackPolicy.deny,
  );

  final SecretStore _secretStore;
  final SharedPreferences _preferences;
  final String? accountId;

  SecretKey get _secretKey => accountId == null
      ? _deviceSecretKey
      : SecretKey(
          namespace: 'ldc_reward',
          name: 'credentials',
          accountId: accountId,
          fallbackPolicy: SecretFallbackPolicy.deny,
        );

  Future<LdcRewardCredentials?> load() async {
    final encoded = await _secretStore.read(_secretKey);
    if (encoded != null && encoded.isNotEmpty) {
      if (accountId == null) await _clearLegacy();
      return _decode(encoded);
    }

    // guest 只是登录前的隔离边界，不能把旧的 device 凭证归属给 guest；
    // 等真实账号出现后再执行一次迁移。
    if (accountId == AccountManager.guestAccountId) return null;

    // 账号作用域启用后，旧的 device 级凭证只迁移一次到当前账号；之后
    // 每个账号使用自己的 SecretKey，清除一个账号不会影响其它账号。
    final legacySecret = accountId == null
        ? null
        : await _secretStore.read(_deviceSecretKey);
    final legacy = legacySecret == null ? _readLegacy() : _decode(legacySecret);
    if (legacy == null) return null;

    await save(legacy);
    await _clearLegacy(clearDeviceSecret: legacySecret != null);
    return legacy;
  }

  Future<void> save(LdcRewardCredentials credentials) {
    return _secretStore.write(
      _secretKey,
      jsonEncode({
        'clientId': credentials.clientId,
        'clientSecret': credentials.clientSecret,
      }),
    );
  }

  Future<void> clear() async {
    await _secretStore.delete(_secretKey);
    if (accountId == null) await _clearLegacy();
  }

  LdcRewardCredentials? _readLegacy() {
    final clientId = _preferences.getString(_legacyClientIdKey);
    final clientSecret = _preferences.getString(_legacyClientSecretKey);
    if (clientId == null ||
        clientSecret == null ||
        clientId.isEmpty ||
        clientSecret.isEmpty) {
      return null;
    }
    return LdcRewardCredentials(clientId: clientId, clientSecret: clientSecret);
  }

  LdcRewardCredentials? _decode(String encoded) {
    final data = jsonDecode(encoded);
    if (data is! Map<String, dynamic>) return null;
    final clientId = data['clientId'];
    final clientSecret = data['clientSecret'];
    if (clientId is! String ||
        clientSecret is! String ||
        clientId.isEmpty ||
        clientSecret.isEmpty) {
      return null;
    }
    return LdcRewardCredentials(clientId: clientId, clientSecret: clientSecret);
  }

  Future<void> _clearLegacy({bool clearDeviceSecret = false}) async {
    final operations = <Future<void>>[
      _preferences.remove(_legacyClientIdKey),
      _preferences.remove(_legacyClientSecretKey),
    ];
    if (clearDeviceSecret) {
      operations.add(_secretStore.delete(_deviceSecretKey));
    }
    await Future.wait(operations);
  }
}
