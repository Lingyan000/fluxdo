import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/rendering.dart';

// ============================================================
// 以下常量和私有类复制自 Flutter popup_menu.dart，
// 因为内部类 (_PopupMenuRoute 等) 不可访问，必须复制才能自定义 barrier 行为。
// ============================================================

// 菜单开合:统一"从触发点缩放生长/收回 + 淡入淡出"。开/关时长分开,
// 且外层与子面板用同一套关闭时长,保证整链一起关时同步、像一个整体收起。
const Duration _kMenuDuration = Duration(milliseconds: 160);
const Duration _kMenuCloseDuration = Duration(milliseconds: 180);
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
            fill: action.active ? 1 : 0,
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
  /// 紧邻其下方的同链 route(子面板指向其父菜单)。用于子面板判断"点在父菜单上"。
  _MenuChainRoute<dynamic>? belowChainRoute;

  /// 挂在本菜单内容根部的 key,用来反查本菜单当前的屏幕矩形 —— 子面板据此区分
  /// "点在父菜单区域(只关子面板)"还是"点在真正的空白(整链关闭)"。
  final GlobalKey menuContentKey = GlobalKey();

  /// 本菜单"生长/收回"的原点(相对自身的对齐点),由 build 时写入。
  Alignment menuPivotAlignment = Alignment.center;

  /// 整链一起关闭时,本菜单要缩向的对齐点(相对自身)。它指向**链底(一级菜单)
  /// 的 pivot 屏幕点**,因此各层会朝同一个点收回 —— 二级菜单被"带着"一起缩进去,
  /// 整组就是一级菜单的那一下动画。为 null 时(单独开/关本层)用 [menuPivotAlignment]。
  Alignment? chainCloseAlignment;

  /// 本菜单当前的全局矩形(尚未布局时返回 null)。
  Rect? currentMenuRect() {
    final RenderObject? ro = menuContentKey.currentContext?.findRenderObject();
    if (ro is RenderBox && ro.hasSize) {
      return ro.localToGlobal(Offset.zero) & ro.size;
    }
    return null;
  }

  /// 本菜单 pivot 的全局坐标点(由矩形 + [menuPivotAlignment] 推出)。
  Offset? ownPivotScreenPoint() {
    final Rect? r = currentMenuRect();
    if (r == null) return null;
    return Offset(
      r.left + (menuPivotAlignment.x + 1) / 2 * r.width,
      r.top + (menuPivotAlignment.y + 1) / 2 * r.height,
    );
  }
}

/// 把全局点 [p] 换算成相对矩形 [r] 的 [Alignment](可超出 [-1,1],用于表示框外的点)。
Alignment _pointToAlignment(Offset p, Rect r) {
  final double hw = r.width / 2;
  final double hh = r.height / 2;
  return Alignment(
    hw == 0 ? 0 : (p.dx - r.center.dx) / hw,
    hh == 0 ? 0 : (p.dy - r.center.dy) / hh,
  );
}

/// 为整条菜单链设置统一的收起原点:让每一层都缩向**链底(一级菜单)的同一个
/// pivot 屏幕点**(不执行 pop)。点空白关闭、选中子项关闭都先调它,保证整组同步收回。
void _prepareChainClose(BuildContext context) {
  final ModalRoute<dynamic>? top = ModalRoute.of(context);
  if (top is! _MenuChainRoute) return;
  // 找到链底(一级菜单),用它的 pivot 作为整组收起的目标点。
  _MenuChainRoute<dynamic> bottom = top;
  while (bottom.belowChainRoute != null) {
    bottom = bottom.belowChainRoute!;
  }
  final Offset? pivot = bottom.ownPivotScreenPoint();
  for (
    _MenuChainRoute<dynamic>? cur = top;
    cur != null;
    cur = cur.belowChainRoute
  ) {
    final Rect? rect = cur.currentMenuRect();
    cur.chainCloseAlignment = (pivot != null && rect != null)
        ? _pointToAlignment(pivot, rect)
        : null;
  }
}

/// 关闭整条菜单链:每层缩向链底统一的 pivot,各层同步收回、二级被"带着"一起缩进去 ——
/// 整组就是一级菜单的那一下关闭动画,而不是各缩各的。
void _dismissMenuChain(BuildContext context) {
  _prepareChainClose(context);
  Navigator.of(context).popUntil((route) => route is! _MenuChainRoute);
}

/// 菜单的开合动画:从触发它的位置 [alignment] 处缩放生长/收回(配合淡入淡出)。
/// [alignment] 是触发点相对菜单自身的对齐点(pivot),由各 route 按位置动态算出,
/// 所以菜单看起来是"从按钮长出来 / 缩回按钮里去",方向随位置变化。
class _MenuPopTransition extends StatefulWidget {
  const _MenuPopTransition({
    super.key,
    required this.animation,
    required this.alignment,
    required this.child,
    this.chainRoute,
  });

  final Animation<double> animation;

  /// 本层自身的生长/收回原点(打开、以及单独关闭本层时用)。
  final Alignment alignment;

  /// 所属菜单 route;整链关闭时从中读取统一的 [_MenuChainRoute.chainCloseAlignment]。
  final _MenuChainRoute<dynamic>? chainRoute;

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
    // 开:减速到位(easeOutCubic);关:用 easeInOutCubic 让整段收回都清晰可见
    // —— 之前用 easeInCubic 会在前 30% 时间就把 scale 缩到 ~0.1,看着像没有动画。
    _scale = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInOutCubic,
    );
    // 淡入在前半程完成;淡出全程渐隐,跟着缩放一起可见。
    _fade = CurvedAnimation(
      parent: widget.animation,
      curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
      reverseCurve: Curves.easeOut,
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
      child: AnimatedBuilder(
        animation: _scale,
        builder: (context, child) {
          // 整链关闭(reverse 且设了 chainCloseAlignment)时,缩向链底统一的 pivot,
          // 让二级菜单被"带着"和一级一起收回;否则用本层自己的原点。
          final Alignment? chainAlign = widget.chainRoute?.chainCloseAlignment;
          final bool chainClosing =
              widget.animation.status == AnimationStatus.reverse &&
              chainAlign != null;
          return Transform.scale(
            scale: _scale.value,
            alignment: chainClosing ? chainAlign : widget.alignment,
            child: child,
          );
        },
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
      // 选中时同步收起:先 cb() 取到值,再立刻 pop 外层(带回结果),
      // 与子面板的 pop 同帧发生,两层一起缩向一级 pivot 收回。
      onSelected: (cb) {
        cb();
        if (selectedValue != null && navigator.mounted) {
          navigator.pop<T>(selectedValue);
        }
      },
    );
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
            Icon(icon, size: 20, fill: selected ? 1 : 0, color: fg),
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
            if (selected) Icon(Symbols.check_rounded, size: 18, color: cs.primary),
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
    required this.subtitleCount,
    this.anchor,
  });

  final IconData icon;
  final String label;
  final Color? iconColor;
  final Color? labelColor;
  final List<Widget> tiles;
  final CapturedThemes capturedThemes;

  /// tiles 中带 subtitle 的行数（高度估算用：带副标题的行更高）
  final int subtitleCount;
  final Rect? anchor;

  @override
  Color? get barrierColor => null;
  // barrier 由 buildPage 自行处理:点空白处整链一次性关闭(支持 tap + 垂直滑动)。
  @override
  bool get barrierDismissible => false;
  @override
  String get barrierLabel => 'submenu';
  @override
  Duration get transitionDuration => _kMenuDuration;
  @override
  Duration get reverseTransitionDuration => _kMenuCloseDuration;

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
                Symbols.keyboard_arrow_up_rounded,
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

          // 估算最终高度：header(48) + 分隔线(1) + 尾部 padding(4)。
          // 行高按实际构成算：单行 tile = 10+20+10 ≈ 40（bodyMedium 文字
          // ~20 + 上下 padding 10）,带 subtitle 的 tile ≈ 58。此前统一按
          // 60/行过估,长列表(如 7 项排序)虚高 ~140px,底界避让把面板
          // 从 anchor 大幅上抬,子菜单看起来"飘"到离入口很远的位置。
          final double estimatedHeight =
              kMinInteractiveDimension +
              1 +
              (tiles.length - subtitleCount) * 40.0 +
              subtitleCount * 58.0 +
              4;

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
          menuPivotAlignment = scaleAlign;

          return Stack(
            children: [
              // 底层 barrier:点在父(一级)菜单区域 → 只关本子面板,回到上一层;
              // 点在真正的空白 / 垂直滑动 → 整条链一起同步关闭。
              _SwipeBarrier(
                onTapAt: (pos) {
                  final Rect? belowRect = belowChainRoute?.currentMenuRect();
                  if (belowRect != null && belowRect.contains(pos)) {
                    Navigator.of(context).maybePop();
                  } else {
                    _dismissMenuChain(context);
                  }
                },
                onSwipe: () => _dismissMenuChain(context),
              ),
              Positioned(
                left: targetLeft,
                top: targetTop,
                width: targetWidth,
                child: _MenuPopTransition(
                  key: menuContentKey,
                  animation: animation,
                  alignment: scaleAlign,
                  chainRoute: this,
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
      role: SemanticsRole.menu,
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

    // pivot 按按钮在屏幕上的位置动态算:菜单从最贴近按钮的位置生长/收回,
    // 所以右上角的按钮就从右上角长出来,方向随位置变化,而不是固定某点。
    final RelativeRect pos = widget.route.position;
    final double originX = pos.right < pos.left
        ? 1.0
        : (pos.left < pos.right ? -1.0 : 0.0);
    double originY = pos.bottom < pos.top ? 1.0 : -1.0;
    final Rect? animationAnchorRect = widget.route.animationAnchorRect;
    if (animationAnchorRect != null) {
      final EdgeInsets menuPadding =
          (widget.route.menuPadding ??
                  popupMenuTheme.menuPadding ??
                  const EdgeInsetsDirectional.symmetric(vertical: 8.0))
              .resolve(Directionality.of(context));
      final double estimatedMenuHeight =
          widget.route.items.fold<double>(
            menuPadding.vertical,
            (height, item) => height + item.height,
          ) +
          (hasHeader ? 52.0 : 0.0);
      if (estimatedMenuHeight > 0) {
        originY =
            ((animationAnchorRect.center.dy - pos.top) / estimatedMenuHeight) *
                2 -
            1;
      }
    }
    final Alignment originAlign = Alignment(originX, originY);
    widget.route.menuPivotAlignment = originAlign;

    return _MenuPopTransition(
      key: widget.route.menuContentKey,
      animation: widget.route.animation!,
      alignment: originAlign,
      chainRoute: widget.route,
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
    this.animationAnchorRect,
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
    super.requestFocus,
    this.popUpAnimationStyle,
    this.headerActions,
  }) : itemSizes = List<Size?>.filled(items.length, null),
       super(traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop);

  final RelativeRect position;
  final Rect? animationAnchorRect;
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
        // 缓动统一交给 _MenuPopTransition,这里保持线性,使外层与子面板的
        // 关闭节奏完全一致(整链一起关时同步收起)。
        curve: popUpAnimationStyle?.curve ?? Curves.linear,
        reverseCurve: popUpAnimationStyle?.reverseCurve ?? Curves.linear,
      );
    }
    return super.createAnimation();
  }

  @override
  Duration get transitionDuration =>
      popUpAnimationStyle?.duration ?? _kMenuDuration;

  @override
  Duration get reverseTransitionDuration => _kMenuCloseDuration;

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
              // 一级菜单没有上层,点/滑空白处即关闭(若有子面板会一并同步关闭)。
              _SwipeBarrier(
                onTapAt: (_) => _dismissMenuChain(context),
                onSwipe: () => _dismissMenuChain(context),
              ),
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
  const _SwipeBarrier({required this.onTapAt, required this.onSwipe});

  /// 点击 barrier:带上点击的全局坐标,调用方据此决定关一层还是整链。
  final void Function(Offset globalPosition) onTapAt;

  /// 垂直滑动 barrier 触发的关闭。
  final VoidCallback onSwipe;

  @override
  State<_SwipeBarrier> createState() => _SwipeBarrierState();
}

class _SwipeBarrierState extends State<_SwipeBarrier> {
  double _totalDragDistance = 0;
  bool _handled = false;
  static const double _dismissThreshold = 20.0;

  void _tap(Offset globalPosition) {
    if (_handled) return;
    _handled = true;
    widget.onTapAt(globalPosition);
  }

  void _swipe() {
    if (_handled) return;
    _handled = true;
    widget.onSwipe();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) => _tap(details.globalPosition),
        onVerticalDragStart: (_) {
          _totalDragDistance = 0;
        },
        onVerticalDragUpdate: (details) {
          _totalDragDistance += details.delta.dy.abs();
          if (_totalDragDistance >= _dismissThreshold) {
            _swipe();
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
  NavigatorState? navigator,
  Rect? animationAnchorRect,
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
  final NavigatorState targetNavigator =
      navigator ?? Navigator.of(context, rootNavigator: useRootNavigator);
  // 外部传入的 navigator 可能是按钮子树的**兄弟**(如用户卡片浮层里的迷你
  // Navigator),不是 context 的祖先 —— InheritedTheme.capture 要求 `to` 必须
  // 是 `from` 的祖先,否则 debug 断言直接失败、菜单打不开。不是祖先时捕获到根。
  bool navigatorIsAncestor = false;
  context.visitAncestorElements((element) {
    if (element == targetNavigator.context) {
      navigatorIsAncestor = true;
      return false;
    }
    return true;
  });
  return targetNavigator.push(
    _SwipeDismissiblePopupRoute<T>(
      position: position,
      animationAnchorRect: animationAnchorRect,
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
        to: navigatorIsAncestor ? targetNavigator.context : null,
      ),
      constraints: constraints,
      clipBehavior: clipBehavior,
      settings: routeSettings,
      requestFocus: requestFocus,
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
    this.menuNavigatorKey,
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

  /// 可选：把菜单 route 推到指定 Navigator 上。
  ///
  /// 用于按钮位于手动 OverlayEntry 内的场景：菜单仍复用同一套路由与样式，
  /// 但可以由后插入/更高层的 Navigator 承载，避免被外层 OverlayEntry 盖住。
  final GlobalKey<NavigatorState>? menuNavigatorKey;

  @override
  State<SwipeDismissiblePopupMenuButton<T>> createState() =>
      _SwipeDismissiblePopupMenuButtonState<T>();
}

class _SwipeDismissiblePopupMenuButtonState<T>
    extends State<SwipeDismissiblePopupMenuButton<T>> {
  void showButtonMenu() {
    final RenderBox button = context.findRenderObject()! as RenderBox;
    final NavigatorState navigator =
        widget.menuNavigatorKey?.currentState ??
        Navigator.of(context, rootNavigator: widget.useRootNavigator);
    final RenderBox overlay =
        navigator.overlay!.context.findRenderObject()! as RenderBox;

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

    final Rect buttonRect = Rect.fromPoints(
      overlay.globalToLocal(button.localToGlobal(Offset.zero)),
      overlay.globalToLocal(button.localToGlobal(button.size.bottomRight(Offset.zero))),
    );

    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromPoints(
        overlay.globalToLocal(button.localToGlobal(offset)),
        overlay.globalToLocal(button.localToGlobal(
          button.size.bottomRight(Offset.zero) + offset,
        )),
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
      navigator: navigator,
      animationAnchorRect: buttonRect,
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
      icon: widget.icon ?? const Icon(Symbols.more_vert_rounded),
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
  await navigator.push(
    _SubmenuRoute(
        icon: icon,
        label: label,
        iconColor: iconColor,
        labelColor: labelColor,
        subtitleCount: children.where((c) => c.subtitle != null).length,
        tiles: [
          for (final c in children)
            Builder(
              builder: (ctx) => _SubmenuRowTile(
                icon: c.icon,
                label: c.label,
                subtitle: c.subtitle,
                selected: c.selected,
                onTap: () {
                  // 选中也走整组收起:先统一各层缩放原点,再同步 pop 二级、并立刻
                  // 让调用方 pop 一级,两层在同一帧一起缩向一级 pivot 收回 ——
                  // 而不是"先关二级、等动画完再关一级"那种顺序关。
                  _prepareChainClose(ctx);
                  Navigator.of(ctx).pop();
                  if (onSelected != null) {
                    onSelected(c.onTap);
                  } else {
                    c.onTap();
                  }
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
}
