import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import '../../l10n/s.dart';
import '../../utils/dialog_utils.dart';

/// 弹出模型选择 sheet
///
/// 设计参考 Kelivo `model_select_sheet.dart`：搜索框 + 收藏区 +
/// 按 provider 分组 + 当前模型高亮 + 品牌图标 + 能力标签。
Future<({AiProvider provider, AiModel model})?> showAiModelSelectSheet({
  required BuildContext context,
  required List<({AiProvider provider, AiModel model})> allModels,
  required ({AiProvider provider, AiModel model}) current,
  required PromptType mode,
}) {
  return showAppBottomSheet<({AiProvider provider, AiModel model})>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    builder: (ctx) =>
        _AiModelSelectSheet(allModels: allModels, current: current, mode: mode),
  );
}

class _AiModelSelectSheet extends ConsumerStatefulWidget {
  const _AiModelSelectSheet({
    required this.allModels,
    required this.current,
    required this.mode,
  });

  final List<({AiProvider provider, AiModel model})> allModels;
  final ({AiProvider provider, AiModel model}) current;
  final PromptType mode;

  @override
  ConsumerState<_AiModelSelectSheet> createState() =>
      _AiModelSelectSheetState();
}

class _AiModelSelectSheetState extends ConsumerState<_AiModelSelectSheet> {
  final _searchController = TextEditingController();
  final _scrollController = AutoScrollController(axis: Axis.vertical);
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    final maxHeight = mediaQuery.size.height * 0.85;
    final favoriteKeys = ref.watch(favoriteAiModelKeysProvider);
    final favoriteModels = ref.watch(favoriteAiModelsProvider(widget.mode));
    final canReorderFavorites = _query.trim().isEmpty;

    final filtered = _filterModels(widget.allModels);
    final visibleFavorites = _filterModels(favoriteModels);
    final sections = _buildSections(filtered, visibleFavorites);

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: TextField(
                controller: _searchController,
                autofocus: false,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: context.l10n.ai_modelSearchHint,
                  prefixIcon: Icon(
                    Icons.search,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHigh,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Flexible(
              child: sections.isEmpty
                  ? _buildEmpty(theme)
                  : _buildScrollableContent(
                      sections,
                      favoriteKeys,
                      theme,
                      canReorderFavorites,
                    ),
            ),
            if (_shouldShowProviderDock(sections))
              _buildProviderDock(sections, favoriteKeys, theme),
          ],
        ),
      ),
    );
  }

  List<({AiProvider provider, AiModel model})> _filterModels(
    List<({AiProvider provider, AiModel model})> models,
  ) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return models;
    return models
        .where((item) {
          final name = (item.model.name ?? item.model.id).toLowerCase();
          final id = item.model.id.toLowerCase();
          final provider = item.provider.name.toLowerCase();
          return name.contains(query) ||
              id.contains(query) ||
              provider.contains(query);
        })
        .toList(growable: false);
  }

  List<_SectionData> _buildSections(
    List<({AiProvider provider, AiModel model})> filtered,
    List<({AiProvider provider, AiModel model})> visibleFavorites,
  ) {
    final sections = <_SectionData>[];
    if (visibleFavorites.isNotEmpty) {
      sections.add(
        _SectionData(
          id: 'favorites',
          title: context.l10n.ai_modelFavoritesSection,
          items: visibleFavorites,
          isFavorites: true,
        ),
      );
    }

    final groups = <String, List<({AiProvider provider, AiModel model})>>{};
    for (final item in filtered) {
      groups.putIfAbsent(item.provider.id, () => []).add(item);
    }
    for (final entry in groups.entries) {
      sections.add(
        _SectionData(
          id: entry.key,
          title: entry.value.first.provider.name,
          items: entry.value,
          provider: entry.value.first.provider,
        ),
      );
    }
    return sections;
  }

  Widget _buildEmpty(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_off,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.ai_modelSearchNoMatch,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScrollableContent(
    List<_SectionData> sections,
    List<String> favoriteKeys,
    ThemeData theme,
    bool canReorderFavorites,
  ) {
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          sliver: SliverMainAxisGroup(
            slivers: [
              for (var index = 0; index < sections.length; index++) ...[
                _buildSectionHeaderSliver(sections[index], index, theme),
                if (sections[index].isFavorites && canReorderFavorites)
                  _buildReorderableFavoriteSectionSliver(
                    sections[index].items,
                    favoriteKeys,
                  )
                else
                  _buildStaticSectionSliver(sections[index], favoriteKeys),
              ],
            ],
          ),
        ),
      ],
    );
  }

  bool _shouldShowProviderDock(List<_SectionData> sections) {
    return sections.length > 1 ||
        sections.any((section) => section.isFavorites);
  }

  Widget _buildSectionHeaderSliver(
    _SectionData section,
    int index,
    ThemeData theme,
  ) {
    final showFavoriteSortHint = section.isFavorites && _query.trim().isEmpty;
    return SliverToBoxAdapter(
      child: AutoScrollTag(
        key: ValueKey('section_${section.id}'),
        controller: _scrollController,
        index: index,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  section.title,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              if (showFavoriteSortHint)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    context.l10n.ai_modelFavoriteSortHint,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStaticSectionSliver(
    _SectionData section,
    List<String> favoriteKeys,
  ) {
    return SliverList(
      delegate: SliverChildBuilderDelegate((context, index) {
        final item = section.items[index];
        return _buildModelRow(
          item: item,
          favoriteKeys: favoriteKeys,
          favoriteRowKey: section.isFavorites
              ? ValueKey('favorite_row_${item.provider.id}_${item.model.id}')
              : null,
        );
      }, childCount: section.items.length),
    );
  }

  Widget _buildReorderableFavoriteSectionSliver(
    List<({AiProvider provider, AiModel model})> items,
    List<String> favoriteKeys,
  ) {
    return SliverReorderableList(
      itemCount: items.length,
      onReorderItem: (oldIndex, newIndex) {
        _handleFavoriteReorder(items, oldIndex, newIndex);
      },
      itemBuilder: (context, index) {
        final item = items[index];
        return ReorderableDelayedDragStartListener(
          key: ValueKey('favorite_row_${item.provider.id}_${item.model.id}'),
          index: index,
          child: _buildModelRow(item: item, favoriteKeys: favoriteKeys),
        );
      },
    );
  }

  Future<void> _handleFavoriteReorder(
    List<({AiProvider provider, AiModel model})> items,
    int oldIndex,
    int newIndex,
  ) async {
    if (oldIndex == newIndex) return;

    final reorderedKeys = [
      for (final item in items)
        buildAiModelKey(item.provider.id, item.model.id),
    ];
    final movedKey = reorderedKeys.removeAt(oldIndex);
    reorderedKeys.insert(newIndex, movedKey);
    await reorderFavoriteAiModelKeys(ref, reorderedKeys);
  }

  Widget _buildModelRow({
    required ({AiProvider provider, AiModel model}) item,
    required List<String> favoriteKeys,
    Key? favoriteRowKey,
  }) {
    final row = _ModelRow(
      item: item,
      current: widget.current,
      isFavorite: favoriteKeys.contains(
        buildAiModelKey(item.provider.id, item.model.id),
      ),
      onToggleFavorite: () =>
          toggleFavoriteAiModel(ref, item.provider.id, item.model.id),
    );
    if (favoriteRowKey == null) {
      return row;
    }
    return KeyedSubtree(key: favoriteRowKey, child: row);
  }

  Widget _buildProviderDock(
    List<_SectionData> sections,
    List<String> favoriteKeys,
    ThemeData theme,
  ) {
    final currentKey = buildAiModelKey(
      widget.current.provider.id,
      widget.current.model.id,
    );
    final currentIsFavorite = favoriteKeys.contains(currentKey);
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = theme.colorScheme.outlineVariant.withValues(
      alpha: 0.25,
    );
    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: SizedBox(
        height: 36,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: sections.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final section = sections[index];
            final isCurrent = section.isFavorites
                ? currentIsFavorite
                : section.provider?.id == widget.current.provider.id &&
                      !currentIsFavorite;
            final background = isCurrent
                ? theme.colorScheme.primary.withValues(
                    alpha: isDark ? 0.08 : 0.05,
                  )
                : Colors.transparent;
            return Material(
              color: background,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                onTap: () => _scrollController.scrollToIndex(
                  index,
                  preferPosition: AutoScrollPosition.begin,
                  duration: const Duration(milliseconds: 280),
                ),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: borderColor),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (section.isFavorites)
                        Icon(
                          Icons.favorite_rounded,
                          size: 18,
                          color: theme.colorScheme.error,
                        )
                      else
                        ModelIcon(
                          providerName: section.provider!.name,
                          modelName: section.provider!.name,
                          size: 18,
                          withBackground: false,
                        ),
                      const SizedBox(width: 6),
                      Text(
                        section.isFavorites
                            ? context.l10n.ai_modelFavoritesDock
                            : section.title,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: theme.colorScheme.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SectionData {
  const _SectionData({
    required this.id,
    required this.title,
    required this.items,
    this.isFavorites = false,
    this.provider,
  });

  final String id;
  final String title;
  final List<({AiProvider provider, AiModel model})> items;
  final bool isFavorites;
  final AiProvider? provider;
}

bool _hasAnyBadge(AiModel model, bool isImageOut) {
  return isImageOut ||
      model.input.contains(Modality.image) ||
      model.abilities.contains(ModelAbility.reasoning) ||
      model.abilities.contains(ModelAbility.tool);
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.item,
    required this.current,
    required this.isFavorite,
    required this.onToggleFavorite,
  });

  final ({AiProvider provider, AiModel model}) item;
  final ({AiProvider provider, AiModel model}) current;
  final bool isFavorite;
  final VoidCallback onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCurrent =
        item.provider.id == current.provider.id &&
        item.model.id == current.model.id;
    final modelName = item.model.name ?? item.model.id;
    final isImageOut = item.model.output.contains(Modality.image);

    return Material(
      color: isCurrent
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: () => Navigator.of(context).pop(item),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      ModelIcon(
                        providerName: item.provider.name,
                        modelName: modelName,
                        size: 36,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              modelName,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: isCurrent
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (item.model.id != modelName)
                              Text(
                                item.model.id,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontSize: 11,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            if (_hasAnyBadge(item.model, isImageOut)) ...[
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 4,
                                runSpacing: 2,
                                children: [
                                  if (isImageOut)
                                    _CapabilityBadge(
                                      icon: Icons.image_outlined,
                                      label: 'image',
                                      color: const Color(0xFFEA580C),
                                    ),
                                  if (item.model.input.contains(Modality.image))
                                    _CapabilityBadge(
                                      icon: Icons.visibility_outlined,
                                      label: 'vision',
                                      color: theme.colorScheme.tertiary,
                                    ),
                                  if (item.model.abilities.contains(
                                    ModelAbility.reasoning,
                                  ))
                                    _CapabilityBadge(
                                      icon: Icons.psychology_alt_outlined,
                                      label: 'reasoning',
                                      color: theme.colorScheme.secondary,
                                    ),
                                  if (item.model.abilities.contains(
                                    ModelAbility.tool,
                                  ))
                                    _CapabilityBadge(
                                      icon: Icons.build_outlined,
                                      label: 'tool',
                                      color: theme.colorScheme.primary,
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              key: ValueKey('favorite_${item.provider.id}_${item.model.id}'),
              tooltip: isFavorite
                  ? context.l10n.ai_modelFavoriteRemove
                  : context.l10n.ai_modelFavoriteAdd,
              onPressed: onToggleFavorite,
              icon: Icon(
                isFavorite ? Icons.favorite : Icons.favorite_border,
                size: 20,
                color: isFavorite
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (isCurrent) ...[
              Icon(
                Icons.check_circle,
                size: 20,
                color: theme.colorScheme.primary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CapabilityBadge extends StatelessWidget {
  const _CapabilityBadge({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

