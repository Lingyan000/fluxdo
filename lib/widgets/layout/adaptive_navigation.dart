import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../navigation/nav_action_bus.dart';
import '../../providers/preferences_provider.dart';
import '../../utils/platform_utils.dart';

/// 导航目标项配置
class AdaptiveDestination {
  const AdaptiveDestination({
    required this.id,
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  /// 稳定 id（home / profile / notifications / ...），用于 NavActionBus 定向派发
  /// 以及页面发布滚动进度到 [navScrollProgressProvider]。
  final String id;
  final Widget icon;
  final Widget selectedIcon;
  final String label;
}

/// 侧边导航栏组件 (平板/桌面)
/// 支持将最后 N 个导航项固定在底部
class AdaptiveNavigationRail extends StatelessWidget {
  const AdaptiveNavigationRail({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    this.categoryShortcuts,
    this.extended = false,
    this.leading,
    this.bottomLeading,
    this.topDestinationCount = 0,
    this.bottomDestinationCount = 1,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<AdaptiveDestination> destinations;
  final Widget? categoryShortcuts;
  final bool extended;
  final Widget? leading;

  /// 底部导航项上方的自定义组件
  final Widget? bottomLeading;

  /// 固定在顶部的导航项数量（从前往后算起）
  final int topDestinationCount;

  /// 固定在底部的导航项数量（从末尾算起）
  final int bottomDestinationCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDesktop = PlatformUtils.isDesktop;

    final safeTopCount = topDestinationCount.clamp(0, destinations.length);
    final remainingAfterTop = destinations.length - safeTopCount;
    final safeBottomCount = bottomDestinationCount.clamp(0, remainingAfterTop);
    final bottomStartIndex = destinations.length - safeBottomCount;
    final topDestinations = destinations.sublist(0, safeTopCount);
    // 既不在 top 也不在 bottom 的剩余项，渲染在 categoryShortcuts 下方、
    // bottomDestinations 上方（视觉上仍归属"底部分组"，只是排在底部分组之前）。
    // 当 topCount + bottomCount == destinations.length 时为空。
    final extraBottomDestinations = destinations.sublist(
      safeTopCount,
      bottomStartIndex,
    );
    final bottomDestinations = destinations.sublist(bottomStartIndex);

    Widget rail = SafeArea(
      child: SizedBox(
        width: extended ? 180 : 72,
        child: Column(
          children: [
            if (leading != null) ...[leading!, const SizedBox(height: 8)],
            const SizedBox(height: 16),
            // 顶部导航项
            ...topDestinations.asMap().entries.map((entry) {
              final index = entry.key;
              final dest = entry.value;
              final selected = index == selectedIndex;

              return _NavigationRailItem(
                icon: selected
                    ? _ActiveDestinationIcon(
                        dest: dest,
                        defaultIcon: dest.selectedIcon,
                      )
                    : dest.icon,
                label: dest.label,
                selected: selected,
                extended: extended,
                colorScheme: colorScheme,
                onTap: () => onDestinationSelected(index),
              );
            }),
            if (categoryShortcuts != null)
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(top: 4),
                  child: categoryShortcuts!,
                ),
              )
            else
              const Spacer(),
            if (bottomLeading != null) ...[
              bottomLeading!,
              const SizedBox(height: 8),
            ],
            ...extraBottomDestinations.asMap().entries.map((entry) {
              final index = entry.key + safeTopCount;
              final dest = entry.value;
              final selected = index == selectedIndex;

              return _NavigationRailItem(
                icon: selected
                    ? _ActiveDestinationIcon(
                        dest: dest,
                        defaultIcon: dest.selectedIcon,
                      )
                    : dest.icon,
                label: dest.label,
                selected: selected,
                extended: extended,
                colorScheme: colorScheme,
                onTap: () => onDestinationSelected(index),
              );
            }),
            // 底部导航项
            ...bottomDestinations.asMap().entries.map((entry) {
              final index = entry.key + bottomStartIndex;
              final dest = entry.value;
              final selected = index == selectedIndex;

              return _NavigationRailItem(
                icon: selected
                    ? _ActiveDestinationIcon(
                        dest: dest,
                        defaultIcon: dest.selectedIcon,
                      )
                    : dest.icon,
                label: dest.label,
                selected: selected,
                extended: extended,
                colorScheme: colorScheme,
                onTap: () => onDestinationSelected(index),
              );
            }),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );

    // 桌面平台：透明背景让窗口 acrylic 效果透出 + 拖动窗口
    if (isDesktop) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (_) => windowManager.startDragging(),
        child: rail,
      );
    }

    return rail;
  }
}

class _NavigationRailItem extends StatelessWidget {
  const _NavigationRailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.extended,
    required this.colorScheme,
    required this.onTap,
  });

  final Widget icon;
  final String label;
  final bool selected;
  final bool extended;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final backgroundColor = selected
        ? colorScheme.secondaryContainer
        : Colors.transparent;
    final iconColor = selected
        ? colorScheme.onSecondaryContainer
        : colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: SizedBox(
            height: 56,
            child: extended
                ? Row(
                    children: [
                      const SizedBox(width: 16),
                      IconTheme(
                        data: IconThemeData(color: iconColor, size: 24),
                        child: icon,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            color: iconColor,
                            fontWeight: selected
                                ? FontWeight.w500
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ],
                  )
                : Center(
                    child: IconTheme(
                      data: IconThemeData(color: iconColor, size: 24),
                      child: icon,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// 底部导航栏组件 (手机)
///
/// 手势分流：
/// - 未选中 tab：点击立即切换
/// - 已选中 tab：按用户偏好派发 [NavTapAction] 到 [navActionBusProvider]
///   - 单击动作非 none：第一次点击立即触发
///   - 双击动作非 none：300ms 内第二次点击触发（覆盖单击的后效）
///   - 两者都 none：无动作
class AdaptiveBottomNavigation extends ConsumerStatefulWidget {
  const AdaptiveBottomNavigation({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<AdaptiveDestination> destinations;

  @override
  ConsumerState<AdaptiveBottomNavigation> createState() =>
      _AdaptiveBottomNavigationState();
}

class _AdaptiveBottomNavigationState
    extends ConsumerState<AdaptiveBottomNavigation> {
  int? _lastActiveTapIndex;
  DateTime? _lastActiveTapTime;
  Timer? _pendingSingleTap;

  static const _doubleTapWindow = Duration(milliseconds: 300);

  @override
  void dispose() {
    _cancelPendingSingleTap();
    super.dispose();
  }

  void _cancelPendingSingleTap() {
    _pendingSingleTap?.cancel();
    _pendingSingleTap = null;
  }

  void _handleTap(int index) {
    // 未选中 tab：直接切换，重置所有待执行状态
    if (index != widget.selectedIndex) {
      _cancelPendingSingleTap();
      widget.onDestinationSelected(index);
      _lastActiveTapIndex = null;
      _lastActiveTapTime = null;
      return;
    }

    final prefs = ref.read(preferencesProvider);
    final single = prefs.bottomSingleTapAction;
    final doubleAction = prefs.bottomDoubleTapAction;

    final hasSingle = single != NavTapAction.none;
    final hasDouble = doubleAction != NavTapAction.none;
    if (!hasSingle && !hasDouble) return;

    final now = DateTime.now();
    final id = widget.destinations[index].id;

    // 判定是否为双击
    final isDouble =
        hasDouble &&
        _lastActiveTapIndex == index &&
        _lastActiveTapTime != null &&
        now.difference(_lastActiveTapTime!) < _doubleTapWindow;

    if (isDouble) {
      // 取消 pending 的单击（互斥：双击不叠加触发单击）
      _cancelPendingSingleTap();
      final navAction = doubleAction.toNavAction();
      if (navAction != null) {
        ref.dispatchNavAction(id, navAction);
      }
      _lastActiveTapIndex = null;
      _lastActiveTapTime = null;
      return;
    }

    // 第一次点击
    _lastActiveTapIndex = index;
    _lastActiveTapTime = now;

    if (!hasSingle) return; // 单击为 none：仅记录，等待第二次

    final navAction = single.toNavAction();
    if (navAction == null) return;

    // 双击也配了动作：延迟 300ms 触发单击，等待可能的第二次点击
    // 否则立即触发（零延迟模式）
    if (hasDouble) {
      _cancelPendingSingleTap();
      _pendingSingleTap = Timer(_doubleTapWindow, () {
        _pendingSingleTap = null;
        if (!mounted) return;
        ref.dispatchNavAction(id, navAction);
        if (_lastActiveTapIndex == index) {
          _lastActiveTapIndex = null;
          _lastActiveTapTime = null;
        }
      });
    } else {
      ref.dispatchNavAction(id, navAction);
    }
  }

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      selectedIndex: widget.selectedIndex,
      onDestinationSelected: _handleTap,
      destinations: widget.destinations.map((d) {
        return NavigationDestination(
          icon: d.icon,
          selectedIcon: _ActiveDestinationIcon(
            dest: d,
            defaultIcon: d.selectedIcon,
          ),
          label: d.label,
        );
      }).toList(),
    );
  }
}

/// 已选中 tab 的动态图标
///
/// 根据 [navScrollProgressProvider] 和用户配置的 [NavTapAction] 决定显示：
/// - 距顶 < 阈值 或 单击动作为 none 或 动作无对应图标 → 显示默认 selectedIcon
/// - 距顶 ≥ [navScrollIconThreshold] → 显示单击动作对应的反馈图标
///
/// 这样用户滚到深处后就能"预览"单击会发生什么，符合 Twitter/Telegram 的交互惯例。
/// 只应放在 NavigationBar 的 selectedIcon 位置（或侧栏 selected 状态下）。
class _ActiveDestinationIcon extends ConsumerWidget {
  const _ActiveDestinationIcon({required this.dest, required this.defaultIcon});

  final AdaptiveDestination dest;
  final Widget defaultIcon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(navScrollProgressProvider(dest.id));
    final action = ref.watch(
      preferencesProvider.select((p) => p.bottomSingleTapAction),
    );

    final actionIcon = action.icon;
    final showActionIcon =
        progress >= navScrollIconThreshold &&
        action != NavTapAction.none &&
        actionIcon != null;

    final child = showActionIcon
        ? Icon(actionIcon, key: ValueKey('nav-action-${action.name}'))
        : KeyedSubtree(key: const ValueKey('nav-default'), child: defaultIcon);

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (c, anim) => FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.7, end: 1.0).animate(anim),
          child: c,
        ),
      ),
      child: child,
    );
  }
}
