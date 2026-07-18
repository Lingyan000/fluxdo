/// 敏感数据在系统安全存储不可用时的降级策略。
enum SecretFallbackPolicy {
  /// 不允许降级；调用方应提示用户安全存储不可用。
  deny,

  /// 仅保存在当前进程内存中，应用退出后自动丢失。
  memoryOnly,
}

enum SecretStoreAvailability { available, unavailable }

/// 敏感数据的逻辑作用域，用于账号退出等场景下批量清理。
class SecretScope {
  const SecretScope({required this.namespace, this.accountId});

  final String namespace;
  final String? accountId;

  String get storagePrefix =>
      _buildStoragePrefix(namespace: namespace, accountId: accountId);
}

/// 类型化的安全存储 Key。
///
/// 新 Key 统一使用 `fluxdo:{namespace}:{account}:v{version}:{name}` 格式。
/// [legacyKeys] 用于从历史 SecureStorage 原始 Key 自动迁移。
class SecretKey {
  const SecretKey({
    required this.namespace,
    required this.name,
    this.accountId,
    this.version = 1,
    this.fallbackPolicy = SecretFallbackPolicy.deny,
    this.legacyKeys = const [],
  }) : _rawStorageKey = null;

  const SecretKey.raw(
    String storageKey, {
    this.fallbackPolicy = SecretFallbackPolicy.memoryOnly,
  }) : namespace = '',
       name = '',
       accountId = null,
       version = 1,
       legacyKeys = const [],
       _rawStorageKey = storageKey;

  final String namespace;
  final String name;
  final String? accountId;
  final int version;
  final SecretFallbackPolicy fallbackPolicy;
  final List<String> legacyKeys;
  final String? _rawStorageKey;

  String get storageKey {
    final raw = _rawStorageKey;
    if (raw != null) return raw;
    return '${_buildStoragePrefix(namespace: namespace, accountId: accountId)}'
        'v$version:${Uri.encodeComponent(name)}';
  }
}

String _buildStoragePrefix({required String namespace, String? accountId}) {
  final encodedNamespace = Uri.encodeComponent(namespace);
  final encodedAccount = accountId == null
      ? 'device'
      : Uri.encodeComponent(accountId);
  return 'fluxdo:$encodedNamespace:$encodedAccount:';
}

abstract interface class SecretStore {
  Future<String?> read(SecretKey key);

  Future<void> write(SecretKey key, String value);

  Future<void> delete(SecretKey key);

  Future<void> deleteScope(SecretScope scope);

  Future<SecretStoreAvailability> checkAvailability();
}

class SecretStoreException implements Exception {
  const SecretStoreException({
    required this.operation,
    required this.key,
    required this.cause,
  });

  final String operation;
  final String key;
  final Object cause;

  @override
  String toString() => 'SecretStoreException($operation, $key): $cause';
}

/// 测试与会话级凭证使用的纯内存实现。
class InMemorySecretStore implements SecretStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(SecretKey key) async => _values[key.storageKey];

  @override
  Future<void> write(SecretKey key, String value) async {
    _values[key.storageKey] = value;
  }

  @override
  Future<void> delete(SecretKey key) async {
    _values.remove(key.storageKey);
  }

  @override
  Future<void> deleteScope(SecretScope scope) async {
    _values.removeWhere((key, _) => key.startsWith(scope.storagePrefix));
  }

  @override
  Future<SecretStoreAvailability> checkAvailability() async =>
      SecretStoreAvailability.available;
}
