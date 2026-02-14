import '../utils/url_helper.dart';

/// 从文本中提取所有 @用户名
/// 返回不重复的用户名列表（不含 @）
List<String> extractMentionNames(String text) {
  final mentionRegex = RegExp(r'(?<=^|\s)@([\w_-]+)(?=\s|$|[,.!?;:]|\))', multiLine: true);
  final matches = mentionRegex.allMatches(text);
  final names = <String>{};
  for (final match in matches) {
    final name = match.group(1);
    if (name != null && name.isNotEmpty) {
      names.add(name);
    }
  }
  return names.toList();
}

/// 用户提及搜索结果中的用户
class MentionUser {
  final String username;
  final String? name;
  final String? avatarTemplate;
  final int? priorityGroup;

  const MentionUser({
    required this.username,
    this.name,
    this.avatarTemplate,
    this.priorityGroup,
  });

  factory MentionUser.fromJson(Map<String, dynamic> json) {
    return MentionUser(
      username: json['username'] as String,
      name: json['name'] as String?,
      avatarTemplate: json['avatar_template'] as String?,
      priorityGroup: json['priority_group'] as int?,
    );
  }

  /// 获取头像 URL（根据尺寸替换模板）
  String getAvatarUrl({int size = 40}) {
    return UrlHelper.resolveAvatarUrl(avatarTemplate: avatarTemplate, size: size);
  }
}

/// 用户提及搜索结果中的群组
class MentionGroup {
  final String name;
  final String? fullName;
  final String? flairUrl;
  final String? flairBgColor;
  final String? flairColor;
  final int? userCount;

  const MentionGroup({
    required this.name,
    this.fullName,
    this.flairUrl,
    this.flairBgColor,
    this.flairColor,
    this.userCount,
  });

  factory MentionGroup.fromJson(Map<String, dynamic> json) {
    return MentionGroup(
      name: json['name'] as String,
      fullName: json['full_name'] as String?,
      flairUrl: json['flair_url'] as String?,
      flairBgColor: json['flair_bg_color'] as String?,
      flairColor: json['flair_color'] as String?,
      userCount: json['user_count'] as int?,
    );
  }
}

/// 用户提及搜索结果
class MentionSearchResult {
  final List<MentionUser> users;
  final List<MentionGroup> groups;

  const MentionSearchResult({
    required this.users,
    required this.groups,
  });

  factory MentionSearchResult.fromJson(Map<String, dynamic> json) {
    return MentionSearchResult(
      users: (json['users'] as List<dynamic>?)
              ?.map((e) => MentionUser.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      groups: (json['groups'] as List<dynamic>?)
              ?.map((e) => MentionGroup.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  /// 是否有结果
  bool get hasResults => users.isNotEmpty || groups.isNotEmpty;

  /// 合并的结果列表（用于 UI 展示）
  List<MentionItem> get items => [
        ...users.map((u) => MentionItem.user(u)),
        ...groups.map((g) => MentionItem.group(g)),
      ];
}

/// 统一的提及项（用户或群组）
class MentionItem {
  final MentionUser? user;
  final MentionGroup? group;

  const MentionItem._({this.user, this.group});

  factory MentionItem.user(MentionUser user) => MentionItem._(user: user);
  factory MentionItem.group(MentionGroup group) => MentionItem._(group: group);

  bool get isUser => user != null;
  bool get isGroup => group != null;

  /// 获取用于插入的文本（用户名或群组名）
  String get mentionName => user?.username ?? group?.name ?? '';

  /// 获取显示名称
  String get displayName =>
      user?.name ?? group?.fullName ?? user?.username ?? group?.name ?? '';
}

/// @ 提及验证结果（来自 /composer/mentions）
class MentionCheckResult {
  /// 有效的用户名列表
  final List<String> validUsernames;
  
  /// 有效的群组名列表（带 mentionable/messageable 信息）
  final Map<String, MentionableGroup> validGroups;
  
  /// 无法提及的用户名列表
  final List<String> cannotSee;
  
  /// 超出最大群组成员数的群组
  final List<String> groupsExceedMembersLimit;
  
  /// 无效的群组
  final List<String> invalidGroups;

  const MentionCheckResult({
    this.validUsernames = const [],
    this.validGroups = const {},
    this.cannotSee = const [],
    this.groupsExceedMembersLimit = const [],
    this.invalidGroups = const [],
  });

  factory MentionCheckResult.fromJson(Map<String, dynamic> json) {
    final groupsJson = json['groups'] as Map<String, dynamic>? ?? {};
    final validGroups = <String, MentionableGroup>{};
    groupsJson.forEach((key, value) {
      if (value is Map<String, dynamic>) {
        validGroups[key] = MentionableGroup.fromJson(value);
      }
    });

    return MentionCheckResult(
      validUsernames: (json['valid'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      validGroups: validGroups,
      cannotSee: (json['cannot_see'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      groupsExceedMembersLimit: (json['groups_with_too_many_members'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      invalidGroups: (json['invalid_groups'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
    );
  }

  /// 检查用户名是否有效
  bool isValidUsername(String username) => validUsernames.contains(username);
  
  /// 检查群组名是否可提及
  bool isValidGroup(String groupName) => validGroups.containsKey(groupName);
}

/// 可提及的群组信息
class MentionableGroup {
  final bool userCount;
  final int maxMentions;

  const MentionableGroup({
    this.userCount = false,
    this.maxMentions = 0,
  });

  factory MentionableGroup.fromJson(Map<String, dynamic> json) {
    return MentionableGroup(
      userCount: json['user_count'] as bool? ?? false,
      maxMentions: json['max_mentions'] as int? ?? 0,
    );
  }
}
