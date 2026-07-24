/// 稍后阅读项数据模型
class ReadLaterItem {
  final int topicId;
  final String title;
  final int? scrollToPostNumber; // 加入浮窗时的阅读位置
  final String? excerpt; // 加入位置楼层的内容摘录
  final DateTime addedAt; // 加入时间（本地生成，不走 TimeUtils）

  const ReadLaterItem({
    required this.topicId,
    required this.title,
    this.scrollToPostNumber,
    this.excerpt,
    required this.addedAt,
  });

  Map<String, dynamic> toJson() => {
        'topicId': topicId,
        'title': title,
        'scrollToPostNumber': scrollToPostNumber,
        'excerpt': excerpt,
        'addedAt': addedAt.toIso8601String(),
      };

  factory ReadLaterItem.fromJson(Map<String, dynamic> json) => ReadLaterItem(
        topicId: json['topicId'] as int,
        title: json['title'] as String,
        scrollToPostNumber: json['scrollToPostNumber'] as int?,
        excerpt: json['excerpt'] as String?,
        addedAt: DateTime.parse(json['addedAt'] as String),
      );

  /// 创建一个更新了阅读位置的副本
  ReadLaterItem copyWith({int? scrollToPostNumber}) => ReadLaterItem(
        topicId: topicId,
        title: title,
        scrollToPostNumber: scrollToPostNumber ?? this.scrollToPostNumber,
        excerpt: excerpt,
        addedAt: addedAt,
      );

  /// 从 cooked HTML 提取纯文本摘录（截断到 [maxLength] 字符）
  ///
  /// 去掉引用块（aside，避免摘录被引用内容占满）、图片和所有标签，
  /// 还原常见 HTML 实体，压缩空白为单空格。内容为空时返回 null。
  static String? excerptFromCooked(String cooked, {int maxLength = 120}) {
    var text = cooked
        .replaceAll(RegExp(r'<aside[\s\S]*?</aside>'), ' ')
        .replaceAll(RegExp(r'<(script|style)[\s\S]*?</\1>'), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return null;
    if (text.length > maxLength) {
      text = '${text.substring(0, maxLength)}…';
    }
    return text;
  }
}
