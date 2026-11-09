import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../services/browser_tabs.dart';
import '../../services/navigation/browser_dock_observer.dart';
import 'browser_dock_motion.dart';
import 'browser_dock_content_layout.dart';
import 'browser_tab_overview.dart';

/// 普通页面在根导航器外避让底栏；带常驻侧栏的页面只缩短主内容区。
class BrowserDockHost extends StatefulWidget {
  const BrowserDockHost({
    super.key,
    required this.controller,
    required this.observer,
    required this.onRestore,
    required this.child,
    this.enabled = true,
    this.iconBuilder,
    this.subtitleBuilder,
    this.blurEnabled = true,
  });

  final BrowserTabsController controller;
  final BrowserDockObserver observer;
  final ValueChanged<BrowserTabSession> onRestore;
  final Widget child;
  final bool enabled;
  final bool blurEnabled;
  final Widget Function(BuildContext, BrowserTabSession, double)? iconBuilder;
  final String Function(BuildContext, BrowserTabSession)? subtitleBuilder;

  @override
  State<BrowserDockHost> createState() => _BrowserDockHostState();
}

class _BrowserDockHostState extends State<BrowserDockHost>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  LocalHistoryEntry? _overviewHistory;
  final _overviewFocus = FocusNode(debugLabel: 'browser overview');
  final _motion = BrowserDockMotion();
  final _contentLayouts = BrowserDockContentLayouts();
  List<BrowserTabSession> _lastBarTabs = const [];
  bool _disposing = false;
  bool _restoreDragging = false;
  double _restoreProgress = 0;
  bool _overviewDragging = false;
  bool _interactiveOverview = false;
  bool _wasMotionActive = false;
  late final _overviewAnimation = AnimationController(vsync: this);
  static const _duration = Duration(milliseconds: 300);
  static final _curve = M3eMotion.defaultEffects.curveFor(_duration);

  void _setExpanded(bool value, {bool animate = true}) {
    if (_interactiveOverview && animate) {
      _overviewAnimation.animateTo(
        value ? 1 : 0,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
    if (_expanded == value) return;
    if (!value) {
      _overviewHistory?.remove();
      _overviewHistory = null;
    } else {
      final route = widget.observer.currentRoute;
      if (route is ModalRoute) {
        _overviewHistory = LocalHistoryEntry(
          onRemove: () {
            _overviewHistory = null;
            if (mounted && !_disposing) _setExpanded(false);
          },
        );
        route.addLocalHistoryEntry(_overviewHistory!);
      }
    }
    setState(() => _expanded = value);
    if (value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _expanded) _overviewFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _disposing = true;
    _overviewHistory?.remove();
    _overviewFocus.dispose();
    _overviewAnimation.dispose();
    _motion.dispose();
    _contentLayouts.dispose();
    super.dispose();
  }

  Future<void> _restore(BrowserTabSession tab) async {
    final session = await widget.controller.take(tab);
    if (session == null) {
      _restoreDragging = false;
      _motion.clearRestoreDrag();
      return;
    }
    if (!mounted) {
      await session.close();
      return;
    }
    _setExpanded(false);
    widget.onRestore(session);
  }

  void _open() {
    final tabs = widget.controller.tabs;
    if (tabs.length == 1) {
      _restore(tabs.single);
    } else if (tabs.isNotEmpty) {
      _setExpanded(true);
    }
  }

  void _startBarDrag(DragStartDetails details) {
    final tabs = widget.controller.tabs;
    if (tabs.length > 1) {
      _interactiveOverview = true;
      _overviewDragging = true;
      _overviewAnimation.stop();
      _setExpanded(true, animate: false);
      return;
    }
    if (tabs.length != 1 ||
        !tabs.single.supportsDragRestore ||
        _motion.active ||
        _restoreDragging) {
      return;
    }
    _restoreDragging = true;
    _restoreProgress = 0;
    _motion.beginRestoreDrag(tabs.single);
    _restore(tabs.single);
  }

  void _updateBarDrag(DragUpdateDetails details) {
    if (_overviewDragging) {
      _updateOverviewDrag(details);
      return;
    }
    if (!_restoreDragging) return;
    final media = MediaQuery.of(context);
    final travel =
        _motion.restoreDragExtent ??
        browserDockRect(media.size, media.padding.bottom).top;
    if (travel <= 0) return;
    _restoreProgress = (_restoreProgress - details.delta.dy / travel).clamp(
      0.0,
      1.0,
    );
    _motion.updateRestoreDrag(_restoreProgress);
  }

  void _endBarDrag(DragEndDetails details) {
    if (_overviewDragging) {
      _endOverviewDrag(details);
      return;
    }
    if (!_restoreDragging) {
      if ((details.primaryVelocity ?? 0) < -100) _open();
      return;
    }
    _restoreDragging = false;
    _motion.endRestoreDrag(-(details.primaryVelocity ?? 0));
  }

  void _cancelBarDrag() {
    if (_overviewDragging) {
      _overviewDragging = false;
      _setExpanded(false);
      return;
    }
    if (!_restoreDragging) return;
    _restoreDragging = false;
    _motion.endRestoreDrag(-1000);
  }

  void _startOverviewDrag(DragStartDetails details) {
    if (!_interactiveOverview) {
      _overviewAnimation.value = 1;
      setState(() => _interactiveOverview = true);
    }
    _overviewAnimation.stop();
    _overviewDragging = true;
  }

  void _updateOverviewDrag(DragUpdateDetails details) {
    final travel = MediaQuery.sizeOf(context).height - 100;
    _overviewAnimation.value =
        (_overviewAnimation.value - details.delta.dy / travel).clamp(0.0, 1.0);
  }

  void _endOverviewDrag(DragEndDetails details) {
    _overviewDragging = false;
    final velocity = -(details.primaryVelocity ?? 0);
    _setExpanded(
      velocity > 650 || (velocity >= -650 && _overviewAnimation.value >= .5),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.controller,
      widget.observer.hidden,
      widget.observer.routeChanges,
      _contentLayouts,
      _motion.stateChanges,
    ]),
    builder: (context, _) {
      if (!widget.enabled) return widget.child;
      final justFinishedMotion = _wasMotionActive && !_motion.active;
      _wasMotionActive = _motion.active;
      final media = MediaQuery.of(context);
      final contentLeft = _contentLayouts.leftFor(widget.observer.currentRoute);
      final dockLeft =
          contentLeft ??
          (_motion.active
              ? _contentLayouts.leftFor(widget.observer.previousRoute) ?? 0.0
              : 0.0);
      final browserInFront =
          widget.observer.currentRoute?.settings.name == browserPageRouteName;
      final tabs = widget.controller.tabs;
      final canSwipeOverview = tabs.isNotEmpty;
      final movingTab = _motion.tab;
      final barTabs = [
        ...tabs,
        if (movingTab != null && !tabs.contains(movingTab)) movingTab,
      ];
      if (barTabs.isNotEmpty) _lastBarTabs = barTabs;
      final visible =
          widget.enabled &&
          barTabs.isNotEmpty &&
          (_motion.active ||
              (!browserInFront && !widget.observer.hidden.value)) &&
          media.viewInsets.bottom == 0;
      final expanded = _expanded && visible;
      final height = visible ? browserDockHeight + media.padding.bottom : 0.0;
      // 转场中只移动合成层；根导航器在开始/结束各布局一次，
      // 不再每帧改 MediaQuery 和网页下层的可用高度。
      final reservedHeight = _motion.active ? 0.0 : height;
      return BrowserDockViewport(
        media: media,
        motion: _motion,
        dockLeftInset: dockLeft,
        child: Stack(
          fit: StackFit.expand,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(end: reservedHeight),
              duration:
                  media.disableAnimations ||
                      browserInFront ||
                      _motion.active ||
                      justFinishedMotion
                  ? Duration.zero
                  : _duration,
              curve: _curve,
              builder: (context, reserved, _) {
                // 会话可立即释放，底栏的静态标题与图标保留到占位退场完成。
                // 否则剩余占位先变成透明，在 Android 上会显示黑色底板。
                if (reserved == 0 && !visible) _lastBarTabs = const [];
                final displayTabs = barTabs.isNotEmpty ? barTabs : _lastBarTabs;
                final exitOpacity = visible
                    ? 1.0
                    : (reserved / (browserDockHeight + media.padding.bottom))
                          .clamp(0.0, 1.0);
                final navigatorInset = contentLeft == null ? reserved : 0.0;
                final contentMedia = browserDockContentMedia(
                  media,
                  navigatorInset,
                );
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    // 覆盖内容区与底栏之间的亚像素接缝，防止收缩末帧透出底色。
                    Positioned(
                      left: dockLeft,
                      right: 0,
                      bottom: 0,
                      height: reserved.ceilToDouble(),
                      child: ColoredBox(
                        color: Theme.of(context).colorScheme.surface,
                      ),
                    ),
                    Positioned.fill(
                      bottom: navigatorInset,
                      child: BrowserDockContentScope(
                        layouts: _contentLayouts,
                        route: contentLeft == null
                            ? null
                            : widget.observer.currentRoute,
                        bottomInset: contentLeft == null ? 0 : reserved,
                        child: MediaQuery(
                          data: contentMedia,
                          child: widget.child,
                        ),
                      ),
                    ),
                    Positioned(
                      left: dockLeft,
                      right: 0,
                      bottom: 0,
                      height: reserved,
                      child: ColoredBox(
                        color: Theme.of(context).colorScheme.surface,
                        child: ClipRect(
                          child: OverflowBox(
                            alignment: Alignment.topCenter,
                            minHeight: browserDockHeight + media.padding.bottom,
                            maxHeight: browserDockHeight + media.padding.bottom,
                            child: IgnorePointer(
                              ignoring: !visible || _motion.active,
                              child: ExcludeSemantics(
                                excluding: !visible,
                                child: displayTabs.isEmpty
                                    ? const SizedBox.shrink()
                                    : Opacity(
                                        opacity: exitOpacity,
                                        child: MediaQuery.removePadding(
                                          context: context,
                                          removeLeft: dockLeft > 0,
                                          child: Overlay.wrap(
                                            child: _buildBar(
                                              context,
                                              displayTabs,
                                            ),
                                          ),
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
              },
            ),
            if (_motion.active &&
                barTabs.isNotEmpty &&
                !media.disableAnimations)
              AnimatedBuilder(
                animation: _motion,
                child: Overlay.wrap(child: _buildCard(context, barTabs)),
                builder: (context, child) =>
                    _buildMovingCard(context, media, dockLeft, child!),
              ),
            Overlay.wrap(
              child: Focus(
                focusNode: _overviewFocus,
                autofocus: true,
                canRequestFocus: expanded,
                onKeyEvent: (_, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.escape) {
                    _setExpanded(false);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: BrowserTabOverview(
                  visible: expanded,
                  animation: canSwipeOverview && _interactiveOverview
                      ? _overviewAnimation
                      : null,
                  onDragStart: canSwipeOverview ? _startOverviewDrag : null,
                  onDragUpdate: canSwipeOverview ? _updateOverviewDrag : null,
                  onDragEnd: canSwipeOverview ? _endOverviewDrag : null,
                  onDragCancel: canSwipeOverview
                      ? () {
                          _overviewDragging = false;
                          _setExpanded(true);
                        }
                      : null,
                  tabs: tabs,
                  blurEnabled: widget.blurEnabled,
                  iconBuilder: widget.iconBuilder,
                  subtitleBuilder: widget.subtitleBuilder,
                  onDismiss: () => _setExpanded(false),
                  onRestore: _restore,
                  onCloseTab: (tab) {
                    if (tabs.length == 1) _setExpanded(false);
                    widget.controller.close(tab);
                  },
                  onCloseAll: () {
                    _setExpanded(false);
                    widget.controller.closeAll();
                  },
                ),
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _buildBar(BuildContext context, List<BrowserTabSession> tabs) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      child: SafeArea(
        top: false,
        child: GestureDetector(
          key: const ValueKey('browser-restore-drag-area'),
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: _startBarDrag,
          onVerticalDragUpdate: _updateBarDrag,
          onVerticalDragEnd: _endBarDrag,
          onVerticalDragCancel: _cancelBarDrag,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: browserDockMaxWidth + browserDockInset * 2,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  browserDockInset,
                  8,
                  browserDockInset,
                  4,
                ),
                child: SizedBox(
                  height: browserDockCardHeight,
                  child: Opacity(
                    opacity:
                        _motion.active &&
                            !MediaQuery.disableAnimationsOf(context)
                        ? 0
                        : 1,
                    child: _buildCard(context, tabs),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMovingCard(
    BuildContext context,
    MediaQueryData media,
    double leftInset,
    Widget card,
  ) {
    final t = _motion.openProgress;
    final rect = Rect.lerp(
      browserDockRect(media.size, media.padding.bottom, leftInset: leftInset),
      Offset.zero & media.size,
      t,
    )!;
    // 放在根导航器外，末段不会被正在收缩的导航器视口裁掉。
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: browserDockCardHeight,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: Opacity(
            key: const ValueKey('browser-moving-dock-card'),
            opacity: 1 - browserDockPageOpacity(t),
            child: card,
          ),
        ),
      ),
    );
  }

  Widget _buildCard(BuildContext context, List<BrowserTabSession> tabs) {
    final colors = Theme.of(context).colorScheme;
    final tab = tabs.last;
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        if (tabs.length > 1)
          Positioned(
            top: -5,
            left: 8,
            right: 8,
            height: 24,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        Material(
          key: const ValueKey('browser-dock-card'),
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _open,
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child:
                      widget.iconBuilder?.call(context, tab, 28) ??
                      const Icon(Symbols.language_rounded),
                ),
                Expanded(
                  child: Text(
                    tabs.length == 1
                        ? _title(context, tab)
                        : context.l10n.webview_minimizedCount(tabs.length),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: context.l10n.webview_minimizedPages,
                  onPressed: () => _setExpanded(true),
                  icon: const Icon(Symbols.expand_less_rounded),
                ),
                if (tabs.length == 1)
                  IconButton(
                    tooltip: context.l10n.common_close,
                    onPressed: () => widget.controller.close(tab),
                    icon: const Icon(Symbols.close_rounded),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _title(BuildContext context, BrowserTabSession tab) =>
      tab.title.isNotEmpty
      ? tab.title
      : tab.url.isNotEmpty
      ? tab.url
      : context.l10n.webview_browser;
}
