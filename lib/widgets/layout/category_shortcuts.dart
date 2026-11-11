import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../models/category.dart';
import '../../providers/discourse_providers.dart';
import '../../providers/pinned_categories_provider.dart';
import '../../utils/font_awesome_helper.dart';
import '../../utils/url_helper.dart';
import '../../services/discourse_cache_manager.dart';
import '../../utils/color_utils.dart';

class CategoryShortcuts extends ConsumerWidget {
  const CategoryShortcuts({
    super.key,
    required this.extended,
    required this.onCategorySelected,
  });

  final bool extended;
  final ValueChanged<int> onCategorySelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinnedIds = ref.watch(pinnedCategoriesProvider);
    final categoriesAsync = ref.watch(categoriesProvider);

    return categoriesAsync.when(
      data: (categories) {
        final categoryMap = {
          for (final category in categories) category.id: category,
        };
        final pinnedCategories = pinnedIds
            .map((id) => categoryMap[id])
            .whereType<Category>()
            .toList();

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: pinnedCategories
              .map(
                (category) => _CategoryShortcutItem(
                  category: category,
                  extended: extended,
                  onTap: () => onCategorySelected(category.id),
                ),
              )
              .toList(),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _CategoryShortcutItem extends ConsumerWidget {
  const _CategoryShortcutItem({
    required this.category,
    required this.extended,
    required this.onTap,
  });

  final Category category;
  final bool extended;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final categoryColor = ColorUtils.category(
      category.color,
      Theme.of(context),
      fallback: colorScheme.primary,
    );
    final activeCategoryId = ref.watch(activeSidebarCategoryIdProvider);
    final isSelected = activeCategoryId == category.id;
    final backgroundColor = isSelected
        ? colorScheme.secondaryContainer
        : Colors.transparent;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: backgroundColor,
        shape: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(16),
        ),
        child: InkWell(
          customBorder: RoundedSuperellipseBorder(
            borderRadius: context.shapes.borderRadius(16),
          ),
          onTap: onTap,
          child: SizedBox(
            height: 56,
            child: extended
                ? Row(
                    children: [
                      const SizedBox(width: 16),
                      _buildCategoryIcon(category, categoryColor, 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          category.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isSelected
                                ? colorScheme.onSecondaryContainer
                                : colorScheme.onSurfaceVariant,
                            fontWeight: isSelected
                                ? FontWeight.w500
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ],
                  )
                : Center(
                    child: _buildCategoryIcon(category, categoryColor, 20),
                  ),
          ),
        ),
      ),
    );
  }
}

Widget _buildCategoryIcon(Category category, Color color, double size) {
  final logoUrl = category.uploadedLogo;
  final faIcon = FontAwesomeHelper.getIcon(category.icon);

  if (faIcon != null) {
    return FaIcon(faIcon, size: size * 0.85, color: color);
  }

  if (logoUrl != null && logoUrl.isNotEmpty) {
    return Image(
      image: discourseImageProvider(UrlHelper.resolveUrlWithCdn(logoUrl)),
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => _buildColorDot(color, size * 0.5),
    );
  }

  if (category.readRestricted) {
    return Icon(Symbols.lock_rounded, size: size * 0.8, color: color);
  }

  return _buildColorDot(color, size * 0.5);
}

Widget _buildColorDot(Color color, double size) {
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
