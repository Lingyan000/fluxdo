part of 'search_filter_panel.dart';

/// 过滤器选项 Chip
class _FilterChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final IconData? icon;

  const _FilterChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? colorScheme.primaryContainer
                : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected
                  ? colorScheme.primary.withValues(alpha: 0.5)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 14,
                  color: isSelected
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: isSelected
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              if (isSelected) ...[
                const SizedBox(width: 4),
                Icon(Icons.check, size: 14, color: colorScheme.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 分类过滤项
class _CategoryFilterItem extends StatelessWidget {
  final String name;
  final Color color;
  final bool isSelected;
  final VoidCallback onTap;
  final bool isAll;
  final Category? category;
  final bool isSubcategory;

  const _CategoryFilterItem({
    required this.name,
    required this.color,
    required this.isSelected,
    required this.onTap,
    this.isAll = false,
    this.category,
    this.isSubcategory = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 图标逻辑
    IconData? faIcon;

    if (category != null) {
      faIcon = FontAwesomeHelper.getIcon(category!.icon);
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: EdgeInsets.only(
            left: isSubcategory ? 6 : 10,
            right: 10,
            top: 6,
            bottom: 6,
          ),
          decoration: BoxDecoration(
            color:
                isSelected ? color.withValues(alpha: 0.15) : color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isSelected ? color : color.withValues(alpha: 0.2),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isAll)
                Icon(Icons.all_inclusive, size: 12, color: theme.colorScheme.onSurface)
              else if (faIcon != null)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FaIcon(faIcon, size: 12, color: color),
                )
              else if (category?.readRestricted ?? false)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(Icons.lock, size: 12, color: color),
                )
              else
                _buildDot(),

              if (!isAll && faIcon == null && !(category?.readRestricted ?? false))
                const SizedBox(width: 6)
              else if (isAll)
                const SizedBox(width: 6),

              Text(
                name,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: theme.colorScheme.onSurface,
                  fontSize: isSubcategory ? 12 : null,
                ),
              ),
              if (isSelected) ...[
                const SizedBox(width: 6),
                Icon(Icons.check, size: 14, color: color),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDot() {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// 已激活过滤条件显示条
class ActiveSearchFiltersBar extends StatelessWidget {
  final SearchFilter filter;
  final VoidCallback? onClearCategory;
  final ValueChanged<String>? onRemoveTag;
  final VoidCallback? onClearStatus;
  final VoidCallback? onClearDateRange;
  final VoidCallback? onClearAll;

  const ActiveSearchFiltersBar({
    super.key,
    required this.filter,
    this.onClearCategory,
    this.onRemoveTag,
    this.onClearStatus,
    this.onClearDateRange,
    this.onClearAll,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      child: filter.isEmpty
          ? const SizedBox.shrink()
          : Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainer.withValues(alpha: 0.5),
                border: Border(
                  bottom: BorderSide(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.2)),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.filter_list,
                          size: 14, color: colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        '当前筛选',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      if (onClearAll != null)
                        InkWell(
                          onTap: onClearAll,
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Text(
                              '清除全部',
                              style:
                                  TextStyle(fontSize: 12, color: colorScheme.error),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        // 分类
                        if (filter.categoryId != null && onClearCategory != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: RemovableCategoryBadge(
                              name: filter.categoryName ?? '分类',
                              onDeleted: onClearCategory!,
                              size: const BadgeSize(
                                padding:
                                    EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                radius: 8,
                                iconSize: 12,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        // 状态
                        if (filter.status != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: _RemovableChip(
                              label: filter.status!.label,
                              onDeleted: onClearStatus,
                            ),
                          ),
                        // 时间范围
                        if (filter.afterDate != null || filter.beforeDate != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: _RemovableChip(
                              label: _formatDateRange(
                                  filter.afterDate, filter.beforeDate),
                              icon: Icons.calendar_today,
                              onDeleted: onClearDateRange,
                            ),
                          ),
                        // 标签
                        ...filter.tags.map((tag) => Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: RemovableTagBadge(
                                name: tag,
                                onDeleted: () => onRemoveTag?.call(tag),
                                size: const BadgeSize(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 6),
                                  radius: 8,
                                  iconSize: 12,
                                  fontSize: 12,
                                ),
                              ),
                            )),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  String _formatDateRange(DateTime? after, DateTime? before) {
    if (after != null && before != null) {
      return '${_formatShortDate(after)} - ${_formatShortDate(before)}';
    } else if (after != null) {
      return '${_formatShortDate(after)} 之后';
    } else if (before != null) {
      return '${_formatShortDate(before)} 之前';
    }
    return '时间范围';
  }

  String _formatShortDate(DateTime date) {
    return '${date.month}/${date.day}';
  }
}

/// 可移除的 Chip
class _RemovableChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onDeleted;

  const _RemovableChip({
    required this.label,
    this.icon,
    this.onDeleted,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (onDeleted != null) ...[
            const SizedBox(width: 4),
            GestureDetector(
              onTap: onDeleted,
              child: Icon(Icons.close, size: 14, color: colorScheme.outline),
            ),
          ],
        ],
      ),
    );
  }
}
