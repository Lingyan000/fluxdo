import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import '../../models/category.dart';
import '../../providers/topic_list/filter_provider.dart';
import '../../providers/topic_list/sort_provider.dart';
import '../common/topic_badges.dart';
import 'filter_dropdown.dart';
import 'category_level_dropdown.dart';
import '../../l10n/s.dart';

/// 筛选选项定义
List<(TopicListFilter, String)> get filterOptions => [
  (TopicListFilter.latest, S.current.topic_filterLatest),
  (TopicListFilter.newTopics, S.current.topic_filterNew),
  (TopicListFilter.unread, S.current.topic_filterUnread),
  (TopicListFilter.unseen, S.current.topic_filterUnseen),
  (TopicListFilter.top, S.current.topic_filterTop),
  (TopicListFilter.hot, S.current.topic_filterHot),
];

/// 获取筛选模式的显示名称
String filterLabel(TopicListFilter filter) {
  for (final option in filterOptions) {
    if (option.$1 == filter) return option.$2;
  }
  return S.current.topic_filterLatest;
}

/// 筛选下拉 + 排序下拉 + 标签 chips（固定在 Tab 和列表之间）
///
/// 纯 callback-based，不再内部读写任何 provider。
class SortAndTagsBar extends StatelessWidget {
  final TopicListFilter currentFilter;
  final bool isLoggedIn;
  final ValueChanged<TopicListFilter> onFilterChanged;
  final NewSubset currentSubset;
  final ValueChanged<NewSubset> onSubsetChanged;
  final TopicSortOrder currentOrder;
  final bool ascending;
  final ValueChanged<TopicSortOrder> onOrderChanged;
  final VoidCallback onToggleAscending;
  final List<String> selectedTags;
  final ValueChanged<String> onTagRemoved;
  final VoidCallback? onAddTag;
  final Category? currentCategory;
  final ValueChanged<Category>? onCategoryChanged;
  final Widget? trailing;

  const SortAndTagsBar({
    super.key,
    required this.currentFilter,
    required this.isLoggedIn,
    required this.onFilterChanged,
    required this.currentSubset,
    required this.onSubsetChanged,
    required this.currentOrder,
    required this.ascending,
    required this.onOrderChanged,
    required this.onToggleAscending,
    required this.selectedTags,
    required this.onTagRemoved,
    this.onAddTag,
    this.currentCategory,
    this.onCategoryChanged,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          // 筛选下拉
          FilterDropdown(
            currentFilter: currentFilter,
            isLoggedIn: isLoggedIn,
            onFilterChanged: onFilterChanged,
          ),
          // 「新话题」子过滤下拉
          if (currentFilter == TopicListFilter.newTopics) ...[
            const SizedBox(width: 4),
            NewSubsetDropdown(
              currentSubset: currentSubset,
              onSubsetChanged: onSubsetChanged,
            ),
          ],
          const SizedBox(width: 4),
          // 排序下拉
          OrderDropdown(
            currentOrder: currentOrder,
            ascending: ascending,
            onOrderChanged: onOrderChanged,
            onToggleAscending: onToggleAscending,
          ),
          // 板块等级切换（内部无同级时自隐藏）
          if (currentCategory != null && onCategoryChanged != null)
            CategoryLevelDropdown(
              currentCategory: currentCategory!,
              onCategoryChanged: onCategoryChanged!,
            ),
          const SizedBox(width: 8),
          // 标签区域
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ...selectedTags.map((tag) => Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: RemovableTagBadge(
                      name: tag,
                      onDeleted: () => onTagRemoved(tag),
                      size: const BadgeSize(
                        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        radius: 6,
                        iconSize: 12,
                        fontSize: 12,
                      ),
                    ),
                  )),
                  if (onAddTag != null)
                    _AddTagButton(
                      colorScheme: colorScheme,
                      onTap: onAddTag!,
                    ),
                ],
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _AddTagButton extends StatelessWidget {
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  const _AddTagButton({
    required this.colorScheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.add_rounded, size: 14, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 2),
            Icon(Symbols.label_rounded, size: 14, color: colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
