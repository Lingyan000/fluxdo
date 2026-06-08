import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/sticker.dart';
import '../../providers/sticker_provider.dart';
import '../../services/discourse_cache_manager.dart';
import '../common/cached_image.dart';
import '../common/loading_spinner.dart';
import '../../../../../l10n/s.dart';

/// 表情包市场浏览面板 (Bottom Sheet)
///
/// 展示市场中所有可用的表情包分组，用户可以添加/移除。
/// 支持分页加载：首次只加载第一页，滚动到底部时自动加载下一页。
class StickerMarketSheet extends ConsumerStatefulWidget {
  const StickerMarketSheet({super.key});

  @override
  ConsumerState<StickerMarketSheet> createState() => _StickerMarketSheetState();
}

class _StickerMarketSheetState extends ConsumerState<StickerMarketSheet> {
  final ScrollController _scrollController = ScrollController();
  bool _scrollThrottled = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _scrollThrottled) return;
    _scrollThrottled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollThrottled = false;
      if (!mounted || !_scrollController.hasClients) return;
      final pos = _scrollController.position;
      if (pos.pixels >= pos.maxScrollExtent - 600) {
        ref.read(marketGroupsProvider.notifier).loadMore();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    final groupsAsync = ref.watch(marketGroupsProvider);
    final subscribedIds = ref.watch(subscribedStickerIdsProvider);

    return Container(
      height: mediaQuery.size.height * 0.8,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // 顶部标题栏
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.5,
                  ),
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
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        S.current.sticker_marketTitle,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: Text(S.current.common_done),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // 内容区域：优先使用已有数据，避免加载态闪烁
          Expanded(
            child: (() {
              final groups = groupsAsync.value;
              if (groups != null) {
                return _buildGroupList(groups, subscribedIds);
              }
              return groupsAsync.when(
                data: (groups) => _buildGroupList(groups, subscribedIds),
                loading: () => const Center(child: LoadingSpinner()),
                error: (err, stack) => _buildError(),
              );
            })(),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 48, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text(S.current.sticker_marketLoadFailed, style: TextStyle(color: theme.colorScheme.error)),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => ref.read(marketGroupsProvider.notifier).refresh(),
            child: Text(S.current.common_retry),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupList(
    List<StickerGroup> groups,
    List<String> subscribedIds,
  ) {
    if (groups.isEmpty) {
      return Center(
        child: Text(
          S.current.sticker_marketEmpty,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final subscribedSet = subscribedIds.toSet();
    final hasMore = ref.read(marketGroupsProvider.notifier).hasMore;
    final itemCount = groups.length + (hasMore ? 1 : 0);

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      scrollCacheExtent: ScrollCacheExtent.pixels(200),
      itemExtent: 72,
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index >= groups.length) {
          // 底部加载指示器
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator.adaptive(strokeWidth: 2),
              ),
            ),
          );
        }
        final group = groups[index];
        final isSubscribed = subscribedSet.contains(group.id);
        return _StickerGroupTile(
          key: ValueKey(group.id),
          group: group,
          isSubscribed: isSubscribed,
          onToggle: () async {
            final notifier = ref.read(subscribedStickerIdsProvider.notifier);
            if (isSubscribed) {
              await notifier.unsubscribe(group.id);
            } else {
              await notifier.subscribe(group.id);
            }
          },
        );
      },
    );
  }
}

/// 市场中的分组列表项
///
/// 保持纯渲染组件，避免滚动过程中为每个 item 额外触发 setState。
class _StickerGroupTile extends StatelessWidget {
  final StickerGroup group;
  final bool isSubscribed;
  final VoidCallback onToggle;

  const _StickerGroupTile({
    super.key,
    required this.group,
    required this.isSubscribed,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return RepaintBoundary(
      child: ListTile(
        dense: true,
        leading: _buildIcon(theme),
        title: Text(group.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          S.current.sticker_emojiCount(group.emojiCount),
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: isSubscribed
            ? FilledButton.tonalIcon(
                onPressed: onToggle,
                icon: const Icon(Icons.check, size: 16),
                label: Text(S.current.sticker_added),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              )
            : OutlinedButton.icon(
                onPressed: onToggle,
                icon: const Icon(Icons.add, size: 16),
                label: Text(S.current.common_add),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              ),
      ),
    );
  }

  Widget _buildIcon(ThemeData theme) {
    final icon = group.icon;
    if (icon.startsWith('http://') || icon.startsWith('https://')) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: RepaintBoundary(
          child: CachedImage(
            url: icon,
            width: 40,
            height: 40,
            memCacheWidth: 80,
            memCacheHeight: 80,
            thumbnailMode: true,
            fit: BoxFit.cover,
            cacheManager: StickerCacheManager(),
            placeholder: (_) => _buildFallbackIcon(theme),
            errorBuilder: (_, _, _) => _buildFallbackIcon(theme),
          ),
        ),
      );
    }

    if (icon.isNotEmpty) {
      return SizedBox(
        width: 40,
        height: 40,
        child: Center(child: Text(icon, style: const TextStyle(fontSize: 24))),
      );
    }

    return _buildFallbackIcon(theme);
  }

  Widget _buildFallbackIcon(ThemeData theme) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Text(
          group.name.isNotEmpty ? group.name[0] : '?',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
