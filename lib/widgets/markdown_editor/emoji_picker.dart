import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/emoji.dart';
import '../../providers/discourse_providers.dart';
import '../../services/emoji_handler.dart';
import '../../services/discourse_cache_manager.dart';
import '../../utils/dialog_utils.dart';
import '../common/cached_image.dart';
import '../common/loading_spinner.dart';
import '../../../../../l10n/s.dart';

/// 常用表情的 Key
const String _recentEmojisKey = 'recent_emojis';

/// 最多保存的常用表情数量
const int _maxRecentEmojis = 30;

class EmojiPicker extends ConsumerStatefulWidget {
  final Function(Emoji) onEmojiSelected;

  /// 底部额外 padding（用于给悬浮 Tab 留空间）
  final double bottomPadding;

  const EmojiPicker({
    super.key,
    required this.onEmojiSelected,
    this.bottomPadding = 0,
  });

  @override
  ConsumerState<EmojiPicker> createState() => _EmojiPickerState();
}

class _EmojiPickerState extends ConsumerState<EmojiPicker>
    with AutomaticKeepAliveClientMixin {
  List<String> _recentEmojiNames = [];

  /// 面板打开时快照，避免实时刷新影响体验
  List<String>? _recentEmojiSnapshot;

  final ScrollController _scrollController = ScrollController();
  final ScrollController _tabScrollController = ScrollController();
  final GlobalKey _contentAreaKey = GlobalKey();
  List<GlobalKey> _groupKeys = [];
  int _activeGroupIndex = 0;
  bool _isProgrammaticScroll = false;
  bool _scrollThrottled = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadRecentEmojis();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _tabScrollController.dispose();
    super.dispose();
  }

  // ==================== 常用表情 ====================

  Future<void> _loadRecentEmojis() async {
    final prefs = await SharedPreferences.getInstance();
    final names = prefs.getStringList(_recentEmojisKey) ?? [];
    if (mounted) {
      setState(() {
        _recentEmojiNames = names;
        _recentEmojiSnapshot = names.toList();
      });
    }
  }

  Future<void> _saveRecentEmoji(String emojiName) async {
    _recentEmojiNames.remove(emojiName);
    _recentEmojiNames.insert(0, emojiName);
    if (_recentEmojiNames.length > _maxRecentEmojis) {
      _recentEmojiNames = _recentEmojiNames.sublist(0, _maxRecentEmojis);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentEmojisKey, _recentEmojiNames);
    // 不调用 setState，下次打开面板时才更新显示
  }

  void _onEmojiTap(Emoji emoji) {
    _saveRecentEmoji(emoji.name);
    widget.onEmojiSelected(emoji);
  }

  // ==================== 滚动锚点 ====================

  void _onScroll() {
    if (_isProgrammaticScroll || _scrollThrottled) return;
    _scrollThrottled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scrollThrottled = false;
      if (mounted) _updateActiveGroup();
    });
  }

  void _updateActiveGroup() {
    if (_groupKeys.isEmpty) return;
    final contentBox =
        _contentAreaKey.currentContext?.findRenderObject() as RenderBox?;
    if (contentBox == null || !contentBox.attached) return;
    final contentTop = contentBox.localToGlobal(Offset.zero).dy;

    int activeIndex = 0;
    for (int i = 0; i < _groupKeys.length; i++) {
      final ctx = _groupKeys[i].currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject();
      if (box == null || box is! RenderBox || !box.attached) continue;
      if (box.localToGlobal(Offset.zero).dy <= contentTop + 20) {
        activeIndex = i;
      }
    }
    if (_activeGroupIndex != activeIndex) {
      setState(() => _activeGroupIndex = activeIndex);
      _ensureTabVisible(activeIndex);
    }
  }

  Future<void> _scrollToGroup(int index) async {
    if (index < 0 || index >= _groupKeys.length) return;
    final ctx = _groupKeys[index].currentContext;
    if (ctx == null) return;
    _isProgrammaticScroll = true;
    setState(() => _activeGroupIndex = index);
    _ensureTabVisible(index);
    await Scrollable.ensureVisible(
      ctx,
      alignment: 0.0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
    _isProgrammaticScroll = false;
  }

  void _ensureTabVisible(int index) {
    if (!_tabScrollController.hasClients) return;
    const tabWidth = 40.0;
    final target = index * tabWidth -
        _tabScrollController.position.viewportDimension / 2 +
        tabWidth / 2;
    _tabScrollController.animateTo(
      target.clamp(0.0, _tabScrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  // ==================== 搜索 ====================

  Future<void> _showSearchDialog(
      BuildContext context, Map<String, List<Emoji>>? emojiGroups) async {
    if (emojiGroups == null || emojiGroups.isEmpty) return;
    final allEmojis = emojiGroups.values.expand((e) => e).toList();
    final onSelected = widget.onEmojiSelected;

    final selectedEmoji = await showAppBottomSheet<Emoji>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _EmojiSearchSheet(allEmojis: allEmojis),
    );

    if (selectedEmoji != null) {
      _saveRecentEmoji(selectedEmoji.name);
      onSelected(selectedEmoji);
    }
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final emojisAsync = ref.watch(emojiGroupsProvider);

    return ClipRect(
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: (() {
          final emojis = emojisAsync.value;
          if (emojis != null) return _buildContent(emojis);
          return emojisAsync.when(
            data: _buildContent,
            loading: () => const Center(child: LoadingSpinner()),
            error: (err, stack) => Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline,
                      size: 48,
                      color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 12),
                  Text(S.current.emoji_loadFailed,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => ref.invalidate(emojiGroupsProvider),
                    child: Text(S.current.common_retry),
                  ),
                ],
              ),
            ),
          );
        })(),
      ),
    );
  }

  Widget _buildContent(Map<String, List<Emoji>> emojiGroups) {
    if (emojiGroups.isEmpty) return Center(child: Text(S.current.emoji_notFound));

    // 构建最近使用的表情（使用快照）
    final recentEmojis = <Emoji>[];
    final recentNames = _recentEmojiSnapshot ?? _recentEmojiNames;
    if (recentNames.isNotEmpty) {
      final allEmojisMap = <String, Emoji>{};
      for (final group in emojiGroups.values) {
        for (final emoji in group) {
          allEmojisMap[emoji.name] = emoji;
        }
      }
      for (final name in recentNames) {
        final emoji = allEmojisMap[name];
        if (emoji != null) recentEmojis.add(emoji);
      }
    }

    final hasRecent = recentEmojis.isNotEmpty;
    final groupKeys = emojiGroups.keys.toList();
    final totalGroups = (hasRecent ? 1 : 0) + groupKeys.length;

    // 确保 keys 数量正确
    while (_groupKeys.length < totalGroups) {
      _groupKeys.add(GlobalKey());
    }
    if (_groupKeys.length > totalGroups) {
      _groupKeys = _groupKeys.sublist(0, totalGroups);
    }

    return Column(
      children: [
        _buildTabBar(emojiGroups, groupKeys, hasRecent),
        Expanded(
          key: _contentAreaKey,
          child: CustomScrollView(
            controller: _scrollController,
            scrollCacheExtent: ScrollCacheExtent.pixels(500),
            slivers: _buildSlivers(
                emojiGroups, groupKeys, hasRecent, recentEmojis),
          ),
        ),
      ],
    );
  }

  Widget _buildTabBar(Map<String, List<Emoji>> emojiGroups,
      List<String> groupKeys, bool hasRecent) {
    final theme = Theme.of(context);
    final totalTabs = (hasRecent ? 1 : 0) + groupKeys.length;
    const tabSlotWidth = 40.0;
    const tabWidth = 36.0;
    const tabMargin = 2.0;
    final activeIndex = _activeGroupIndex.clamp(0, totalTabs - 1);

    return Row(
      children: [
        IconButton(
          icon:
              Icon(Icons.search, size: 20, color: theme.colorScheme.primary),
          onPressed: () => _showSearchDialog(context, emojiGroups),
          tooltip: S.current.emoji_searchTooltip,
        ),
        Container(
            height: 20, width: 1, color: theme.colorScheme.outlineVariant),
        Expanded(
          child: SizedBox(
            height: 40,
            child: SingleChildScrollView(
              controller: _tabScrollController,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: SizedBox(
                width: totalTabs * tabSlotWidth,
                height: 40,
                child: Stack(
                  children: [
                    // 滑动指示器
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      left: activeIndex * tabSlotWidth + tabMargin,
                      top: 4,
                      bottom: 4,
                      width: tabWidth,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    // Tab 图标
                    Row(
                      children: List.generate(totalTabs, (index) {
                        Widget icon;
                        if (hasRecent && index == 0) {
                          icon = Icon(
                            Icons.access_time,
                            size: 20,
                            color: activeIndex == index
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                          );
                        } else {
                          final groupIndex = hasRecent ? index - 1 : index;
                          final firstEmoji =
                              emojiGroups[groupKeys[groupIndex]]!.first;
                          icon = CachedImage(
                            url: EmojiHandler().getEmojiUrl(firstEmoji.name),
                            width: 24,
                            height: 24,
                            memCacheWidth: 48,
                            memCacheHeight: 48,
                            fit: BoxFit.contain,
                            cacheManager: EmojiCacheManager(),
                          );
                        }
                        return GestureDetector(
                          onTap: () => _scrollToGroup(index),
                          child: SizedBox(
                            width: tabSlotWidth,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: tabMargin,
                                vertical: 4,
                              ),
                              child: Center(child: icon),
                            ),
                          ),
                        );
                      }),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildSlivers(
    Map<String, List<Emoji>> emojiGroups,
    List<String> groupKeys,
    bool hasRecent,
    List<Emoji> recentEmojis,
  ) {
    final slivers = <Widget>[];
    int keyIndex = 0;

    if (hasRecent) {
      slivers.add(SliverToBoxAdapter(
        child: _buildSectionHeader(S.current.common_recentlyUsed, _groupKeys[keyIndex]),
      ));
      slivers.add(_buildEmojiSliverGrid(recentEmojis));
      keyIndex++;
    }

    for (final groupKey in groupKeys) {
      slivers.add(SliverToBoxAdapter(
        child: _buildSectionHeader(
            _formatGroupName(groupKey), _groupKeys[keyIndex]),
      ));
      slivers.add(_buildEmojiSliverGrid(emojiGroups[groupKey]!));
      keyIndex++;
    }

    // 底部留白
    if (widget.bottomPadding > 0) {
      slivers.add(SliverToBoxAdapter(
        child: SizedBox(height: widget.bottomPadding),
      ));
    }

    return slivers;
  }

  Widget _buildSectionHeader(String title, GlobalKey key) {
    return Padding(
      key: key,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildEmojiSliverGrid(List<Emoji> emojis) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate(
          (_, index) => _buildEmojiItem(emojis[index]),
          childCount: emojis.length,
        ),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 40,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
      ),
    );
  }

  Widget _buildEmojiItem(Emoji emoji) {
    return InkWell(
      onTap: () => _onEmojiTap(emoji),
      borderRadius: BorderRadius.circular(4),
      child: Tooltip(
        message: ':${emoji.name}:',
        child: Padding(
          padding: const EdgeInsets.all(4.0),
          child: CachedImage(
            url: EmojiHandler().getEmojiUrl(emoji.name),
            fit: BoxFit.contain,
            memCacheWidth: 64,
            memCacheHeight: 64,
            cacheManager: EmojiCacheManager(),
          ),
        ),
      ),
    );
  }

  String _formatGroupName(String name) {
    if (name == 'smileys_&_emotion') return S.current.emoji_smileys;
    if (name == 'people_&_body') return S.current.emoji_people;
    if (name == 'animals_&_nature') return S.current.emoji_animals;
    if (name == 'food_&_drink') return S.current.emoji_food;
    if (name == 'activities') return S.current.emoji_activities;
    if (name == 'travel_&_places') return S.current.emoji_travel;
    if (name == 'objects') return S.current.emoji_objects;
    if (name == 'symbols') return S.current.emoji_symbols;
    if (name == 'flags') return S.current.emoji_flags;
    return name.replaceAll('_&_', ' & ').replaceAll('_', ' ').capitalize();
  }
}

extension StringExtension on String {
  String capitalize() {
    if (isEmpty) return this;
    return "${this[0].toUpperCase()}${substring(1)}";
  }
}

/// 表情搜索面板 (Bottom Sheet)
class _EmojiSearchSheet extends StatefulWidget {
  final List<Emoji> allEmojis;

  const _EmojiSearchSheet({required this.allEmojis});

  @override
  State<_EmojiSearchSheet> createState() => _EmojiSearchSheetState();
}

class _EmojiSearchSheetState extends State<_EmojiSearchSheet> {
  final _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.toLowerCase().trim());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);

    final results = _query.isEmpty
        ? <Emoji>[]
        : widget.allEmojis.where((emoji) {
            return emoji.name.toLowerCase().contains(_query) ||
                emoji.searchAliases
                    .any((alias) => alias.toLowerCase().contains(_query));
          }).toList();

    return Container(
      height: mediaQuery.size.height * 0.8,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: theme.colorScheme.outlineVariant
                      .withValues(alpha: 0.5),
                  width: 0.5,
                ),
              ),
            ),
            child: Column(
              children: [
                Container(
                  width: 32,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 44,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          textAlignVertical: TextAlignVertical.center,
                          style: const TextStyle(fontSize: 16),
                          decoration: InputDecoration(
                            hintText: S.current.emoji_searchHint,
                            hintStyle: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding:
                                const EdgeInsets.only(left: 0, right: 12),
                            prefixIcon: Icon(Icons.search,
                                size: 20,
                                color: theme.colorScheme.onSurface),
                            suffixIcon: _query.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.cancel, size: 18),
                                    color:
                                        theme.colorScheme.onSurfaceVariant,
                                    onPressed: () =>
                                        _searchController.clear(),
                                  )
                                : null,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () {
                        FocusScope.of(context).unfocus();
                        Navigator.pop(context);
                      },
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding:
                            const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: Text(S.current.common_cancel),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: _query.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.emoji_emotions_outlined,
                            size: 48,
                            color: theme.colorScheme.outline
                                .withValues(alpha: 0.5)),
                        const SizedBox(height: 16),
                        Text(S.current.emoji_searchPrompt,
                            style: TextStyle(
                                color:
                                    theme.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  )
                : results.isEmpty
                    ? Center(
                        child: Text(S.current.emoji_searchNotFound,
                            style: TextStyle(
                                color:
                                    theme.colorScheme.onSurfaceVariant)),
                      )
                    : GridView.builder(
                        padding: EdgeInsets.fromLTRB(
                            16, 16, 16, mediaQuery.viewInsets.bottom + 16),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 48,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                        ),
                        itemCount: results.length,
                        itemBuilder: (context, index) {
                          final emoji = results[index];
                          return InkWell(
                            onTap: () {
                              FocusScope.of(context).unfocus();
                              Navigator.pop(context, emoji);
                            },
                            borderRadius: BorderRadius.circular(8),
                            child: Tooltip(
                              message: ':${emoji.name}:',
                              child: Padding(
                                padding: const EdgeInsets.all(4.0),
                                child: CachedImage(
                                  url: EmojiHandler()
                                      .getEmojiUrl(emoji.name),
                                  fit: BoxFit.contain,
                                  memCacheWidth: 80,
                                  memCacheHeight: 80,
                                  cacheManager: EmojiCacheManager(),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
