import 'dart:async';
import 'dart:convert';

import 'package:fluxdo_render/semantic_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 紧急草稿只能在同一站点、同一已登录账号下查看；旧版无归属记录不猜测归属。
class SemanticRecoveryScope {
  const SemanticRecoveryScope({required this.site, required this.userId});

  final String site;
  final int userId;

  bool get isValid => site.isNotEmpty && userId > 0;

  bool matches(Map<String, dynamic> json) =>
      isValid && json['site'] == site && json['userId'] == userId;

  Map<String, dynamic> toJson() => {'site': site, 'userId': userId};
}

class SemanticRecoveryRecord {
  const SemanticRecoveryRecord({
    required this.id,
    required this.scope,
    required this.savedAt,
    required this.lastRaw,
    required this.tree,
    required this.description,
  });

  final String id;
  final SemanticRecoveryScope scope;
  final DateTime savedAt;
  final String lastRaw;
  final SemanticNode tree;
  final String description;

  String get preview {
    final text = tree.textContent.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'scope': scope.toJson(),
    'savedAtMillis': savedAt.millisecondsSinceEpoch,
    'lastRaw': lastRaw,
    'semanticTree': tree.toJson(),
    'description': description,
  };
}

/// 串行读改写，避免 dispose 的异步备份覆盖用户刚刚执行的删除。
/// 不认识、损坏或无账号归属的记录保留原样，但绝不向当前用户暴露内容。
class SemanticRecoveryStore {
  static const storageKey = 'rich_composer_semantic_recovery';
  static Future<void>? _pending;

  Future<T> _serialized<T>(Future<T> Function(SharedPreferences) operation) {
    Future<T> run() async => operation(await SharedPreferences.getInstance());
    final previous = _pending;
    final result = previous == null ? run() : previous.then((_) => run());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pending = tail;
    // 空闲时释放尾 Future，避免保留已结束的调用域（含测试时钟）。
    unawaited(
      tail.then((_) {
        if (identical(_pending, tail)) _pending = null;
      }),
    );
    return result;
  }

  Map<String, dynamic>? _decode(String raw) {
    try {
      final value = jsonDecode(raw);
      return value is Map<String, dynamic> ? value : null;
    } catch (_) {
      return null;
    }
  }

  bool _matches(
    Map<String, dynamic>? json,
    SemanticRecoveryScope scope,
    String id,
  ) =>
      json != null &&
      json['id'] == id &&
      json['scope'] is Map<String, dynamic> &&
      scope.matches(json['scope'] as Map<String, dynamic>);

  Future<List<SemanticRecoveryRecord>> read(SemanticRecoveryScope scope) =>
      _serialized((prefs) async {
        if (!scope.isValid) return [];
        final records = <SemanticRecoveryRecord>[];
        for (final raw in prefs.getStringList(storageKey) ?? <String>[]) {
          try {
            final json = _decode(raw);
            if (json == null ||
                json['version'] != 1 ||
                json['scope'] is! Map<String, dynamic> ||
                !scope.matches(json['scope'] as Map<String, dynamic>)) {
              continue;
            }
            final id = json['id'] as String;
            if (id.isEmpty) continue;
            records.add(
              SemanticRecoveryRecord(
                id: id,
                scope: scope,
                savedAt: DateTime.fromMillisecondsSinceEpoch(
                  json['savedAtMillis'] as int,
                ),
                lastRaw: json['lastRaw'] as String,
                tree: SemanticNode.fromJson(
                  Map<String, dynamic>.from(json['semanticTree'] as Map),
                ),
                description: json['description'] as String,
              ),
            );
          } catch (_) {
            // 单条损坏不应阻止其他草稿被发现，也不能污染当前正文。
          }
        }
        records.sort((a, b) => b.savedAt.compareTo(a.savedAt));
        return records;
      });

  Future<void> save(SemanticRecoveryRecord record) =>
      _serialized((prefs) async {
        if (!record.scope.isValid) return;
        final records = prefs.getStringList(storageKey) ?? <String>[];
        records.removeWhere(
          (raw) => _matches(_decode(raw), record.scope, record.id),
        );
        records.add(jsonEncode(record.toJson()));
        if (!await prefs.setStringList(storageKey, records)) {
          throw StateError('紧急草稿保存失败');
        }
      });

  /// 仅明确丢弃或确认安全同步后调用；不触及其他账号以及无法识别的记录。
  Future<void> remove(SemanticRecoveryScope scope, String id) =>
      _serialized((prefs) async {
        if (!scope.isValid) return;
        final records = prefs.getStringList(storageKey) ?? <String>[];
        records.removeWhere((raw) => _matches(_decode(raw), scope, id));
        if (!await prefs.setStringList(storageKey, records)) {
          throw StateError('紧急草稿删除失败');
        }
      });
}
