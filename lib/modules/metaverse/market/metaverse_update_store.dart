import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../plugin/metaverse_plugin_store.dart';

enum MetaverseUpdateFrequency {
  disabled(Duration.zero),
  sixHours(Duration(hours: 6)),
  daily(Duration(days: 1)),
  weekly(Duration(days: 7));

  const MetaverseUpdateFrequency(this.interval);
  final Duration interval;
}

class MetaverseUpdateState {
  const MetaverseUpdateState({
    this.frequency = MetaverseUpdateFrequency.daily,
    this.excluded = const {},
    this.reports = const {},
    this.lastCheck,
    this.nextCheck = 0,
    this.retryAt = 0,
    this.checking = false,
    this.failed = false,
  });
  final MetaverseUpdateFrequency frequency;
  final Set<String> excluded;
  final Map<String, Map<String, dynamic>> reports;
  final int? lastCheck;
  final int nextCheck, retryAt;
  final bool checking, failed;
  bool get enabled => frequency != MetaverseUpdateFrequency.disabled;
  bool allows(InstalledMetaversePlugin plugin) =>
      !excluded.contains(keyFor(plugin));
  static String keyFor(InstalledMetaversePlugin plugin) =>
      jsonEncode([plugin.id, plugin.source]);
}

/// 更新计划与待安装包不属于插件数据。短事务隔离前台和系统唤醒，后台不改安装索引。
class MetaverseUpdateStore {
  MetaverseUpdateStore(Directory directory, {DateTime Function()? clock})
    : path = '${directory.path}/updates.sqlite',
      _clock = clock ?? DateTime.now {
    directory.createSync(recursive: true);
  }
  final String path;
  final DateTime Function() _clock;
  int get now => _clock().millisecondsSinceEpoch;

  T _transaction<T>(
    T Function(Database db, Map<String, dynamic> state) action, {
    bool readOnly = false,
  }) {
    final db = sqlite3.open(path);
    try {
      db.execute('PRAGMA busy_timeout = 3000');
      db.execute(
        'CREATE TABLE IF NOT EXISTS settings (id INTEGER PRIMARY KEY, value TEXT NOT NULL)',
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS pending (id TEXT PRIMARY KEY, base TEXT NOT NULL, digest TEXT NOT NULL, body BLOB NOT NULL)',
      );
      db.execute(readOnly ? 'BEGIN' : 'BEGIN IMMEDIATE');
      try {
        final rows = db.select('SELECT value FROM settings WHERE id = 1');
        final state = rows.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(rows.single['value'] as String)
                  as Map<String, dynamic>;
        final result = action(db, state);
        if (!readOnly) {
          db.execute('INSERT OR REPLACE INTO settings VALUES (1, ?)', [
            jsonEncode(state),
          ]);
        }
        db.execute('COMMIT');
        return result;
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    } finally {
      db.close();
    }
  }

  static String baseOf(InstalledMetaversePlugin plugin) =>
      jsonEncode([plugin.source, plugin.manifest.version, plugin.codeRevision]);
  static MetaverseUpdateFrequency _frequency(Map<String, dynamic> s) =>
      MetaverseUpdateFrequency.values
          .where((v) => v.name == s['frequency'])
          .firstOrNull ??
      MetaverseUpdateFrequency.daily;
  static Map<String, dynamic> _reports(Map<String, dynamic> s) =>
      (s['reports'] ??= <String, dynamic>{}) as Map<String, dynamic>;

  MetaverseUpdateState snapshot() => _transaction(
    (db, s) => MetaverseUpdateState(
      frequency: _frequency(s),
      excluded: Set<String>.from(s['excluded'] as List? ?? []),
      reports: {
        for (final entry in _reports(s).entries)
          entry.key: Map<String, dynamic>.from(entry.value as Map),
      },
      lastCheck: s['lastCheck'] as int?,
      nextCheck: s['nextCheck'] as int? ?? 0,
      retryAt: s['retryAt'] as int? ?? 0,
      checking: (s['leaseUntil'] as int? ?? 0) > now,
      failed: s['failed'] == true,
    ),
    readOnly: true,
  );

  void setFrequency(MetaverseUpdateFrequency value) => _transaction((db, s) {
    if (_frequency(s) == value) return;
    s['frequency'] = value.name;
    _cancel(s);
    final next =
        (s['lastCheck'] as int? ?? now) + value.interval.inMilliseconds;
    final retry = s['retryAt'] as int? ?? 0;
    s['nextCheck'] = next > retry ? next : retry;
  });
  void setAllowed(InstalledMetaversePlugin plugin, bool allowed) =>
      _transaction((db, s) {
        final excluded = Set<String>.from(s['excluded'] as List? ?? []);
        final key = MetaverseUpdateState.keyFor(plugin);
        if (allowed) {
          excluded.remove(key);
        } else {
          excluded.add(key);
        }
        s['excluded'] = excluded.toList();
        _cancel(s);
        if (!allowed) {
          db.execute('DELETE FROM pending WHERE id = ?', [plugin.id]);
          _reports(s).remove(plugin.id);
        }
      });
  void _cancel(Map<String, dynamic> s) {
    s['generation'] = (s['generation'] as int? ?? 0) + 1;
    s.remove('lease');
    s.remove('leaseUntil');
  }

  /// 清理已卸载、换源及已被手动更新的候选，不依靠后台缓存的安装列表提交更新。
  void reconcile(List<InstalledMetaversePlugin> installed) =>
      _transaction((db, s) {
        final plugins = {for (final plugin in installed) plugin.id: plugin};
        for (final row in db.select('SELECT id, base FROM pending')) {
          final plugin = plugins[row['id']];
          if (plugin == null || baseOf(plugin) != row['base']) {
            db.execute('DELETE FROM pending WHERE id = ?', [row['id']]);
            _reports(s).remove(row['id']);
          }
        }
        _reports(s).removeWhere(
          (id, report) =>
              plugins[id] == null || plugins[id]!.source != report['source'],
        );
        final valid = installed.map(MetaverseUpdateState.keyFor).toSet();
        s['excluded'] = (s['excluded'] as List? ?? [])
            .where(valid.contains)
            .toList();
      });

  int? begin({bool force = false}) => _transaction((db, s) {
    if ((s['leaseUntil'] as int? ?? 0) > now ||
        (s['retryAt'] as int? ?? 0) > now ||
        (!force &&
            (_frequency(s) == MetaverseUpdateFrequency.disabled ||
                (s['nextCheck'] as int? ?? 0) > now))) {
      return null;
    }
    final token = (s['generation'] as int? ?? 0) + 1;
    s['generation'] = token;
    s['lease'] = token;
    s['leaseUntil'] = now + const Duration(minutes: 5).inMilliseconds;
    return token;
  });
  bool _active(Map<String, dynamic> s, int token) =>
      s['lease'] == token && (s['leaseUntil'] as int? ?? 0) > now;
  bool active(int token) =>
      _transaction((db, s) => _active(s, token), readOnly: true);

  void report(
    int token,
    InstalledMetaversePlugin plugin,
    String version,
    String status, {
    Uint8List? bytes,
    String? digest,
  }) => _transaction((db, s) {
    if (!_active(s, token)) return;
    _reports(s)[plugin.id] = {
      'source': plugin.source,
      'version': version,
      'status': status,
      'at': now,
    };
    if (bytes != null && digest != null) {
      db.execute('INSERT OR REPLACE INTO pending VALUES (?, ?, ?, ?)', [
        plugin.id,
        baseOf(plugin),
        digest,
        bytes,
      ]);
    } else if (status != 'failed') {
      db.execute('DELETE FROM pending WHERE id = ?', [plugin.id]);
    }
  });

  void finish(int token, {required bool failed, int notBefore = 0}) =>
      _transaction((db, s) {
        if (!_active(s, token)) return;
        s.remove('lease');
        s.remove('leaseUntil');
        s['lastCheck'] = now;
        s['failed'] = failed;
        final failures = failed ? (s['failures'] as int? ?? 0) + 1 : 0;
        s['failures'] = failures;
        final retry = Duration(
          minutes: (15 * (1 << (failures - 1).clamp(0, 5))).clamp(15, 360),
        );
        final localRetry = now + retry.inMilliseconds;
        s['retryAt'] = failed
            ? (notBefore > localRetry ? notBefore : localRetry)
            : 0;
        s['nextCheck'] = failed
            ? s['retryAt']
            : now + _frequency(s).interval.inMilliseconds;
      });

  ({String base, String digest, Uint8List bytes})? pending(String id) =>
      _transaction((db, s) {
        final rows = db.select('SELECT * FROM pending WHERE id = ?', [id]);
        if (rows.isEmpty) return null;
        final row = rows.single;
        return (
          base: row['base'] as String,
          digest: row['digest'] as String,
          bytes: row['body'] as Uint8List,
        );
      }, readOnly: true);
  void applied(InstalledMetaversePlugin plugin) => _transaction((db, s) {
    db.execute('DELETE FROM pending WHERE id = ?', [plugin.id]);
    _reports(s)[plugin.id] = {
      'source': plugin.source,
      'version': plugin.manifest.version,
      'status': 'updated',
      'at': now,
    };
  });

  /// 后台引擎可能没有日志文件句柄，先持久化，再由前台归入各插件日志。
  void queueEvent(Map<String, dynamic> event) => _transaction((db, s) {
    final events = List<dynamic>.from(s['events'] as List? ?? []);
    events.add({...event, 'timestamp': _clock().toIso8601String()});
    s['events'] = events
        .skip((events.length - 64).clamp(0, events.length))
        .toList();
  });
  List<Map<String, dynamic>> takeEvents() => _transaction((db, s) {
    final events = [
      for (final event in s['events'] as List? ?? [])
        Map<String, dynamic>.from(event as Map),
    ];
    s.remove('events');
    return events;
  });

  void discard(String id, {String? status}) => _transaction((db, s) {
    db.execute('DELETE FROM pending WHERE id = ?', [id]);
    if (status == null) {
      _reports(s).remove(id);
    } else if (_reports(s)[id] case final Map report) {
      report['status'] = status;
    }
  });
}
