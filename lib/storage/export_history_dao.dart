import 'package:hive_ce/hive.dart';

import 'app_database.dart';

/// 导出格式。
enum ExportHistoryFormat {
  markdown('md'),
  html('html'),
  notion('notion');

  const ExportHistoryFormat(this.code);
  final String code;

  static ExportHistoryFormat fromCode(String code) {
    return values.firstWhere(
      (f) => f.code == code,
      orElse: () => ExportHistoryFormat.markdown,
    );
  }
}

/// 导出目标类型。
enum ExportHistoryTarget {
  localFile('local_file'),
  notion('notion'),

  /// 只经系统分享面板发出去了,本地没有留下可打开的文件。
  shared('shared');

  const ExportHistoryTarget(this.code);
  final String code;

  static ExportHistoryTarget fromCode(String code) {
    return values.firstWhere(
      (t) => t.code == code,
      orElse: () => ExportHistoryTarget.localFile,
    );
  }
}

/// 导出来源类型。当前只有「帖子详情」，预留扩展（如批量收藏、用户主页等）。
enum ExportHistorySource {
  topic('topic');

  const ExportHistorySource(this.code);
  final String code;

  static ExportHistorySource fromCode(String code) {
    return values.firstWhere(
      (s) => s.code == code,
      orElse: () => ExportHistorySource.topic,
    );
  }
}

/// 导出状态。
enum ExportHistoryStatus {
  success('success'),
  failed('failed');

  const ExportHistoryStatus(this.code);
  final String code;

  static ExportHistoryStatus fromCode(String code) {
    return values.firstWhere(
      (s) => s.code == code,
      orElse: () => ExportHistoryStatus.success,
    );
  }
}

/// 单条导出历史。
///
/// [targetRef] 含义：
/// - localFile: 文件的最终引用——本地路径，或 Android 落公共目录/另存为拿到的
///   `content://` uri
/// - notion: Notion page URL
/// - shared: 空字符串（分享不产生本地文件）
class ExportHistoryEntry {
  const ExportHistoryEntry({
    required this.id,
    required this.sourceType,
    required this.sourceTopicId,
    required this.sourceTitle,
    required this.format,
    required this.targetType,
    required this.targetRef,
    required this.status,
    required this.createdAt,
    this.size,
    this.errorMessage,
    this.postCount,
  });

  /// 全局唯一 id（uuid v4）。
  final String id;
  final ExportHistorySource sourceType;
  final int sourceTopicId;
  final String sourceTitle;
  final ExportHistoryFormat format;
  final ExportHistoryTarget targetType;
  final String targetRef;
  final ExportHistoryStatus status;
  final DateTime createdAt;

  /// 文件大小（字节）。Notion 同步无此字段。
  final int? size;

  /// 失败时的错误信息。
  final String? errorMessage;

  /// 实际导出/同步的帖子数。
  final int? postCount;

  ExportHistoryEntry copyWith({
    String? targetRef,
    ExportHistoryStatus? status,
    String? errorMessage,
    int? size,
    int? postCount,
  }) {
    return ExportHistoryEntry(
      id: id,
      sourceType: sourceType,
      sourceTopicId: sourceTopicId,
      sourceTitle: sourceTitle,
      format: format,
      targetType: targetType,
      targetRef: targetRef ?? this.targetRef,
      status: status ?? this.status,
      createdAt: createdAt,
      size: size ?? this.size,
      errorMessage: errorMessage ?? this.errorMessage,
      postCount: postCount ?? this.postCount,
    );
  }
}

/// 注入式 box 工厂。
typedef ExportHistoryBoxFactory =
    Future<Box<Map>> Function(String accountId);

/// 导出历史 DAO，账号维度隔离（每账号一个 box）。
///
/// box value 拆字段存储：`source` / `topic_id` / `title` / `format` /
/// `target_type` / `target_ref` / `status` / `created_at` / `size` /
/// `error` / `post_count`。`format` 与 `created_at` 放顶层是为了让列表渲染
/// 和过滤不需要逐条 jsonDecode。
class ExportHistoryDao {
  ExportHistoryDao({ExportHistoryBoxFactory? boxFactory})
    : _boxFactory = boxFactory ?? AppDatabase.exportHistoryBox;

  final ExportHistoryBoxFactory _boxFactory;

  static const String _kSource = 'source';
  static const String _kTopicId = 'topic_id';
  static const String _kTitle = 'title';
  static const String _kFormat = 'format';
  static const String _kTargetType = 'target_type';
  static const String _kTargetRef = 'target_ref';
  static const String _kStatus = 'status';
  static const String _kCreatedAt = 'created_at';
  static const String _kSize = 'size';
  static const String _kError = 'error';
  static const String _kPostCount = 'post_count';

  /// 读取所有历史，按 [createdAt] 倒序。
  Future<List<ExportHistoryEntry>> readAll(String accountId) async {
    final box = await _boxFactory(accountId);
    final entries = <ExportHistoryEntry>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw == null) continue;
      entries.add(_entryFromBox(key as String, raw));
    }
    entries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(entries);
  }

  Future<void> upsertOne(String accountId, ExportHistoryEntry entry) async {
    final box = await _boxFactory(accountId);
    await box.put(entry.id, _entryToBox(entry));
  }

  Future<void> deleteOne(String accountId, String id) async {
    final box = await _boxFactory(accountId);
    await box.delete(id);
  }

  Future<void> deleteByIds(String accountId, Set<String> ids) async {
    if (ids.isEmpty) return;
    final box = await _boxFactory(accountId);
    await box.deleteAll(ids);
  }

  /// 清空某账号的全部历史。
  Future<void> clearAccount(String accountId) async {
    final box = await _boxFactory(accountId);
    await box.clear();
  }

  ExportHistoryEntry _entryFromBox(String id, Map raw) {
    return ExportHistoryEntry(
      id: id,
      sourceType: ExportHistorySource.fromCode(
        (raw[_kSource] as String?) ?? 'topic',
      ),
      sourceTopicId: (raw[_kTopicId] as num).toInt(),
      sourceTitle: (raw[_kTitle] as String?) ?? '',
      format: ExportHistoryFormat.fromCode(
        (raw[_kFormat] as String?) ?? 'md',
      ),
      targetType: ExportHistoryTarget.fromCode(
        (raw[_kTargetType] as String?) ?? 'local_file',
      ),
      targetRef: (raw[_kTargetRef] as String?) ?? '',
      status: ExportHistoryStatus.fromCode(
        (raw[_kStatus] as String?) ?? 'success',
      ),
      createdAt: DateTime.parse(raw[_kCreatedAt] as String),
      size: (raw[_kSize] as num?)?.toInt(),
      errorMessage: raw[_kError] as String?,
      postCount: (raw[_kPostCount] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> _entryToBox(ExportHistoryEntry entry) {
    return {
      _kSource: entry.sourceType.code,
      _kTopicId: entry.sourceTopicId,
      _kTitle: entry.sourceTitle,
      _kFormat: entry.format.code,
      _kTargetType: entry.targetType.code,
      _kTargetRef: entry.targetRef,
      _kStatus: entry.status.code,
      _kCreatedAt: entry.createdAt.toUtc().toIso8601String(),
      if (entry.size != null) _kSize: entry.size,
      if (entry.errorMessage != null) _kError: entry.errorMessage,
      if (entry.postCount != null) _kPostCount: entry.postCount,
    };
  }
}
