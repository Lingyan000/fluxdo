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

  /// 整行退灰系数(已读态用)。原为调用方外包 Opacity(factor) ——
  /// 文本字形与 8px 色块互不重叠,逐色 alpha 预乘与整层透明像素恒等,
  /// 省掉每张已读卡一个合成层。不能由调用方预乘 metaColor 代替:
  /// 内部 '#' 用 withValues(alpha:0.6) 会把预乘过的 alpha 覆盖掉。
  final double opacityFactor;

  const CategoryTagsLine({
    super.key,
    this.category,
    this.tags = const [],
    required this.metaColor,
    this.opacityFactor = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = opacityFactor;
    final baseColor = f == 1.0
        ? metaColor
        : metaColor.withValues(alpha: metaColor.a * f);
    final style = theme.textTheme.labelSmall?.copyWith(color: baseColor);

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
          style: TextStyle(color: metaColor.withValues(alpha: 0.6 * f)),
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
    final chipColor = f == 1.0
        ? categoryColor
        : categoryColor.withValues(alpha: categoryColor.a * f);
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: chipColor,
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
