import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../models/category.dart';
import '../../services/discourse_cache_manager.dart';
import '../../utils/color_utils.dart';
import '../../utils/url_helper.dart';
import '../../utils/tag_icon_list.dart';

class BadgeSize {
  final EdgeInsets padding;
  final double radius;
  final double iconSize;
  final double fontSize;

  const BadgeSize({
    required this.padding,
    required this.radius,
    required this.iconSize,
    required this.fontSize,
  });

  // Matches TopicCard tag/category badges.
  static const BadgeSize compact = BadgeSize(
    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    radius: 6,
    iconSize: 10,
    fontSize: 10,
  );
}

class TagBadge extends StatelessWidget {
  final String name;
  final BadgeSize size;
  final TextStyle? textStyle;
  final Color? backgroundColor;
  final Border? border;

  const TagBadge({
    super.key,
    required this.name,
    this.size = BadgeSize.compact,
    this.textStyle,
    this.backgroundColor,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tagInfo = TagIconList.get(name);
    final bg = backgroundColor ??
        theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5);
    final text = textStyle ??
        theme.textTheme.labelSmall?.copyWith(
          fontSize: size.fontSize,
          color: theme.colorScheme.onSurfaceVariant,
        );

    return Container(
      padding: size.padding,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(size.radius),
        border: border,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tagInfo != null) ...[
            FaIcon(
              tagInfo.icon,
              size: size.iconSize,
              color: tagInfo.color,
            ),
            const SizedBox(width: 4),
          ],
          Text(name, style: text),
        ],
      ),
    );
  }
}

/// 可删除的标签徽章
class RemovableTagBadge extends StatelessWidget {
  final String name;
  final VoidCallback onDeleted;
  final BadgeSize size;
  final Color? backgroundColor;

  const RemovableTagBadge({
    super.key,
    required this.name,
    required this.onDeleted,
    this.size = BadgeSize.compact,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tagInfo = TagIconList.get(name);
    final bg = backgroundColor ??
        theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onDeleted,
        borderRadius: BorderRadius.circular(size.radius),
        child: Container(
          padding: size.padding,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(size.radius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (tagInfo != null) ...[
                FaIcon(
                  tagInfo.icon,
                  size: size.iconSize,
                  color: tagInfo.color,
                ),
                const SizedBox(width: 4),
              ],
              Text(
                name,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: size.fontSize,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.close,
                size: size.iconSize + 2,
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 可删除的分类徽章
class RemovableCategoryBadge extends StatelessWidget {
  final String name;
  final VoidCallback onDeleted;
  final BadgeSize size;

  const RemovableCategoryBadge({
    super.key,
    required this.name,
    required this.onDeleted,
    this.size = BadgeSize.compact,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = theme.colorScheme.secondaryContainer;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onDeleted,
        borderRadius: BorderRadius.circular(size.radius),
        child: Container(
          padding: size.padding,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(size.radius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.category_outlined,
                size: size.iconSize,
                color: theme.colorScheme.onSecondaryContainer,
              ),
              const SizedBox(width: 4),
              Text(
                name,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: size.fontSize,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.close,
                size: size.iconSize + 2,
                color: theme.colorScheme.onSecondaryContainer.withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CategoryBadge extends StatelessWidget {
  final Category category;
  final IconData? faIcon;
  final String? logoUrl;
  final BadgeSize size;
  final TextStyle? textStyle;
  final bool showLockWhenRestricted;

  const CategoryBadge({
    super.key,
    required this.category,
    this.faIcon,
    this.logoUrl,
    this.size = BadgeSize.compact,
    this.textStyle,
    this.showLockWhenRestricted = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final categoryColor = ColorUtils.parseHex(category.color);
    final text = textStyle ??
        theme.textTheme.labelSmall?.copyWith(
          fontSize: size.fontSize,
          fontWeight: FontWeight.w500,
          color: theme.colorScheme.onSurface,
        );

    return Container(
      padding: size.padding,
      decoration: BoxDecoration(
        color: categoryColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(size.radius),
        border: Border.all(
          color: categoryColor.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (faIcon != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: FaIcon(
                faIcon,
                size: size.iconSize,
                color: categoryColor,
              ),
            )
          else if (logoUrl != null && logoUrl!.isNotEmpty)
            Image(
              image: discourseImageProvider(
                UrlHelper.resolveUrl(logoUrl!),
              ),
              width: size.iconSize,
              height: size.iconSize,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) {
                return _buildCategoryDot(categoryColor);
              },
            )
          else if (showLockWhenRestricted && category.readRestricted)
            _buildCategoryLock(categoryColor)
          else
            _buildCategoryDot(categoryColor),
          const SizedBox(width: 4),
          Text(category.name, style: text),
        ],
      ),
    );
  }

  Widget _buildCategoryDot(Color color) {
    return Container(
      width: size.iconSize * 0.6,
      height: size.iconSize * 0.6,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }

  Widget _buildCategoryLock(Color color) {
    return Icon(
      Icons.lock,
      size: size.iconSize,
      color: color,
    );
  }

}
