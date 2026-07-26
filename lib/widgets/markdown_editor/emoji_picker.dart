import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/emoji.dart';
import '../../providers/discourse_providers.dart';
import '../../services/emoji_handler.dart';
import '../../services/discourse_cache_manager.dart';
import '../../utils/dialog_utils.dart';
import '../common/app_bottom_sheet.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../../../../../l10n/s.dart';

/// 常用表情的 Key
const String _recentEmojisKey = 'recent_emojis';

/// 最多保存的常用表情数量
const int _maxRecentEmojis = 30;

class EmojiPicker extends ConsumerStatefulWidget {
  final Function(Emoji) onEmojiSelected;

  /// 底部额外 padding（用于给悬浮 Tab 留空间）
  final double bottomPadding;

  /// 搜索用内联视图(桌面悬浮弹层场景:bottomSheet 会被压在
  /// OverlayEntry 弹层下面,且交互割裂),false 走 bottomSheet
  final bool inlineSearch;

  /// 紧凑模式(桌面悬浮弹层):顶部圆角交给弹层壳,分类栏收紧
  final bool compact;

  const EmojiPicker({
    super.key,
    required this.onEmojiSelected,
    this.bottomPadding = 0,
    this.inlineSearch = false,
    this.compact = false,
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

  /// 当前激活的 group index。用 ValueNotifier 不用 setState ——
  /// 滚动时这个值频繁变,如果走 setState 会 rebuild 整个 emoji panel,
  /// 几十张 emoji widget 全 build 一遍,卡。改 notifier 后只 TabBar 监听。
  final ValueNotifier<int> _activeGroupIndex = ValueNotifier<int>(0);

  bool _isProgrammaticScroll = false;
  bool _scrollThrottled = false;

  /// 内联搜索态(仅 widget.inlineSearch 时进入):内容区切换为搜索视图
  bool _searching = false;

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
    _activeGroupIndex.dispose();
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
    if (_activeGroupIndex.value != activeIndex) {
      _activeGroupIndex.value = activeIndex;
      _ensureTabVisible(activeIndex);
    }
  }

  Future<void> _scrollToGroup(int index) async {
    if (index < 0 || index >= _groupKeys.length) return;
    final ctx = _groupKeys[index].currentContext;
    if (ctx == null) return;
    _isProgrammaticScroll = true;
    _activeGroupIndex.value = index;
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
    final tabWidth = widget.compact ? 34.0 : 40.0;
    final target =
        index * tabWidth -
        _tabScrollController.position.viewportDimension / 2 +
        tabWidth / 2;
    _tabScrollController.animateTo(
      target.clamp(0.0, _tabScrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  // ==================== 搜索 ====================

  void _onSearchPressed(
    BuildContext context,
    Map<String, List<Emoji>>? emojiGroups,
  ) {
    if (emojiGroups == null || emojiGroups.isEmpty) return;
    if (widget.inlineSearch) {
      setState(() => _searching = true);
    } else {
      _showSearchDialog(context, emojiGroups);
    }
  }

  Future<void> _showSearchDialog(
    BuildContext context,
    Map<String, List<Emoji>>? emojiGroups,
  ) async {
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
          // 紧凑模式在弹层壳里,壳已裁圆角,自身不再画顶部圆角
          borderRadius: widget.compact
              ? null
              : const BorderRadius.vertical(top: Radius.circular(16)),
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
                  Icon(
                    Symbols.error_rounded,
                    size: 48,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    S.current.emoji_loadFailed,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
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
    if (emojiGroups.isEmpty)
      return Center(child: Text(S.current.emoji_notFound));

    // 内联搜索态:整个内容区切换为搜索视图(桌面悬浮弹层场景)
    if (_searching) {
      return _EmojiSearchView(
        allEmojis: emojiGroups.values.expand((e) => e).toList(),
        onSelected: _onEmojiTap,
        onClose: () => setState(() => _searching = false),
        bottomPadding: widget.bottomPadding,
      );
    }

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
            // 预 build 屏外内容,滚动到时 widget 已 ready、图已在加载。
            // 注意别贪大:cell 行高 ~48px、~10 列,这个值每 +500px 就是
            // 面板挂载那一帧多 build ~100 个 cell(InkWell+Tooltip+Image),
            // 直接加重"打开面板顿一下"。emoji 是小 PNG + 磁盘索引 O(1),
            // 加载本身很快,800px(~2 屏)足够掩护滚动。
            scrollCacheExtent: ScrollCacheExtent.pixels(800),
            slivers: _buildSlivers(
              emojiGroups,
              groupKeys,
              hasRecent,
              recentEmojis,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTabBar(
    Map<String, List<Emoji>> emojiGroups,
    List<String> groupKeys,
    bool hasRecent,
  ) {
    final theme = Theme.of(context);
    final compact = widget.compact;
    final totalTabs = (hasRecent ? 1 : 0) + groupKeys.length;
    final tabSlotWidth = compact ? 34.0 : 40.0;
    final tabWidth = compact ? 30.0 : 36.0;
    const tabMargin = 2.0;
    final barHeight = compact ? 36.0 : 40.0;

    // 整个 TabBar 用 RepaintBoundary 隔离,内部 ValueListenableBuilder 监听
    // activeIndex 局部更新,滚动时只 TabBar 重绘,不影响下方 emoji grid。
    return RepaintBoundary(
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              Symbols.search_rounded,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            visualDensity: compact ? VisualDensity.compact : null,
            onPressed: () => _onSearchPressed(context, emojiGroups),
            tooltip: S.current.emoji_searchTooltip,
          ),
          Container(
            height: 20,
            width: 1,
            color: theme.colorScheme.outlineVariant,
          ),
          Expanded(
            child: SizedBox(
              height: barHeight,
              child: SingleChildScrollView(
                controller: _tabScrollController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: SizedBox(
                  width: totalTabs * tabSlotWidth,
                  height: barHeight,
                  child: Stack(
                    children: [
                      // 滑动指示器
                      ValueListenableBuilder<int>(
                        valueListenable: _activeGroupIndex,
                        builder: (_, raw, _) {
                          final activeIndex = raw.clamp(0, totalTabs - 1);
                          return AnimatedPositioned(
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
                          );
                        },
                      ),
                      // Tab 图标
                      Row(
                        children: List.generate(totalTabs, (index) {
                          Widget icon;
                          if (hasRecent && index == 0) {
                            icon = ValueListenableBuilder<int>(
                              valueListenable: _activeGroupIndex,
                              builder: (_, raw, _) {
                                final activeIndex = raw.clamp(0, totalTabs - 1);
                                return Icon(
                                  Symbols.access_time_rounded,
                                  size: 20,
                                  color: activeIndex == index
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.onSurfaceVariant,
                                );
                              },
                            );
                          } else {
                            final groupIndex = hasRecent ? index - 1 : index;
                            final firstEmoji =
                                emojiGroups[groupKeys[groupIndex]]!.first;
                            icon = _EmojiCell(
                              name: firstEmoji.name,
                              width: 24,
                              height: 24,
                              decodeSize: 48,
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
      ),
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
      slivers.add(
        SliverToBoxAdapter(
          child: _buildSectionHeader(
            S.current.common_recentlyUsed,
            _groupKeys[keyIndex],
          ),
        ),
      );
      slivers.add(_buildEmojiSliverGrid(recentEmojis));
      keyIndex++;
    }

    for (final groupKey in groupKeys) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildSectionHeader(
            _formatGroupName(groupKey),
            _groupKeys[keyIndex],
          ),
        ),
      );
      slivers.add(_buildEmojiSliverGrid(emojiGroups[groupKey]!));
      keyIndex++;
    }

    // 底部留白
    if (widget.bottomPadding > 0) {
      slivers.add(
        SliverToBoxAdapter(child: SizedBox(height: widget.bottomPadding)),
      );
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
    // RepaintBoundary 隔离单 cell 重绘 — 一个 emoji 解码完 setImage 时
    // 只这一格重绘,不连累整个 grid。
    return RepaintBoundary(
      child: InkWell(
        onTap: () => _onEmojiTap(emoji),
        borderRadius: BorderRadius.circular(4),
        child: Tooltip(
          message: ':${emoji.name}:',
          child: Padding(
            padding: const EdgeInsets.all(4.0),
            child: _EmojiCell(name: emoji.name, decodeSize: 64),
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

/// 单个 emoji 图片 cell:BlobImageProvider(零 sqlite 寻址)+ 解码
/// 尺寸约束 + 淡底占位。
///
/// 占位是 Telegram 双端同款的 ~6% alpha 圆角底 —— 几乎不可见,但消除
/// 冷缓存下"空白格子逐个蹦图"的观感;图就绪直接替换,无过渡动画,
/// 稳态零视觉差异。
class _EmojiCell extends StatelessWidget {
  const _EmojiCell({
    required this.name,
    required this.decodeSize,
    this.width,
    this.height,
  });

  final String name;
  final int decodeSize;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    return Image(
      image: ResizeImage(
        emojiImageProvider(EmojiHandler().getEmojiUrl(name)),
        width: decodeSize,
        height: decodeSize,
        policy: ResizeImagePolicy.fit,
      ),
      width: width,
      height: height,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) return child;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.onSurfaceVariant.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SizedBox(width: width, height: height),
        );
      },
      errorBuilder: (_, _, _) => SizedBox(width: width, height: height),
    );
  }
}

/// 内联表情搜索视图(桌面悬浮弹层用:替换面板内容区,不弹 sheet)。
///
/// 顶部小搜索框(自动聚焦)+ 结果 grid;返回按钮/Esc 由外层弹层管,
/// 这里只提供关闭回调按钮。选中走 [onSelected](记最近使用后回调编辑器),
/// 不自动退出搜索态 —— 与弹层"连续选择"语义一致。
class _EmojiSearchView extends StatefulWidget {
  final List<Emoji> allEmojis;
  final ValueChanged<Emoji> onSelected;
  final VoidCallback onClose;

  /// 底部额外 padding(悬浮切换 Tab 占位,同 EmojiPicker.bottomPadding)
  final double bottomPadding;

  const _EmojiSearchView({
    required this.allEmojis,
    required this.onSelected,
    required this.onClose,
    this.bottomPadding = 0,
  });

  @override
  State<_EmojiSearchView> createState() => _EmojiSearchViewState();
}

class _EmojiSearchViewState extends State<_EmojiSearchView> {
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

    final results = _query.isEmpty
        ? <Emoji>[]
        : widget.allEmojis.where((emoji) {
            return emoji.name.toLowerCase().contains(_query) ||
                emoji.searchAliases.any(
                  (alias) => alias.toLowerCase().contains(_query),
                );
          }).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Symbols.arrow_back_rounded, size: 20),
                color: theme.colorScheme.onSurfaceVariant,
                visualDensity: VisualDensity.compact,
                onPressed: widget.onClose,
                tooltip: S.current.common_cancel,
              ),
              Expanded(
                child: Container(
                  height: 36,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    autofocus: true,
                    textAlignVertical: TextAlignVertical.center,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: S.current.emoji_searchHint,
                      hintStyle: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.only(right: 12),
                      prefixIcon: Icon(
                        Symbols.search_rounded,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      suffixIcon: _query.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Symbols.cancel_rounded,
                                  size: 16),
                              color: theme.colorScheme.onSurfaceVariant,
                              onPressed: () => _searchController.clear(),
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _query.isEmpty
              ? Center(
                  child: Text(
                    S.current.emoji_searchPrompt,
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : results.isEmpty
              ? Center(
                  child: Text(
                    S.current.emoji_searchNotFound,
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : GridView.builder(
                  padding: EdgeInsets.fromLTRB(
                    12,
                    8,
                    12,
                    12 + widget.bottomPadding,
                  ),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 40,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                      ),
                  itemCount: results.length,
                  itemBuilder: (context, index) {
                    final emoji = results[index];
                    return InkWell(
                      onTap: () => widget.onSelected(emoji),
                      borderRadius: BorderRadius.circular(4),
                      child: Tooltip(
                        message: ':${emoji.name}:',
                        child: Padding(
                          padding: const EdgeInsets.all(4.0),
                          child: _EmojiCell(name: emoji.name, decodeSize: 64),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
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
                emoji.searchAliases.any(
                  (alias) => alias.toLowerCase().contains(_query),
                );
          }).toList();

    return AppSheetScaffold(
      showCloseButton: false,
      contentPadding: EdgeInsets.zero,
      maxHeightFactor: 0.8,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
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
            child: Row(
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
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.only(
                          left: 0,
                          right: 12,
                        ),
                        prefixIcon: Icon(
                          Symbols.search_rounded,
                          size: 20,
                          color: theme.colorScheme.onSurface,
                        ),
                        suffixIcon: _query.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Symbols.cancel_rounded, size: 18),
                                color: theme.colorScheme.onSurfaceVariant,
                                onPressed: () => _searchController.clear(),
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
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: Text(S.current.common_cancel),
                ),
              ],
            ),
          ),

          // 内容区域
          Expanded(
            child: _query.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Symbols.emoji_emotions_rounded,
                          size: 48,
                          color: theme.colorScheme.outline.withValues(
                            alpha: 0.5,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          S.current.emoji_searchPrompt,
                          style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                : results.isEmpty
                ? Center(
                    child: Text(
                      S.current.emoji_searchNotFound,
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : GridView.builder(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      16,
                      16,
                      mediaQuery.viewInsets.bottom + 16,
                    ),
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
                            child: _EmojiCell(name: emoji.name, decodeSize: 80),
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
