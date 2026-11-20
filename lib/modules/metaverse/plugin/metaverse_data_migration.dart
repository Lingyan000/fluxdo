import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

import 'metaverse_plugin_installer.dart';
import 'metaverse_plugin_store.dart';

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
    final match = RegExp(r'^(@forum-account:(?:null|\d+):)(.*)$')
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
    final bridge = _MigrationBridge(Map.of(group.value));
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
        arguments: {'fromVersion': fromVersion, 'toVersion': target},
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
  _MigrationBridge(this.data);
  final Map<String, Object?> data;
  @override
  void log(String level, String message) {}
  @override
  Future<Object?> call(String method, Map<String, Object?> params) async {
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
