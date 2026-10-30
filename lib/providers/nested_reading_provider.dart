import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/nested_reading_position.dart';
import 'core_providers.dart';
import 'theme_provider.dart';

/// 按账号隔离；最多保存最近 200 个话题，滚动停止后合并写盘。
class NestedReadingStore {
  NestedReadingStore(this._prefs, String account)
    : _key = 'nested_reading_v1_$account',
      sortKey = 'nested_sort_$account' {
    try {
      final raw = jsonDecode(_prefs.getString(_key) ?? '{}');
      if (raw is Map) {
        for (final entry in raw.entries) {
          final id = int.tryParse('${entry.key}');
          final value = entry.value;
          if (id == null || value is! Map<String, dynamic>) continue;
          final position = NestedReadingPosition.fromJson(value);
          if (position != null) _positions[id] = position;
        }
      }
    } catch (_) {
      /* 旧记录损坏不影响打开话题。 */
    }
  }

  final SharedPreferences _prefs;
  final String _key;
  final String sortKey;
  final Map<int, NestedReadingPosition> _positions = {};
  final Map<String, NestedReadingSession> _sessions = {};
  Timer? _saveTimer;

  String get sort => nestedSort(_prefs.getString(sortKey));
  Future<void> setSort(String value) =>
      _prefs.setString(sortKey, nestedSort(value));
  NestedReadingPosition? position(int topicId) => _positions[topicId];
  NestedReadingSession? existingSession(String id) => _sessions[id];
  NestedReadingSession session(String id) {
    final result = _sessions.putIfAbsent(id, NestedReadingSession.new);
    // 窗口/栈恢复只需要最近的现场，避免无限保留懒加载子树。
    if (_sessions.length > 30) _sessions.remove(_sessions.keys.first);
    return result;
  }

  void save(int topicId, NestedReadingPosition position) {
    _positions.remove(topicId);
    _positions[topicId] = position;
    while (_positions.length > 200) {
      _positions.remove(_positions.keys.first);
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), flush);
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await _prefs.setString(
      _key,
      jsonEncode(
        _positions.map((key, value) => MapEntry('$key', value.toJson())),
      ),
    );
  }

  void dispose() {
    unawaited(flush());
  }
}

final nestedReadingStoreProvider = Provider<NestedReadingStore>((ref) {
  final account = ref.watch(
    currentUserProvider.select((user) => user.value?.username),
  );
  final store = NestedReadingStore(
    ref.watch(sharedPreferencesProvider),
    account ?? 'anonymous',
  );
  ref.onDispose(store.dispose);
  return store;
});
