import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../models/category.dart';
import '../../models/topic.dart';
import '../../utils/color_utils.dart';
import '../../utils/tag_icon_list.dart';

/// ▪分类色标+名 + 标签轻文本,单行 ellipsis。
/// 话题卡片与搜索卡片共用;分类和标签都为空时请勿构造(调用方判空)。
///
/// 形态约定:
/// - 分类:8px 圆角色块(Discourse 分类色,按主题亮度适配)+ 中性色名称
/// - 标签:有图标的用彩色小图标,无图标的加 "#" 前缀
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

    final spans = <InlineSpan>[];
    final category = this.category;
    if (category != null) {
      // 统一用 Discourse 式分类色标(小圆角方块):
      // FA 图标/logo/圆点三种形态混排是列表显乱的来源,
      // 色标形态恒定,颜色即分类身份;色按主题亮度适配可读性
      final categoryColor = ColorUtils.readableOn(
        _parseCategoryColor(category.color),
        theme.brightness,
      );
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            margin: const EdgeInsets.only(right: 4),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: categoryColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      );
      spans.add(
        TextSpan(
          // 分类名用中性色:颜色锚点只留给前面的色标
          text: category.name,
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
      );
    }
    for (final tag in tags) {
      if (spans.isNotEmpty) spans.add(const TextSpan(text: '   '));
      final tagInfo = TagIconList.get(tag.name);
      if (tagInfo != null) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(right: 3),
              child: FaIcon(
                tagInfo.icon,
                size: 10,
                // 标签图标色同样按主题亮度适配
                color: ColorUtils.readableOn(tagInfo.color, theme.brightness),
              ),
            ),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: '#',
            style: TextStyle(color: metaColor.withValues(alpha: 0.6)),
          ),
        );
      }
      spans.add(TextSpan(text: tag.name));
    }

    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
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
