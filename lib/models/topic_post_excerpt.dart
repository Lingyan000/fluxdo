import 'package:html/parser.dart' as html_parser;

/// 楼层摘要（`/t/{id}/excerpts.json`）：时间线与拖动定位预览未加载楼层用
class TopicPostExcerpt {
  const TopicPostExcerpt({
    required this.postId,
    required this.username,
    required this.text,
  });

  final int postId;
  final String? username;

  /// 纯文本摘要；表情图换回其 :shortcode: 文本，其余标签剥离
  final String text;

  factory TopicPostExcerpt.fromJson(Map<String, dynamic> json) {
    return TopicPostExcerpt(
      postId: json['post_id'] as int,
      username: json['username'] as String?,
      text: plainTextFromHtml(json['excerpt'] as String? ?? ''),
    );
  }

  /// HTML 片段转单行纯文本（表情图取 alt）；[maxLength] 截断以免长帖全文解析后占内存
  static String plainTextFromHtml(String html, {int? maxLength}) {
    final fragment = html_parser.parseFragment(html);
    // 图片灯箱的「文件名 尺寸 体积」说明不属于正文
    for (final meta in fragment.querySelectorAll('.meta')) {
      meta.remove();
    }
    for (final img in fragment.querySelectorAll('img')) {
      final alt = img.attributes['alt'];
      img.replaceWith(html_parser.parseFragment(alt ?? ''));
    }
    final text = fragment.text?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
    if (maxLength == null || text.length <= maxLength) return text;
    return '${text.substring(0, maxLength)}…';
  }
}
