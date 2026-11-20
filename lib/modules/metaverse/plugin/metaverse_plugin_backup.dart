import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'metaverse_plugin_manifest.dart';
import '../market/metaverse_update_store.dart';
import 'metaverse_plugin_store.dart';

/// 备份保存来源与普通数据，恢复队列不属于安装索引，不执行备份中的代码。
class MetaversePluginBackup {
  MetaversePluginBackup(this.root, {this.reservedHosts = const []});
  final Directory root;
  final List<String> reservedHosts;
  static const section = 'metaverse';
  static const maxBytes = 72 * 1024 * 1024;

  T _database<T>(T Function(Database) run) {
    root.createSync(recursive: true);
    final db = sqlite3.open('${root.path}/restore.sqlite');
    try {
      db.execute('PRAGMA busy_timeout = 3000');
      db.execute(
        'CREATE TABLE IF NOT EXISTS pending (id TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      return run(db);
    } finally {
      db.close();
    }
  }

  Future<Map<String, Object?>> export(MetaversePluginStore store) async {
    final entries = <Map<String, Object?>>[];
    for (final plugin in store.loadIndex()) {
      await store.settleRelease(plugin);
      final data = await store.readStorage(plugin.id);
      final preferences = await store.preferences(plugin.manifest);
      // 正在更新时宁可让用户重试，不能把两个版本的数据拼在一起。
      final after = store
          .loadIndex()
          .where((p) => p.id == plugin.id)
          .firstOrNull;
      if (after?.codeRevision != plugin.codeRevision ||
          after?.source != plugin.source ||
          after?.installationId != plugin.installationId) {
        throw StateError('插件更新中，请稍后重新备份');
      }
      entries.add({
        'manifest': plugin.manifest.raw,
        'source': plugin.source,
        'data': data,
        'publisherKey': ?plugin.publisherKey,
        'autoUpdate': MetaverseUpdateStore(root).snapshot().allows(plugin),
        'preferences': preferences,
      });
    }
    final updates = MetaverseUpdateStore(root).snapshot();
    return {
      'version': 1,
      'plugins': entries,
      'updates': {
        'frequency': updates.frequency.name,
        'preview': updates.preview,
      },
    };
  }

  /// 旧备份只有清单和来源，转为待恢复条目，绝不恢复启用或授权。
  Object? sectionFrom(Map<String, dynamic> backup) {
    final current = (backup['sections'] as Map?)?[section];
    if (current != null) return current;
    final legacy =
        ((backup['data'] as Map?)?[MetaversePluginStore.indexKey]
            as Map?)?['value'];
    if (legacy is! String) return null;
    final records = jsonDecode(legacy);
    if (records is! List) throw const FormatException('旧插件备份无效');
    return {
      'version': 1,
      'plugins': [
        for (final record in records)
          {
            'manifest': record['manifest'],
            'source': record['source'],
            'data': <String, Object?>{},
          },
      ],
    };
  }

  List<Map<String, dynamic>> validate(Object? section) {
    if (section == null) return [];
    if (utf8.encode(jsonEncode(section)).length > maxBytes ||
        section is! Map ||
        section['version'] != 1 ||
        section['plugins'] is! List ||
        (section['plugins'] as List).length > 32) {
      throw const FormatException('插件备份格式无效');
    }
    final updates = section['updates'];
    if (updates != null &&
        (updates is! Map ||
            !MetaverseUpdateFrequency.values.any(
              (f) => f.name == updates['frequency'],
            ) ||
            updates['preview'] is! bool)) {
      throw const FormatException('备份更新设置无效');
    }
    final result = <Map<String, dynamic>>[], ids = <String>{};
    for (final item in section['plugins'] as List) {
      if (item is! Map<String, dynamic> ||
          item['data'] is! Map<String, dynamic> ||
          item['source'] is! String ||
          utf8.encode(jsonEncode(item['data'])).length >
              MetaversePluginStore.maxStorageBytes) {
        throw const FormatException('插件备份数据无效');
      }
      final manifest = MetaversePluginManifest.parse(
        item['manifest'],
        reservedHosts: reservedHosts,
        allowLegacyMetadata: true,
      );
      if (!ids.add(manifest.id)) throw const FormatException('插件备份包含重复条目');
      final source = item['source'] as String,
          uri = Uri.tryParse(item['source']);
      if (source != 'file:${manifest.id}' &&
          (uri == null ||
              uri.scheme != 'https' ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty ||
              source.length > 4096)) {
        throw const FormatException('插件备份来源无效');
      }
      if (item['publisherKey'] != null &&
          (item['publisherKey'] is! String ||
              !RegExp(r'^[a-f0-9]{64}$')
                  .hasMatch(item['publisherKey'] as String))) {
        throw const FormatException('备份公钥指纹无效');
      }
      if (item['autoUpdate'] != null && item['autoUpdate'] is! bool)
        throw const FormatException('备份更新开关无效');
      final preferences = item['preferences'] ?? <String, Object?>{};
      if (preferences is! Map ||
          preferences.length > 24 ||
          manifest.preferences.any(
            (f) =>
                preferences.containsKey(f.key) &&
                !f.accepts(preferences[f.key]),
          )) {
        throw const FormatException('备份偏好无效');
      }
      result.add({
        'manifest': manifest.raw,
        'source': source,
        'data': item['data'],
        'preferences': preferences,
        'publisherKey': item['publisherKey'],
        'autoUpdate': item['autoUpdate'] != false,
      });
    }
    return result;
  }

  void stage(Object? section) {
    final entries = validate(section);
    if (section is Map && section['updates'] is Map) {
      final updates = section['updates'] as Map;
      MetaverseUpdateStore(root)
        ..setFrequency(
          MetaverseUpdateFrequency.values.firstWhere(
            (f) => f.name == updates['frequency'],
          ),
        )
        ..setPreview(updates['preview'] as bool);
    }
    _database((db) {
      db.execute('BEGIN IMMEDIATE');
      try {
        final ids = {
          for (final row in db.select('SELECT id FROM pending')) row['id'],
          for (final item in entries) (item['manifest'] as Map)['id'],
        };
        if (ids.length > 32) throw const FormatException('待恢复插件数量超过上限');
        for (final item in entries) {
          db.execute('INSERT OR REPLACE INTO pending VALUES (?, ?)', [
            (item['manifest'] as Map)['id'],
            jsonEncode(item),
          ]);
        }
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    });
  }

  List<Map<String, dynamic>> pending() => _database(
    (db) => [
      for (final row in db.select('SELECT value FROM pending ORDER BY id'))
        jsonDecode(row['value'] as String) as Map<String, dynamic>,
    ],
  );
  void remove(String id) =>
      _database((db) => db.execute('DELETE FROM pending WHERE id = ?', [id]));
}
