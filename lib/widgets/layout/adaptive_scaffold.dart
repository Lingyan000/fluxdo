import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../pages/topics_page.dart';
import '../../providers/category_provider.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/topic_list/tab_state_provider.dart';
import '../../utils/responsive.dart';
import '../../l10n/s.dart';
import '../notification/notification_quick_panel.dart';
import 'adaptive_navigation.dart';
import 'category_shortcuts.dart';
import '../topic/category_tab_manager_sheet.dart';

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
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<AdaptiveDestination> destinations;
  final Widget body;
  final Widget? floatingActionButton;
  final Widget? railLeading;
  final Widget? railBottomLeading;
  final bool extendedRail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showRail = Responsive.showNavigationRail(context);
    final sidebarCategoryController = ref.read(
      activeSidebarCategoryIdProvider.notifier,
    );
    final activeSidebarCategoryId = ref.watch(activeSidebarCategoryIdProvider);
    final railSelectedIndex =
        activeSidebarCategoryId != null && selectedIndex == 0
        ? -1
        : selectedIndex;

    // 始终 watch barVisibilityProvider，避免条件 watch 导致 Riverpod 行为不一致
    final hideBarOnScroll = ref.watch(
      preferencesProvider.select((p) => p.hideBarOnScroll),
    );
    final visibility = (selectedIndex == 0 && hideBarOnScroll)
        ? ref.watch(barVisibilityProvider)
        : 1.0;

    final hasAcrylic = Platform.isMacOS || Platform.isWindows;
    final useAcrylicRail = showRail && hasAcrylic;
    final railWidth = extendedRail ? 180.0 : 72.0;
    final overlayLeftInset = showRail
        ? railWidth + (useAcrylicRail ? 0.0 : 1.0)
        : 0.0;

    return Stack(
      children: [
        Scaffold(
          backgroundColor: useAcrylicRail ? Colors.transparent : null,
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
                  categoryShortcuts: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CategoryShortcuts(
                        extended: extendedRail,
                        onCategorySelected: (categoryId) {
                          sidebarCategoryController.state = categoryId;
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
                  bottomLeading: _SidebarBottomActions(
                    child: railBottomLeading,
                  ),
                ),
                if (!useAcrylicRail)
                  const VerticalDivider(thickness: 1, width: 1),
              ],
              Expanded(
                key: const ValueKey('adaptive-body'),
                // 桌面 acrylic 模式：用 Material 给 body 提供不透明背景
                // TopicsScreen 等页面没有自己的 Scaffold，
                // Material 和 Scaffold 内部是同一个组件，不会产生双层背景
                child: useAcrylicRail
                    ? Material(
                        color: Theme.of(context).colorScheme.surface,
                        child: body,
                      )
                    : body,
              ),
            ],
          ),
          floatingActionButton: floatingActionButton,
          bottomNavigationBar: showRail
              ? null
              : _AnimatedBottomNav(
                  visibility: visibility,
                  selectedIndex: selectedIndex,
                  onDestinationSelected: onDestinationSelected,
                  destinations: destinations,
                ),
        ),
        Positioned.fill(
          left: overlayLeftInset,
          child: const SidebarNotificationPanel(),
        ),
      ],
    );
  }
}

class _SidebarBottomActions extends StatelessWidget {
  const _SidebarBottomActions({this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [if (child != null) child!],
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
                        Icons.add_rounded,
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
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                  )
                : Center(
                    child: Icon(
                      Icons.add_rounded,
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

/// 带动画的底部导航栏
class _AnimatedBottomNav extends StatelessWidget {
  const _AnimatedBottomNav({
    required this.visibility,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });

  final double visibility;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<AdaptiveDestination> destinations;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: visibility,
        child: Opacity(
          opacity: visibility,
          child: AdaptiveBottomNavigation(
            selectedIndex: selectedIndex,
            onDestinationSelected: onDestinationSelected,
            destinations: destinations,
          ),
        ),
      ),
    );
  }
}
