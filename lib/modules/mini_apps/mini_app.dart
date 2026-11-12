/// Public directory metadata. Runtime grants and tokens are never persisted here.
class MiniApp {
  const MiniApp({
    required this.id,
    required this.name,
    this.description = '',
    this.iconUrl = '',
    this.version = '',
    this.author = '',
    this.authorUsername = '',
    this.authorAvatarTemplate = '',
    this.rating = 0,
    this.ratingCount = 0,
    this.usageCount = 0,
    this.recentUsageCount,
    this.canTip = false,
    this.favorited = false,
    this.releaseNotes = '',
    this.discussionTopicId,
  });

  final String id, name, description, iconUrl, version, author, authorUsername;
  final String authorAvatarTemplate;
  final double rating;
  final int ratingCount, usageCount;
  final int? recentUsageCount;
  final bool canTip;
  final bool favorited;
  final String releaseNotes;
  final int? discussionTopicId;

  factory MiniApp.fromJson(Map<String, dynamic> json) {
    final author = json['author'] as Map<String, dynamic>? ?? const {};
    final username = author['username'] as String? ?? '';
    final displayName = author['name'] as String? ?? '';
    return MiniApp(
      id: json['app_id'] as String,
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      iconUrl: json['icon_url'] as String? ?? '',
      version: json['version'] as String? ?? '',
      author: displayName.trim().isEmpty ? username : displayName,
      authorUsername: username,
      authorAvatarTemplate: author['avatar_template'] as String? ?? '',
      rating: (json['rating_average'] as num?)?.toDouble() ?? 0,
      ratingCount: (json['rating_count'] as num?)?.toInt() ?? 0,
      usageCount: (json['usage_count'] as num?)?.toInt() ?? 0,
      recentUsageCount: (json['recent_usage_count'] as num?)?.toInt(),
      canTip: json['can_tip'] == true,
      favorited: json['is_favorited'] == true,
      releaseNotes: json['release_notes'] as String? ?? '',
      discussionTopicId: (json['discussion_topic_id'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
    'app_id': id,
    'name': name,
    'description': description,
    'icon_url': iconUrl,
    'version': version,
    'release_notes': releaseNotes,
    'discussion_topic_id': discussionTopicId,
    'rating_average': rating,
    'rating_count': ratingCount,
    'usage_count': usageCount,
    if (recentUsageCount != null) 'recent_usage_count': recentUsageCount,
    'can_tip': canTip,
    'is_favorited': favorited,
    'author': {
      'username': authorUsername,
      'name': author,
      'avatar_template': authorAvatarTemplate,
    },
  };
}

class MiniAppDirectory {
  const MiniAppDirectory({
    required this.apps,
    required this.page,
    required this.perPage,
    required this.total,
  });
  final List<MiniApp> apps;
  final int page, perPage, total;
  bool get hasMore => perPage > 0 && (page + 1) * perPage < total;

  factory MiniAppDirectory.fromJson(Map<String, dynamic> json) =>
      MiniAppDirectory(
        apps: (json['apps'] as List)
            .map((e) => MiniApp.fromJson(e as Map<String, dynamic>))
            .toList(),
        page: (json['page'] as num).toInt(),
        perPage: (json['per_page'] as num).toInt(),
        total: (json['total'] as num).toInt(),
      );
}

class MiniAppDetails {
  const MiniAppDetails(
    this.app,
    this.embedUrl, {
    this.configuration = const {},
    this.feedback = const {},
  });
  final MiniApp app;
  final String embedUrl;
  final Map<String, dynamic> configuration;
  final Map<String, dynamic> feedback;
  Map<String, dynamic> toJson() => {
    'app': {...app.toJson(), ...feedback},
    'configuration': {...configuration, 'embedUrl': embedUrl},
  };
  factory MiniAppDetails.fromJson(Map<String, dynamic> json) => MiniAppDetails(
    MiniApp.fromJson(json['app'] as Map<String, dynamic>),
    (json['configuration'] as Map<String, dynamic>)['embedUrl'] as String,
    configuration: json['configuration'] as Map<String, dynamic>,
    feedback: json['app'] as Map<String, dynamic>,
  );
}
