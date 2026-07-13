import 'package:flutter/material.dart';
import '../../models/category.dart';
import '../../models/topic.dart';
import '../../utils/color_utils.dart';

/// ▪分类色标+名 + 标签轻文本,单行 ellipsis。
/// 话题卡片与搜索卡片共用;分类和标签都为空时请勿构造(调用方判空)。
///
/// 形态约定:
/// - 分类:8px 圆角色块(Discourse 分类色,按主题亮度适配)+ 中性色名称
/// - 标签:统一使用 "#" 前缀
class CategoryTagsLine extends StatelessWidget {
  final Category? category;
  final List<Tag> tags;
  final Color metaColor;

  const CategoryTagsLine({
    super.key,
    this.category,
    this.tags = const [],
    required this.metaColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(color: metaColor);

    // WidgetSpan 会为色块和 FA 图标创建额外子树，并让 RenderParagraph
    // 进入占位子节点布局。统一改为独立色块 + 纯 TextSpan 标签。
    final spans = <InlineSpan>[];
    final category = this.category;
    if (category != null) {
      spans.add(
        TextSpan(
          text: category.name,
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
      );
    }
    for (final tag in tags) {
      if (spans.isNotEmpty) spans.add(const TextSpan(text: '   '));
      spans.add(
        TextSpan(
          text: '#',
          style: TextStyle(color: metaColor.withValues(alpha: 0.6)),
        ),
      );
      spans.add(TextSpan(text: tag.name));
    }

    final text = Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (category == null) return text;

    final categoryColor = ColorUtils.readableOn(
      _parseCategoryColor(category.color),
      theme.brightness,
    );
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: categoryColor,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(child: text),
      ],
    );
  }

  Color _parseCategoryColor(String hex) {
    final clean = hex.replaceAll('#', '');
    if (clean.length == 6) {
      return Color(int.parse('0xFF$clean'));
    }
    return Colors.grey;
  }
}
