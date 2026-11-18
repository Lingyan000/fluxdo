import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

import '../plugin/metaverse_plugin_store.dart';
import '../plugin/metaverse_task.dart';

/// 宿主控制记录独立于插件数据。短事务提供跨引擎调度租约与撤销边界。
class MetaverseTaskStore {
  MetaverseTaskStore(Directory root, {DateTime Function()? clock})
    : path = '${root.path}/tasks.sqlite',
      _clock = clock ?? DateTime.now {
    root.createSync(recursive: true);
  }
  final String path;
  final DateTime Function() _clock;
  int get now => _clock().millisecondsSinceEpoch;

  T transaction<T>(
    T Function(Map<String, dynamic> state) action, {
    bool readOnly = false,
  }) {
    final db = sqlite3.open(path);
    try {
      db.execute('PRAGMA busy_timeout = 3000');
      db.execute(
        'CREATE TABLE IF NOT EXISTS control (id INTEGER PRIMARY KEY, value TEXT NOT NULL)',
      );
      db.execute(readOnly ? 'BEGIN' : 'BEGIN IMMEDIATE');
      try {
        final rows = db.select('SELECT value FROM control WHERE id = 1');
        final state = rows.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(rows.single['value'] as String)
                  as Map<String, dynamic>;
        final result = action(state);
        if (!readOnly) {
          db.execute('INSERT OR REPLACE INTO control VALUES (1, ?)', [
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

  static Map<String, dynamic> map(Map<String, dynamic> s, String key) =>
      (s[key] ??= <String, dynamic>{}) as Map<String, dynamic>;

  List<int> sync({
    required int? accountId,
    required String? username,
    required List<InstalledMetaversePlugin> plugins,
  }) => transaction((s) {
    final dismissed = <int>[];
    if ((s['account'] as Map?)?['id'] != accountId) {
      dismissed.addAll(
        map(s, 'notifications').values.map((v) => v['id'] as int),
      );
      for (final kind in ['jobs', 'notifications', 'grants', 'badges']) {
        map(s, kind).clear();
      }
      s.remove('events');
      s['epoch'] = (s['epoch'] as int? ?? 0) + 1;
      s['account'] = accountId == null
          ? null
          : {'id': accountId, 'username': username};
    }
    final approved = {
      for (final p in plugins)
        if (p.enabled &&
            p.suspendedReason == null &&
            p.manifest.runtimeSupported &&
            (p.manifest.tasks.isNotEmpty ||
                p.manifest.capabilities.notifications ||
                p.manifest.requiredFeatures.contains('navigationBadge')))
          p.id: {'revision': p.codeRevision, 'source': p.source},
    };
    final previous = map(s, 'plugins');
    for (final id in previous.keys.toList()) {
      if (!approved.containsKey(id) ||
          approved[id]?['source'] != previous[id]['source']) {
        dismissed.addAll(
          map(
            s,
            'notifications',
          ).values.where((v) => v['plugin'] == id).map((v) => v['id'] as int),
        );
        _removePlugin(s, id);
      }
    }
    s['plugins'] = approved;
    return dismissed;
  });

  void _removePlugin(Map<String, dynamic> s, String id) {
    (s['events'] as List?)?.removeWhere((event) => event['pluginId'] == id);
    for (final kind in ['jobs', 'badges', 'notifications', 'grants']) {
      map(s, kind).removeWhere((_, value) => (value as Map)['plugin'] == id);
    }
  }

  void revoke(String id) => transaction((s) {
    _removePlugin(s, id);
    map(s, 'plugins').remove(id);
  });
  Map<String, dynamic> snapshot() => transaction((s) => s, readOnly: true);
  String _key(int account, String plugin, String id) => '$account:$plugin:$id';

  static int dueAt(Map job, {required bool background}) {
    final due = job['nextAt'] as int, os = job['backgroundAfter'] as int? ?? 0;
    return background && os > due ? os : due;
  }

  Map<String, dynamic> schedule(
    int account,
    String plugin,
    MetaverseTaskSchedule request, {
    required bool background,
  }) => transaction((s) {
    if ((s['account'] as Map?)?['id'] != account ||
        !map(s, 'plugins').containsKey(plugin)) {
      throw const MetaversePluginCallException('task_account_changed');
    }
    final key = _key(account, plugin, request.id);
    final job = <String, dynamic>{
      'id': request.id,
      'plugin': plugin,
      'account': account,
      'intervalSeconds': request.intervalSeconds,
      'background': background,
      'nextAt': now + request.intervalSeconds * 1000,
      'failures': 0,
    };
    map(s, 'jobs')[key] = job;
    return Map<String, dynamic>.of(job);
  });
  void cancel(int account, String plugin, String id) => transaction((s) {
    map(s, 'jobs').remove(_key(account, plugin, id));
  });
  List<Map<String, dynamic>> tasks(int account, String plugin) => transaction(
    (s) => map(s, 'jobs').values
        .where((v) => v['account'] == account && v['plugin'] == plugin)
        .map(
          (v) => {
            for (final key in [
              'id',
              'intervalSeconds',
              'background',
              'nextAt',
              'lastAt',
              'error',
            ])
              key: v[key],
          },
        )
        .toList(),
    readOnly: true,
  );

  /// 全局每次执行一项；持久化租约防止两个 Flutter engine 重复执行。
  Map<String, dynamic>? claim({required bool background}) => transaction((s) {
    final account = (s['account'] as Map?)?['id'];
    if (account == null) return null;
    final jobs = map(s, 'jobs');
    if (jobs.values.any((v) => (v['leaseUntil'] as int? ?? 0) > now)) {
      return null;
    }
    final candidates =
        jobs.entries.where((entry) {
          final v = entry.value as Map;
          return v['account'] == account &&
              map(s, 'plugins').containsKey(v['plugin']) &&
              (!background || v['background'] == true) &&
              dueAt(v, background: background) <= now;
        }).toList()..sort(
          (a, b) =>
              (a.value['nextAt'] as int).compareTo(b.value['nextAt'] as int),
        );
    if (candidates.isEmpty) return null;
    final selected = candidates.first;
    final job = selected.value as Map<String, dynamic>;
    s['sequence'] = (s['sequence'] as int? ?? 0) + 1;
    final token = [s['epoch'], now, s['sequence']].join(':');
    job['lease'] = token;
    job['leaseUntil'] = now + 30000;
    // 进程被终止时不会立即重复执行；不补发积压周期。
    final interval = (job['intervalSeconds'] as int) * 1000;
    job['nextAt'] = now + interval;
    if (background) {
      job['backgroundAfter'] = now + (interval < 900000 ? 900000 : interval);
    }
    return {
      ...job,
      'key': selected.key,
      'epoch': s['epoch'],
      'installed': map(s, 'plugins')[job['plugin']],
      'username': s['account']['username'],
    };
  });

  bool active(Map<String, dynamic> lease) => transaction((s) {
    final job = map(s, 'jobs')[lease['key']] as Map?;
    return s['epoch'] == lease['epoch'] &&
        (s['account'] as Map?)?['id'] == lease['account'] &&
        job?['lease'] == lease['lease'] &&
        (job?['leaseUntil'] as int? ?? 0) > now &&
        jsonEncode(map(s, 'plugins')[lease['plugin']]) ==
            jsonEncode(lease['installed']);
  }, readOnly: true);

  void finish(Map<String, dynamic> lease, {String? error}) => transaction((s) {
    final job = map(s, 'jobs')[lease['key']] as Map?;
    if (job == null ||
        job['lease'] != lease['lease'] ||
        s['epoch'] != lease['epoch'] ||
        jsonEncode(map(s, 'plugins')[lease['plugin']]) !=
            jsonEncode(lease['installed'])) {
      return;
    }
    job.remove('lease');
    job.remove('leaseUntil');
    job['lastAt'] = now;
    job['error'] = error;
    final failures = error == null
        ? 0
        : ((job['failures'] as int? ?? 0) + 1).clamp(1, 8);
    job['failures'] = failures;
    if (failures > 0) {
      final retry = now + (60000 * (1 << (failures - 1))).clamp(60000, 3600000);
      if (retry > job['nextAt']) job['nextAt'] = retry;
    }
  });

  // 由前台唯一写入方轮转日志文件；后台只暂存已经脱敏的记录。
  void queueEvents(int account, List<Map<String, dynamic>> events) => transaction((s) {
    if ((s['account'] as Map?)?['id'] != account) return;
    final queue = (s['events'] ??= <dynamic>[]) as List;
    for (final event in events) {
      if (map(s, 'plugins').containsKey(event['pluginId'])) queue.add(event);
    }
    while (queue.length > 64 || utf8.encode(jsonEncode(queue)).length > 128 * 1024) { queue.removeAt(0); }
  });

  List<Map<String, dynamic>> takeEvents() => transaction((s) =>
      [for (final event in (s.remove('events') as List?) ?? []) Map<String, dynamic>.from(event as Map)]);

  void setBadge(int account, String plugin, String page, int count) =>
      transaction((s) {
        _requireOwner(s, account, plugin);
        map(s, 'badges')[_key(account, plugin, page)] = {
          'account': account,
          'plugin': plugin,
          'page': page,
          'count': count,
        };
      });
  Map<String, int> badges(int account) => transaction(
    (s) => {
      for (final badge in map(s, 'badges').values)
        if (badge['account'] == account &&
            map(s, 'plugins').containsKey(badge['plugin']))
          ['plugin', badge['plugin'], badge['page']].join(':'):
              badge['count'] as int,
    },
    readOnly: true,
  );

  bool notificationsAllowed(int account, String plugin) => transaction(
    (s) =>
        (map(s, 'grants')[_key(account, plugin, 'notifications')]
            as Map?)?['allowed'] ==
        true,
    readOnly: true,
  );
  void allowNotifications(int account, String plugin, bool value) =>
      transaction((s) {
        _requireOwner(s, account, plugin);
        map(s, 'grants')[_key(account, plugin, 'notifications')] = {
          'plugin': plugin,
          'account': account,
          'allowed': value,
        };
      });

  /// 通知使用宿主分配的稳定整数 ID；相同业务键更新同一条，不刷屏。
  Map<String, dynamic> notification(
    int account,
    String plugin,
    String key, {
    required String page,
    required Map<String, Object?> params,
  }) => transaction((s) {
    _requireOwner(s, account, plugin);
    if ((map(s, 'grants')[_key(account, plugin, 'notifications')]
            as Map?)?['allowed'] !=
        true) {
      throw const MetaversePluginCallException(
        'notification_permission_denied',
      );
    }
    final entries = map(s, 'notifications'), full = _key(account, plugin, key);
    final existing = entries[full] as Map?;
    if (entries.values
            .where(
              (v) => v['plugin'] == plugin && now - (v['at'] as int) < 60000,
            )
            .length >=
        3) {
      return {'deliver': false};
    }
    if (existing == null &&
        entries.values.where((v) => v['plugin'] == plugin).length >= 64) {
      throw const MetaversePluginCallException('notification_limit');
    }
    final id =
        existing?['id'] ??
        (1000000 + ((s['notificationSequence'] as int? ?? 0) + 1) % 1000000000);
    if (existing == null) {
      s['notificationSequence'] = (s['notificationSequence'] as int? ?? 0) + 1;
    }
    final data = {
      'id': id,
      'plugin': plugin,
      'account': account,
      'page': page,
      'params': params,
      'at': now,
      'key': key,
    };
    final deliver = existing == null || now - (existing['at'] as int) >= 60000;
    if (deliver) entries[full] = data;
    return {...data, 'deliver': deliver};
  });

  List<int> notificationIds(String plugin, {int? account, String? key}) =>
      transaction(
        (s) => map(s, 'notifications').values
            .where(
              (v) =>
                  v['plugin'] == plugin &&
                  (account == null || v['account'] == account) &&
                  (key == null || v['key'] == key),
            )
            .map((v) => v['id'] as int)
            .toList(),
        readOnly: true,
      );
  void forgetNotifications(String plugin, {int? account, String? key}) =>
      transaction((s) {
        map(s, 'notifications').removeWhere(
          (_, v) =>
              v['plugin'] == plugin &&
              (account == null || v['account'] == account) &&
              (key == null || v['key'] == key),
        );
      });
  Map<String, dynamic>? notificationTarget(int id) => transaction((s) {
    final account = (s['account'] as Map?)?['id'];
    for (final item in map(s, 'notifications').values) {
      if (item['id'] == id &&
          item['account'] == account &&
          (map(s, 'grants')[_key(account, item['plugin'], 'notifications')] as Map?)?['allowed'] == true &&
          map(s, 'plugins').containsKey(item['plugin'])) {
        return Map<String, dynamic>.from(item as Map);
      }
    }
    return null;
  }, readOnly: true);

  void _requireOwner(Map<String, dynamic> s, int account, String plugin) {
    if ((s['account'] as Map?)?['id'] != account ||
        !map(s, 'plugins').containsKey(plugin)) {
      throw const MetaversePluginCallException('task_account_changed');
    }
  }
}
