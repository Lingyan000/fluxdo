/// 编辑器 `#` 补全的候选项(分类 / 标签)。
///
/// 对应 Discourse `GET /hashtags/search.json` 的一条 result —— 网页版
/// composer 的 `#` 补全用的就是这个接口,字段口径保持一致:
///
/// ```json
/// {"text":"开发调优","slug":"dev","ref":"dev","type":"category",
///  "icon":"folder","colors":["0088CC"],"relative_url":"/c/dev/4","id":4,
///  "secondary_text":"x 123","description":"..."}
/// ```
///
/// [ref] 是**插入正文的引用串**(不含 `#`),由服务端算好消歧后缀
/// (同名标签会给成 `名称::tag`),客户端别自己猜。
class HashtagItem {
  const HashtagItem({
    required this.kind,
    required this.label,
    required this.ref,
    this.slug,
    this.colorHex,
    this.secondaryText,
    this.relativeUrl,
    this.description,
    this.icon,
    this.id,
  });

  factory HashtagItem.fromJson(Map<String, dynamic> json) {
    final type = (json['type'] as String?)?.toLowerCase();
    final colors = (json['colors'] as List?)?.whereType<String>();
    return HashtagItem(
      kind: type == 'tag' ? HashtagKind.tag : HashtagKind.category,
      label: (json['text'] as String?)?.trim() ?? '',
      ref: (json['ref'] as String?) ?? (json['slug'] as String?) ?? '',
      slug: json['slug'] as String?,
      colorHex: (colors == null || colors.isEmpty) ? null : colors.first,
      secondaryText: (json['secondary_text'] as String?)?.trim(),
      relativeUrl: json['relative_url'] as String?,
      description: json['description'] as String?,
      icon: (json['icon'] as String?)?.trim(),
      id: json['id'] is int ? json['id'] as int : null,
    );
  }

  final HashtagKind kind;

  /// 展示名(分类名 / 标签名)
  final String label;

  /// 插入正文的引用串(不含 `#`)
  final String ref;

  final String? slug;

  /// 分类色(6 位十六进制,不带 `#`)
  final String? colorHex;

  /// 右侧副文本(标签是 `x 话题数`)
  final String? secondaryText;

  final String? relativeUrl;
  final String? description;

  /// 服务端给的 Font Awesome 图标名(站点 `hashtag_icons`,分类默认
  /// `folder`、标签默认 `tag`;分类自定义了图标就是那个)
  final String? icon;
  final int? id;
}

enum HashtagKind { category, tag }
