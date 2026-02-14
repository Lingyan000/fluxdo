import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../models/category.dart';
import '../../providers/discourse_providers.dart';
import '../../providers/pinned_categories_provider.dart';
import '../../utils/font_awesome_helper.dart';
import '../../services/discourse_cache_manager.dart';
import '../../utils/color_utils.dart';
import '../../utils/url_helper.dart';
import '../../pages/category_topics_page.dart';

// ============================================================
// 工具函数
// ============================================================

/// 构建分类图标 widget
/// [preferImage] 为 true 时图片优先（用于网格），false 时图标优先（用于 chips）
Widget _buildCategoryIcon(Category category, Color color, double size, {bool preferImage = false}) {
  final logoUrl = category.uploadedLogo;
  final faIcon = FontAwesomeHelper.getIcon(category.icon);

  if (preferImage) {
    // 图片优先：logo → FA 图标 → lock → 色点
    if (logoUrl != null && logoUrl.isNotEmpty) {
      return Image(
        image: discourseImageProvider(
          UrlHelper.resolveUrl(logoUrl),
        ),
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (_, e, s) {
          if (faIcon != null) return FaIcon(faIcon, size: size * 0.7, color: color);
          return _buildColorDot(color, size * 0.5);
        },
      );
    }
    if (faIcon != null) return FaIcon(faIcon, size: size * 0.7, color: color);
  } else {
    // 图标优先：FA 图标 → logo → lock → 色点
    if (faIcon != null) return FaIcon(faIcon, size: size * 0.7, color: color);
    if (logoUrl != null && logoUrl.isNotEmpty) {
      return Image(
        image: discourseImageProvider(
          UrlHelper.resolveUrl(logoUrl),
        ),
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (_, e, s) => _buildColorDot(color, size * 0.5),
      );
    }
  }

  if (category.readRestricted) {
    return Icon(Icons.lock, size: size * 0.7, color: color);
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

/// 弹出子分类选择菜单（浏览模式：导航到分类话题页）
Future<void> _showSubcategoryMenu({
  required BuildContext context,
  required Offset tapPosition,
  required Category parent,
  required List<Category> subcategories,
  required Color parentColor,
  required VoidCallback onDone,
}) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final result = await showMenu<Category>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromCenter(center: tapPosition, width: 0, height: 0),
      Offset.zero & overlay.size,
    ),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    elevation: 6,
    items: [
      // "全部"
      PopupMenuItem<Category>(
        value: parent,
        child: Row(
          children: [
            _buildCategoryIcon(parent, parentColor, 20),
            const SizedBox(width: 10),
            Text('全部', style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
      // 子分类
      ...subcategories.map((sub) {
        final subColor = ColorUtils.parseHex(sub.color);
        return PopupMenuItem<Category>(
          value: sub,
          child: Row(
            children: [
              _buildCategoryIcon(sub, subColor, 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(sub.name, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        );
      }),
    ],
  );

  if (result != null && context.mounted) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CategoryTopicsPage(category: result)),
    );
  }
}

// ============================================================
// 分类浏览 BottomSheet（一级页面）
// ============================================================

class CategoryTabManagerSheet extends ConsumerWidget {
  const CategoryTabManagerSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinnedIds = ref.watch(pinnedCategoriesProvider);
    final categoriesAsync = ref.watch(categoriesProvider);
    final categoryMapAsync = ref.watch(categoryMapProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 拖动柄
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
          // 标题
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              '全部分类',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          const Divider(height: 1),
          // 内容
          Expanded(
            child: categoriesAsync.when(
              data: (categories) {
                final categoryMap = categoryMapAsync.value ?? {};
                return _BrowseContent(
                  pinnedIds: pinnedIds,
                  categories: categories,
                  categoryMap: categoryMap,
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('加载分类失败: $e')),
            ),
          ),
        ],
      ),
    );
  }
}

class _BrowseContent extends ConsumerWidget {
  final List<int> pinnedIds;
  final List<Category> categories;
  final Map<int, Category> categoryMap;

  const _BrowseContent({
    required this.pinnedIds,
    required this.categories,
    required this.categoryMap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final pinnedCategories = pinnedIds
        .map((id) => categoryMap[id])
        .whereType<Category>()
        .toList();

    // 所有顶级分类
    final topCategories = categories
        .where((c) => c.parentCategoryId == null)
        .toList();

    // 父→子映射
    final Map<int, List<Category>> subcategoryMap = {};
    for (final c in categories) {
      if (c.parentCategoryId != null) {
        subcategoryMap.putIfAbsent(c.parentCategoryId!, () => []);
        subcategoryMap[c.parentCategoryId]!.add(c);
      }
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        // ---- 我的分类 ----
        Row(
          children: [
            Text(
              '我的分类',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const _PinnedCategoryEditPage()),
                );
              },
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('编辑'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (pinnedCategories.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              '点击"编辑"添加常用分类到标签栏',
              style: TextStyle(color: colorScheme.outline, fontSize: 13),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: pinnedCategories.map((category) {
                final color = ColorUtils.parseHex(category.color);
                return _buildQuickChip(context, category, color);
              }).toList(),
            ),
          ),

        const Divider(height: 1),
        const SizedBox(height: 16),

        // ---- 全部分类（网格） ----
        Text(
          '全部分类',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),

        // 网格：全部 + 顶级分类
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 88,
            childAspectRatio: 0.9,
            crossAxisSpacing: 8,
            mainAxisSpacing: 4,
          ),
          itemCount: topCategories.length,
          itemBuilder: (context, index) {
            final category = topCategories[index];
            final color = ColorUtils.parseHex(category.color);
            final subs = subcategoryMap[category.id];
            final hasSubs = subs != null && subs.isNotEmpty;

            return _CategoryGridItem(
              label: category.name,
              color: color,
              isSelected: false,
              hasSubs: hasSubs,
              iconWidget: _buildCategoryIcon(category, color, 24, preferImage: true),
              onTapUp: (details) {
                if (hasSubs) {
                  _showSubcategoryMenu(
                    context: context,
                    tapPosition: details.globalPosition,
                    parent: category,
                    subcategories: subs,
                    parentColor: color,
                    onDone: () => Navigator.pop(context),
                  );
                } else {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CategoryTopicsPage(category: category),
                    ),
                  );
                }
              },
            );
          },
        ),
      ],
    );
  }

  /// 我的分类区域的快捷 Chip（切换到对应 Tab）
  Widget _buildQuickChip(
    BuildContext context,
    Category category,
    Color color,
  ) {
    return GestureDetector(
      onTap: () {
        // 返回 category ID，TopicsPage 负责切换到对应 Tab
        Navigator.pop(context, category.id);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: color.withValues(alpha: 0.2),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildCategoryIcon(category, color, 14),
            const SizedBox(width: 6),
            Text(
              category.name,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// 网格项
// ============================================================

class _CategoryGridItem extends StatelessWidget {
  final String label;
  final Color color;
  final bool isSelected;
  final bool hasSubs;
  final Widget? iconWidget;
  final GestureTapUpCallback? onTapUp;

  const _CategoryGridItem({
    required this.label,
    required this.color,
    required this.isSelected,
    this.hasSubs = false,
    this.iconWidget,
    this.onTapUp,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTapUp: onTapUp != null ? (details) => onTapUp!(details) : null,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 圆形图标容器
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isSelected
                  ? color.withValues(alpha: 0.2)
                  : colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
              border: isSelected
                  ? Border.all(color: color, width: 2)
                  : null,
            ),
            child: Center(child: iconWidget ?? const SizedBox.shrink()),
          ),
          const SizedBox(height: 6),
          // 名称 + 子分类箭头
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    color: isSelected ? color : colorScheme.onSurface,
                  ),
                ),
              ),
              if (hasSubs)
                Icon(Icons.arrow_drop_down, size: 14, color: colorScheme.outline),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================
// 二级页面：编辑固定分类
// ============================================================

class _PinnedCategoryEditPage extends ConsumerWidget {
  const _PinnedCategoryEditPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinnedIds = ref.watch(pinnedCategoriesProvider);
    final categoriesAsync = ref.watch(categoriesProvider);
    final categoryMapAsync = ref.watch(categoryMapProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('编辑我的分类'), centerTitle: false),
      body: categoriesAsync.when(
        data: (categories) {
          final categoryMap = categoryMapAsync.value ?? {};
          return _EditContent(
            pinnedIds: pinnedIds,
            categories: categories,
            categoryMap: categoryMap,
            theme: theme,
            colorScheme: colorScheme,
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载分类失败: $e')),
      ),
    );
  }
}

class _EditContent extends ConsumerWidget {
  final List<int> pinnedIds;
  final List<Category> categories;
  final Map<int, Category> categoryMap;
  final ThemeData theme;
  final ColorScheme colorScheme;

  const _EditContent({
    required this.pinnedIds,
    required this.categories,
    required this.categoryMap,
    required this.theme,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinnedCategories = pinnedIds
        .map((id) => categoryMap[id])
        .whereType<Category>()
        .toList();

    // 未 pin 的顶级分类
    final topLevel = categories
        .where((c) => c.parentCategoryId == null && !pinnedIds.contains(c.id))
        .toList();

    // 未 pin 的子分类映射
    final Map<int, List<Category>> subMap = {};
    for (final c in categories) {
      if (c.parentCategoryId != null && !pinnedIds.contains(c.id)) {
        subMap.putIfAbsent(c.parentCategoryId!, () => []);
        subMap[c.parentCategoryId]!.add(c);
      }
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        // ---- 已添加 ----
        Text(
          '已添加',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '拖拽排序，点击移除',
          style: TextStyle(color: colorScheme.outline, fontSize: 12),
        ),
        const SizedBox(height: 8),
        if (pinnedCategories.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: Text(
                '点击下方分类添加到标签栏',
                style: TextStyle(color: colorScheme.outline, fontSize: 13),
              ),
            ),
          )
        else
          ReorderableListView.builder(
            shrinkWrap: true,
            buildDefaultDragHandles: false,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: pinnedCategories.length,
            onReorder: (oldIndex, newIndex) {
              ref.read(pinnedCategoriesProvider.notifier).reorder(oldIndex, newIndex);
            },
            proxyDecorator: (child, index, animation) {
              return Material(
                elevation: 2,
                borderRadius: BorderRadius.circular(8),
                child: child,
              );
            },
            itemBuilder: (context, index) {
              final category = pinnedCategories[index];
              final color = ColorUtils.parseHex(category.color);
              return _PinnedCategoryTile(
                key: ValueKey(category.id),
                category: category,
                color: color,
                categoryMap: categoryMap,
                index: index,
                onRemove: () {
                  ref.read(pinnedCategoriesProvider.notifier).remove(category.id);
                },
              );
            },
          ),

        const SizedBox(height: 20),
        const Divider(height: 1),
        const SizedBox(height: 12),

        // ---- 可添加（网格） ----
        Text(
          '可添加',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),

        // 网格展示可添加的顶级分类
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 88,
            childAspectRatio: 0.9,
            crossAxisSpacing: 8,
            mainAxisSpacing: 4,
          ),
          itemCount: topLevel.length,
          itemBuilder: (context, index) {
            final category = topLevel[index];
            final color = ColorUtils.parseHex(category.color);
            final subs = subMap[category.id];
            final hasSubs = subs != null && subs.isNotEmpty;

            return _CategoryGridItem(
              label: category.name,
              color: color,
              isSelected: false,
              hasSubs: hasSubs,
              iconWidget: _buildCategoryIcon(category, color, 24, preferImage: true),
              onTapUp: (details) {
                if (hasSubs) {
                  _showAddSubcategoryMenu(
                    context: context,
                    ref: ref,
                    tapPosition: details.globalPosition,
                    parent: category,
                    subcategories: subs,
                    parentColor: color,
                  );
                } else {
                  ref.read(pinnedCategoriesProvider.notifier).add(category.id);
                }
              },
            );
          },
        ),
      ],
    );
  }

  /// 弹出子分类菜单（添加模式：选择添加哪个）
  Future<void> _showAddSubcategoryMenu({
    required BuildContext context,
    required WidgetRef ref,
    required Offset tapPosition,
    required Category parent,
    required List<Category> subcategories,
    required Color parentColor,
  }) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final allItems = [parent, ...subcategories];

    final result = await showMenu<Category>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromCenter(center: tapPosition, width: 0, height: 0),
        Offset.zero & overlay.size,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 6,
      items: allItems.map((cat) {
        final color = ColorUtils.parseHex(cat.color);
        final isParent = cat.id == parent.id;
        return PopupMenuItem<Category>(
          value: cat,
          child: Row(
            children: [
              _buildCategoryIcon(cat, color, 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isParent ? '${cat.name}（全部）' : cat.name,
                  style: TextStyle(
                    fontWeight: isParent ? FontWeight.w600 : FontWeight.normal,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );

    if (result != null && context.mounted) {
      ref.read(pinnedCategoriesProvider.notifier).add(result.id);
    }
  }
}

// ============================================================
// 已固定分类行（编辑页）
// ============================================================

class _PinnedCategoryTile extends StatelessWidget {
  final Category category;
  final Color color;
  final Map<int, Category> categoryMap;
  final VoidCallback onRemove;
  final int index;

  const _PinnedCategoryTile({
    super.key,
    required this.category,
    required this.color,
    required this.categoryMap,
    required this.onRemove,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final parentName = category.parentCategoryId != null
        ? categoryMap[category.parentCategoryId]?.name
        : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            _buildCategoryIcon(category, color, 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    category.name,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  if (parentName != null)
                    Text(parentName, style: TextStyle(fontSize: 12, color: colorScheme.outline)),
                ],
              ),
            ),
            GestureDetector(
              onTap: onRemove,
              child: Icon(Icons.remove_circle_outline, size: 20, color: colorScheme.error),
            ),
            const SizedBox(width: 12),
            ReorderableDragStartListener(
              index: index,
              child: Icon(Icons.drag_indicator, size: 20, color: colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}
