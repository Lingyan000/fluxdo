import 'dart:convert';

import 'package:hive_ce/hive.dart';

import '../models/draft.dart';
import '../storage/app_database.dart';

typedef LocalDraftBoxFactory = Future<Box<Map>> Function();

class LocalDraftEntry {
  const LocalDraftEntry({
    required this.data,
    required this.sequence,
    required this.updatedAt,
    this.synced = false,
    this.baseFingerprint,
  });

  final DraftData data;
  final int sequence;
  final DateTime updatedAt;
  final bool synced;
  final String? baseFingerprint;
  bool get hasLocalChanges =>
      !synced && data.contentFingerprint != baseFingerprint;
}

/// 本地草稿快照。云端确认后保留缓存，发送或舍弃后清理。
class LocalDraftStore {
  LocalDraftStore({
    LocalDraftBoxFactory? boxFactory,
    DateTime Function()? now,
    this.retention = const Duration(days: 30),
  }) : _boxFactory =
           boxFactory ?? (() => AppDatabase.namedBox(_defaultBoxName)),
       _now = now ?? DateTime.now;

  static const String _defaultBoxName = 'local_drafts';
  static const String _dataKey = 'data';
  static const String _sequenceKey = 'sequence';
  static const String _updatedAtKey = 'updated_at';

  final LocalDraftBoxFactory _boxFactory;
  final DateTime Function() _now;
  final Duration retention;

  Future<LocalDraftEntry?> read(String accountId, String draftKey) async {
    final box = await _boxFactory();
    await _pruneExpired(box);
    final raw = box.get(_entryKey(accountId, draftKey));
    if (raw == null) return null;

    try {
      final encodedData = raw[_dataKey] as String;
      return LocalDraftEntry(
        data: DraftData.fromJson(
          jsonDecode(encodedData) as Map<String, dynamic>,
        ),
        sequence: (raw[_sequenceKey] as num?)?.toInt() ?? 0,
        updatedAt: DateTime.parse(raw[_updatedAtKey] as String),
        synced: raw['synced'] == true,
        baseFingerprint: _normalizeFingerprint(
          raw['base_fingerprint'] as String?,
        ),
      );
    } catch (_) {
      await box.delete(_entryKey(accountId, draftKey));
      return null;
    }
  }

  Future<void> write({
    required String accountId,
    required String draftKey,
    required DraftData data,
    required int sequence,
    bool synced = false,
    String? baseFingerprint,
  }) async {
    final box = await _boxFactory();
    await _pruneExpired(box);
    await box.put(_entryKey(accountId, draftKey), {
      _dataKey: data.toJsonString(),
      _sequenceKey: sequence,
      _updatedAtKey: _now().toUtc().toIso8601String(),
      'synced': synced,
      'base_fingerprint': ?baseFingerprint,
    });
  }

  /// 保存回执只能确认同一份内容；拉取云端时可替换指定的旧缓存。
  /// 两种路径都不能覆盖另一个编辑器已经写入的新内容。
  Future<bool> recordSync({
    required String accountId,
    required String draftKey,
    required DraftData data,
    required int sequence,
    required bool synced,
    String? baseFingerprint,
    String? expectedFingerprint,
  }) async {
    final box = await _boxFactory();
    final key = _entryKey(accountId, draftKey);
    final raw = box.get(key);
    if (raw != null) {
      final current = DraftData.fromJson(
        jsonDecode(raw[_dataKey] as String) as Map<String, dynamic>,
      );
      if (current.contentFingerprint != data.contentFingerprint &&
          current.contentFingerprint != expectedFingerprint) {
        return false;
      }
    }
    await box.put(key, {
      _dataKey: data.toJsonString(),
      _sequenceKey: sequence,
      _updatedAtKey: raw?[_updatedAtKey] ?? _now().toUtc().toIso8601String(),
      'synced': synced,
      'base_fingerprint': ?baseFingerprint,
    });
    return true;
  }

  /// 列表响应也更新已同步缓存；列表有分页，缺席的 key 不代表已删除。
  Future<void> cacheRemoteDrafts(String accountId, List<Draft> drafts) async {
    for (final draft in drafts) {
      final local = await read(accountId, draft.draftKey);
      if (local?.hasLocalChanges == true &&
          local!.data.contentFingerprint != draft.data.contentFingerprint) {
        continue;
      }
      await recordSync(
        accountId: accountId,
        draftKey: draft.draftKey,
        data: draft.data,
        sequence: draft.sequence,
        synced: true,
        baseFingerprint: draft.data.contentFingerprint,
        expectedFingerprint: local?.data.contentFingerprint,
      );
    }
  }

  String? _normalizeFingerprint(String? fingerprint) {
    if (fingerprint == null) return null;
    try {
      return DraftData.fromJson(
        jsonDecode(fingerprint) as Map<String, dynamic>,
      ).contentFingerprint;
    } catch (_) {
      return fingerprint;
    }
  }

  Future<Map<String, LocalDraftEntry>> list(String accountId) async {
    final box = await _boxFactory();
    await _pruneExpired(box);
    final keys = <String>[];
    for (final key in box.keys.toList()) {
      try {
        final parts = jsonDecode(key as String) as List;
        if (parts.length == 2 && parts[0] == accountId && parts[1] is String) {
          keys.add(parts[1] as String);
        }
      } catch (_) {
        // 不属于草稿命名空间的 key 不参与恢复。
      }
    }
    final result = <String, LocalDraftEntry>{};
    for (final key in keys) {
      final entry = await read(accountId, key);
      if (entry != null) result[key] = entry;
    }
    return result;
  }

  /// 只删除服务端刚确认的那个版本，避免旧请求误删后续输入。
  Future<bool> deleteIfMatches({
    required String accountId,
    required String draftKey,
    required DraftData data,
  }) async {
    final box = await _boxFactory();
    final key = _entryKey(accountId, draftKey);
    final raw = box.get(key);
    if (raw?[_dataKey] != data.toJsonString()) return false;
    await box.delete(key);
    return true;
  }

  Future<void> delete(String accountId, String draftKey) async {
    final box = await _boxFactory();
    await box.delete(_entryKey(accountId, draftKey));
  }

  Future<void> _pruneExpired(Box<Map> box) async {
    final cutoff = _now().toUtc().subtract(retention);
    final expiredKeys = <dynamic>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      final updatedAtRaw = raw?[_updatedAtKey] as String?;
      final updatedAt = updatedAtRaw == null
          ? null
          : DateTime.tryParse(updatedAtRaw)?.toUtc();
      if (updatedAt == null || updatedAt.isBefore(cutoff)) {
        expiredKeys.add(key);
      }
    }
    if (expiredKeys.isNotEmpty) await box.deleteAll(expiredKeys);
  }

  String _entryKey(String accountId, String draftKey) {
    return jsonEncode([accountId, draftKey]);
  }
}

/// 在线列表以服务器为准，同时保留尚未同步的本地稿；断网时使用本地缓存。
List<Draft> mergeLocalDrafts(
  List<Draft> server,
  Map<String, LocalDraftEntry> local, {
  required bool serverAvailable,
}) {
  final drafts = {for (final draft in server) draft.draftKey: draft};
  for (final item in local.entries) {
    final entry = item.value;
    final remote = drafts[item.key];
    if (!entry.data.hasContent) {
      if (remote == null ||
          remote.sequence <= entry.sequence ||
          remote.data.contentFingerprint == entry.baseFingerprint) {
        drafts.remove(item.key);
      }
      continue;
    }
    if (!serverAvailable || entry.hasLocalChanges) {
      drafts[item.key] = (remote ?? Draft(draftKey: item.key, data: entry.data))
          .copyWith(
            data: entry.data,
            sequence: entry.sequence,
            updatedAt: entry.updatedAt,
            excerpt: entry.data.reply,
          );
    }
  }
  return drafts.values.toList()..sort(
    (a, b) => (b.updatedAt ?? DateTime(1970)).compareTo(
      a.updatedAt ?? DateTime(1970),
    ),
  );
}
