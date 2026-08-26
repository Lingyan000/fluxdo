/// 表情包市场索引信息
class StickerMarketIndex {
  final int totalPages;
  final int pageSize;
  final int totalGroups;

  const StickerMarketIndex({
    required this.totalPages,
    required this.pageSize,
    required this.totalGroups,
  });

  factory StickerMarketIndex.fromJson(Map<String, dynamic> json) {
    return StickerMarketIndex(
      totalPages: json['totalPages'] as int? ?? 0,
      pageSize: json['pageSize'] as int? ?? 0,
      totalGroups: json['totalGroups'] as int? ?? 0,
    );
  }
}

/// 市场分类（topic）
class StickerMarketTopic {
  final String id;
  final String label;
  final int totalGroups;
  final int totalPages;

  const StickerMarketTopic({
    required this.id,
    required this.label,
    required this.totalGroups,
    required this.totalPages,
  });

  factory StickerMarketTopic.fromJson(Map<String, dynamic> json) {
    return StickerMarketTopic(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? '',
      totalGroups: json['totalGroups'] as int? ?? 0,
      totalPages: json['totalPages'] as int? ?? 0,
    );
  }
}

/// 表情包分组
class StickerGroup {
  final String id;
  final String name;
  final String icon;
  final int order;
  final int emojiCount;
  final bool isArchived;

  /// 所属市场分类 id（旧数据可能缺失，空串表示未知）
  final String topic;

  const StickerGroup({
    required this.id,
    required this.name,
    required this.icon,
    required this.order,
    required this.emojiCount,
    required this.isArchived,
    this.topic = '',
  });
  factory StickerGroup.fromJson(Map<String, dynamic> json) {
    return StickerGroup(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      icon: json['icon'] as String? ?? '',
      order: json['order'] as int? ?? 0,
      emojiCount: json['emojiCount'] as int? ?? 0,
      isArchived: json['isArchived'] as bool? ?? false,
      topic: json['topic'] as String? ?? '',
    );
  }
}

/// 表情包项
class StickerItem {
  final String id;
  final String name;
  final String url;
  final int width;
  final int height;
  final String groupId;

  const StickerItem({
    required this.id,
    required this.name,
    required this.url,
    required this.width,
    required this.height,
    required this.groupId,
  });

  factory StickerItem.fromJson(Map<String, dynamic> json) {
    return StickerItem(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      url: json['url'] as String? ?? '',
      width: json['width'] as int? ?? 0,
      height: json['height'] as int? ?? 0,
      groupId: json['groupId'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'width': width,
    'height': height,
    'groupId': groupId,
  };

  /// 转换为 Markdown 图片格式
  String toMarkdown() => '![$name|${width}x$height,30%]($url)';
}

/// 表情包分组详情（包含所有表情）
class StickerGroupDetail {
  final String id;
  final String name;
  final String icon;
  final List<StickerItem> emojis;

  const StickerGroupDetail({
    required this.id,
    required this.name,
    required this.icon,
    required this.emojis,
  });

  factory StickerGroupDetail.fromJson(Map<String, dynamic> json) {
    return StickerGroupDetail(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      icon: json['icon'] as String? ?? '',
      emojis:
          (json['emojis'] as List<dynamic>?)
              ?.map((e) => StickerItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}
