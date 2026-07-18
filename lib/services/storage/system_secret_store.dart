import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secret_store.dart';

/// 基于系统 Keychain / Keystore / Credential Store 的统一敏感数据存储。
///
/// 默认严格失败，不写入明文 SharedPreferences。确实允许可用性降级的数据
/// 可在 [SecretKey] 上声明 [SecretFallbackPolicy.memoryOnly]，降级内容只在
/// 当前进程存活。
class SystemSecretStore implements SecretStore {
  SystemSecretStore({FlutterSecureStorage? secureStorage})
    : _secureStorage =
          secureStorage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  static final SystemSecretStore instance = SystemSecretStore();

  final FlutterSecureStorage _secureStorage;
  final Map<String, String> _memoryFallback = {};

  @override
  Future<String?> read(SecretKey key) async {
    try {
      final value = await _secureStorage.read(key: key.storageKey);
      if (value != null) {
        _memoryFallback.remove(key.storageKey);
        return value;
      }
      final migrated = await _migrateLegacyValue(key);
      return migrated ?? _memoryFallback[key.storageKey];
    } catch (error) {
      return _handleReadFailure(key, error);
    }
  }

  @override
  Future<void> write(SecretKey key, String value) async {
    try {
      await _secureStorage.write(key: key.storageKey, value: value);
      _memoryFallback.remove(key.storageKey);
    } catch (error) {
      if (key.fallbackPolicy == SecretFallbackPolicy.memoryOnly) {
        _logMemoryFallback('write', key, error);
        _memoryFallback[key.storageKey] = value;
        return;
      }
      throw _exception('write', key, error);
    }
  }

  @override
  Future<void> delete(SecretKey key) async {
    _memoryFallback.remove(key.storageKey);
    try {
      await _secureStorage.delete(key: key.storageKey);
      for (final legacyKey in key.legacyKeys) {
        await _secureStorage.delete(key: legacyKey);
      }
    } catch (error) {
      if (key.fallbackPolicy == SecretFallbackPolicy.memoryOnly) {
        _logMemoryFallback('delete', key, error);
        return;
      }
      throw _exception('delete', key, error);
    }
  }

  @override
  Future<void> deleteScope(SecretScope scope) async {
    _memoryFallback.removeWhere(
      (key, _) => key.startsWith(scope.storagePrefix),
    );
    try {
      final values = await _secureStorage.readAll();
      for (final key in values.keys.toList(growable: false)) {
        if (key.startsWith(scope.storagePrefix)) {
          await _secureStorage.delete(key: key);
        }
      }
    } catch (error) {
      throw SecretStoreException(
        operation: 'deleteScope',
        key: scope.storagePrefix,
        cause: error,
      );
    }
  }

  @override
  Future<SecretStoreAvailability> checkAvailability() async {
    try {
      await _secureStorage.read(key: 'fluxdo:system:device:availability_probe');
      return SecretStoreAvailability.available;
    } catch (_) {
      return SecretStoreAvailability.unavailable;
    }
  }

  Future<String?> _migrateLegacyValue(SecretKey key) async {
    for (final legacyKey in key.legacyKeys) {
      final value = await _secureStorage.read(key: legacyKey);
      if (value == null) continue;
      try {
        await _secureStorage.write(key: key.storageKey, value: value);
        await _secureStorage.delete(key: legacyKey);
      } catch (error) {
        if (key.fallbackPolicy != SecretFallbackPolicy.memoryOnly) rethrow;
        // 迁移写入失败时继续使用旧值，且不删除旧 Key，避免升级丢数据。
        _logMemoryFallback('migrate', key, error);
      }
      return value;
    }
    return null;
  }

  String? _handleReadFailure(SecretKey key, Object error) {
    if (key.fallbackPolicy == SecretFallbackPolicy.memoryOnly) {
      _logMemoryFallback('read', key, error);
      return _memoryFallback[key.storageKey];
    }
    throw _exception('read', key, error);
  }

  SecretStoreException _exception(
    String operation,
    SecretKey key,
    Object error,
  ) => SecretStoreException(
    operation: operation,
    key: key.storageKey,
    cause: error,
  );

  void _logMemoryFallback(String operation, SecretKey key, Object error) {
    debugPrint(
      '[SystemSecretStore] $operation(${key.storageKey}) failed; '
      'using memory-only fallback: $error',
    );
  }
}
