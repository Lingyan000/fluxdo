import 'package:fluxdo/utils/avatar_url.dart';
import '../utils/time_utils.dart';
import '../utils/url_helper.dart';

/// 单个字段的「旧 → 新」对比。
///
/// 对应 discourse 后端 `Hash#diff` 风格的 JSON：
/// - 数组形式 `[previous, current]`（绝大多数字段）
/// - 对象形式 `{"previous": ..., "current": ...}`（少数字段如 `body_changes`）
class PostRevisionChange<T> {
  final T? previous;
  final T? current;

  const PostRevisionChange({this.previous, this.current});

  /// [json] 既可能是 `[previous, current]` 列表，也可能是
  /// `{"previous": x, "current": y}` 对象。
  /// [parse] 把单个原始值转成目标类型。
  static PostRevisionChange<T>? parse<T>(
    dynamic json,
    T? Function(dynamic value) parse,
  ) {
    if (json == null) return null;
    if (json is List) {
      final previous = json.isNotEmpty ? parse(json[0]) : null;
      final current = json.length > 1 ? parse(json[1]) : null;
      if (previous == null && current == null) return null;
      return PostRevisionChange<T>(previous: previous, current: current);
    }
    if (json is Map<String, dynamic>) {
      final previous = parse(json['previous']);
      final current = parse(json['current']);
      if (previous == null && current == null) return null;
      return PostRevisionChange<T>(previous: previous, current: current);
    }
    return null;
  }
}

/// 编辑者变更（user_changes），保留旧/新两个用户的关键字段。
class PostRevisionUserChange {
  final String? previousUsername;
  final String? previousName;
  final String? previousAvatarTemplate;
  final String? currentUsername;
  final String? currentName;
  final String? currentAvatarTemplate;

  const PostRevisionUserChange({
    this.previousUsername,
    this.previousName,
    this.previousAvatarTemplate,
    this.currentUsername,
    this.currentName,
    this.currentAvatarTemplate,
  });

  static PostRevisionUserChange? fromJson(dynamic json) {
    if (json is! Map<String, dynamic>) return null;
    final previous = json['previous'] as Map<String, dynamic>?;
    final current = json['current'] as Map<String, dynamic>?;
    if (previous == null && current == null) return null;
    return PostRevisionUserChange(
      previousUsername: previous?['username'] as String?,
      previousName: previous?['name'] as String?,
      previousAvatarTemplate: previous?['avatar_template'] as String?,
      currentUsername: current?['username'] as String?,
      currentName: current?['name'] as String?,
      currentAvatarTemplate: current?['avatar_template'] as String?,
    );
  }

  String? previousAvatarUrl({int size = 48}) =>
      _avatarUrl(previousAvatarTemplate, size);
  String? currentAvatarUrl({int size = 48}) =>
      _avatarUrl(currentAvatarTemplate, size);

  static String? _avatarUrl(String? template, int size) {
    if (template == null || template.isEmpty) return null;
    final filled = AvatarUrl.resolve(template, size: size);
    return UrlHelper.resolveUrlWithCdn(filled);
  }
}

/// 正文 diff 三种格式，对应后端 `PostRevisionSerializer#body_changes`：
/// - [inline]：单列交错 HTML（带 `<ins>/<del>` 或 `diff-ins/diff-del` class）
/// - [sideBySide]：双列 HTML（previous / current）
/// - [sideBySideMarkdown]：双列 markdown 原文 HTML 表格
class PostRevisionBodyChanges {
  final String? inline;
  final String? sideBySide;
  final String? sideBySideMarkdown;

  const PostRevisionBodyChanges({
    this.inline,
    this.sideBySide,
    this.sideBySideMarkdown,
  });

  bool get isEmpty =>
      (inline == null || inline!.isEmpty) &&
      (sideBySide == null || sideBySide!.isEmpty) &&
      (sideBySideMarkdown == null || sideBySideMarkdown!.isEmpty);

  static PostRevisionBodyChanges? fromJson(dynamic json) {
    if (json is! Map<String, dynamic>) return null;
    return PostRevisionBodyChanges(
      inline: json['inline'] as String?,
      sideBySide: json['side_by_side'] as String?,
      sideBySideMarkdown: json['side_by_side_markdown'] as String?,
    );
  }
}

/// 帖子编辑历史（一个版本）。
///
/// 对应 discourse 后端 `PostRevisionSerializer`。
class PostRevision {
  // 导航
  final int firstRevision;
  final int previousRevision;
  final int currentRevision;
  final int? nextRevision;
  final int lastRevision;
  final int currentVersion;
  final int versionCount;

  // 作者（执行此次编辑的人）
  final String username;
  final String? displayUsername;
  final String? actingUserName;
  final String avatarTemplate;

  // 元
  final DateTime createdAt;
  final String? editReason;
  final bool previousHidden;
  final bool currentHidden;
  final bool canEdit;
  final bool diffError;

  // 变化
  final PostRevisionBodyChanges? bodyChanges;
  final PostRevisionChange<String>? titleChanges;
  final PostRevisionChange<List<String>>? tagsChanges;
  final PostRevisionChange<int>? categoryIdChanges;
  final PostRevisionUserChange? userChanges;
  final PostRevisionChange<int>? replyToPostNumberChanges;
  final PostRevisionChange<bool>? wikiChanges;
  final PostRevisionChange<int>? postTypeChanges;
  final PostRevisionChange<String>? localeChanges;

  const PostRevision({
    required this.firstRevision,
    required this.previousRevision,
    required this.currentRevision,
    required this.nextRevision,
    required this.lastRevision,
    required this.currentVersion,
    required this.versionCount,
    required this.username,
    required this.displayUsername,
    required this.actingUserName,
    required this.avatarTemplate,
    required this.createdAt,
    required this.editReason,
    required this.previousHidden,
    required this.currentHidden,
    required this.canEdit,
    required this.diffError,
    required this.bodyChanges,
    required this.titleChanges,
    required this.tagsChanges,
    required this.categoryIdChanges,
    required this.userChanges,
    required this.replyToPostNumberChanges,
    required this.wikiChanges,
    required this.postTypeChanges,
    required this.localeChanges,
  });

  factory PostRevision.fromJson(Map<String, dynamic> json) {
    final currentRevision = json['current_revision'] as int? ?? 1;
    return PostRevision(
      firstRevision: json['first_revision'] as int? ?? 1,
      previousRevision: json['previous_revision'] as int? ?? currentRevision,
      currentRevision: currentRevision,
      nextRevision: json['next_revision'] as int?,
      lastRevision: json['last_revision'] as int? ?? currentRevision,
      currentVersion: json['current_version'] as int? ?? currentRevision,
      versionCount: json['version_count'] as int? ?? 1,
      username: json['username'] as String? ?? '',
      displayUsername: json['display_username'] as String?,
      actingUserName: json['acting_user_name'] as String?,
      avatarTemplate: json['avatar_template'] as String? ?? '',
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?) ??
          DateTime.now(),
      editReason: (json['edit_reason'] as String?)?.isNotEmpty == true
          ? json['edit_reason'] as String
          : null,
      previousHidden: json['previous_hidden'] as bool? ?? false,
      currentHidden: json['current_hidden'] as bool? ?? false,
      canEdit: json['can_edit'] as bool? ?? false,
      diffError: json['diff_error'] as bool? ?? false,
      bodyChanges: PostRevisionBodyChanges.fromJson(json['body_changes']),
      titleChanges: PostRevisionChange.parse<String>(
        json['title_changes'],
        (v) => v?.toString(),
      ),
      tagsChanges: PostRevisionChange.parse<List<String>>(
        json['tags_changes'],
        (v) => v is List ? v.map((e) => e.toString()).toList() : null,
      ),
      categoryIdChanges: PostRevisionChange.parse<int>(
        json['category_id_changes'],
        (v) => v is int ? v : (v is num ? v.toInt() : null),
      ),
      userChanges: PostRevisionUserChange.fromJson(json['user_changes']),
      replyToPostNumberChanges: PostRevisionChange.parse<int>(
        json['reply_to_post_number_changes'],
        (v) => v is int ? v : (v is num ? v.toInt() : null),
      ),
      wikiChanges: PostRevisionChange.parse<bool>(
        json['wiki_changes'],
        (v) => v is bool ? v : null,
      ),
      postTypeChanges: PostRevisionChange.parse<int>(
        json['post_type_changes'],
        (v) => v is int ? v : (v is num ? v.toInt() : null),
      ),
      localeChanges: PostRevisionChange.parse<String>(
        json['locale_changes'],
        (v) => v?.toString(),
      ),
    );
  }

  String getAvatarUrl({int size = 48}) {
    if (avatarTemplate.isEmpty) return '';
    final filled = AvatarUrl.resolve(avatarTemplate, size: size);
    return UrlHelper.resolveUrlWithCdn(filled);
  }

  /// 显示给用户看的「编辑者」名字：优先 displayUsername，回退 username。
  String get displayActor =>
      (displayUsername != null && displayUsername!.isNotEmpty)
          ? displayUsername!
          : username;

  bool get hasPreviousRevision => previousRevision != currentRevision;
  bool get hasNextRevision =>
      nextRevision != null && nextRevision != currentRevision;
  bool get hasMultipleVersions => versionCount > 1;

  /// 是否存在任何「非 body」字段变化。用来决定 modal 里要不要渲染元数据 diff 区。
  bool get hasMetaChanges =>
      titleChanges != null ||
      tagsChanges != null ||
      categoryIdChanges != null ||
      userChanges != null ||
      replyToPostNumberChanges != null ||
      wikiChanges != null ||
      postTypeChanges != null ||
      localeChanges != null;
}
