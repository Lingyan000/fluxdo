import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../models/category.dart';
import '../../models/search_filter.dart';
import '../../providers/category_provider.dart';
import '../../utils/color_utils.dart';
import '../../utils/font_awesome_helper.dart';
import '../../utils/tag_icon_list.dart';
import '../common/tag_selection_sheet.dart';
import '../common/topic_badges.dart';

part '_search_filter_widgets.dart';

/// 搜索高级过滤器面板
/// 作为 BottomSheet 显示，支持分类、标签、状态、时间范围过滤
class SearchFilterPanel extends ConsumerStatefulWidget {
  /// 当前过滤条件
  final SearchFilter filter;

  /// 过滤条件变化回调
  final ValueChanged<SearchFilter> onFilterChanged;

  /// 是否隐藏搜索范围类型（主搜索页面不需要显示）
  final bool hideInType;

  const SearchFilterPanel({
    super.key,
    required this.filter,
    required this.onFilterChanged,
    this.hideInType = false,
  });

  @override
  ConsumerState<SearchFilterPanel> createState() => _SearchFilterPanelState();
}

class _SearchFilterPanelState extends ConsumerState<SearchFilterPanel> {
  late SearchFilter _localFilter;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _localFilter = widget.filter;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _updateFilter(SearchFilter newFilter) {
    setState(() {
      _localFilter = newFilter;
    });
  }

  void _setCategory(Category? category) {
    if (category == null) {
      _updateFilter(_localFilter.copyWith(clearCategory: true));
    } else {
      // 查找父分类 slug
      String? parentSlug;
      if (category.parentCategoryId != null) {
        final categoryMap = ref.read(categoryMapProvider).value;
        if (categoryMap != null) {
          final parent = categoryMap[category.parentCategoryId];
          parentSlug = parent?.slug;
        }
      }
      _updateFilter(_localFilter.copyWith(
        categoryId: category.id,
        categorySlug: category.slug,
        categoryName: category.name,
        parentCategorySlug: parentSlug,
      ));
    }
  }

  void _setStatus(SearchStatus? status) {
    _updateFilter(_localFilter.copyWith(
      status: status,
      clearStatus: status == null,
    ));
  }

  void _toggleTag(String tag) {
    final currentTags = List<String>.from(_localFilter.tags);
    if (currentTags.contains(tag)) {
      currentTags.remove(tag);
    } else {
      currentTags.add(tag);
    }
    _updateFilter(_localFilter.copyWith(tags: currentTags));
  }

  void _setTags(List<String> tags) {
    _updateFilter(_localFilter.copyWith(tags: tags));
  }

  void _setDateRange({DateTime? after, DateTime? before}) {
    _updateFilter(_localFilter.copyWith(
      afterDate: after,
      beforeDate: before,
      clearDateRange: after == null && before == null,
    ));
  }

  void _clearAll() {
    _updateFilter(_localFilter.clear());
  }

  Future<void> _openTagSearchSheet() async {
    final tagsAsync = ref.read(tagsProvider);
    final availableTags = tagsAsync.when(
      data: (tags) => tags,
      loading: () => <String>[],
      error: (e, s) => <String>[],
    );

    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => TagSelectionSheet(
        availableTags: availableTags,
        selectedTags: _localFilter.tags,
        maxTags: 99,
      ),
    );

    if (result != null && mounted) {
      _setTags(result);
    }
  }

  Future<void> _selectDateRange() async {
    final now = DateTime.now();
    final initialRange = DateTimeRange(
      start: _localFilter.afterDate ?? now.subtract(const Duration(days: 30)),
      end: _localFilter.beforeDate ?? now,
    );

    final result = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2010),
      lastDate: now,
      initialDateRange: initialRange,
      locale: const Locale('zh', 'CN'),
      helpText: '选择时间范围',
      cancelText: '取消',
      confirmText: '确定',
      saveText: '确定',
    );

    if (result != null && mounted) {
      _setDateRange(after: result.start, before: result.end);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final categoriesAsync = ref.watch(categoriesProvider);
    final tagsAsync = ref.watch(tagsProvider);

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶部拖动柄
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12),
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // 标题栏
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '高级搜索',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                // 重置按钮
                Visibility(
                  visible: _localFilter.isNotEmpty,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: TextButton(
                    onPressed: _localFilter.isNotEmpty ? _clearAll : null,
                    style: TextButton.styleFrom(
                      foregroundColor: colorScheme.error,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('重置'),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // 内容区域
          Expanded(
            child: ListView(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              children: [
                // 状态选择
                Text(
                  '状态',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                _buildStatusSection(theme),

                const SizedBox(height: 24),

                // 时间范围
                Text(
                  '时间范围',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                _buildDateRangeSection(theme),

                const SizedBox(height: 24),

                // 分类选择
                Text(
                  '分类',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                categoriesAsync.when(
                  data: (categories) => _buildCategoryGrid(
                    context,
                    categories,
                    _localFilter.categoryId,
                  ),
                  loading: () => const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                  error: (e, _) => Center(child: Text('加载分类失败: $e')),
                ),

                const SizedBox(height: 24),

                // 标签选择
                Row(
                  children: [
                    Text(
                      '标签',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _openTagSearchSheet,
                      icon: const Icon(Icons.search, size: 18),
                      label: const Text('搜索更多'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                tagsAsync.when(
                  data: (hotTags) {
                    // 找出已选但不在热门中的标签
                    final extraSelectedTags = _localFilter.tags
                        .where((t) => !hotTags.contains(t))
                        .toList();

                    if (hotTags.isEmpty && extraSelectedTags.isEmpty) {
                      return Text(
                        '暂无热门标签',
                        style: TextStyle(color: colorScheme.outline),
                      );
                    }

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 已选的非热门标签
                        if (extraSelectedTags.isNotEmpty) ...[
                          Text(
                            '已选标签',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 8),
                          _buildTagWrap(extraSelectedTags, theme),
                          const SizedBox(height: 16),
                        ],
                        // 热门标签
                        if (hotTags.isNotEmpty) ...[
                          Text(
                            '热门标签',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 8),
                          _buildTagWrap(hotTags, theme),
                        ],
                      ],
                    );
                  },
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Text('加载标签失败: $e'),
                ),
              ],
            ),
          ),

          // 底部确认按钮区域
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    widget.onFilterChanged(_localFilter);
                    Navigator.pop(context);
                  },
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('应用筛选', style: TextStyle(fontSize: 16)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusSection(ThemeData theme) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        // 全部选项
        _FilterChip(
          label: '全部',
          isSelected: _localFilter.status == null,
          onTap: () => _setStatus(null),
        ),
        // 状态选项
        ...SearchStatus.values.map((status) => _FilterChip(
              label: status.label,
              isSelected: _localFilter.status == status,
              onTap: () =>
                  _setStatus(_localFilter.status == status ? null : status),
            )),
      ],
    );
  }

  Widget _buildDateRangeSection(ThemeData theme) {
    final hasDateRange =
        _localFilter.afterDate != null || _localFilter.beforeDate != null;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        // 不限
        _FilterChip(
          label: '不限',
          isSelected: !hasDateRange,
          onTap: () => _setDateRange(),
        ),
        // 快捷选项
        _FilterChip(
          label: '最近一周',
          isSelected: false,
          onTap: () {
            final now = DateTime.now();
            _setDateRange(
              after: now.subtract(const Duration(days: 7)),
              before: now,
            );
          },
        ),
        _FilterChip(
          label: '最近一月',
          isSelected: false,
          onTap: () {
            final now = DateTime.now();
            _setDateRange(
              after: now.subtract(const Duration(days: 30)),
              before: now,
            );
          },
        ),
        _FilterChip(
          label: '最近一年',
          isSelected: false,
          onTap: () {
            final now = DateTime.now();
            _setDateRange(
              after: now.subtract(const Duration(days: 365)),
              before: now,
            );
          },
        ),
        // 自定义
        _FilterChip(
          label: hasDateRange ? _formatDateRange() : '自定义',
          isSelected: hasDateRange,
          onTap: _selectDateRange,
          icon: Icons.calendar_today,
        ),
      ],
    );
  }

  String _formatDateRange() {
    final after = _localFilter.afterDate;
    final before = _localFilter.beforeDate;
    if (after != null && before != null) {
      return '${_formatShortDate(after)} - ${_formatShortDate(before)}';
    } else if (after != null) {
      return '${_formatShortDate(after)} 之后';
    } else if (before != null) {
      return '${_formatShortDate(before)} 之前';
    }
    return '自定义';
  }

  String _formatShortDate(DateTime date) {
    return '${date.month}/${date.day}';
  }

  Widget _buildCategoryGrid(
    BuildContext context,
    List<Category> categories,
    int? selectedId,
  ) {
    // 顶级分类
    final topCategories =
        categories.where((c) => c.parentCategoryId == null).toList();

    // 父类ID -> 子类列表 映射
    final Map<int, List<Category>> subcategoryMap = {};
    for (final category in categories) {
      if (category.parentCategoryId != null) {
        subcategoryMap.putIfAbsent(category.parentCategoryId!, () => []);
        subcategoryMap[category.parentCategoryId]!.add(category);
      }
    }

    // 分离孤立父类和组合父类
    final List<Category> isolatedParents = [];
    final List<Category> groupParents = [];

    for (final parent in topCategories) {
      if (subcategoryMap.containsKey(parent.id) &&
          subcategoryMap[parent.id]!.isNotEmpty) {
        groupParents.add(parent);
      } else {
        isolatedParents.add(parent);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部区域："全部" + 孤立父类
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // "全部" 选项
            _CategoryFilterItem(
              name: '全部',
              color: Colors.grey,
              isSelected: selectedId == null,
              onTap: () => _setCategory(null),
              isAll: true,
            ),
            ...isolatedParents.map((category) {
              final isSelected = selectedId == category.id;
              final categoryColor = ColorUtils.parseHex(category.color);
              return _CategoryFilterItem(
                name: category.name,
                color: categoryColor,
                isSelected: isSelected,
                category: category,
                onTap: () => _setCategory(isSelected ? null : category),
              );
            }),
          ],
        ),

        if (groupParents.isNotEmpty) const SizedBox(height: 16),

        // 分组区域
        ...groupParents.map((parent) {
          final subcategories = subcategoryMap[parent.id]!;
          final isParentSelected = selectedId == parent.id;
          final parentColor = ColorUtils.parseHex(parent.color);

          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 父分类标题
                _CategoryFilterItem(
                  name: parent.name,
                  color: parentColor,
                  isSelected: isParentSelected,
                  category: parent,
                  onTap: () => _setCategory(isParentSelected ? null : parent),
                ),
                const SizedBox(height: 8),

                // 子分类列表
                IntrinsicHeight(
                  child: Row(
                    children: [
                      // 左侧引导线
                      Container(
                        width: 2,
                        margin: const EdgeInsets.only(
                            left: 12, right: 12, top: 4, bottom: 4),
                        decoration: BoxDecoration(
                          color: parentColor.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                      // 子分类 Wrap
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: subcategories.map((sub) {
                            final isSubSelected = selectedId == sub.id;
                            final subColor = ColorUtils.parseHex(sub.color);
                            return _CategoryFilterItem(
                              name: sub.name,
                              color: subColor,
                              isSelected: isSubSelected,
                              category: sub,
                              isSubcategory: true,
                              onTap: () =>
                                  _setCategory(isSubSelected ? null : sub),
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildTagWrap(List<String> tags, ThemeData theme) {
    final colorScheme = theme.colorScheme;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: tags.map((tag) {
        final isSelected = _localFilter.tags.contains(tag);
        final tagInfo = TagIconList.get(tag);

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _toggleTag(tag),
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: isSelected
                    ? colorScheme.primaryContainer
                    : colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
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
                  if (tagInfo != null || isSelected)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: Center(
                          child: isSelected
                              ? Icon(
                                  Icons.check,
                                  size: 14,
                                  color: colorScheme.primary,
                                )
                              : FaIcon(
                                  tagInfo!.icon,
                                  size: 12,
                                  color: tagInfo.color,
                                ),
                        ),
                      ),
                    ),
                  Text(
                    tag,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: isSelected
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

}
