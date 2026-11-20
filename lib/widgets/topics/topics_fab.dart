import 'package:app_icons/app_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show MatrixUtils, RenderStack;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../models/shortcut_binding.dart';
import '../../providers/shortcut_provider.dart';
import '../../providers/preferences_provider.dart';
import '../../utils/responsive.dart';
import '../../pages/topics_page.dart' show barVisibilityProvider;

/// 首页固定创作入口与独立刷新工具。菜单不使用遮罩或背景模糊。
class TopicsFab extends ConsumerStatefulWidget {
  const TopicsFab({
    super.key,
    required this.onRefresh,
    required this.onCreateTopic,
    required this.onOpenDrafts,
    this.canCreate = true,
    this.isActive = true,
  });

  final VoidCallback onRefresh;
  final VoidCallback onCreateTopic;
  final VoidCallback onOpenDrafts;
  final bool canCreate;
  final bool isActive;

  @override
  ConsumerState<TopicsFab> createState() => _TopicsFabState();
}

class _TopicsFabState extends ConsumerState<TopicsFab>
    with TickerProviderStateMixin {
  final _portal = OverlayPortalController();
  final _tapGroup = Object();
  final _triggerFocus = FocusNode();
  final _menuFocus = FocusNode();
  late final AnimationController _appearanceScale;
  late final AnimationController _appearanceAlpha;
  late final Listenable _appearance;
  bool _present = false;
  bool _reduceMotion = false;
  bool _closeQueued = false;
  bool _hiddenWhileTickerMuted = false;
  double _scrollVisibility = 1;
  late final ShortcutSurfaceBinding _shortcutSurface;

  @override
  void initState() {
    super.initState();
    // 访客没有主 FAB，也要在挂载阶段初始化，不能在 dispose 首次创建 ticker。
    _appearanceScale = AnimationController.unbounded(vsync: this);
    _appearanceAlpha = AnimationController.unbounded(vsync: this);
    _appearance = Listenable.merge([_appearanceScale, _appearanceAlpha]);
    _shortcutSurface = ShortcutSurfaceBinding(
      ref: ref,
      id: 'home.fabMenu',
      triggerAction: ShortcutAction.createTopic,
      enabled: () => mounted && _present && _scrollVisibility == 1,
    );
  }

  LocalHistoryEntry? _history;
  bool _expanded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAppearance();
  }

  @override
  void didUpdateWidget(covariant TopicsFab oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAppearance();
  }

  void _syncAppearance() {
    // isCurrentOf 会在 push/pop 时通知，普通重建和滚动不会重播入场。
    final routeVisible = ModalRoute.isCurrentOf(context) ?? true;
    final present = widget.isActive && routeVisible;
    final reduceMotion =
        !M3eFlags.of(context).enabled ||
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.reduceMotionOf(context);
    // IndexedStack 非活跃 tab 会禁用 ticker，反向动画无法推进。
    // 回来时从零入场，不能沿用冻结在 1 的旧进度而跳过 Appearing。
    if (!present && !TickerMode.valuesOf(context).enabled) {
      _hiddenWhileTickerMuted = true;
    }
    if (present && _hiddenWhileTickerMuted) {
      _hiddenWhileTickerMuted = false;
      _appearanceScale.value = 0;
      _appearanceAlpha.value = 0;
    }
    if (present != _present || reduceMotion != _reduceMotion) {
      _present = present;
      _reduceMotion = reduceMotion;
      final target = present ? 1.0 : 0.0;
      if (reduceMotion) {
        _appearanceScale.value = target;
        _appearanceAlpha.value = target;
      } else {
        M3eMotion.fastSpatial.animateTo(_appearanceScale, target);
        M3eMotion.fastEffects.animateTo(_appearanceAlpha, target);
      }
    }
    if ((!present || !widget.canCreate) && _portal.isShowing) {
      _queueHiddenMenuClose();
    }
  }

  void _queueHiddenMenuClose() {
    if (_closeQueued) return;
    _closeQueued = true;
    // OverlayPortal 不允许在 build/didUpdateWidget 中直接隐藏。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _closeQueued = false;
      if (!mounted) return;
      if (_expanded) {
        _close(immediately: true, restoreFocus: false);
      } else {
        _onMenuDismissed();
      }
    });
  }

  @override
  void dispose() {
    final history = _history;
    _history = null;
    history?.remove();
    _shortcutSurface.disposeDeferred();
    _appearanceScale.dispose();
    _appearanceAlpha.dispose();
    _triggerFocus.dispose();
    _menuFocus.dispose();
    super.dispose();
  }

  void _onMenuDismissed() {
    if (mounted && !_expanded && _portal.isShowing) setState(_portal.hide);
  }

  void _toggle() {
    if (!_present || _scrollVisibility < 1) return;
    if (_expanded) {
      _close();
      return;
    }
    setState(() => _expanded = true);
    final route = ModalRoute.of(context);
    if (route != null) {
      final entry = LocalHistoryEntry(
        impliesAppBarDismissal: false,
        onRemove: () {
          if (_history == null) return;
          _history = null;
          if (mounted) _close();
        },
      );
      _history = entry;
      route.addLocalHistoryEntry(entry);
    }
    _shortcutSurface.register(context, onClose: _scheduleClose);
    _portal.show();
    _menuFocus.requestFocus();
    HapticFeedback.lightImpact();
  }

  void _scheduleClose() {
    // 焦点与全局 HardwareKeyboard 都会收到同一事件，本帧保留 surface
    // 拦截，避免 ESC 同时关闭右侧详情，或 Enter 同时打开列表话题。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _expanded) _close();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _close({bool immediately = false, bool restoreFocus = true}) {
    final history = _history;
    _history = null;
    history?.remove();
    if (!_expanded) return;
    setState(() => _expanded = false);
    _shortcutSurface.clearDeferred();
    if (restoreFocus) _triggerFocus.requestFocus();
    if (immediately || _reduceMotion) _portal.hide();
  }

  void _select(VoidCallback action) {
    _close(immediately: true, restoreFocus: false);
    action();
  }

  @override
  Widget build(BuildContext context) {
    final barVisibility = ref.watch(barVisibilityProvider).clamp(0.0, 1.0);
    final hideBarOnScroll = ref.watch(
      preferencesProvider.select((p) => p.hideBarOnScroll),
    );
    final showRefresh = ref.watch(
      preferencesProvider.select((p) => p.homeRefreshButton),
    );
    // 与底栏使用相同规则和同一逐帧进度，不再叠加延迟动画。
    // 宽屏使用 NavigationRail，没有滚动隐藏的底栏，FAB 保持可见。
    final visibility =
        Responsive.showBottomNavigation(context) &&
            (hideBarOnScroll || barVisibility == 0)
        ? barVisibility
        : 1.0;
    _scrollVisibility = visibility;
    if (_portal.isShowing && visibility < 1) _queueHiddenMenuClose();
    final media = MediaQuery.of(context);
    final barHeight = (media.padding.bottom - media.viewPadding.bottom).clamp(
      0.0,
      double.infinity,
    );
    final refreshCovered = widget.canCreate && _portal.isShowing;
    final refreshStyle = IconButton.styleFrom(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      minimumSize: const Size.square(48),
    );

    final controls = TapRegion(
      groupId: _tapGroup,
      onTapOutside: (_) {
        if (_expanded) _close(restoreFocus: false);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // 展开时由菜单占据辅助按钮区域，保留槽位避免主按钮跳动。
          if (showRefresh)
            ExcludeFocus(
              excluding: refreshCovered,
              child: ExcludeSemantics(
                excluding: refreshCovered,
                child: IgnorePointer(
                  ignoring: refreshCovered,
                  child: Opacity(
                    opacity: refreshCovered ? 0 : 1,
                    child: SizedBox(
                      width: 56,
                      height: 48,
                      child: Center(
                        child: _appear(
                          id: 'refresh',
                          visibility: visibility,
                          child: IconButton.filledTonal(
                            key: const ValueKey('topics-refresh'),
                            tooltip: context.l10n.common_refresh,
                            style:
                                IconButtonTheme.of(context).style
                                    ?.merge(refreshStyle) ??
                                refreshStyle,
                            onPressed: widget.onRefresh,
                            icon: const Icon(Symbols.refresh_rounded),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (widget.canCreate) ...[
            if (showRefresh) const SizedBox(height: 12),
            OverlayPortal.overlayChildLayoutBuilder(
              controller: _portal,
              overlayChildBuilder: _buildMenu,
              child: SizedBox(
                width: 56,
                height: 56,
                child: Center(
                  child: _appear(
                    id: 'create',
                    visibility: visibility,
                    child: M3eFabMenuButton(
                      key: const ValueKey('topics-create-menu'),
                      expanded: _expanded,
                      focusNode: _triggerFocus,
                      tooltip: _expanded
                          ? context.l10n.common_close
                          : context.l10n.topicsScreen_createTopic,
                      icon: const Icon(Symbols.add_rounded),
                      closeIcon: const Icon(Symbols.close_rounded),
                      onPressed: _toggle,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
    // 隐藏/退场开始就停用点击、键盘和无障碍，避免透明按钮抢焦点。
    final interactive = _present && visibility == 1;
    // 平移必须在命中测试包装层之外，避免抬高后的刷新落在旧布局边界外。
    return Transform.translate(
      offset: Offset(0, -barHeight * visibility),
      child: IgnorePointer(
        ignoring: !interactive,
        child: ExcludeFocus(
          excluding: !interactive,
          child: ExcludeSemantics(excluding: !interactive, child: controls),
        ),
      ),
    );
  }

  Widget _appear({
    required String id,
    required double visibility,
    required Widget child,
  }) {
    return AnimatedBuilder(
      animation: _appearance,
      child: child,
      builder: (context, child) {
        final opacity = _appearanceAlpha.value.clamp(0.0, 1.0) * visibility;
        final scale = (0.2 + 0.8 * _appearanceScale.value) * visibility;
        return Opacity(
          key: ValueKey('topics-$id-appearance-opacity'),
          opacity: opacity,
          child: Transform.scale(
            key: ValueKey('topics-$id-appearance-scale'),
            scale: _reduceMotion ? 1 : scale,
            alignment: Alignment.center,
            child: child,
          ),
        );
      },
    );
  }

  Widget _buildMenu(BuildContext context, OverlayChildLayoutInfo layout) {
    final media = MediaQuery.of(context);
    final anchor = MatrixUtils.transformPoint(
      layout.childPaintTransform,
      layout.childSize.topRight(Offset.zero),
    );
    // 最近的 Stack 就是 master 格，不能用整窗宽度让菜单侵入导航栏。
    final pane = this.context.findAncestorRenderObjectOfType<RenderStack>();
    final overlay = Overlay.of(this.context).context.findRenderObject();
    final paneLeft =
        pane?.localToGlobal(Offset.zero, ancestor: overlay).dx ?? 0;
    final availableWidth = anchor.dx - paneLeft - 16;
    final menuBottom = anchor.dy - 8;
    final availableHeight = menuBottom - media.viewPadding.top - 16;
    final menuVisible = _present && _scrollVisibility == 1;
    return Stack(
      children: [
        Positioned(
          right: layout.overlaySize.width - anchor.dx,
          bottom: layout.overlaySize.height - menuBottom,
          child: Visibility(
            visible: menuVisible,
            maintainState: true,
            child: TapRegion(
              groupId: _tapGroup,
              child: FocusScope(
                child: Focus(
                  focusNode: _menuFocus,
                  onKeyEvent: (_, event) {
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.escape) {
                      _scheduleClose();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: availableWidth.clamp(0.0, 320.0),
                      maxHeight: availableHeight.clamp(0.0, media.size.height),
                    ),
                    child: SingleChildScrollView(
                      reverse: true,
                      child: M3eFabMenuItems(
                        expanded: _expanded,
                        onDismissed: _onMenuDismissed,
                        iconAlignment: IconAlignment.end,
                        items: [
                          M3eFabMenuItem(
                            label: Text(context.l10n.topicsScreen_myDrafts),
                            icon: const Icon(Symbols.drafts_rounded, size: 24),
                            onPressed: () => _select(widget.onOpenDrafts),
                          ),
                          M3eFabMenuItem(
                            label: Text(context.l10n.topicsScreen_createTopic),
                            icon: const Icon(Symbols.edit_rounded, size: 24),
                            onPressed: () => _select(widget.onCreateTopic),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
