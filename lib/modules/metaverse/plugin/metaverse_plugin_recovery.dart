part of 'metaverse_plugin_store.dart';

/// 代码索引与数据切换通过持久准备记录衔接；启动时按已提交索引完成或撤销。
/// 设计依据: docs/plugins/automatic-updates.md 的版本恢复与数据迁移约定。
extension MetaversePluginRecovery on MetaversePluginStore {
  Future<Map<String, Object?>> preferences(MetaversePluginManifest manifest) =>
      _dataTransaction(manifest.id, (db) {
        final saved = _release(db)['preferences'] as Map? ?? const {};
        return {
          for (final field in manifest.preferences)
            field.key: field.accepts(saved[field.key])
                ? saved[field.key]
                : field.defaultValue,
        };
      });
  Future<void> setPreference(
    MetaversePluginManifest manifest,
    String key,
    Object value,
  ) => _operations.run(
    manifest.id,
    () => _dataTransaction(manifest.id, (db) {
      final spec = manifest.preferences.where((f) => f.key == key).firstOrNull;
      if (spec == null || !spec.accepts(value)) throw ArgumentError('偏好值无效');
      final state = _release(db);
      (state['preferences'] ??= <String, Object?>{})[key] = value;
      _saveRelease(db, state);
    }),
  );
  Map<String, dynamic> _release(Database db) {
    db.execute(
      'CREATE TABLE IF NOT EXISTS release_state (id INTEGER PRIMARY KEY, value TEXT NOT NULL)',
    );
    final rows = db.select('SELECT value FROM release_state WHERE id = 1');
    return rows.isEmpty
        ? {}
        : jsonDecode(rows.single['value'] as String) as Map<String, dynamic>;
  }

  void _saveRelease(Database db, Map<String, dynamic> value) => db.execute(
    'INSERT OR REPLACE INTO release_state VALUES (1, ?)',
    [jsonEncode(value)],
  );

  Future<Map<String, dynamic>> releaseStatus(String id) =>
      _dataTransaction(id, (db) {
        final state = _release(db);
        return {
          for (final key in [
            'previous',
            'target',
            'healthy',
            'rejected',
            'reason',
          ])
            if (state.containsKey(key)) key: state[key],
          if (state['prepared'] is Map)
            'prepared': {'target': state['prepared']['target']},
        };
      });

  Future<void> prepareRelease(
    InstalledMetaversePlugin? previous,
    InstalledMetaversePlugin next,
    Map<String, Object?> data, {
    bool reset = false,
    Map<String, Object?>? preferences,
  }) => _operations.run(
    next.id,
    () => _dataTransaction(next.id, (db) {
      if (utf8.encode(jsonEncode(data)).length >
          MetaversePluginStore.maxStorageBytes) {
        throw StateError('插件存储超出容量上限');
      }
      final state = _release(db);
      state['prepared'] = {
        'previous': previous?.toJson(),
        'target': next.codeRevision,
        'installationId': next.installationId,
        'snapshot': _readData(db),
        'candidate': data,
        'reset': reset,
        'preferences': ?preferences,
      };
      _saveRelease(db, state);
    }),
  );

  bool _matchesPrepared(Map prepared, InstalledMetaversePlugin installed) =>
      prepared['target'] == installed.codeRevision &&
      (prepared['installationId'] == null ||
          prepared['installationId'] == installed.installationId);

  Future<void> settleRelease(InstalledMetaversePlugin installed) =>
      _operations.run(installed.id, () async {
        final pending = await _dataTransaction(
          installed.id,
          (db) => _release(db)['prepared'],
        );
        if (pending is! Map) return;
        // 凭证清理失败时保留准备记录，下一次启动仍必须先完成清理。
        if (_matchesPrepared(pending, installed) && pending['reset'] == true) {
          await _deleteToken(installed.id);
          await clearLegacyPluginRecords(_secretStore, installed.id);
        }
        await _dataTransaction(installed.id, (db) {
          final state = _release(db), prepared = state['prepared'];
          if (prepared is! Map) return;
          if (_matchesPrepared(prepared, installed)) {
            _saveData(
              db,
              (prepared['candidate'] as Map).cast<String, Object?>(),
            );
            if (prepared['reset'] == true) {
              state.clear();
            } else {
              state.addAll({
                'previous': prepared['previous'],
                'target': prepared['target'],
                'snapshot': prepared['snapshot'],
                'healthy': false,
              });
              state.remove('reason');
            }
            if (prepared['preferences'] is Map)
              state['preferences'] = prepared['preferences'];
            if (prepared['rollback'] == true) {
              state
                ..remove('previous')
                ..remove('snapshot');
              state['healthy'] = true;
              state['reason'] = 'rollback';
            }
          } else if ((prepared['previous'] as Map?)?['codeRevision'] !=
                  installed.codeRevision ||
              (prepared['previous'] as Map?)?['installationId'] !=
                  installed.installationId) {
            throw StateError('插件版本恢复记录与安装索引不一致');
          }
          state.remove('prepared');
          _saveRelease(db, state);
        });
      });

  Future<void> markHealthy(String id, String? revision) => _operations.run(
    id,
    () => _dataTransaction(id, (db) {
      final state = _release(db);
      if (state['target'] == revision && revision != null) {
        state['healthy'] = true;
        _saveRelease(db, state);
      }
    }),
  );

  Future<InstalledMetaversePlugin?> previousRelease(
    InstalledMetaversePlugin installed, {
    bool probationOnly = false,
  }) async {
    await settleRelease(installed);
    final state = await releaseStatus(installed.id);
    if (state['target'] != installed.codeRevision ||
        (probationOnly && state['healthy'] == true))
      return null;
    final previous = state['previous'];
    if (previous is! Map<String, dynamic>) return null;
    final record = InstalledMetaversePlugin.fromJson(
      previous,
      reservedHosts: reservedHosts,
    );
    if (record.source != installed.source ||
        !record.manifest.runtimeSupported ||
        record.codeRevision == null)
      return null;
    await readCodeRevision(record.id, record.codeRevision!);
    return record;
  }

  /// 回退也先准备，再切索引。保留用户后来关闭的权限，不恢复旧授权。
  Future<void> prepareRollback(
    InstalledMetaversePlugin current,
    InstalledMetaversePlugin previous,
  ) => _operations.run(
    current.id,
    () => _dataTransaction(current.id, (db) {
      final state = _release(db);
      if (state['target'] != current.codeRevision || state['snapshot'] is! Map)
        throw StateError('没有可恢复的数据快照');
      state['rejected'] = <String>{
        ...List<String>.from(state['rejected'] as List? ?? []),
        current.codeRevision!,
      }.toList().reversed.take(16).toList();
      state['prepared'] = {
        'previous': current.toJson(),
        'target': previous.codeRevision,
        'rollback': true,
        'installationId': previous.installationId,
        'snapshot': _readData(db),
        'candidate': state['snapshot'],
      };
      _saveRelease(db, state);
    }),
  );

  Future<void> finishRollback(
    InstalledMetaversePlugin installed,
    String reason,
  ) async {
    await settleRelease(installed);
    await _operations.run(
      installed.id,
      () => _dataTransaction(installed.id, (db) {
        final state = _release(db)
          ..remove('previous')
          ..remove('snapshot');
        state['healthy'] = true;
        state['reason'] = reason;
        _saveRelease(db, state);
      }),
    );
    await pruneCode(installed);
  }

  Future<void> pruneCode(InstalledMetaversePlugin installed) =>
      _operations.run(installed.id, () async {
        final state = await releaseStatus(installed.id);
        final keep = {
          installed.codeRevision,
          (state['previous'] as Map?)?['codeRevision'],
          (state['prepared'] as Map?)?['target'],
        };
        final directory = await _directory(installed.id);
        await for (final file in directory.list(followLinks: false)) {
          if (file is! File) continue;
          final match = RegExp(r'^code-([a-f0-9]{64})\.json$')
              .firstMatch(p.basename(file.path));
          if (match != null && !keep.contains(match[1])) await file.delete();
        }
      });

  Future<void> clearReleaseHistory(String id) => _operations.run(
    id,
    () => _dataTransaction(id, (db) {
      _saveRelease(db, {});
    }),
  );
}
