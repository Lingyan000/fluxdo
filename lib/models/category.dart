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
  });

  /// 是否允许在此分类创建话题
  bool get canCreateTopic => permission != null && permission! <= 1;

  Category copyWith({
    int? id,
    String? name,
    String? color,
    String? textColor,
    String? slug,
    String? description,
    int? parentCategoryId,
    String? uploadedLogo,
    String? uploadedBackground,
    bool? readRestricted,
    String? icon,
    String? topicTemplate,
    int? minimumRequiredTags,
    List<RequiredTagGroup>? requiredTagGroups,
    List<String>? allowedTags,
    List<String>? allowedTagGroups,
    bool? allowGlobalTags,
    int? permission,
    int? notificationLevel,
  }) {
    return Category(
      id: id ?? this.id,
      name: name ?? this.name,
      color: color ?? this.color,
      textColor: textColor ?? this.textColor,
      slug: slug ?? this.slug,
      description: description ?? this.description,
      parentCategoryId: parentCategoryId ?? this.parentCategoryId,
      uploadedLogo: uploadedLogo ?? this.uploadedLogo,
      uploadedBackground: uploadedBackground ?? this.uploadedBackground,
      readRestricted: readRestricted ?? this.readRestricted,
      icon: icon ?? this.icon,
      topicTemplate: topicTemplate ?? this.topicTemplate,
      minimumRequiredTags: minimumRequiredTags ?? this.minimumRequiredTags,
      requiredTagGroups: requiredTagGroups ?? this.requiredTagGroups,
      allowedTags: allowedTags ?? this.allowedTags,
      allowedTagGroups: allowedTagGroups ?? this.allowedTagGroups,
      allowGlobalTags: allowGlobalTags ?? this.allowGlobalTags,
      permission: permission ?? this.permission,
      notificationLevel: notificationLevel ?? this.notificationLevel,
    );
  }

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
  muted(0, '静音', '不接收此分类的任何通知'),
  regular(1, '常规', '只在被 @ 提及或回复时通知'),
  tracking(2, '跟踪', '显示新帖未读计数'),
  watching(3, '关注', '每个新回复都通知'),
  watchingFirstPost(4, '关注新话题', '此分类有新话题时通知');

  const CategoryNotificationLevel(this.value, this.label, this.description);
  final int value;
  final String label;
  final String description;

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