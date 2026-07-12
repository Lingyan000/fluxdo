import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:common_ui/common_ui.dart';

import '../../models/category.dart';
import '../../providers/discourse_providers.dart';

/// 同级板块等级选项：父分类 + 子分类列表
class CategoryLevelOptions {
  final Category parent;
  final List<Category> children;

  const CategoryLevelOptions({
    required this.parent,
    required this.children,
  });

  List<Category> get all => [parent, ...children];
}

/// 解析当前分类的同级等级列表。
/// 无子分类时返回 null（不显示下拉）。
CategoryLevelOptions? resolveCategoryLevels(
  Category current,
  List<Category> all,
  Map<int, Category> map,
) {
  final Category parent;
  final List<Category> children;

  if (current.parentCategoryId != null) {
    final p = map[current.parentCategoryId];
    if (p == null) return null;
    parent = p;
    children = all
        .where((c) => c.parentCategoryId == parent.id)
        .toList(growable: false);
  } else {
    parent = current;
    children = all
        .where((c) => c.parentCategoryId == current.id)
        .toList(growable: false);
  }

  if (children.isEmpty) return null;
  return CategoryLevelOptions(parent: parent, children: children);
}

/// 按钮/菜单项短标签：去掉父分类名前缀与分隔符，父分类显示「全部LV」
String categoryLevelLabel(Category category, Category parent) {
  if (category.id == parent.id) return '全部LV';
  final name = category.name;
  final parentName = parent.name;
  if (name.startsWith(parentName)) {
    final rest = name.substring(parentName.length);
    // 去掉前缀后的分隔符（空格、逗号、斜杠、中点等）
    final cleaned = rest.replaceFirst(RegExp(r'^[\s,，\-_/·:：]+'), '');
    if (cleaned.isNotEmpty) return cleaned;
  }
  // 名称本身含「LV数字」时优先只显示等级
  final lvMatch = RegExp(r'LV\s*\d+', caseSensitive: false).firstMatch(name);
  if (lvMatch != null) {
    return lvMatch.group(0)!.toUpperCase().replaceAll(' ', '');
  }
  return name;
}

/// 板块等级切换下拉（风格与 FilterDropdown / OrderDropdown 一致）
class CategoryLevelDropdown extends ConsumerWidget {
  final Category currentCategory;
  final ValueChanged<Category> onCategoryChanged;

  const CategoryLevelDropdown({
    super.key,
    required this.currentCategory,
    required this.onCategoryChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categoriesAsync = ref.watch(categoriesProvider);
    final categories = categoriesAsync.value;
    if (categories == null) return const SizedBox.shrink();

    final map = {for (final c in categories) c.id: c};
    // 若 map 中有更新后的 current，优先用它
    final current = map[currentCategory.id] ?? currentCategory;
    final options = resolveCategoryLevels(current, categories, map);
    if (options == null) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;
    final label = categoryLevelLabel(current, options.parent);
    final isParentSelected = current.id == options.parent.id;

    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: SwipeDismissiblePopupMenuButton<int>(
        onSelected: (id) {
          if (id == current.id) return;
          final target = map[id];
          if (target != null) onCategoryChanged(target);
        },
        offset: const Offset(0, 36),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        tooltip: label,
        itemBuilder: (context) {
          return options.all.map((cat) {
            final isSelected = cat.id == current.id;
            final itemLabel = categoryLevelLabel(cat, options.parent);
            return PopupMenuItem<int>(
              value: cat.id,
              child: Row(
                children: [
                  if (isSelected)
                    Icon(Symbols.check_rounded, size: 16, color: colorScheme.primary)
                  else
                    const SizedBox(width: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      itemLabel,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            );
          }).toList();
        },
        child: _buildChild(colorScheme, label, !isParentSelected),
      ),
    );
  }

  Widget _buildChild(ColorScheme colorScheme, String label, bool isActive) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isActive
            ? colorScheme.primaryContainer.withValues(alpha: 0.3)
            : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 96),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: isActive ? colorScheme.primary : colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 2),
          Icon(
            Symbols.arrow_drop_down_rounded,
            size: 18,
            color: isActive ? colorScheme.primary : colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}
