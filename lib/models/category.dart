import '../l10n/s.dart';

class Category {
  final int id;
  final String name;
  final String color;
  final String textColor;
  final String slug;
  final String? description;
  final int? parentCategoryId;
  final String? uploadedLogo;
  final String? uploadedBackground;
  final bool readRestricted;
  final String? icon;
  final String? topicTemplate;
  final int minimumRequiredTags;
  final List<RequiredTagGroup> requiredTagGroups;
  final List<String> allowedTags;
  final List<String> allowedTagGroups;
  final bool allowGlobalTags;
  final int? permission; // 0 = full, 1 = create/reply, 2 = reply only, 3 = see
  final int? notificationLevel; // 0=muted, 1=regular, 2=tracking, 3=watching

  /// post-voting(问答)插件分类字段:新话题默认勾选问答模式
  final bool createAsPostVotingDefault;

  /// 该分类强制所有新话题为问答模式(用户不可取消)
  final bool onlyPostVotingInThisCategory;

  /// 站点是否装了 post-voting 插件 —— 从「分类 JSON 是否下发插件注入
  /// 字段」派生,不做站点白名单
  final bool hasPostVotingFields;

  Category({
    required this.id,
    required this.name,
    required this.color,
    required this.textColor,
    required this.slug,
    this.description,
    this.parentCategoryId,
    this.uploadedLogo,
    this.uploadedBackground,
    this.readRestricted = false,
    this.icon,
    this.topicTemplate,
    this.minimumRequiredTags = 0,
    this.requiredTagGroups = const [],
    this.allowedTags = const [],
    this.allowedTagGroups = const [],
    this.allowGlobalTags = true,
    this.permission,
    this.notificationLevel,
    this.createAsPostVotingDefault = false,
    this.onlyPostVotingInThisCategory = false,
    this.hasPostVotingFields = false,
  });

  /// 是否允许在此分类创建话题
  bool get canCreateTopic => permission != null && permission! <= 1;

  factory Category.fromJson(Map<String, dynamic> json) {
    return Category(
      id: int.tryParse(json['id']?.toString() ?? '0') ?? 0,
      name: json['name'] as String? ?? 'Unknown',
      color: json['color'] as String? ?? '000000',
      textColor: json['text_color'] as String? ?? 'FFFFFF',
      slug: json['slug'] as String? ?? '',
      description: json['description'] as String?,
      parentCategoryId: json['parent_category_id'] != null
          ? int.tryParse(json['parent_category_id'].toString())
          : null,
      uploadedLogo: (json['uploaded_logo'] as Map?)?['url']?.toString(),
      uploadedBackground: (json['uploaded_background'] as Map?)?['url']?.toString(),
      readRestricted: json['read_restricted'] as bool? ?? false,
      icon: json['icon'] as String?,
      topicTemplate: json['topic_template'] as String?,
      minimumRequiredTags: json['minimum_required_tags'] as int? ?? 0,
      requiredTagGroups: (json['required_tag_groups'] as List<dynamic>?)
          ?.map((e) => RequiredTagGroup.fromJson(e as Map<String, dynamic>))
          .toList() ?? [],
      allowedTags: (json['allowed_tags'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList() ?? [],
      allowedTagGroups: (json['allowed_tag_groups'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList() ?? [],
      allowGlobalTags: json['allow_global_tags'] as bool? ?? true,
      permission: json['permission'] as int?,
      notificationLevel: json['notification_level'] as int?,
      createAsPostVotingDefault:
          json['create_as_post_voting_default'] as bool? ?? false,
      onlyPostVotingInThisCategory:
          json['only_post_voting_in_this_category'] as bool? ?? false,
      hasPostVotingFields: json.containsKey('create_as_post_voting_default'),
    );
  }
}

class RequiredTagGroup {
  final String name;
  final int minCount;

  RequiredTagGroup({required this.name, required this.minCount});

  factory RequiredTagGroup.fromJson(Map<String, dynamic> json) {
    return RequiredTagGroup(
      name: json['name'] as String? ?? '',
      minCount: json['min_count'] as int? ?? 0,
    );
  }
}

/// 分类通知级别（比话题多一个 watchingFirstPost）
enum CategoryNotificationLevel {
  muted(0),
  regular(1),
  tracking(2),
  watching(3),
  watchingFirstPost(4);

  const CategoryNotificationLevel(this.value);
  final int value;

  String get label {
    switch (this) {
      case CategoryNotificationLevel.muted: return S.current.category_levelMuted;
      case CategoryNotificationLevel.regular: return S.current.category_levelRegular;
      case CategoryNotificationLevel.tracking: return S.current.category_levelTracking;
      case CategoryNotificationLevel.watching: return S.current.category_levelWatching;
      case CategoryNotificationLevel.watchingFirstPost: return S.current.category_levelWatchingFirstPost;
    }
  }

  String get description {
    switch (this) {
      case CategoryNotificationLevel.muted: return S.current.category_levelMutedDesc;
      case CategoryNotificationLevel.regular: return S.current.category_levelRegularDesc;
      case CategoryNotificationLevel.tracking: return S.current.category_levelTrackingDesc;
      case CategoryNotificationLevel.watching: return S.current.category_levelWatchingDesc;
      case CategoryNotificationLevel.watchingFirstPost: return S.current.category_levelWatchingFirstPostDesc;
    }
  }

  static CategoryNotificationLevel fromValue(int? value) {
    return CategoryNotificationLevel.values.firstWhere(
      (e) => e.value == value,
      orElse: () => CategoryNotificationLevel.regular,
    );
  }
}

class SiteResponse {
  final List<Category> categories;

  SiteResponse({required this.categories});

  factory SiteResponse.fromJson(Map<String, dynamic> json) {
    final categoriesJson = json['categories'] as List<dynamic>? ?? [];
    return SiteResponse(
      categories: categoriesJson
          .map((c) => Category.fromJson(c as Map<String, dynamic>))
          .toList(),
    );
  }
}