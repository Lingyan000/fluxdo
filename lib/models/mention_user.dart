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

/// 用户自定义状态(站点开启 enable_user_status 时序列化端附带的
/// `status: {emoji, description, ends_at}`)。
class UserCustomStatus {
  final String? emoji;
  final String? description;

  const UserCustomStatus({this.emoji, this.description});

  factory UserCustomStatus.fromJson(Map<String, dynamic> json) {
    return UserCustomStatus(
      emoji: json['emoji'] as String?,
      description: json['description'] as String?,
    );
  }
}

/// 用户提及搜索结果中的用户
class MentionUser {
  final int? id;
  final String username;
  final String? name;
  final String? avatarTemplate;
  final int? priorityGroup;
  final UserCustomStatus? status;

  const MentionUser({
    this.id,
    required this.username,
    this.name,
    this.avatarTemplate,
    this.priorityGroup,
    this.status,
  });

  factory MentionUser.fromJson(Map<String, dynamic> json) {
    return MentionUser(
      id: json['id'] as int?,
      username: json['username'] as String,
      name: json['name'] as String?,
      avatarTemplate: json['avatar_template'] as String?,
      priorityGroup: json['priority_group'] as int?,
      status: json['status'] is Map<String, dynamic>
          ? UserCustomStatus.fromJson(json['status'] as Map<String, dynamic>)
          : null,
    );
  }

  /// 获取头像 URL（根据尺寸替换模板）
  String? getAvatarUrl(String baseUrl, {int size = 40}) {
    if (avatarTemplate == null) return null;
    final url = avatarTemplate!.replaceAll('{size}', size.toString());
    return UrlHelper.resolveUrlWithCdn(url);
  }

  /// 展示名:优先真实姓名,姓名为空(很多用户没填,服务端给的是空字符串
  /// 不是 null)则退到用户名。**不要**用 `name ?? username` 代替——`??`
  /// 只在 null 时才回退,空字符串会直接把用户名顶掉,显示成空白。
  String get displayName => name?.isNotEmpty == true ? name! : username;
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
