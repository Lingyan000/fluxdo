import 'dart:io';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../pages/topics_page.dart';
import '../../providers/category_provider.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/topic_list/tab_state_provider.dart';
import '../../utils/nav_chrome_metrics.dart';
import '../../utils/responsive.dart';
import '../../l10n/s.dart';
import '../notification/notification_quick_panel.dart';
import 'adaptive_navigation.dart';
import 'category_shortcuts.dart';
import '../topic/category_tab_manager_sheet.dart';
import '../topic/category_drawer.dart';

/// 自适应 Scaffold
///
/// 根据屏幕宽度自动切换布局：
/// - 手机: 底部导航
/// - 平板/桌面: 侧边导航栏
///
/// 使用单一 Scaffold + Row 结构，确保布局切换时 body 不会被卸载重建。
class AdaptiveScaffold extends ConsumerWidget {
  const AdaptiveScaffold({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    required this.body,
    this.floatingActionButton,
    this.railLeading,
    this.railBottomLeading,
    this.extendedRail = false,
    this.hideNavigationRail = false,
    this.hideBottomNavigation = false,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<AdaptiveDestination> destinations;
  final Widget body;
  final Widget? floatingActionButton;
  final Widget? railLeading;
  final Widget? railBottomLeading;
  final bool extendedRail;

  /// 二级平行视界中两侧都属于内容页时隐藏最外层全局侧栏，释放横向空间。
  /// 手机底栏不受影响。
  final bool hideNavigationRail;

  /// 窄屏投影态(平行视界详情全宽盖在 tab 体内)时隐藏底栏——观感对齐
  /// 全屏详情页(合成路由时代底栏被路由盖住,投影态用显式谓词达成)。
  final bool hideBottomNavigation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showRail =
        Responsive.showNavigationRail(context) && !hideNavigationRail;
    final sidebarCategoryController = ref.read(
      activeSidebarCategoryIdProvider.notifier,
    );
    final activeSidebarCategoryId = ref.watch(activeSidebarCategoryIdProvider);
    final railSelectedIndex =
        activeSidebarCategoryId != null && selectedIndex == 0
        ? -1
        : selectedIndex;

    final hasAcrylic = Platform.isMacOS || Platform.isWindows;
    final useAcrylicRail = showRail && hasAcrylic;
    final railWidth = extendedRail ? 180.0 : 72.0;
    // 双栏判定的「Rail 应占宽」记账(判定轴与分配轴同轴,见
    // NavChromeMetrics 注释)。写形态宽而非可见宽:hideNavigationRail
    // 临时隐藏不改判定,避免 pop→Rail 回来→塌成投影的反馈环。
    NavChromeMetrics.railWidth = railWidth;
    // 左缘覆盖层(通知面板)的让位宽。Rail 内部套着 SafeArea:异形屏
    // 横屏(挖孔/刘海转到左侧)时它实际占宽 = 左安全区 + 形态宽,这里
    // 必须扣同一口径——只扣形态宽会让面板左缘劈在 Rail 身上(盖住
    // 选中 pill 右半,实测横屏截图踩中)。
    final overlayLeftInset = showRail
        ? MediaQuery.paddingOf(context).left +
              railWidth +
              (useAcrylicRail ? 0.0 : 1.0)
        : 0.0;

    return Stack(
      children: [
        Scaffold(
          backgroundColor: useAcrylicRail ? Colors.transparent : null,
          // 底栏隐藏改为整条平移出屏（paint-only），内容延伸到底栏后面;
          // body 高度不再随底栏显隐变化，收放过程零 relayout
          extendBody: true,
          body: Row(
            children: [
              if (showRail) ...[
                AdaptiveNavigationRail(
                  selectedIndex: railSelectedIndex,
                  onDestinationSelected: (index) {
                    sidebarCategoryController.state = null;
                    onDestinationSelected(index);
                  },
                  destinations: destinations,
                  topDestinationCount: destinations.isEmpty ? 0 : 1,
                  bottomDestinationCount: destinations.length <= 1
                      ? 0
                      : destinations.length - 1,
                  categoryShortcuts: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CategoryShortcuts(
                        extended: extendedRail,
                        onCategorySelected: (categoryId) {
                          sidebarCategoryController.state = categoryId;
                          // 再次点击当前板块也必须形成一次明确导航事件（高亮
                          // 状态 provider 同值会被去重），首页靠 tap 事件从
                          // 深层平行视界退回板块列表。
                          final tap = ref.read(sidebarCategoryTapProvider);
                          ref.read(sidebarCategoryTapProvider.notifier).state = (
                            categoryId: categoryId,
                            nonce: (tap?.nonce ?? 0) + 1,
                          );
                          if (selectedIndex != 0) {
                            onDestinationSelected(0);
                          }
                          ref
                                  .read(currentTabCategoryIdProvider.notifier)
                                  .state =
                              categoryId;
                        },
                      ),
                      _SidebarCategoryAddButton(
                        extended: extendedRail,
                        onOpenCategoryManager: () async {
                          sidebarCategoryController.state = null;
                          if (selectedIndex != 0) {
                            onDestinationSelected(0);
                          }
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const PinnedCategoryEditPage(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  extended: extendedRail,
                  leading: railLeading,
                  bottomLeading: railBottomLeading,
                ),
                if (!useAcrylicRail)
                  const VerticalDivider(thickness: 1, width: 1),
              ],
              Expanded(
                key: const ValueKey('adaptive-body'),
                // 桌面 acrylic 模式：用 Material 给 body 提供不透明背景
                // TopicsScreen 等页面没有自己的 Scaffold，
                // Material 和 Scaffold 内部是同一个组件，不会产生双层背景。
                // Material 必须**恒驻**(acrylic 与否只切颜色):acrylic 随
                // showRail 翻转(深层平行视界隐藏 Rail→退栈 Rail 回来),
                // 若按条件插拔 Material,body 链型变化会把整棵页面子树
                // (含平行视界容器/切换动画 State)连根重建——退栈动画
                // 直接丢失,只剩瞬切。
                child: Material(
                  type: useAcrylicRail
                      ? MaterialType.canvas
                      : MaterialType.transparency,
                  color: useAcrylicRail
                      ? Theme.of(context).colorScheme.surface
                      : null,
                  child: body,
                ),
              ),
            ],
          ),
          floatingActionButton: floatingActionButton,
          bottomNavigationBar: showRail || hideNavigationRail
              ? null
              : _AnimatedBottomNav(
                  selectedIndex: selectedIndex,
                  onDestinationSelected: onDestinationSelected,
                  destinations: destinations,
                  forceHidden: hideBottomNavigation,
                ),
        ),
        Positioned.fill(
          left: overlayLeftInset,
          child: const SidebarNotificationPanel(),
        ),
        // 分类侧栏：宿主挂本层 Stack 末位（盖得住底栏/FAB，被详情页
        // 路由天然遮挡）。打开方式：☰ / chips ＋ / 首页"全部"tab 整页
        // 右滑跟手拖出（TabBarView 首缘 overscroll 逐帧喂 dragBy，见
        // TopicsPage）。受控实现（非 DrawerController：其拖拽驱动是
        // 私有 API，做不了外部逐帧喂增量的跟手拖出）。
        ControlledCategoryDrawer(
          key: CategoryDrawerHost.drawerKey,
          onPinnedSelected: (category) {
            // 与 rail 的 CategoryShortcuts 同通路：首页监听
            // activeSidebarCategoryIdProvider 切分类 tab
            sidebarCategoryController.state = category.id;
            if (selectedIndex != 0) {
              onDestinationSelected(0);
            }
            ref.read(currentTabCategoryIdProvider.notifier).state = category.id;
          },
        ),
      ],
    );
  }
}

class _SidebarCategoryAddButton extends StatelessWidget {
  const _SidebarCategoryAddButton({
    required this.extended,
    required this.onOpenCategoryManager,
  });

  final bool extended;
  final Future<void> Function() onOpenCategoryManager;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onOpenCategoryManager,
          child: SizedBox(
            height: 56,
            child: extended
                ? Row(
                    children: [
                      const SizedBox(width: 16),
                      Icon(
                        Symbols.add_rounded,
                        color: Theme.of(context).colorScheme.primary,
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          context.l10n.category_editMyCategories,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                  )
                : Center(
                    child: Icon(
                      Symbols.add_rounded,
                      color: Theme.of(context).colorScheme.primary,
                      size: 22,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// 带动画的底部导航栏：随 [barVisibilityProvider] 整条平移出屏
/// （原生 Android HideBottomViewOnScrollBehavior 同款滑出式）。
///
/// watch 收在本组件内部 —— 首页收缩逐帧写 visibility 时只有这一个
/// 节点 rebuild，不再打穿 AdaptiveScaffold 整页（旧实现整个 Scaffold
/// 连带 IndexedStack 七个 tab 页顶层每帧 update）。FractionalTranslation
/// 是 paint 期平移：不改布局，Scaffold body 尺寸恒定，hit-test 跟随
/// 平移，滑出后不挡列表触摸。导航栏本体走 Consumer.child 稳定实例，
/// 每帧只更新平移量，子树零 diff。
class _AnimatedBottomNav extends StatelessWidget {
  const _AnimatedBottomNav({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    this.forceHidden = false,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<AdaptiveDestination> destinations;

  /// 投影态强制隐藏(平移出屏,paint-only,槽高不变零 relayout)。
  final bool forceHidden;

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, child) {
        final hideBarOnScroll = ref.watch(
          preferencesProvider.select((p) => p.hideBarOnScroll),
        );
        final barVisibility = ref.watch(barVisibilityProvider);
        // 首页开启滚动折叠时跟随进度；其他页恒显。barVisibility == 0.0
        // 是各页的"强制隐藏"通道（如书签工作台模式），任何 tab 都生效。
        final visibility =
            (selectedIndex == 0 && hideBarOnScroll) || barVisibility == 0.0
            ? barVisibility
            : 1.0;
        return FractionalTranslation(
          translation: Offset(0, 1.0 - visibility),
          child: child,
        );
      },
      // 外层只承担投影态的离散开合动画,滚动隐藏路径(内层逐帧平移)
      // 手感不变。
      child: AnimatedSlide(
        offset: Offset(0, forceHidden ? 1.0 : 0.0),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        child: AdaptiveBottomNavigation(
          selectedIndex: selectedIndex,
          onDestinationSelected: onDestinationSelected,
          destinations: destinations,
        ),
      ),
    );
  }
}
