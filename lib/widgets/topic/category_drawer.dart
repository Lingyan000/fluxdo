import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' show SpringDescription, SpringSimulation;
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../models/category.dart';
import '../../models/tag_search_result.dart';
import '../../providers/discourse_providers.dart';
import '../../providers/pinned_categories_provider.dart';
import '../../utils/font_awesome_helper.dart';
import '../../utils/motion_springs.dart';
import '../../utils/number_utils.dart';
import '../../utils/tag_icon_list.dart';
import '../../utils/url_helper.dart';
import '../../services/discourse_cache_manager.dart';
import '../../pages/category_topics_page.dart';
import '../../pages/tag_topics_page.dart';
import '../../l10n/s.dart';
import 'topic_notification_button.dart'
    show getCategoryNotificationIcon, showCategoryNotificationLevelSheet;
import 'category_tab_manager_sheet.dart' show PinnedCategoryEditPage;

/// 分类侧栏的全局开关与拖拽入口。
/// 宿主 [ControlledCategoryDrawer] 挂在 AdaptiveScaffold 顶层，通过本
/// 静态 key 驱动;首页 TabBarView 首缘 overscroll 桥逐帧调 [dragBy]
/// 实现整块区域右滑跟手拖出。
class CategoryDrawerHost {
  CategoryDrawerHost._();

  static final GlobalKey<ControlledCategoryDrawerState> drawerKey =
      GlobalKey<ControlledCategoryDrawerState>();

  /// 抽屉是否可见（返回键拦截链用，见首页 PopScope）
  static bool get isOpen => drawerKey.currentState?.isOpen ?? false;

  static void open() => drawerKey.currentState?.open();

  static void close() => drawerKey.currentState?.close();

  /// 跟手拖拽：水平位移增量（px，向右为正）
  static void dragBy(double dx) => drawerKey.currentState?.dragBy(dx);

  /// 松手收尾：按速度/位置就近开或关
  static void settle(double velocityDx) =>
      drawerKey.currentState?.settle(velocityDx);
}

/// 受控分类抽屉：自持 AnimationController(0..1) 驱动遮罩与面板。
///
/// 不用 DrawerController：它的拖拽驱动（_move/_settle）是私有 API，
/// 外部只能 open/close —— 做不了"TabBarView 首缘 overscroll 逐帧
/// 喂增量"的跟手拖出（用户点名：右滑慢慢打开，不是触发即弹）。
/// 开着时面板/遮罩上水平拖拽关闭、点遮罩关闭、返回键关闭，语义与系统
/// 抽屉一致。返回键有两路：LocalHistoryEntry 覆盖普通路由;首页根路由
/// 挂着 canPop:false 的 PopScope（双击退出），其 doNotPop 判定优先于
/// LocalHistory 内部消费，故由首页 PopScope 回调查 [CategoryDrawerHost.isOpen]
/// 兜底关闭。
class ControlledCategoryDrawer extends StatefulWidget {
  const ControlledCategoryDrawer({super.key, required this.onPinnedSelected});

  /// 点收藏分类：宿主负责切到首页并选中该分类 tab
  final ValueChanged<Category> onPinnedSelected;

  @override
  State<ControlledCategoryDrawer> createState() =>
      ControlledCategoryDrawerState();
}

class ControlledCategoryDrawerState extends State<ControlledCategoryDrawer>
    with SingleTickerProviderStateMixin {
  /// Drawer 默认面板宽（拖拽增量归一化用）
  static const double _panelWidth = 304.0;

  late final AnimationController _anim = AnimationController.unbounded(
    vsync: this,
  )..addListener(_syncHistory);

  /// 收尾弹簧(与首页头部运动系统同族,见 [kHeaderMotionSpring])
  static final SpringDescription _spring = kHeaderSpringDescription;

  LocalHistoryEntry? _history;
  bool _removingHistory = false;

  /// 抽屉是否可见（含拖拽/动画中间态）
  bool get isOpen => _anim.value > 0;

  void open() => _springTo(1.0);

  void close() => _springTo(0.0);

  void dragBy(double dx) {
    _anim.stop();
    _anim.value = (_anim.value + dx / _panelWidth).clamp(0.0, 1.0);
  }

  /// 松手收尾：继承指针速度的弹簧（快甩快合，速度连续无断层）
  void settle(double velocityDx) {
    final v = velocityDx / _panelWidth;
    final double target;
    if (velocityDx.abs() >= 365) {
      target = velocityDx > 0 ? 1.0 : 0.0;
    } else {
      target = _anim.value >= 0.5 ? 1.0 : 0.0;
    }
    _springTo(target, velocity: v);
  }

  void _springTo(double target, {double velocity = 0}) {
    if (_anim.value == target && velocity == 0) return;
    _anim
        .animateWith(SpringSimulation(_spring, _anim.value, target, velocity))
        .whenComplete(() {
          // unbounded 不夹值，弹簧收敛后钉到端点
          _anim.value = target;
        });
  }

  /// 返回键联动：抽屉可见即挂 LocalHistoryEntry（返回=关抽屉）
  void _syncHistory() {
    final visible = _anim.value > 0;
    if (visible && _history == null) {
      final route = ModalRoute.of(context);
      if (route != null) {
        _history = LocalHistoryEntry(
          onRemove: () {
            _history = null;
            if (!_removingHistory) close();
          },
        );
        route.addLocalHistoryEntry(_history!);
      }
    } else if (!visible && _history != null) {
      final entry = _history;
      _history = null;
      _removingHistory = true;
      entry?.remove();
      _removingHistory = false;
    }
  }

  @override
  void dispose() {
    _history?.remove();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, child) {
        // unbounded 控制器（弹簧可轻微过冲），显示前夹回 [0,1]
        final v = _anim.value.clamp(0.0, 1.0);
        if (v == 0) return const SizedBox.shrink();
        return SizedBox.expand(
          child: Stack(
            children: [
              // 遮罩：跟手渐变;点击/拖拽关闭
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: close,
                  onHorizontalDragUpdate: (d) => dragBy(d.primaryDelta ?? 0),
                  onHorizontalDragEnd: (d) =>
                      settle(d.velocity.pixelsPerSecond.dx),
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.54 * v),
                  ),
                ),
              ),
              // 面板：paint 平移跟手滑入;面板上水平拖拽关闭
              Align(
                alignment: Alignment.centerLeft,
                child: FractionalTranslation(
                  translation: Offset(v - 1.0, 0),
                  child: GestureDetector(
                    onHorizontalDragUpdate: (d) => dragBy(d.primaryDelta ?? 0),
                    onHorizontalDragEnd: (d) =>
                        settle(d.velocity.pixelsPerSecond.dx),
                    child: child,
                  ),
                ),
              ),
            ],
          ),
        );
      },
      child: CategoryDrawer(
        onRequestClose: close,
        onPinnedSelected: widget.onPinnedSelected,
      ),
    );
  }
}

/// 首页分类侧栏：分类的管理中枢。
///
/// 宿主以 **DrawerController 挂在 AdaptiveScaffold 顶层**呈现（原生
/// 抽屉全套跟手手势：左缘拖出/拖拽关闭/甩动 settle/遮罩渐变;左缘滑
/// 是全局手势，任意底部 tab 可用）。本组件即抽屉面板;关闭走
/// [onRequestClose]（内容不在路由里，Navigator.pop 语义不可靠）。
///
/// 行上克制：常驻可点的只有「行本体」;收藏/订阅收进长按（桌面右键）
/// 分类操作菜单;🔒 受限做成图标块右下角标。
///
/// - 收藏区：已 pin 分类，点行 → 切到首页对应分类 tab
/// - 全部分类区：父子分组;带 chevron 的父分类点行=展开/收起，展开
///   首行「全部话题」进父分类聚合页;无子分类行点行=进页
/// - 「编辑」→ 收藏排序页（拖拽调序，复用 PinnedCategoryEditPage）
class CategoryDrawer extends ConsumerStatefulWidget {
  const CategoryDrawer({
    super.key,
    required this.onPinnedSelected,
    required this.onRequestClose,
  });

  /// 点收藏分类：宿主负责切到首页并选中该分类 tab
  final ValueChanged<Category> onPinnedSelected;

  /// 请求关闭抽屉（宿主调 DrawerControllerState.close）
  final VoidCallback onRequestClose;

  @override
  ConsumerState<CategoryDrawer> createState() => _CategoryDrawerState();
}

class _CategoryDrawerState extends ConsumerState<CategoryDrawer> {
  /// 已展开子分类的父分类 id 集合（默认全收起）
  final Set<int> _expandedIds = {};

  /// 当前页签：false = 分类，true = 标签
  bool _showTags = false;

  /// 标签搜索词（本地过滤 /tags.json 全量数据，无需请求）
  final TextEditingController _tagQueryController = TextEditingController();
  String _tagQuery = '';

  /// 标签列表滚动控制（组导航跳转用）
  final ScrollController _tagListController = ScrollController();

  /// 当前视口所在组（组导航高亮跟随）
  final ValueNotifier<int> _activeTagGroup = ValueNotifier(0);

  /// 组导航 chip 的 key（高亮变化时 ensureVisible 滚到可见）
  final Map<int, GlobalKey> _tagChipKeys = {};

  /// 跳转动画进行中：滚动监听不抢高亮（否则点末组会被反算顶掉）
  bool _tagJumpInFlight = false;

  /// 各组在标签列表中的起始偏移（行高恒定，可精确预计算）
  List<double> _tagGroupOffsets = const [];

  // 标签列表行高常量（偏移表的根基：三种成员高度全部钉死）
  static const double _kTagLabelExtent = 28.0;
  static const double _kTagRowExtent = 50.0; // 48 行 + 2 底距
  static const double _kTagGroupGapExtent = 10.0;
  static const double _kTagListTopPadding = 2.0;

  @override
  void initState() {
    super.initState();
    _tagListController.addListener(_onTagListScroll);
  }

  /// 滚动反算当前组：视口顶所在组 → 组导航高亮跟随
  void _onTagListScroll() {
    if (_tagJumpInFlight || !_tagListController.hasClients) return;
    final offsets = _tagGroupOffsets;
    if (offsets.length < 2) return;
    final px = _tagListController.position.pixels + _kTagLabelExtent;
    var idx = 0;
    for (var i = 0; i < offsets.length; i++) {
      if (offsets[i] <= px) {
        idx = i;
      } else {
        break;
      }
    }
    if (_activeTagGroup.value != idx) {
      _activeTagGroup.value = idx;
      _ensureTagChipVisible(idx);
    }
  }

  /// 组导航点击：直达该组起点（clamp 到可滚上限，末组不足一屏也稳）
  Future<void> _jumpToTagGroup(int index) async {
    if (index >= _tagGroupOffsets.length || !_tagListController.hasClients) {
      return;
    }
    _tagJumpInFlight = true;
    _activeTagGroup.value = index;
    _ensureTagChipVisible(index);
    final target = _tagGroupOffsets[index].clamp(
      0.0,
      _tagListController.position.maxScrollExtent,
    );
    await _tagListController.animateTo(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
    _tagJumpInFlight = false;
  }

  /// 高亮 chip 滚到导航条可见区（跳转/滚动跟随两路共用）
  void _ensureTagChipVisible(int index) {
    final ctx = _tagChipKeys[index]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _tagQueryController.dispose();
    _tagListController.dispose();
    _activeTagGroup.dispose();
    super.dispose();
  }

  /// 关抽屉并 push 页面。抽屉不在路由里（DrawerController 常驻
  /// Overlay），Navigator.pop 不可用 —— 关闭走宿主回调，push 用本页
  /// context 的 Navigator。
  void _closeAndPush(Widget page) {
    widget.onRequestClose();
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  /// 长按/右键分类行：收藏与订阅的操作菜单（低频操作不常驻行上）
  Future<void> _showCategoryMenu(
    BuildContext rowContext,
    Category category, {
    required bool pinned,
    required CategoryNotificationLevel? level,
  }) async {
    final colorScheme = Theme.of(rowContext).colorScheme;
    final box = rowContext.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(rowContext).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final position = RelativeRect.fromRect(
      box.localToGlobal(Offset.zero, ancestor: overlay) & box.size,
      Offset.zero & overlay.size,
    );

    final action = await showMenu<Symbol>(
      context: rowContext,
      position: position,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      items: [
        PopupMenuItem(
          value: #togglePin,
          child: Row(
            children: [
              Icon(
                Symbols.star_rounded,
                size: 18,
                fill: pinned ? 1 : 0,
                color: pinned ? colorScheme.primary : null,
              ),
              const SizedBox(width: 10),
              Text(
                pinned
                    ? S.current.category_unpin
                    : S.current.category_pinToTabs,
              ),
            ],
          ),
        ),
        if (level != null)
          PopupMenuItem(
            value: #subscription,
            child: Row(
              children: [
                Icon(
                  getCategoryNotificationIcon(level),
                  size: 18,
                  color: level != CategoryNotificationLevel.regular
                      ? colorScheme.primary
                      : null,
                ),
                const SizedBox(width: 10),
                Text(S.current.topic_notificationSettings),
              ],
            ),
          ),
      ],
    );

    if (!mounted) return;
    switch (action) {
      case #togglePin:
        final notifier = ref.read(pinnedCategoriesProvider.notifier);
        pinned ? notifier.remove(category.id) : notifier.add(category.id);
      case #subscription:
        _openSubscriptionSheet(category);
      default:
    }
  }

  /// 分类订阅设置：拉起级别面板（乐观更新 + 失败回退）。
  /// 侧栏已全局化（宿主是 AdaptiveScaffold），订阅逻辑自持。
  void _openSubscriptionSheet(Category category) {
    final overrides = ref.read(categoryNotificationOverridesProvider);
    final effectiveLevel = overrides[category.id] ?? category.notificationLevel;
    final level = CategoryNotificationLevel.fromValue(effectiveLevel);
    showCategoryNotificationLevelSheet(context, level, (newLevel) async {
      final oldLevel = effectiveLevel;
      // 乐观更新
      ref.read(categoryNotificationOverridesProvider.notifier).state = {
        ...ref.read(categoryNotificationOverridesProvider),
        category.id: newLevel.value,
      };
      try {
        final service = ref.read(discourseServiceProvider);
        await service.setCategoryNotificationLevel(category.id, newLevel.value);
      } catch (_) {
        // 失败时回退
        if (mounted) {
          final current = ref.read(categoryNotificationOverridesProvider);
          if (oldLevel != null) {
            ref.read(categoryNotificationOverridesProvider.notifier).state = {
              ...current,
              category.id: oldLevel,
            };
          } else {
            ref
                .read(categoryNotificationOverridesProvider.notifier)
                .state = Map.from(current)
              ..remove(category.id);
          }
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final pinnedIds = ref.watch(pinnedCategoriesProvider);
    final categoriesAsync = ref.watch(categoriesProvider);
    final isLoggedIn = ref.watch(currentUserProvider).value != null;
    final overrides = ref.watch(categoryNotificationOverridesProvider);

    CategoryNotificationLevel? levelFor(Category c) {
      if (!isLoggedIn) return null;
      return CategoryNotificationLevel.fromValue(
        overrides[c.id] ?? c.notificationLevel,
      );
    }

    return Drawer(
      backgroundColor: colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(24)),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // —— 头部：分类 ⇄ 标签 页签切换（编辑铅笔只属于分类页）——
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
              child: Row(
                children: [
                  _DrawerTabSwitcher(
                    showTags: _showTags,
                    onChanged: (v) => setState(() => _showTags = v),
                  ),
                  const Spacer(),
                  if (!_showTags && pinnedIds.isNotEmpty)
                    IconButton(
                      icon: const Icon(Symbols.edit_rounded, size: 20),
                      tooltip: S.current.common_edit,
                      visualDensity: VisualDensity.compact,
                      onPressed: () =>
                          _closeAndPush(const PinnedCategoryEditPage()),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _showTags
                  ? _buildTagsList()
                  : _buildCategoriesList(categoriesAsync, pinnedIds, levelFor),
            ),
          ],
        ),
      ),
    );
  }

  /// 分类页签：收藏区 + 全部分类父子树（原侧栏主体）
  Widget _buildCategoriesList(
    AsyncValue<List<Category>> categoriesAsync,
    List<int> pinnedIds,
    CategoryNotificationLevel? Function(Category) levelFor,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return categoriesAsync.when(
      loading: () => const Center(child: LoadingSpinner()),
      error: (_, _) => Center(child: Text(S.current.common_loadFailed)),
      data: (categories) {
        final categoryMap = {for (final c in categories) c.id: c};
        final pinned = pinnedIds
            .map((id) => categoryMap[id])
            .whereType<Category>()
            .toList();
        final pinnedSet = pinnedIds.toSet();

        // 父子分组（保持服务器顺序）：顶级分类 + 各自子分类;
        // 父不可见的孤儿子分类兜底提为顶级
        final childrenOf = <int, List<Category>>{};
        final topLevel = <Category>[];
        for (final c in categories) {
          final parentId = c.parentCategoryId;
          if (parentId != null && categoryMap.containsKey(parentId)) {
            (childrenOf[parentId] ??= []).add(c);
          } else {
            topLevel.add(c);
          }
        }

        Widget rowFor(
          Category category, {
          required bool indent,
          List<Category> children = const [],
        }) {
          final expanded = _expandedIds.contains(category.id);
          final isPinned = pinnedSet.contains(category.id);
          final hasChildren = children.isNotEmpty;
          return _CategoryRow(
            category: category,
            pinned: isPinned,
            indent: indent,
            expandState: hasChildren ? expanded : null,
            // 单一职责：带 chevron 的行只做展开/收起，不带的只做
            // 进页。父分类自身的话题列表走展开后的第一行
            // 「全部话题」入口（Amazon/Play 分类树范式）——
            // 消灭"同样的行为却不同"和 ↗ 小目标
            onTap: hasChildren
                ? () => setState(() {
                    expanded
                        ? _expandedIds.remove(category.id)
                        : _expandedIds.add(category.id);
                  })
                : () => _closeAndPush(CategoryTopicsPage(category: category)),
            onLongPress: (rowContext) => _showCategoryMenu(
              rowContext,
              category,
              pinned: isPinned,
              level: levelFor(category),
            ),
          );
        }

        /// 展开后的首行：「全部话题」—— 父分类自身聚合页的入口
        Widget allTopicsRowFor(Category parent) {
          return _AllTopicsRow(
            parentColor: _parseColor(parent.color, colorScheme.primary),
            onTap: () => _closeAndPush(CategoryTopicsPage(category: parent)),
          );
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
          children: [
            // —— 收藏区（点行切首页对应分类 tab，无展开语义）——
            if (pinned.isNotEmpty) ...[
              _SectionLabel(text: S.current.category_myCategories),
              for (final category in pinned)
                _CategoryRow(
                  category: category,
                  pinned: true,
                  indent: false,
                  onTap: () {
                    widget.onRequestClose();
                    widget.onPinnedSelected(category);
                  },
                  onLongPress: (rowContext) => _showCategoryMenu(
                    rowContext,
                    category,
                    pinned: true,
                    level: levelFor(category),
                  ),
                ),
              const SizedBox(height: 12),
            ],
            // —— 全部分类区（父子分组，子分类默认折叠）——
            _SectionLabel(text: S.current.category_allCategories),
            for (final parent in topLevel) ...[
              rowFor(
                parent,
                indent: false,
                children: childrenOf[parent.id] ?? const [],
              ),
              if (_expandedIds.contains(parent.id)) ...[
                // 首行「全部话题」= 父分类自身聚合页入口
                allTopicsRowFor(parent),
                for (final child in childrenOf[parent.id] ?? const [])
                  rowFor(child, indent: true),
              ],
            ],
          ],
        );
      },
    );
  }

  /// 标签页签：/tags.json 全量数据，**保留服务端标签组结构**分区展
  /// 示（有分组的站点各组一节，未分组归「其他标签」；未开分组则单
  /// 列表）。顶部搜索框本地过滤；行式排布 + 热度条（组内相对榜首）。
  Widget _buildTagsList() {
    final colorScheme = Theme.of(context).colorScheme;
    final groupsAsync = ref.watch(siteTagGroupsProvider);
    return groupsAsync.when(
      loading: () => const Center(child: LoadingSpinner()),
      error: (_, _) => Center(child: Text(S.current.common_loadFailed)),
      data: (groups) {
        if (groups.isEmpty) {
          return Center(child: Text(S.current.tag_noTags));
        }

        // 本地过滤（name/text 都匹配；标签量级几百，逐帧过滤无压力）
        final query = _tagQuery.trim().toLowerCase();
        final filtered = <SiteTagGroup>[];
        for (final group in groups) {
          final tags = query.isEmpty
              ? group.tags
              : group.tags
                    .where(
                      (t) =>
                          t.name.toLowerCase().contains(query) ||
                          t.text.toLowerCase().contains(query),
                    )
                    .toList();
          if (tags.isNotEmpty) {
            filtered.add(SiteTagGroup(name: group.name, tags: tags));
          }
        }

        // 只有一个无名组 = 站点未开分组，不渲染组标题
        final showGroupLabels =
            filtered.length > 1 ||
            (filtered.isNotEmpty && filtered.first.name != null);

        // 拍平成 (组标题 | 标签行) 序列供懒构建（全站几百个标签，
        // eager 构建整棵列表不划算）;成员高度全部钉死，同步产出
        // 各组起始偏移供组导航精确直达
        final items = <Widget>[];
        final offsets = <double>[];
        var cursor = _kTagListTopPadding;
        for (final group in filtered) {
          offsets.add(cursor);
          if (showGroupLabels) {
            items.add(
              SizedBox(
                height: _kTagLabelExtent,
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                    child: Text(
                      group.name ?? S.current.tag_otherTags,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            );
            cursor += _kTagLabelExtent;
          }
          final maxCount = group.tags.first.count;
          for (final tag in group.tags) {
            items.add(
              _TagRow(
                tag: tag,
                heat: maxCount > 0 ? tag.count / maxCount : 0,
                onTap: () => _closeAndPush(TagTopicsPage(tagName: tag.name)),
              ),
            );
          }
          cursor += group.tags.length * _kTagRowExtent;
          items.add(const SizedBox(height: _kTagGroupGapExtent));
          cursor += _kTagGroupGapExtent;
        }
        _tagGroupOffsets = offsets;
        if (_activeTagGroup.value >= filtered.length) {
          _activeTagGroup.value = 0;
        }

        return Column(
          children: [
            // —— 搜索框：本地过滤，胶囊形与首页搜索同族 ——
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
              child: SizedBox(
                height: 40,
                child: TextField(
                  controller: _tagQueryController,
                  onChanged: (v) => setState(() => _tagQuery = v),
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: S.current.tag_searchHint,
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.7,
                      ),
                    ),
                    prefixIcon: Icon(
                      Symbols.search_rounded,
                      size: 20,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    suffixIcon: _tagQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Symbols.close_rounded, size: 18),
                            color: colorScheme.onSurfaceVariant,
                            visualDensity: VisualDensity.compact,
                            onPressed: () {
                              _tagQueryController.clear();
                              setState(() => _tagQuery = '');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                    contentPadding: EdgeInsets.zero,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),
            // —— 组导航：横滑 chip 条，点击直达该组；滚动反向跟随
            // 高亮（联系人索引条的横版）——
            if (showGroupLabels && filtered.length > 1)
              SizedBox(
                height: 34,
                child: ValueListenableBuilder<int>(
                  valueListenable: _activeTagGroup,
                  builder: (context, active, _) => ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 6),
                    itemBuilder: (context, i) {
                      final selected = i == active;
                      return _TagGroupChip(
                        key: _tagChipKeys[i] ??= GlobalKey(),
                        label: filtered[i].name ?? S.current.tag_otherTags,
                        selected: selected,
                        onTap: () => _jumpToTagGroup(i),
                      );
                    },
                  ),
                ),
              ),
            Expanded(
              child: items.isEmpty
                  ? Center(child: Text(S.current.tag_noTagsFound))
                  : ListView.builder(
                      controller: _tagListController,
                      padding: const EdgeInsets.fromLTRB(
                        12,
                        _kTagListTopPadding,
                        12,
                        24,
                      ),
                      itemCount: items.length,
                      itemBuilder: (context, index) => items[index],
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// 分区小标题（大写风格次级文字）
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.category,
    required this.pinned,
    required this.indent,
    required this.onTap,
    required this.onLongPress,
    this.expandState,
  });

  final Category category;
  final bool pinned;
  final bool indent;

  /// 行本体点击：有子分类 = 展开/收起，无子分类 = 进分类页
  final VoidCallback onTap;

  /// 长按/桌面右键：分类操作菜单（收藏/订阅）。传行的 context 供菜单
  /// 锚定在行位置
  final void Function(BuildContext rowContext) onLongPress;

  /// 子分类展开态（null = 无子分类，行尾无 chevron）
  final bool? expandState;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final categoryColor = _parseColor(category.color, colorScheme.primary);
    final expanded = expandState;

    return Padding(
      padding: EdgeInsets.only(left: indent ? 20 : 0, bottom: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: Builder(
          builder: (rowContext) => InkWell(
            onTap: onTap,
            onLongPress: () => onLongPress(rowContext),
            onSecondaryTap: () => onLongPress(rowContext),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: SizedBox(
                height: 48,
                child: Row(
                  children: [
                    // 彩色图标块（🔒 受限为右下小角标）
                    _CategoryIconBlock(
                      category: category,
                      color: categoryColor,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        category.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: pinned
                              ? FontWeight.w500
                              : FontWeight.w400,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                    // 收藏态：小 ★ 状态点缀（非按钮，长按菜单里操作）
                    if (pinned)
                      Icon(
                        Symbols.star_rounded,
                        size: 16,
                        fill: 1,
                        color: colorScheme.primary.withValues(alpha: 0.75),
                      ),
                    // 展开态指示（非按钮：整行即展开/收起）
                    if (expanded != null) ...[
                      const SizedBox(width: 4),
                      AnimatedRotation(
                        turns: expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: Icon(
                          Symbols.keyboard_arrow_down_rounded,
                          size: 20,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 展开后的首行「全部话题」：父分类自身聚合页的入口。
/// 与子分类行同构（同 48 行高、同 32px 图标块规格），图标块继承
/// 父分类色，用列表符号代替分类图标 —— 融入分组又可辨识。
class _AllTopicsRow extends StatelessWidget {
  const _AllTopicsRow({required this.parentColor, required this.onTap});

  final Color parentColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 20, bottom: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: SizedBox(
              height: 48,
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: parentColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Center(
                      child: Icon(
                        Symbols.clear_all_rounded,
                        size: 18,
                        color: parentColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      S.current.category_allTopics,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 标签组导航 chip：小号胶囊，选中着色 secondaryContainer（与页签
/// 切换器同语汇）
class _TagGroupChip extends StatelessWidget {
  const _TagGroupChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Material(
        color: selected
            ? colorScheme.secondaryContainer
            : colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? colorScheme.onSecondaryContainer
                    : colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 标签页签的行：与分类行同构（48 高、32 图标块）。
/// 图标块 = TagIconList 配色图标，无配置则通用 # 号；行尾右对齐
/// 话题数 + 底部细热度条（相对榜首归一化）——排行榜式可比较。
class _TagRow extends StatelessWidget {
  const _TagRow({required this.tag, required this.heat, required this.onTap});

  final TagInfo tag;

  /// 热度（0..1，相对最热标签）
  final double heat;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final tagInfo = TagIconList.get(tag.name);
    final accent = tagInfo?.color ?? colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: SizedBox(
              height: 48,
              child: Row(
                children: [
                  // 图标块：与分类图标块同规格
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Center(
                      child: tagInfo != null
                          ? FaIcon(tagInfo.icon, size: 15, color: accent)
                          : Icon(Symbols.tag_rounded, size: 17, color: accent),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tag.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14.5,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 5),
                        // 热度条：4px 圆角细条，相对榜首归一化
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: SizedBox(
                            height: 3,
                            child: LayoutBuilder(
                              builder: (context, constraints) => Stack(
                                children: [
                                  Container(
                                    color: colorScheme.surfaceContainerHighest
                                        .withValues(alpha: 0.6),
                                  ),
                                  Container(
                                    width:
                                        constraints.maxWidth *
                                        heat.clamp(0.02, 1.0),
                                    color: accent.withValues(alpha: 0.65),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    NumberUtils.formatCount(tag.count),
                    style: TextStyle(
                      fontSize: 12,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 抽屉头部的「分类 ⇄ 标签」分段切换（M3 connected button group 简
/// 化版：胶囊底 + 滑动选中块）
class _DrawerTabSwitcher extends StatelessWidget {
  const _DrawerTabSwitcher({required this.showTags, required this.onChanged});

  final bool showTags;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    Widget segment(String label, bool selected, VoidCallback onTap) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? colorScheme.secondaryContainer : null,
            borderRadius: BorderRadius.circular(20),
          ),
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected
                  ? colorScheme.onSecondaryContainer
                  : colorScheme.onSurfaceVariant,
            ),
            child: Text(label),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(23),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          segment(
            S.current.category_categories,
            !showTags,
            () => onChanged(false),
          ),
          segment(S.current.tag_tabTags, showTags, () => onChanged(true)),
        ],
      ),
    );
  }
}

/// 分类彩色图标块：分类色 12% 底 + 图标/logo/色点居中；受限分类在
/// 右下角叠 🔒 小角标（元信息贴着身份元素，不占行上操作位）
class _CategoryIconBlock extends StatelessWidget {
  const _CategoryIconBlock({required this.category, required this.color});

  final Category category;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final block = Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Center(child: _buildCategoryIcon(category, color, 18)),
    );
    if (!category.readRestricted) return block;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        block,
        Positioned(
          right: -3,
          bottom: -3,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Symbols.lock_rounded,
              size: 9,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

Color _parseColor(String hex, Color fallback) {
  try {
    return Color(int.parse('FF$hex', radix: 16));
  } catch (_) {
    return fallback;
  }
}

Widget _buildCategoryIcon(Category category, Color color, double size) {
  final logoUrl = category.uploadedLogo;
  final faIcon = FontAwesomeHelper.getIcon(category.icon);

  if (faIcon != null) {
    return FaIcon(faIcon, size: size * 0.85, color: color);
  }

  if (logoUrl != null && logoUrl.isNotEmpty) {
    return Image(
      image: discourseImageProvider(UrlHelper.resolveUrlWithCdn(logoUrl)),
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => _colorDot(color, size * 0.5),
    );
  }

  return _colorDot(color, size * 0.5);
}

Widget _colorDot(Color color, double size) {
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
