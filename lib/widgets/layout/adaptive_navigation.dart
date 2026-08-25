import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:window_manager/window_manager.dart';

import '../../navigation/nav_action_bus.dart';
import '../../providers/preferences_provider.dart';
import '../../utils/blur_config.dart';
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
    final labelless = ref.watch(
      preferencesProvider.select((p) => p.bottomNavLabelless),
    );
    final floating = ref.watch(
      preferencesProvider.select((p) => p.bottomNavFloating),
    );
    final floatingBlur = ref.watch(
      preferencesProvider.select((p) => p.bottomNavFloatingBlur),
    );

    // 悬浮胶囊：自绘条目布局。M3 的「未选中图标居中、标签下垂」两段式
    // 结构在紧凑胶囊高度下必然失衡，改为压实的图标+标签整体。
    if (floating) {
      final itemHeight = _CapsuleMetrics.itemHeight(
        context,
        labelless: labelless,
      );
      return _FloatingBottomBarShell(
        itemHeight: itemHeight,
        blur: floatingBlur,
        itemCount: widget.destinations.length,
        child: _CapsuleNavBar(
          selectedIndex: widget.selectedIndex,
          onDestinationSelected: _handleTap,
          destinations: widget.destinations,
          labelless: labelless,
          itemHeight: itemHeight,
        ),
      );
    }

    return NavigationBar(
      selectedIndex: widget.selectedIndex,
      onDestinationSelected: _handleTap,
      // 无字模式：只留图标，槽高从默认 80 收到 56
      //（M3 无标签态规范高：图标 24 + 上下各 16）
      height: labelless ? 56 : null,
      labelBehavior: labelless
          ? NavigationDestinationLabelBehavior.alwaysHide
          : null,
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

/// 悬浮胶囊底栏的全部几何规格。
///
/// 收在一处而非散落于各组件：这些值互相咬合（槽宽由 item 高派生、胶囊高
/// 由 item 高 + 内边距派生、圆角由胶囊高派生），分散定义时改一个必漏其余。
///
/// 取值来源：
/// - 基准 [itemHeightLabeled] = 48，比 Telegram 双端的 56 紧凑。实测参考
///   设计（1200px 截图，dpr 2.75）量得选中 pill 高 98px ≈ 36dp、图标与
///   标签压在其中上下几乎不留白 —— 悬浮形态的关键是「压实」。
///   48 = 上 4 + 图标 24 + 间距 1 + 标签行高 ~13 + 下 4。
/// - 外边距/内边距对齐 Telegram（iOS `TabBarComponent` innerInset 4、
///   sideInset 12；Android `MainTabsActivity` inset ≈4、距导航栏 8）。
abstract final class _CapsuleMetrics {
  /// 带字态 item 基准高
  static const double itemHeightLabeled = 48;

  /// 无字态 item 高（图标 24 + 上下各 8，收成接近正圆的选中 pill）
  static const double itemHeightLabelless = 40;

  /// 图标尺寸（与既有 Rail / NavigationBar 同轴）
  static const double iconSize = 24;

  /// 图标区距 item 顶部的偏移
  static const double iconTop = 4;

  /// 图标底边到标签顶边的间距。参考设计与 TG 两端都近乎贴合
  /// （TG iOS ~3 / Android ~0.33），「压实的一坨」是这套视觉语言的关键，
  /// 不能按 M3 的舒展间距给。
  static const double iconGap = 1;

  /// 标签距 item 底部的留白
  static const double labelBottom = 4;

  /// 标签字号。TG iOS 10 semibold / Android 12 medium，取 11
  /// 兼顾中文标签可读性与紧凑高度。
  static const double labelSize = 11;

  /// 标签行高倍数
  static const double labelHeight = 1.2;

  /// 胶囊内容四周留白（TG iOS innerInset 4 / Android inset ≈4）
  static const double innerInset = 4;

  /// 槽宽 / item 高的比例。槽宽由高派生而非独立常量：选中 pill 铺满整个
  /// 槽位，一旦两者脱钩，改高就会让 pill 的胖瘦比例漂移。
  ///
  /// 1.6 取自实测参考设计（pill 213×98 物理像素 ≈ 77×36dp，比例 2.14）
  /// 与 M3 槽位（72×80，比例 0.9）之间：前者标签在 pill 外故可以很扁，
  /// 本实现 pill 含标签，取 1.6 让胶囊不至于过宽。
  static const double slotAspect = 1.6;

  /// 槽宽下限：中文两字标签（字号 11）约 22 宽，加左右各 6 呼吸位。
  /// 无字态按比例算出的槽宽会偏窄，这里兜底。
  static const double minSlotWidth = 56;

  /// 胶囊距屏幕左右边缘的最小外边距（TG iOS sideInset 12）
  static const double outerMargin = 12;

  /// 胶囊距屏幕底缘的外边距（TG 双端一致 8）
  static const double bottomMargin = 8;

  /// 胶囊最大宽度。宽屏（平板竖屏 / 折叠展开）不拉满，
  /// 取 TG iOS 500 与 Android 344 的中间档。
  static const double maxWidth = 420;

  /// 单个条目的高度。
  ///
  /// 带字态随文字缩放上浮：[labelSize] 在极大字体设置下会顶破固定高度
  /// （图标区 + 标签的自然高超过基准就会溢出裁字），因此按缩放后的标签
  /// 行高补偿。缩放 ≤1 时恒为基准值，不影响默认观感。
  static double itemHeight(BuildContext context, {required bool labelless}) {
    if (labelless) return itemHeightLabelless;
    final scaled = MediaQuery.textScalerOf(
      context,
    ).scale(labelSize * labelHeight);
    final natural = iconTop + iconSize + iconGap + scaled + labelBottom;
    return math.max(itemHeightLabeled, natural);
  }

  /// 槽宽：随 item 高等比缩放，改高时 pill 的胖瘦比例保持不变。
  static double slotWidth(double itemHeight) =>
      math.max(itemHeight * slotAspect, minSlotWidth);
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

/// 悬浮底栏外壳：宽度随入口数量自适应的胶囊，悬浮于内容之上（Scaffold
/// 已 extendBody，内容从胶囊后面透出）。
///
/// 几何全部取自 [_CapsuleMetrics]（对齐 Telegram 双端：iOS
/// `TabBarComponent` / Android `MainTabsActivity` +
/// `BlurredBackgroundProviderImpl.mainTabs`）：
/// - 胶囊高 = item 高 + 内边距 ×2，圆角 = 全高一半（stadium）
/// - 槽宽 = item 高 × [_CapsuleMetrics.slotAspect]：与高绑定，
///   改高时选中 pill 的胖瘦比例不漂移
/// - 左右/底部外边距见 [_CapsuleMetrics.outerMargin] / `bottomMargin`
/// - 最大宽 [_CapsuleMetrics.maxWidth]：宽屏不铺满，居中悬浮
/// - 描边 0.4，上浅下深（模拟玻璃边缘的受光差）
/// - 阴影极柔：blur 24 / 黑 6%，offset (0,2)。TG 的影子几乎不可见
///   （iOS 黑 4%），重影会让胶囊显得「贴纸」而非「悬浮」
///
/// 安全区由外层 SafeArea 统一承担（留白在胶囊之外），内部不再嵌套
/// 任何会消费底部 padding 的组件。
class _FloatingBottomBarShell extends StatelessWidget {
  const _FloatingBottomBarShell({
    required this.itemHeight,
    required this.blur,
    required this.itemCount,
    required this.child,
  });

  /// 单个条目高度（胶囊高 = 本值 + [_CapsuleMetrics.innerInset] × 2）
  final double itemHeight;

  /// 毛玻璃模糊开关
  final bool blur;

  /// 入口数量（自适应宽度的基准）
  final int itemCount;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final barHeight = itemHeight + _CapsuleMetrics.innerInset * 2;
    final radius = barHeight / 2;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );

    // 内容留白（最内层，玻璃/实色两种底色共用）
    final content = Padding(
      padding: const EdgeInsets.all(_CapsuleMetrics.innerInset),
      child: child,
    );

    // 模糊开：BackdropFilter + 半透明底色透出内容；模糊关：实色胶囊。
    // 底色不透明度取 TG Android mainTabs（液态玻璃 0.85 / 关闭 0.76）。
    final body = blur
        ? BackdropFilter(
            filter: createBlurFilter(blurSigma),
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: shape,
                color: scheme.surfaceContainer.withValues(alpha: 0.82),
              ),
              child: content,
            ),
          )
        : DecoratedBox(
            decoration: ShapeDecoration(
              shape: shape,
              color: scheme.surfaceContainer,
            ),
            child: content,
          );

    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = math.min(
            constraints.maxWidth - _CapsuleMetrics.outerMargin * 2,
            _CapsuleMetrics.maxWidth,
          );
          // 槽宽随 item 高等比缩放：改高时 pill 的胖瘦比例保持不变
          final slotWidth = _CapsuleMetrics.slotWidth(itemHeight);
          final width = math.min(
            slotWidth * itemCount + _CapsuleMetrics.innerInset * 2,
            maxWidth,
          );
          return Padding(
            padding: const EdgeInsets.only(bottom: _CapsuleMetrics.bottomMargin),
            child: Align(
              // 槽位约束是 looseConstraints.tighten(width)：maxHeight 几乎
              // 是整个页面高，Expand 类组件（Center）会把胶囊顶到屏幕中间。
              // heightFactor 收缩到子组件高度，多余空间一律贴底。
              alignment: Alignment.bottomCenter,
              heightFactor: 1.0,
              child: SizedBox(
                width: width,
                // 投影放在模糊层之外：玻璃下的内容清晰穿透，影子独立柔和
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    shape: shape,
                    shadows: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: isDark ? 0.18 : 0.06,
                        ),
                        blurRadius: 24,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(radius),
                    // 描边画在裁切之内（最上层）：0.4 宽的边如果落在
                    // ClipRRect 外侧会被抗锯齿吃掉半条，看着忽隐忽现
                    child: Stack(
                      fit: StackFit.passthrough,
                      children: [
                        body,
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _CapsuleBorderPainter(
                                radius: radius,
                                isDark: isDark,
                              ),
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
        },
      ),
    );
  }
}

/// 胶囊描边：上浅下深的单像素级细边。
///
/// TG Android `BlurredBackgroundProviderImpl.mainTabs` 用两个色分别画上下
/// 边（浅色 top 黑 6.7% / bottom 黑 12.5%，深色 top 白 2.4% / bottom 白
/// 6.7%），模拟玻璃边缘的受光差。这里用一条垂直渐变描边等价表达。
///
/// 不用 `scheme.outline`：那是中灰色，压在半透明玻璃上会显脏；TG 两端都
/// 是纯黑/纯白低透明度。
class _CapsuleBorderPainter extends CustomPainter {
  const _CapsuleBorderPainter({required this.radius, required this.isDark});

  final double radius;
  final bool isDark;

  static const double _width = 0.4;

  @override
  void paint(Canvas canvas, Size size) {
    // 描边以路径为中心线各占一半，内缩半个宽度才能整条落在胶囊内
    final rect = Offset.zero & size;
    final inner = rect.deflate(_width / 2);
    final rrect = RRect.fromRectAndRadius(
      inner,
      Radius.circular(radius - _width / 2),
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _width
      ..shader = ui.Gradient.linear(
        Offset(inner.center.dx, inner.top),
        Offset(inner.center.dx, inner.bottom),
        isDark
            ? [
                const Color(0x0AFFFFFF),
                const Color(0x14FFFFFF),
              ]
            : [
                const Color(0x11000000),
                const Color(0x20000000),
              ],
      );
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(_CapsuleBorderPainter old) =>
      old.radius != radius || old.isDark != isDark;
}

/// 悬浮胶囊底栏的条目区：图标+标签压实成一组，选中指示 pill 在槽位之间
/// 弹簧滑动。
///
/// 选中表达取 Telegram 双端实测的共识（与 M3 相反）：
/// - pill **铺满整个条目**（含标签），圆角 = 半高的 stadium；M3 是只包
///   图标的 64×32 短胶囊 + 标签垂在胶囊外下方
/// - pill 填充是**强调色 ~9% 的极淡底**（iOS 降级态黑 7.5%/白 10%，
///   Android `multAlpha(tabSelected, 0.09)`）；M3 是不透明 secondaryContainer
///
/// pill 不做入场缩放：Android 的 60%→100% 缩放属于「每个 tab 自绘 pill
/// 从无到有」那套机制，而滑动共享 pill（长按拖拽模式）只插值位置/宽度。
/// 两者叠加会让 pill 在飞行途中先缩后涨，与弹簧滑动打架。
///
/// 手势语义（单击/双击已选中项的动作派发）由调用方的
/// [onDestinationSelected] 承载，与贴底 NavigationBar 完全一致。
class _CapsuleNavBar extends StatefulWidget {
  const _CapsuleNavBar({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    required this.labelless,
    required this.itemHeight,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<AdaptiveDestination> destinations;
  final bool labelless;
  final double itemHeight;

  @override
  State<_CapsuleNavBar> createState() => _CapsuleNavBarState();
}

class _CapsuleNavBarState extends State<_CapsuleNavBar>
    with SingleTickerProviderStateMixin {
  /// pill 位置（以槽位序号为单位的连续值），弹簧驱动
  late final AnimationController _position;

  static final SpringDescription _spring = M3eMotion.fastSpatial.description;

  @override
  void initState() {
    super.initState();
    _position = AnimationController.unbounded(vsync: this)
      ..value = widget.selectedIndex.toDouble();
  }

  @override
  void didUpdateWidget(_CapsuleNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedIndex != oldWidget.selectedIndex) {
      if (M3eFlags.of(context).enabled) {
        _position.animateWith(
          SpringSimulation(
            _spring,
            _position.value,
            widget.selectedIndex.toDouble(),
            0,
          ),
        );
      } else {
        _position.animateTo(
          widget.selectedIndex.toDouble(),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = widget.destinations.length;

    // pill 底色：强调色 9% 淡底。TG Android 用 multAlpha(tabSelected, 0.09)，
    // iOS 降级态用中性黑/白低透明度 —— 取前者，选中项与主题强调色同源。
    final pillColor = scheme.primary.withValues(alpha: 0.11);

    return Semantics(
      role: ui.SemanticsRole.tabBar,
      explicitChildNodes: true,
      container: true,
      child: SizedBox(
        height: widget.itemHeight,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final slot = constraints.maxWidth / count;
            return Stack(
              children: [
                // 滑动选中 pill：铺满整个条目槽位，位置弹簧插值
                AnimatedBuilder(
                  animation: _position,
                  builder: (context, _) {
                    // 入口增删导致越界时收敛到有效区间
                    final pos = _position.value.clamp(
                      0.0,
                      (count - 1).toDouble(),
                    );
                    return Positioned(
                      left: slot * pos,
                      top: 0,
                      width: slot,
                      height: widget.itemHeight,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: ShapeDecoration(
                            color: pillColor,
                            shape: const StadiumBorder(),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                // 条目行：Material 提供 InkWell 的墨水画布
                Material(
                  type: MaterialType.transparency,
                  child: Row(
                    children: [
                      for (var i = 0; i < count; i++)
                        Expanded(
                          child: _CapsuleNavItem(
                            dest: widget.destinations[i],
                            selected: i == widget.selectedIndex,
                            labelless: widget.labelless,
                            onTap: () => widget.onDestinationSelected(i),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 胶囊底栏的单个条目：图标顶对齐 + 标签贴底，压实成一组。
///
/// 排布取 Telegram 双端（iOS 图标 y=3 / 文字距底 8；Android 图标顶 4 /
/// 文字顶 28.33）：**不是** M3 的「图标在 pill 内居中、标签下垂」两段式，
/// 而是整组紧凑地占满条目高度。
class _CapsuleNavItem extends StatelessWidget {
  const _CapsuleNavItem({
    required this.dest,
    required this.selected,
    required this.labelless,
    required this.onTap,
  });

  final AdaptiveDestination dest;
  final bool selected;
  final bool labelless;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 选中只切一个色轴（TG 两端共识：图标不换 filled、字重变化很轻），
    // 选中态用强调色与 pill 淡底同源。
    final iconColor = selected ? scheme.primary : scheme.onSurfaceVariant;

    final icon = IconTheme(
      data: IconThemeData(color: iconColor, size: _CapsuleMetrics.iconSize),
      child: selected
          ? _ActiveDestinationIcon(dest: dest, defaultIcon: dest.selectedIcon)
          : dest.icon,
    );

    return Semantics(
      // tabBar 容器要求每个子节点都是 tab role，缺了会在 debug 下
      // 直接抛「Children of TabBar must have the tab role」
      role: ui.SemanticsRole.tab,
      selected: selected,
      child: Tooltip(
        message: dest.label,
        child: InkWell(
          // 墨水跟随 pill 的 stadium 造型（pill 铺满整个条目）
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: labelless
              // 无字态：图标在条目内居中
              ? Center(child: icon)
              : Padding(
                  padding: const EdgeInsets.only(
                    top: _CapsuleMetrics.iconTop,
                    bottom: _CapsuleMetrics.labelBottom,
                  ),
                  child: Column(
                    children: [
                      SizedBox(height: _CapsuleMetrics.iconSize, child: icon),
                      const SizedBox(height: _CapsuleMetrics.iconGap),
                      // 标签占满剩余高度并在其中居中：字体放大时
                      // _CapsuleMetrics.itemHeight 已同步上浮，这里不会溢出
                      Expanded(
                        child: Center(
                          child: Text(
                            dest.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: _CapsuleMetrics.labelSize,
                              height: _CapsuleMetrics.labelHeight,
                              color: iconColor,
                              // 中文字重只差一档：选中 w600 / 未选中 w500
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
