import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/utils/color_utils.dart';
import 'package:fluxdo/utils/url_helper.dart';
import 'package:fluxdo/utils/font_awesome_helper.dart';
import 'package:fluxdo/services/discourse_cache_manager.dart';

class CategorySelectionSheet extends StatefulWidget {
  final List<Category> categories;
  final Category? selectedCategory;

  const CategorySelectionSheet({
    super.key,
    required this.categories,
    this.selectedCategory,
  });

  @override
  State<CategorySelectionSheet> createState() => _CategorySelectionSheetState();
}

class _CategorySelectionSheetState extends State<CategorySelectionSheet> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';
  late List<Category> _availableCategories;

  @override
  void initState() {
    super.initState();
    _availableCategories = widget.categories.where((c) => c.canCreateTopic).toList();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  List<_CategoryItem> _buildList() {
    final query = _searchQuery.toLowerCase();
    
    if (query.isNotEmpty) {
      final matches = _availableCategories.where((c) {
        return c.name.toLowerCase().contains(query) || 
               (c.description != null && c.description!.toLowerCase().contains(query));
      }).toList();
      
      return matches.map((c) => _CategoryItem(category: c, depth: 0)).toList();
    }

    final Map<int?, List<Category>> childrenMap = {};
    for (final cat in _availableCategories) {
      childrenMap.putIfAbsent(cat.parentCategoryId, () => []).add(cat);
    }

    List<_CategoryItem> buildItems(int? parentId, int depth) {
      final children = childrenMap[parentId] ?? [];
      final items = <_CategoryItem>[];
      for (final cat in children) {
        items.add(_CategoryItem(category: cat, depth: depth));
        items.addAll(buildItems(cat.id, depth + 1));
      }
      return items;
    }

    return buildItems(null, 0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _buildList();

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // 顶部拖拽条和搜索栏区域
              Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                      width: 0.5,
                    ),
                  ),
                ),
                child: Column(
                  children: [
                    // 拖拽条
                    Container(
                      width: 32,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    // 搜索栏
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            height: 44,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: TextField(
                              controller: _searchController,
                              focusNode: _searchFocusNode,
                              textAlignVertical: TextAlignVertical.center,
                              style: const TextStyle(fontSize: 16),
                              decoration: InputDecoration(
                                hintText: '搜索分类...',
                                hintStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: const EdgeInsets.only(left: 0, right: 12),
                                prefixIcon: Icon(Icons.search, size: 20, color: theme.colorScheme.onSurface),
                                suffixIcon: _searchQuery.isNotEmpty 
                                  ? IconButton(
                                      icon: const Icon(Icons.cancel, size: 18),
                                      color: theme.colorScheme.onSurfaceVariant,
                                      onPressed: () {
                                        _searchController.clear();
                                        setState(() => _searchQuery = '');
                                      },
                                    )
                                  : null,
                              ),
                              onChanged: (value) => setState(() => _searchQuery = value),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          child: const Text('取消'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // List
              Expanded(
                child: items.isEmpty
                  ? Center(
                      child: Text(
                        _searchQuery.isEmpty ? '暂无分类' : '未找到相关分类',
                        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      controller: scrollController,
                      itemCount: items.length,
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                      ),
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final cat = item.category;
                        final isSelected = widget.selectedCategory?.id == cat.id;

                        // 查找父级以获取图标（如果当前没有）
                        final parent = cat.parentCategoryId != null 
                            ? widget.categories.firstWhere((c) => c.id == cat.parentCategoryId, orElse: () => cat)
                            : null;
                        
                        return InkWell(
                          onTap: () => Navigator.pop(context, cat),
                          child: Container(
                            padding: EdgeInsets.only(
                              left: 16 + item.depth * 24.0,
                              right: 16,
                              top: 12,
                              bottom: 12,
                            ),
                            color: isSelected ? theme.colorScheme.primaryContainer.withValues(alpha: 0.2) : null,
                            child: Row(
                              children: [
                                _buildCategoryIcon(cat, parent),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          if (cat.readRestricted)
                                            Padding(
                                              padding: const EdgeInsets.only(right: 6),
                                              child: Icon(Icons.lock, size: 14, color: theme.colorScheme.onSurfaceVariant),
                                            ),
                                                                              Text(
                                                                                cat.name,
                                                                                style: theme.textTheme.titleSmall?.copyWith(
                                                                                  fontWeight: FontWeight.bold,
                                                                                  color: ColorUtils.parseHex(cat.color),
                                                                                ),
                                                                              ),
                                                                            ],
                                                                          ),                                      if (cat.description != null && cat.description!.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 4),
                                          child: Text(
                                            cat.description!,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.bodySmall?.copyWith(
                                              color: theme.colorScheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                if (isSelected)
                                  Icon(Icons.check, color: theme.colorScheme.primary),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCategoryIcon(Category category, Category? parent) {
    IconData? faIcon = FontAwesomeHelper.getIcon(category.icon);
    String? logoUrl = category.uploadedLogo;

    if (faIcon == null && (logoUrl == null || logoUrl.isEmpty) && parent != null) {
      faIcon = FontAwesomeHelper.getIcon(parent.icon);
      logoUrl = parent.uploadedLogo;
    }

    if (faIcon != null) {
      return FaIcon(faIcon, size: 20, color: ColorUtils.parseHex(category.color));
    }

    if (logoUrl != null && logoUrl.isNotEmpty) {
      final fullUrl = UrlHelper.resolveUrl(logoUrl);
      return SizedBox(
        width: 24,
        height: 24,
        child: Image(
          image: discourseImageProvider(fullUrl),
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => _buildDot(category.color),
        ),
      );
    }

    return _buildDot(category.color);
  }

  Widget _buildDot(String colorHex) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: ColorUtils.parseHex(colorHex),
        shape: BoxShape.circle,
      ),
    );
  }
}

class _CategoryItem {
  final Category category;
  final int depth;

  _CategoryItem({required this.category, required this.depth});
}
