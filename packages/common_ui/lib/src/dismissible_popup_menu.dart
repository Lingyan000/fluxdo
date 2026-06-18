import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

// ============================================================
// 以下常量和私有类复制自 Flutter popup_menu.dart，
// 因为内部类 (_PopupMenuRoute 等) 不可访问，必须复制才能自定义 barrier 行为。
// ============================================================

// 菜单开合:统一用"弹簧弹入 + 快速淡入",短促 + 有物理反馈。
const Duration _kMenuDuration = Duration(milliseconds: 160);
const double _kMenuCloseIntervalEnd = 2.0 / 3.0;
const double _kMenuMaxWidth = 5.0 * _kMenuWidthStep;
const double _kMenuMinWidth = 2.0 * _kMenuWidthStep;
const double _kMenuWidthStep = 56.0;
const double _kMenuScreenPadding = 8.0;

// 菜单顶部圆形快捷按钮配置。
class MenuQuickAction {
  const MenuQuickAction({
    required this.icon,
    this.onTap,
    this.tooltip,
    this.enabled = true,
    this.active = false,
    this.submenu,
  }) : assert(onTap != null || submenu != null, 'onTap 和 submenu 至少要提供一个');

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool enabled;
  final bool active;

  /// 提供时,点击按钮会从按钮位置长大一个子面板,子项被点击时调用其 onTap。
  final MenuQuickActionSubmenu? submenu;
}

class MenuQuickActionSubmenu {
  const MenuQuickActionSubmenu({
    required this.icon,
    required this.label,
    required this.children,
    this.iconColor,
    this.labelColor,
  });

  final IconData icon;
  final String label;
  final List<MenuQuickActionSubmenuChild> children;
  final Color? iconColor;
  final Color? labelColor;
}

class MenuQuickActionSubmenuChild {
  const MenuQuickActionSubmenuChild({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? subtitle;
  final bool selected;
}

// 顶部圆形快捷按钮条。
class _QuickActionsHeader extends StatelessWidget {
  const _QuickActionsHeader({required this.actions, required this.onAfterTap});

  final List<MenuQuickAction> actions;
  final VoidCallback onAfterTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < actions.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            _QuickActionButton(
              action: actions[i],
              activeColor: cs.primaryContainer,
              inactiveColor: cs.surfaceContainerHighest,
              activeIconColor: cs.onPrimaryContainer,
              inactiveIconColor: cs.onSurface,
              onAfterTap: onAfterTap,
            ),
          ],
        ],
      ),
    );
  }
}

class _QuickActionButton extends StatelessWidget {
  const _QuickActionButton({
    required this.action,
    required this.activeColor,
    required this.inactiveColor,
    required this.activeIconColor,
    required this.inactiveIconColor,
    required this.onAfterTap,
  });

  final MenuQuickAction action;
  final Color activeColor;
  final Color inactiveColor;
  final Color activeIconColor;
  final Color inactiveIconColor;
  final VoidCallback onAfterTap;

  Future<void> _openSubmenu(BuildContext context) async {
    final submenu = action.submenu!;
    await showAnchoredSubmenu(
      context: context,
      icon: submenu.icon,
      label: submenu.label,
      iconColor: submenu.iconColor,
      labelColor: submenu.labelColor,
      children: submenu.children,
      onSelected: (cb) {
        onAfterTap();
        cb();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool hasSubmenu = action.submenu != null;
    final bool enabled = action.enabled && (action.onTap != null || hasSubmenu);
    final Color bg = action.active ? activeColor : inactiveColor;
    final Color fg = action.active ? activeIconColor : inactiveIconColor;
    final Widget button = Material(
      color: bg,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled
            ? () {
                if (hasSubmenu) {
                  _openSubmenu(context);
                } else {
                  onAfterTap();
                  action.onTap!();
                }
              }
            : null,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            action.icon,
            size: 20,
            color: enabled ? fg : fg.withValues(alpha: 0.38),
          ),
        ),
      ),
    );
    if (action.tooltip != null) {
      return Tooltip(message: action.tooltip!, child: button);
    }
    return button;
  }
}

// ============================================================
// 可展开菜单项：点击 entry → 推送子菜单 PopupRoute（hero 飞出 header）；
// 原 menu 同时缩放 + 蒙层降级为背景。子项点击关闭外层 menu 并返回 value。
// 多个 entry 共享 [_MenuExpansionController]，保证同时只展开一个。
// ============================================================

class _MenuExpansionController extends ChangeNotifier {
  Object? _activeId;
  bool _disposed = false;

  Object? get activeId => _activeId;

  bool get isAnyActive => _activeId != null;

  bool isActive(Object id) => _activeId == id;

  void open(Object id) {
    if (_disposed || _activeId == id) return;
    _activeId = id;
    notifyListeners();
  }

  void close(Object id) {
    // 整链一次性关闭时,外层菜单可能已先于子面板被销毁,这里要容忍释放后调用。
    if (_disposed || _activeId != id) return;
    _activeId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _MenuExpansionScope extends InheritedNotifier<_MenuExpansionController> {
  const _MenuExpansionScope({
    required _MenuExpansionController controller,
    required super.child,
  }) : super(notifier: controller);

  static _MenuExpansionController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_MenuExpansionScope>()
      ?.notifier;
}

/// 标记:属于同一条"弹出菜单链"的 route(外层菜单 + 各级子面板)。
/// 点击/滑动 barrier 时,沿这个标记把整条链一次性全部关闭,而不是逐层关。
mixin _MenuChainRoute<T> on PopupRoute<T> {
  /// 紧邻其下方的同链 route(子面板指向其父菜单)。用于整链关闭时找到下层。
  _MenuChainRoute<dynamic>? belowChainRoute;
}

/// 关闭当前 Navigator 顶部的整条菜单链:**只让最顶层这一个 route 播放关闭动画**
/// (缩回它的触发点),下方的菜单 route 无动画即时移除 —— 这样整条链是作为
/// 一个整体收起,而不是每层各放各的关闭动画。
void _dismissMenuChain(BuildContext context) {
  final NavigatorState navigator = Navigator.of(context);
  final ModalRoute<dynamic>? top = ModalRoute.of(context);
  if (top is! _MenuChainRoute) {
    navigator.pop();
    return;
  }
  // 收集顶层下方的所有同链 route。
  final List<Route<dynamic>> below = <Route<dynamic>>[];
  _MenuChainRoute<dynamic>? cur = top.belowChainRoute;
  while (cur != null) {
    below.add(cur as Route<dynamic>);
    cur = cur.belowChainRoute;
  }
  // 下层即时移除(无动画),只保留顶层做关闭动画。
  for (final Route<dynamic> route in below) {
    if (route.isActive) navigator.removeRoute(route);
  }
  navigator.pop();
}

/// 菜单的开合动画:从触发它的位置 [alignment] 处缩放生长/收回(配合淡入淡出)。
/// [alignment] 是触发点相对菜单自身的对齐点(pivot),由各 route 按位置动态算出,
/// 所以菜单看起来是"从按钮长出来 / 缩回按钮里去",方向随位置变化。
class _MenuPopTransition extends StatefulWidget {
  const _MenuPopTransition({
    required this.animation,
    required this.alignment,
    required this.child,
  });

  final Animation<double> animation;
  final Alignment alignment;
  final Widget child;

  @override
  State<_MenuPopTransition> createState() => _MenuPopTransitionState();
}

class _MenuPopTransitionState extends State<_MenuPopTransition> {
  late final CurvedAnimation _scale;
  late final CurvedAnimation _fade;

  @override
  void initState() {
    super.initState();
    // 开:减速到位(easeOutCubic);关:加速收回(easeInCubic)。
    _scale = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    // 淡入比缩放更早完成,淡出更晚开始,让"实体感"集中在中段。
    _fade = CurvedAnimation(
      parent: widget.animation,
      curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
      reverseCurve: const Interval(0.3, 1.0, curve: Curves.easeIn),
    );
  }

  @override
  void dispose() {
    _scale.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: ScaleTransition(
        scale: _scale,
        alignment: widget.alignment,
        child: widget.child,
      ),
    );
  }
}

/// 可展开的菜单项。点击后推送一个子面板，hero 动画把 header 飞过去；
/// 子项被点击时关闭整链并把外层菜单的结果设为该子项 value。
class ExpandablePopupMenuEntry<T> extends PopupMenuEntry<T> {
  const ExpandablePopupMenuEntry({
    super.key,
    required this.icon,
    required this.label,
    required this.children,
    this.iconColor,
    this.labelColor,
  });

  final IconData icon;
  final String label;
  final List<ExpandableMenuChild<T>> children;
  final Color? iconColor;
  final Color? labelColor;

  @override
  double get height => kMinInteractiveDimension;

  @override
  bool represents(T? value) => children.any((c) => c.value == value);

  @override
  State<ExpandablePopupMenuEntry<T>> createState() =>
      _ExpandablePopupMenuEntryState<T>();
}

class ExpandableMenuChild<T> {
  const ExpandableMenuChild({
    required this.value,
    required this.icon,
    required this.label,
    this.subtitle,
    this.selected = false,
  });

  final T value;
  final IconData icon;
  final String label;
  final String? subtitle;
  final bool selected;
}

class _ExpandablePopupMenuEntryState<T>
    extends State<ExpandablePopupMenuEntry<T>> {
  Future<void> _openSubmenu(BuildContext context) async {
    final NavigatorState navigator = Navigator.of(context);
    T? selectedValue;
    await showAnchoredSubmenu(
      context: context,
      icon: widget.icon,
      label: widget.label,
      iconColor: widget.iconColor,
      labelColor: widget.labelColor,
      children: [
        for (final child in widget.children)
          MenuQuickActionSubmenuChild(
            icon: child.icon,
            label: child.label,
            subtitle: child.subtitle,
            selected: child.selected,
            onTap: () => selectedValue = child.value,
          ),
      ],
      // entry 模式:选中后由 _ExpandablePopupMenuEntryState 自己 pop 外层菜单,
      // 这里只暂存值,不立刻调用,以免与外层 pop 顺序冲突。
      onSelected: (cb) => cb(),
    );
    if (selectedValue != null && navigator.mounted) {
      navigator.pop<T>(selectedValue);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    // 不再隐藏 entry,让用户看到 panel 从 entry 位置长大盖住它。
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => _openSubmenu(context),
        child: _ExpandableHeader(
          icon: widget.icon,
          label: widget.label,
          iconColor: widget.iconColor ?? cs.onSurface,
          labelColor: widget.labelColor ?? cs.onSurface,
        ),
      ),
    );
  }
}

class _ExpandableHeader extends StatelessWidget {
  const _ExpandableHeader({
    required this.icon,
    required this.label,
    required this.iconColor,
    required this.labelColor,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final Color iconColor;
  final Color labelColor;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: iconColor),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(color: labelColor),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

class _SubmenuRowTile extends StatelessWidget {
  const _SubmenuRowTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final Color fg = selected ? cs.primary : cs.onSurface;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: fg),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: fg,
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (selected) Icon(Icons.check, size: 18, color: cs.primary),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// Submenu route：以 PopupRoute 形式打开,带 hero 接收。
// ============================================================

class _SubmenuRoute extends PopupRoute<void> with _MenuChainRoute<void> {
  _SubmenuRoute({
    required this.icon,
    required this.label,
    required this.iconColor,
    required this.labelColor,
    required this.tiles,
    required this.capturedThemes,
    this.anchor,
  });

  final IconData icon;
  final String label;
  final Color? iconColor;
  final Color? labelColor;
  final List<Widget> tiles;
  final CapturedThemes capturedThemes;
  final Rect? anchor;

  @override
  Color? get barrierColor => null;
  // barrier 由 buildPage 自行处理:点空白处整链一次性关闭(支持 tap + 垂直滑动)。
  @override
  bool get barrierDismissible => false;
  @override
  String get barrierLabel => 'submenu';
  @override
  Duration get transitionDuration => const Duration(milliseconds: 160);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 120);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final PopupMenuThemeData popupMenuTheme = PopupMenuTheme.of(context);
    final ShapeBorder shape =
        popupMenuTheme.shape ??
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(20));

    final Widget panelContent = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: () => Navigator.of(context).maybePop(),
            child: _ExpandableHeader(
              icon: icon,
              label: label,
              iconColor: iconColor ?? cs.onSurface,
              labelColor: labelColor ?? cs.onSurface,
              trailing: Icon(
                Icons.keyboard_arrow_up,
                size: 20,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        ),
        Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.4)),
        ...tiles,
        const SizedBox(height: 4),
      ],
    );

    return capturedThemes.wrap(
      // 注意:anchor 用的是相对 overlay(含状态栏)的全局坐标,下面的 Positioned
      // 必须用同一套坐标系。这里不能套 SafeArea —— 它会把原点下移一个状态栏
      // 高度,导致移动端子面板整体下移、盖不住 header 那一行(PC 无状态栏故正常)。
      // 改为手动用安全区 insets 做上下边界保护。
      LayoutBuilder(
        builder: (context, constraints) {
          final Size screen = constraints.biggest;
          final EdgeInsets safeInsets = MediaQuery.paddingOf(context);
          const double maxPanelWidth = 340;
          const double minPanelWidth = 240;
          const double screenPadding = 12;

          double targetWidth = anchor?.width ?? minPanelWidth;
          targetWidth = targetWidth.clamp(minPanelWidth, maxPanelWidth);

          // 估算最终高度（header + 子项 + 一点 padding）。
          final double estimatedHeight =
              kMinInteractiveDimension + tiles.length * 60 + 12;

          double targetLeft = anchor?.left ?? (screen.width - targetWidth) / 2;
          // panel 顶部比 entry 顶部稍微高一点（向上凸出 8px）,其余部分往下铺。
          double targetTop = anchor != null
              ? anchor!.top - 8
              : screen.height * 0.2;
          final double topLimit = safeInsets.top + screenPadding;
          final double bottomLimit =
              screen.height - safeInsets.bottom - screenPadding;
          if (targetLeft + targetWidth > screen.width - screenPadding) {
            targetLeft = screen.width - screenPadding - targetWidth;
          }
          if (targetLeft < screenPadding) targetLeft = screenPadding;
          if (targetTop + estimatedHeight > bottomLimit) {
            targetTop = bottomLimit - estimatedHeight;
          }
          if (targetTop < topLimit) targetTop = topLimit;
          // 子面板缩放原点:贴近触发它的 anchor 顶部,营造"从按钮长出来"的感觉。
          final double scaleAlignX = anchor != null && targetWidth > 0
              ? (((anchor!.center.dx - targetLeft) / targetWidth) * 2 - 1)
                    .clamp(-1.0, 1.0)
              : 0.0;
          final Alignment scaleAlign = Alignment(scaleAlignX, -1.0);

          return Stack(
            children: [
              // 底层 barrier:点/滑空白处整链一次性关闭。
              _SwipeBarrier(onDismiss: () => _dismissMenuChain(context)),
              Positioned(
                left: targetLeft,
                top: targetTop,
                width: targetWidth,
                child: _MenuPopTransition(
                  animation: animation,
                  alignment: scaleAlign,
                  child: Material(
                    shape: shape,
                    color: popupMenuTheme.color ?? cs.surfaceContainerLow,
                    surfaceTintColor: Colors.transparent,
                    elevation: popupMenuTheme.elevation ?? 3,
                    clipBehavior: Clip.antiAlias,
                    child: panelContent,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ------ _MenuItem / _RenderMenuItem ------

class _MenuItem extends SingleChildRenderObjectWidget {
  const _MenuItem({required this.onLayout, required super.child});

  final ValueChanged<Size> onLayout;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMenuItem(onLayout);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderMenuItem renderObject,
  ) {
    renderObject.onLayout = onLayout;
  }
}

class _RenderMenuItem extends RenderShiftedBox {
  _RenderMenuItem(this.onLayout, [RenderBox? child]) : super(child);

  ValueChanged<Size> onLayout;

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      child?.getDryLayout(constraints) ?? Size.zero;

  @override
  void performLayout() {
    if (child == null) {
      size = Size.zero;
    } else {
      child!.layout(constraints, parentUsesSize: true);
      size = constraints.constrain(child!.size);
      final BoxParentData childParentData = child!.parentData! as BoxParentData;
      childParentData.offset = Offset.zero;
    }
    onLayout(size);
  }
}

// ------ _PopupMenu widget ------

class _PopupMenu<T> extends StatefulWidget {
  const _PopupMenu({
    super.key,
    required this.itemKeys,
    required this.route,
    required this.semanticLabel,
    this.constraints,
    required this.clipBehavior,
  });

  final List<GlobalKey> itemKeys;
  final _SwipeDismissiblePopupRoute<T> route;
  final String? semanticLabel;
  final BoxConstraints? constraints;
  final Clip clipBehavior;

  @override
  State<_PopupMenu<T>> createState() => _PopupMenuState<T>();
}

class _PopupMenuState<T> extends State<_PopupMenu<T>> {
  final _MenuExpansionController _expansion = _MenuExpansionController();

  @override
  void dispose() {
    _expansion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> children = <Widget>[];
    final ThemeData theme = Theme.of(context);
    final PopupMenuThemeData popupMenuTheme = PopupMenuTheme.of(context);

    for (int i = 0; i < widget.route.items.length; i += 1) {
      Widget item = widget.route.items[i];
      if (widget.route.initialValue != null &&
          widget.route.items[i].represents(widget.route.initialValue)) {
        item = ColoredBox(color: theme.highlightColor, child: item);
      }
      children.add(
        _MenuItem(
          onLayout: (Size size) {
            widget.route.itemSizes[i] = size;
          },
          child: KeyedSubtree(key: widget.itemKeys[i], child: item),
        ),
      );
    }

    final List<MenuQuickAction>? headerActions = widget.route.headerActions;
    final bool hasHeader = headerActions != null && headerActions.isNotEmpty;

    final Widget body = Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: widget.semanticLabel,
      child: SingleChildScrollView(
        padding:
            widget.route.menuPadding ??
            popupMenuTheme.menuPadding ??
            const EdgeInsetsDirectional.symmetric(vertical: 8.0),
        child: ListBody(
          children: [
            if (hasHeader)
              _QuickActionsHeader(
                actions: headerActions,
                onAfterTap: () => Navigator.of(context).maybePop(),
              ),
            ...children,
          ],
        ),
      ),
    );

    // 有 header 时不走 stepWidth=56 的 Material spec 对齐，让菜单宽度跟着内容走，
    // 避免 header 被 spaceBetween 撑开后按钮间距过大。
    final Widget child = _MenuExpansionScope(
      controller: _expansion,
      child: ConstrainedBox(
        constraints:
            widget.constraints ??
            const BoxConstraints(
              minWidth: _kMenuMinWidth,
              maxWidth: _kMenuMaxWidth,
            ),
        child: hasHeader
            ? IntrinsicWidth(child: body)
            : IntrinsicWidth(stepWidth: _kMenuWidthStep, child: body),
      ),
    );

    // pivot 按按钮在屏幕上的位置动态算:菜单从最贴近按钮的那个角生长/收回,
    // 所以右上角的按钮就从右上角长出来,方向随位置变化,而不是固定某点。
    final RelativeRect pos = widget.route.position;
    final double originX = pos.right < pos.left
        ? 1.0
        : (pos.left < pos.right ? -1.0 : 0.0);
    final double originY = pos.bottom < pos.top ? 1.0 : -1.0;
    final Alignment originAlign = Alignment(originX, originY);

    return _MenuPopTransition(
      animation: widget.route.animation!,
      alignment: originAlign,
      child: AnimatedBuilder(
        animation: _expansion,
        builder: (context, menuChild) {
          // 子面板展开时,外层菜单后退一档(缩放 + 蒙层)做层级提示。
          final bool dimmed = _expansion.isAnyActive;
          return AnimatedScale(
            scale: dimmed ? 0.94 : 1.0,
            alignment: originAlign,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: Stack(
              children: [
                Material(
                  shape: widget.route.shape ?? popupMenuTheme.shape,
                  color: widget.route.color ?? popupMenuTheme.color,
                  clipBehavior: widget.clipBehavior,
                  type: MaterialType.card,
                  elevation:
                      widget.route.elevation ?? popupMenuTheme.elevation ?? 8.0,
                  shadowColor:
                      widget.route.shadowColor ?? popupMenuTheme.shadowColor,
                  surfaceTintColor:
                      widget.route.surfaceTintColor ??
                      popupMenuTheme.surfaceTintColor,
                  child: menuChild,
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !dimmed,
                    child: AnimatedOpacity(
                      opacity: dimmed ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.32),
                          borderRadius:
                              (widget.route.shape ?? popupMenuTheme.shape)
                                  is RoundedRectangleBorder
                              ? ((widget.route.shape ?? popupMenuTheme.shape!)
                                        as RoundedRectangleBorder)
                                    .borderRadius
                                    .resolve(Directionality.of(context))
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
        child: child,
      ),
    );
  }
}

// ------ _PopupMenuRouteLayout ------

class _PopupMenuRouteLayout extends SingleChildLayoutDelegate {
  _PopupMenuRouteLayout(
    this.position,
    this.itemSizes,
    this.selectedItemIndex,
    this.textDirection,
    this.padding,
    this.avoidBounds,
  );

  final RelativeRect position;
  List<Size?> itemSizes;
  final int? selectedItemIndex;
  final TextDirection textDirection;
  EdgeInsets padding;
  final Set<Rect> avoidBounds;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.loose(
      constraints.biggest,
    ).deflate(const EdgeInsets.all(_kMenuScreenPadding) + padding);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double y = position.top;
    double x;
    if (position.left > position.right) {
      x = size.width - position.right - childSize.width;
    } else if (position.left < position.right) {
      x = position.left;
    } else {
      x = switch (textDirection) {
        TextDirection.rtl => size.width - position.right - childSize.width,
        TextDirection.ltr => position.left,
      };
    }
    final Offset wantedPosition = Offset(x, y);
    final Offset originCenter = position.toRect(Offset.zero & size).center;
    final Iterable<Rect> subScreens =
        DisplayFeatureSubScreen.subScreensInBounds(
          Offset.zero & size,
          avoidBounds,
        );
    final Rect subScreen = _closestScreen(subScreens, originCenter);
    return _fitInsideScreen(subScreen, childSize, wantedPosition);
  }

  Rect _closestScreen(Iterable<Rect> screens, Offset point) {
    Rect closest = screens.first;
    for (final Rect screen in screens) {
      if ((screen.center - point).distance <
          (closest.center - point).distance) {
        closest = screen;
      }
    }
    return closest;
  }

  Offset _fitInsideScreen(Rect screen, Size childSize, Offset wantedPosition) {
    double x = wantedPosition.dx;
    double y = wantedPosition.dy;
    if (x < screen.left + _kMenuScreenPadding + padding.left) {
      x = screen.left + _kMenuScreenPadding + padding.left;
    } else if (x + childSize.width >
        screen.right - _kMenuScreenPadding - padding.right) {
      x = screen.right - childSize.width - _kMenuScreenPadding - padding.right;
    }
    if (y < screen.top + _kMenuScreenPadding + padding.top) {
      y = _kMenuScreenPadding + padding.top;
    } else if (y + childSize.height >
        screen.bottom - _kMenuScreenPadding - padding.bottom) {
      y =
          screen.bottom -
          childSize.height -
          _kMenuScreenPadding -
          padding.bottom;
    }
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_PopupMenuRouteLayout oldDelegate) {
    assert(itemSizes.length == oldDelegate.itemSizes.length);
    return position != oldDelegate.position ||
        selectedItemIndex != oldDelegate.selectedItemIndex ||
        textDirection != oldDelegate.textDirection ||
        !listEquals(itemSizes, oldDelegate.itemSizes) ||
        padding != oldDelegate.padding ||
        !setEquals(avoidBounds, oldDelegate.avoidBounds);
  }
}

// ============================================================
// 自定义 Route：barrier 支持滑动关闭
// ============================================================

class _SwipeDismissiblePopupRoute<T> extends PopupRoute<T>
    with _MenuChainRoute<T> {
  _SwipeDismissiblePopupRoute({
    required this.position,
    required this.items,
    required this.itemKeys,
    this.initialValue,
    this.elevation,
    this.surfaceTintColor,
    this.shadowColor,
    required this.barrierLabel,
    this.semanticLabel,
    this.shape,
    this.menuPadding,
    this.color,
    required this.capturedThemes,
    this.constraints,
    required this.clipBehavior,
    super.settings,
    this.popUpAnimationStyle,
    this.headerActions,
  }) : itemSizes = List<Size?>.filled(items.length, null),
       super(traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop);

  final RelativeRect position;
  final List<PopupMenuEntry<T>> items;
  final List<GlobalKey> itemKeys;
  final List<Size?> itemSizes;
  final T? initialValue;
  final double? elevation;
  final Color? surfaceTintColor;
  final Color? shadowColor;
  final String? semanticLabel;
  final ShapeBorder? shape;
  final EdgeInsetsGeometry? menuPadding;
  final Color? color;
  final CapturedThemes capturedThemes;
  final BoxConstraints? constraints;
  final Clip clipBehavior;
  final AnimationStyle? popUpAnimationStyle;
  final List<MenuQuickAction>? headerActions;

  CurvedAnimation? _animation;

  @override
  Animation<double> createAnimation() {
    if (popUpAnimationStyle != AnimationStyle.noAnimation) {
      return _animation ??= CurvedAnimation(
        parent: super.createAnimation(),
        curve: popUpAnimationStyle?.curve ?? Curves.linear,
        reverseCurve:
            popUpAnimationStyle?.reverseCurve ??
            const Interval(0.0, _kMenuCloseIntervalEnd),
      );
    }
    return super.createAnimation();
  }

  @override
  Duration get transitionDuration =>
      popUpAnimationStyle?.duration ?? _kMenuDuration;

  // 关键：禁用框架自带的 barrier，改由 buildPage 中自行处理
  @override
  bool get barrierDismissible => false;

  @override
  Color? get barrierColor => null;

  @override
  final String barrierLabel;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    int? selectedItemIndex;
    if (initialValue != null) {
      for (
        int index = 0;
        selectedItemIndex == null && index < items.length;
        index += 1
      ) {
        if (items[index].represents(initialValue)) {
          selectedItemIndex = index;
        }
      }
    }

    final Widget menu = _PopupMenu<T>(
      route: this,
      itemKeys: itemKeys,
      semanticLabel: semanticLabel,
      constraints: constraints,
      clipBehavior: clipBehavior,
    );

    final MediaQueryData mediaQuery = MediaQuery.of(context);

    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      removeBottom: true,
      removeLeft: true,
      removeRight: true,
      child: Builder(
        builder: (context) {
          return Stack(
            children: [
              // 底层：自定义 barrier（可响应 tap 和垂直滑动）。
              // 点/滑空白处时整链一次性关闭(含所有已展开的子面板)。
              _SwipeBarrier(onDismiss: () => _dismissMenuChain(context)),
              // 上层：菜单内容（优先接收手势事件）
              LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  return CustomSingleChildLayout(
                    delegate: _PopupMenuRouteLayout(
                      position,
                      itemSizes,
                      selectedItemIndex,
                      Directionality.of(context),
                      mediaQuery.padding,
                      DisplayFeatureSubScreen.avoidBounds(mediaQuery).toSet(),
                    ),
                    child: capturedThemes.wrap(menu),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _animation?.dispose();
    super.dispose();
  }
}

/// 自定义 barrier：支持点击和垂直滑动关闭。
///
/// 在 [Stack] 中处于菜单内容的 **下层**，所以当手指在菜单上时，
/// 菜单内容会优先接收事件，此 barrier 不会响应。
class _SwipeBarrier extends StatefulWidget {
  const _SwipeBarrier({required this.onDismiss});
  final VoidCallback onDismiss;

  @override
  State<_SwipeBarrier> createState() => _SwipeBarrierState();
}

class _SwipeBarrierState extends State<_SwipeBarrier> {
  double _totalDragDistance = 0;
  bool _dismissed = false;
  static const double _dismissThreshold = 20.0;

  void _dismiss() {
    if (_dismissed) return;
    _dismissed = true;
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _dismiss,
        onVerticalDragStart: (_) {
          _totalDragDistance = 0;
        },
        onVerticalDragUpdate: (details) {
          _totalDragDistance += details.delta.dy.abs();
          if (_totalDragDistance >= _dismissThreshold) {
            _dismiss();
          }
        },
      ),
    );
  }
}

// ============================================================
// 公开 API
// ============================================================

/// 显示支持滑动空白区域关闭的弹出菜单。
///
/// 功能与 [showMenu] 一致，但弹出菜单外的空白区域（barrier）
/// 除了支持点击关闭外，还支持垂直滑动关闭。
Future<T?> showSwipeDismissibleMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<PopupMenuEntry<T>> items,
  T? initialValue,
  double? elevation,
  Color? shadowColor,
  Color? surfaceTintColor,
  String? semanticLabel,
  ShapeBorder? shape,
  EdgeInsetsGeometry? menuPadding,
  Color? color,
  bool useRootNavigator = false,
  BoxConstraints? constraints,
  Clip clipBehavior = Clip.antiAlias,
  RouteSettings? routeSettings,
  AnimationStyle? popUpAnimationStyle,
  bool? requestFocus,
  List<MenuQuickAction>? headerActions,
}) {
  assert(items.isNotEmpty);

  switch (Theme.of(context).platform) {
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      break;
    case TargetPlatform.android:
    case TargetPlatform.fuchsia:
    case TargetPlatform.linux:
    case TargetPlatform.windows:
      semanticLabel ??= MaterialLocalizations.of(context).popupMenuLabel;
  }

  final List<GlobalKey> menuItemKeys = List<GlobalKey>.generate(
    items.length,
    (int index) => GlobalKey(),
  );
  final NavigatorState navigator = Navigator.of(
    context,
    rootNavigator: useRootNavigator,
  );
  return navigator.push(
    _SwipeDismissiblePopupRoute<T>(
      position: position,
      items: items,
      itemKeys: menuItemKeys,
      initialValue: initialValue,
      elevation: elevation,
      shadowColor: shadowColor,
      surfaceTintColor: surfaceTintColor,
      semanticLabel: semanticLabel,
      barrierLabel: MaterialLocalizations.of(context).menuDismissLabel,
      shape: shape,
      menuPadding: menuPadding,
      color: color,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
      constraints: constraints,
      clipBehavior: clipBehavior,
      settings: routeSettings,
      popUpAnimationStyle: popUpAnimationStyle,
      headerActions: headerActions,
    ),
  );
}

/// 支持滑动空白区域关闭的 PopupMenuButton。
///
/// 在原生 [PopupMenuButton] 基础上，额外支持在 barrier（菜单外的空白区域）
/// 上进行垂直滑动来关闭菜单，改善移动端体验。
class SwipeDismissiblePopupMenuButton<T> extends StatefulWidget {
  const SwipeDismissiblePopupMenuButton({
    super.key,
    required this.itemBuilder,
    this.initialValue,
    this.onOpened,
    this.onSelected,
    this.onCanceled,
    this.tooltip,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.padding = const EdgeInsets.all(8.0),
    this.menuPadding,
    this.child,
    this.borderRadius,
    this.splashRadius,
    this.icon,
    this.iconSize,
    this.offset = Offset.zero,
    this.enabled = true,
    this.shape,
    this.color,
    this.iconColor,
    this.enableFeedback,
    this.constraints,
    this.position,
    this.clipBehavior = Clip.antiAlias,
    this.useRootNavigator = false,
    this.popUpAnimationStyle,
    this.routeSettings,
    this.style,
    this.requestFocus,
    this.headerActions,
  }) : assert(
         !(child != null && icon != null),
         'You can only pass [child] or [icon], not both.',
       );

  final PopupMenuItemBuilder<T> itemBuilder;
  final T? initialValue;
  final VoidCallback? onOpened;
  final PopupMenuItemSelected<T>? onSelected;
  final PopupMenuCanceled? onCanceled;
  final String? tooltip;
  final double? elevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? menuPadding;
  final Widget? child;
  final BorderRadius? borderRadius;
  final double? splashRadius;
  final Widget? icon;
  final double? iconSize;
  final Offset offset;
  final bool enabled;
  final ShapeBorder? shape;
  final Color? color;
  final Color? iconColor;
  final bool? enableFeedback;
  final BoxConstraints? constraints;
  final PopupMenuPosition? position;
  final Clip clipBehavior;
  final bool useRootNavigator;
  final AnimationStyle? popUpAnimationStyle;
  final RouteSettings? routeSettings;
  final ButtonStyle? style;
  final bool? requestFocus;

  /// 可选：菜单顶部圆形快捷按钮条。
  /// 不为空时会在 items 上方多渲染一行圆形按钮，点击后菜单自动关闭并触发回调。
  final List<MenuQuickAction>? headerActions;

  @override
  State<SwipeDismissiblePopupMenuButton<T>> createState() =>
      _SwipeDismissiblePopupMenuButtonState<T>();
}

class _SwipeDismissiblePopupMenuButtonState<T>
    extends State<SwipeDismissiblePopupMenuButton<T>> {
  void showButtonMenu() {
    final RenderBox button = context.findRenderObject()! as RenderBox;
    final RenderBox overlay =
        Navigator.of(
              context,
              rootNavigator: widget.useRootNavigator,
            ).overlay!.context.findRenderObject()!
            as RenderBox;

    final PopupMenuThemeData popupMenuTheme = PopupMenuTheme.of(context);
    final PopupMenuPosition popupMenuPosition =
        widget.position ?? popupMenuTheme.position ?? PopupMenuPosition.over;

    late Offset offset;
    switch (popupMenuPosition) {
      case PopupMenuPosition.over:
        offset = widget.offset;
      case PopupMenuPosition.under:
        offset = Offset(0.0, button.size.height) + widget.offset;
        if (widget.child == null) {
          offset -= Offset(0.0, widget.padding.vertical / 2);
        }
    }

    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(offset, ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero) + offset,
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    final List<PopupMenuEntry<T>> items = widget.itemBuilder(context);
    if (items.isEmpty) return;

    widget.onOpened?.call();

    showSwipeDismissibleMenu<T>(
      context: context,
      position: position,
      items: items,
      initialValue: widget.initialValue,
      elevation: widget.elevation,
      shadowColor: widget.shadowColor,
      surfaceTintColor: widget.surfaceTintColor,
      shape: widget.shape,
      menuPadding: widget.menuPadding,
      color: widget.color,
      constraints: widget.constraints,
      clipBehavior: widget.clipBehavior,
      useRootNavigator: widget.useRootNavigator,
      popUpAnimationStyle: widget.popUpAnimationStyle,
      routeSettings: widget.routeSettings,
      requestFocus: widget.requestFocus,
      headerActions: widget.headerActions,
    ).then<void>((T? newValue) {
      if (!mounted) return;
      if (newValue == null) {
        widget.onCanceled?.call();
        return;
      }
      widget.onSelected?.call(newValue);
    });
  }

  @override
  Widget build(BuildContext context) {
    final IconThemeData iconTheme = IconTheme.of(context);
    final PopupMenuThemeData popupMenuTheme = PopupMenuTheme.of(context);
    final bool enableFeedback =
        widget.enableFeedback ?? popupMenuTheme.enableFeedback ?? true;

    if (widget.child != null) {
      return Tooltip(
        message:
            widget.tooltip ?? MaterialLocalizations.of(context).showMenuTooltip,
        child: InkWell(
          borderRadius: widget.borderRadius,
          onTap: widget.enabled ? showButtonMenu : null,
          canRequestFocus: widget.enabled,
          radius: widget.splashRadius,
          enableFeedback: enableFeedback,
          child: widget.child,
        ),
      );
    }

    return IconButton(
      icon: widget.icon ?? Icon(Icons.adaptive.more),
      padding: widget.padding,
      splashRadius: widget.splashRadius,
      iconSize: widget.iconSize ?? popupMenuTheme.iconSize ?? iconTheme.size,
      color: widget.iconColor ?? popupMenuTheme.iconColor ?? iconTheme.color,
      tooltip:
          widget.tooltip ?? MaterialLocalizations.of(context).showMenuTooltip,
      onPressed: widget.enabled ? showButtonMenu : null,
      enableFeedback: enableFeedback,
      style: widget.style,
    );
  }
}

// ============================================================
// 公开 API:从一个 anchor 位置长出子面板
// ============================================================

/// 从 [context] 所在的 widget 位置长大一个子面板。子项被点击后菜单
/// 反向收回到 anchor,然后 [onSelected] 用对应的回调被调用。
///
/// - 适用于不在 menu 内部使用的场景(比如普通工具栏按钮);
/// - 如果有外层 menu(SwipeDismissiblePopupMenuButton),会同时让外层
///   menu 缩放 + 蒙层。
Future<void> showAnchoredSubmenu({
  required BuildContext context,
  required IconData icon,
  required String label,
  required List<MenuQuickActionSubmenuChild> children,
  Color? iconColor,
  Color? labelColor,
  void Function(VoidCallback selectedCallback)? onSelected,
}) async {
  final NavigatorState navigator = Navigator.of(context);
  final RenderBox? box = context.findRenderObject() as RenderBox?;
  final RenderBox? overlayBox =
      navigator.overlay?.context.findRenderObject() as RenderBox?;
  Rect? anchor;
  if (box != null && overlayBox != null && box.hasSize) {
    final Offset topLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    anchor = topLeft & box.size;
  }
  final _MenuExpansionController? expansion = _MenuExpansionScope.maybeOf(
    context,
  );
  // 记录下方的父级菜单 route,供整链关闭时即时移除下层(整体收起)。
  final ModalRoute<dynamic>? belowRoute = ModalRoute.of(context);
  final Object id = Object();
  expansion?.open(id);
  VoidCallback? selectedCallback;
  await navigator.push(
    _SubmenuRoute(
        icon: icon,
        label: label,
        iconColor: iconColor,
        labelColor: labelColor,
        tiles: [
          for (final c in children)
            Builder(
              builder: (ctx) => _SubmenuRowTile(
                icon: c.icon,
                label: c.label,
                subtitle: c.subtitle,
                selected: c.selected,
                onTap: () {
                  selectedCallback = c.onTap;
                  Navigator.of(ctx).pop();
                },
              ),
            ),
        ],
        anchor: anchor,
        capturedThemes: InheritedTheme.capture(
          from: context,
          to: navigator.context,
        ),
      )
      ..belowChainRoute = belowRoute is _MenuChainRoute<dynamic>
          ? belowRoute
          : null,
  );
  expansion?.close(id);
  if (selectedCallback != null) {
    if (onSelected != null) {
      onSelected(selectedCallback!);
    } else {
      selectedCallback!();
    }
  }
}
