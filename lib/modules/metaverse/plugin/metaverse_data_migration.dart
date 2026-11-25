import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

import 'metaverse_plugin_installer.dart';
import 'metaverse_plugin_store.dart';
import 'metaverse_plugin_manifest.dart';

/// 显式共享区与遗留未归属数据使用不同命名空间，增加共享区不能暴露旧账号数据。
/// 设计依据: docs/plugins/api.md §普通存储作用域。
Map<String, Object?> prepareMetaverseStorageScopes({
  required MetaversePluginManifest previous,
  required MetaversePluginManifest next,
  required Map<String, Object?> data,
}) {
  if (previous.explicitStorage && !next.explicitStorage) {
    throw const MetaversePluginCallException('storage_scopes_cannot_be_removed');
  }
  if (!previous.explicitStorage && !previous.accountScoped &&
      next.explicitStorage && !next.accountScoped) {
    final result = Map<String, Object?>.of(data);
    for (final entry in data.entries.where((entry) => !entry.key.startsWith('@'))) {
      final key = '@shared:${entry.key}';
      if (result.containsKey(key) &&
          !const DeepCollectionEquality().equals(result[key], entry.value)) {
        throw const MetaversePluginCallException('storage_scope_conflict');
      }
      result[key] = entry.value;
      result.remove(entry.key);
    }
    return result;
  }
  return data;
}

Map<String, Object?> partitionMetaverseData(Map<String, Object?> data, int? account) {
  final result = Map<String, Object?>.of(data);
  if (account == null) return result;
  for (final entry in data.entries.where((entry) => !entry.key.startsWith('@'))) {
    result.putIfAbsent('@forum-account:$account:${entry.key}', () => entry.value);
    result.remove(entry.key);
  }
  return result;
}

/// 旧公共数据只能在隔离脚本中分类，页面与后台任务始终只读取自己的账号分区。
/// 设计依据: docs/plugins/automatic-updates.md §版本恢复与数据迁移。
Future<Map<String, Object?>> migrateMetaverseAccountData({
  required Map<String, Object?> data,
  required int account,
  required String script,
  required MetaverseScriptEngineFactory engineFactory,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final legacy = <String, Object?>{
    for (final entry in data.entries)
      if (!entry.key.startsWith('@')) entry.key: entry.value,
  };
  final prefix = '@forum-account:$account:';
  final current = <String, Object?>{
    for (final entry in data.entries)
      if (entry.key.startsWith(prefix)) entry.key.substring(prefix.length): entry.value,
  };
  final marker = '@account-migration:$account';
  final revision = sha256.convert(utf8.encode(script)).toString();
  Map<String, Object?> stamp(Map<String, Object?> source) => {
    'revision': revision,
    'source': sha256.convert(utf8.encode(jsonEncode(source))).toString(),
  };
  if (const DeepCollectionEquality().equals(data[marker], stamp(legacy))) {
    return data;
  }
  final bridge = _MigrationBridge({}, partitionOnly: true);
  final runtime = await MetaversePluginRuntime.start(
    engineFactory: engineFactory,
    script: script,
    bridge: bridge,
  );
  try {
    final output = await runtime.runTask(
      'account-migration', background: false, event: 'storage.partition', timeout: timeout,
      arguments: {'accountId': account, 'legacy': legacy, 'account': current},
    );
    bool validData(Object? value) => value is Map<String, dynamic> &&
        value.keys.every((key) => key.isNotEmpty && key.length <= 128 && !key.startsWith('@'));
    if (output is! Map<String, dynamic> || !validData(output['legacy']) ||
        !validData(output['account'])) {
      throw const MetaversePluginCallException('account_migration_invalid_result');
    }
    final remaining = (output['legacy'] as Map).cast<String, Object?>();
    final migrated = (output['account'] as Map).cast<String, Object?>();
    final result = <String, Object?>{
      for (final entry in data.entries)
        if (entry.key.startsWith('@') && !entry.key.startsWith(prefix)) entry.key: entry.value,
      ...remaining,
      for (final entry in migrated.entries) '$prefix${entry.key}': entry.value,
      marker: stamp(remaining),
    };
    if (utf8.encode(jsonEncode(result)).length > MetaversePluginStore.maxStorageBytes) {
      throw const MetaversePluginCallException('storage_limit');
    }
    return result;
  } finally {
    runtime.dispose();
  }
}

/// 升级时逐个整理已有分区，不依赖下次登录账号的顺序。
Future<Map<String, Object?>> migrateMetaverseAccountPartitions({
  required MetaversePluginPackage package,
  required Map<String, Object?> data,
  required MetaverseScriptEngineFactory engineFactory,
}) async {
  if (!package.manifest.accountScoped ||
      !package.manifest.requiredFeatures.contains('accountDataMigration')) {
    return data;
  }
  final accounts = <int>{};
  for (final key in data.keys) {
    final match = RegExp(r'^@forum-account:(\d+):').firstMatch(key);
    if (match != null) accounts.add(int.parse(match[1]!));
  }
  var result = data;
  final watch = Stopwatch()..start();
  for (final account in accounts) {
    if (watch.elapsed >= const Duration(seconds: 20)) {
      throw const MetaversePluginCallException('migration_timeout');
    }
    result = await migrateMetaverseAccountData(data: result, account: account,
      script: package.code.script, engineFactory: engineFactory,
      timeout: const Duration(seconds: 20) - watch.elapsed);
  }
  return result;
}

/// 迁移运行器只处理数据副本，不提供网络、凭证、页面或系统任务能力。
Future<Map<String, Object?>> migrateMetaverseData({
  required MetaversePluginPackage package,
  required int fromVersion,
  required Map<String, Object?> data,
  required MetaverseScriptEngineFactory engineFactory,
}) async {
  final target = package.manifest.dataVersion;
  if (fromVersion == target) return data;
  if (target < fromVersion) {
    throw const MetaversePluginCallException(
      'data_downgrade_requires_snapshot',
    );
  }
  if (data.isEmpty) return {};
  final groups = <String, Map<String, Object?>>{};
  for (final entry in data.entries) {
    if (entry.key.startsWith('@account-migration:')) continue;
    final match = RegExp(r'^(@forum-account:(?:null|\d+):|@shared:)(.*)$')
        .firstMatch(entry.key);
    final prefix = match?[1] ?? '';
    (groups[prefix] ??= {})[match?[2] ?? entry.key] = entry.value;
  }
  final result = <String, Object?>{};
  final watch = Stopwatch()..start();
  for (final group in groups.entries) {
    if (watch.elapsed >= const Duration(seconds: 20)) {
      throw const MetaversePluginCallException('migration_timeout');
    }
    final scope = group.key == '@shared:' ? 'shared' :
        group.key.startsWith('@forum-account:') ? 'account' : 'legacy';
    final bridge = _MigrationBridge(Map.of(group.value), scope: scope);
    final runtime = await MetaversePluginRuntime.start(
      engineFactory: engineFactory,
      script: package.code.script,
      bridge: bridge,
    );
    try {
      await runtime.runTask(
        'migration',
        background: false,
        event: 'storage.migrate',
        timeout: const Duration(seconds: 20) - watch.elapsed,
        arguments: {'fromVersion': fromVersion, 'toVersion': target, 'scope': scope},
      );
      result.addAll(
        bridge.data.map((key, value) => MapEntry('${group.key}$key', value)),
      );
      if (utf8.encode(jsonEncode(result)).length >
          MetaversePluginStore.maxStorageBytes) {
        throw const MetaversePluginCallException('storage_limit');
      }
    } finally {
      runtime.dispose();
    }
  }
  return result;
}

class _MigrationBridge implements MetaversePluginBridge {
  _MigrationBridge(this.data, {this.partitionOnly = false, this.scope = 'legacy'});
  final Map<String, Object?> data;
  final bool partitionOnly;
  final String scope;
  @override
  void log(String level, String message) {}
  @override
  Future<Object?> call(String method, Map<String, Object?> params) async {
    if (partitionOnly && method != 'crypto.sha256' && method != 'host.features') {
      throw const MetaversePluginCallException('account_migration_isolated');
    }
    if (method.startsWith('storage.') && params['scope'] != null && params['scope'] != scope) {
      throw const MetaversePluginCallException('migration_scope_mismatch');
    }
    String key(Object? value) {
      if (value is! String ||
          value.isEmpty ||
          value.length > 128 ||
          value.startsWith('@')) {
        throw const MetaversePluginCallException('storage_invalid_key');
      }
      return value;
    }

    void put(String k, Object? value) {
      if (value == null) {
        data.remove(k);
      } else {
        data[k] = value;
      }
    }

    switch (method) {
      case 'crypto.sha256' when partitionOnly:
        final text = params['text'];
        if (text is! String || utf8.encode(text).length > MetaversePluginStore.maxStorageBytes) {
          throw const MetaversePluginCallException('crypto_invalid_text');
        }
        return sha256.convert(utf8.encode(text)).toString();
      case 'host.features':
        return PluginFeatures.supported.toList();
      case 'storage.get':
        return data[key(params['key'])];
      case 'storage.set':
        put(key(params['key']), params['value']);
      case 'storage.remove':
        data.remove(key(params['key']));
      case 'storage.setMany':
        final entries = params['entries'];
        if (entries is! Map || entries.length > 128) {
          throw const MetaversePluginCallException('storage_invalid_arguments');
        }
        for (final k in entries.keys) {
          key(k);
        }
        entries.forEach((k, value) => put(k as String, value));
      case 'storage.compareAndSet':
        final k = key(params['key']);
        if (!const DeepCollectionEquality().equals(data[k], params['expected'])) {
          return false;
        }
        put(k, params['value']);
        return true;
      default:
        throw const MetaversePluginCallException('migration_storage_only');
    }
    if (utf8.encode(jsonEncode(data)).length >
        MetaversePluginStore.maxStorageBytes) {
      throw const MetaversePluginCallException('storage_limit');
    }
    return null;
  }
}
