import 'dart:math' as math;

import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../common/fading_edge_scroll_view.dart';
import 'composer_desktop_layout.dart';
import 'composer_island.dart';
import 'composer_tool_style.dart';
import 'composer_tools_anchor.dart';
import 'composer_tools_panel.dart';

/// 桌面工作区：宽屏分列操作与格式，窄窗收回同一条横栏。
/// 所有命令复用宿主的编辑器和选区；临时工具面板不改变栏位的位置。
class ComposerDesktopWorkbench extends StatefulWidget {
  const ComposerDesktopWorkbench({
    super.key,
    required this.tools,
    required this.emoji,
    required this.controls,
    required this.history,
    this.contentActions,
    this.anchor,
    this.onExpandTools,
  });
  final List<Widget> tools;
  final Widget emoji;
  final List<Widget> controls;
  final List<Widget> history;
  final Widget? contentActions;
  final ComposerToolsAnchor? anchor;
  final VoidCallback? onExpandTools;

  @override
  State<ComposerDesktopWorkbench> createState() =>
      _ComposerDesktopWorkbenchState();
}

class _ComposerDesktopWorkbenchState extends State<ComposerDesktopWorkbench>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation;
  final _focus = FocusNode();
  final _panelKey = GlobalKey();
  LocalHistoryEntry? _history;
  bool _presenting = false;
  bool _reduced = false;
  bool _disposed = false;
  late final CurvedAnimation _panelAnimation;

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 160),
    )..addStatusListener(_status);
    _panelAnimation = CurvedAnimation(
      parent: _animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    widget.anchor?.addListener(_changed);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced =
        MediaQuery.disableAnimationsOf(context) ||
        !M3eFlags.of(context).enabled;
    if (_presenting && !TickerMode.valuesOf(context).enabled) {
      // 切换预览时编辑器会 Offstage。结束被暂停的退场，不能留下
      // 未完成的工具会话，等回到编辑页才突然继续播放。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || TickerMode.valuesOf(context).enabled || !_presenting) {
          return;
        }
        widget.anchor?.dismiss();
        _animation.value = 0;
        _status(AnimationStatus.dismissed);
      });
    }
  }

  @override
  void didUpdateWidget(covariant ComposerDesktopWorkbench oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.anchor != widget.anchor) {
      oldWidget.anchor?.removeListener(_changed);
      widget.anchor?.addListener(_changed);
    }
  }

  bool _onKey(KeyEvent event) {
    if (!_presenting ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        ModalRoute.of(context)?.isCurrent != true) {
      return false;
    }
    widget.anchor?.collapse();
    return true;
  }

  void _changed() {
    if (_disposed || !mounted) return;
    final anchor = widget.anchor!;
    if (anchor.expanded && !_presenting) {
      _presenting = true;
      anchor.animation = _animation;
      _history = LocalHistoryEntry(
        impliesAppBarDismissal: false,
        onRemove: () {
          final systemDismissed = _history != null;
          _history = null;
          if (systemDismissed) anchor.dismiss();
        },
      );
      ModalRoute.of(context)?.addLocalHistoryEntry(_history!);
      _focus.requestFocus();
    }
    setState(() {});
    if (_reduced) {
      _animation.value = anchor.expanded ? 1 : 0;
      if (!anchor.expanded) _status(AnimationStatus.dismissed);
    } else if (anchor.expanded) {
      _animation.forward();
    } else if (_presenting) {
      _animation.reverse();
    }
  }

  void _status(AnimationStatus status) {
    if (status != AnimationStatus.dismissed || !_presenting || _disposed) {
      return;
    }
    _presenting = false;
    final history = _history;
    _history = null;
    history?.remove();
    widget.anchor?.finish();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _disposed = true;
    HardwareKeyboard.instance.removeHandler(_onKey);
    widget.anchor?.removeListener(_changed);
    final history = _history;
    _history = null;
    history?.remove();
    widget.anchor?.finish();
    _panelAnimation.dispose();
    _animation.dispose();
    _focus.dispose();
    super.dispose();
  }

  Widget _surface({required Widget child, ComposerToolsAnchor? anchor}) =>
      TextFieldTapRegion(
        child: TapRegion(
          groupId: this,
          onTapOutside: _presenting ? (_) => widget.anchor?.dismiss() : null,
          child: ComposerIsland(
            expanded: _presenting,
            padding: EdgeInsets.zero,
            radius: 28,
            toolsAnchor: anchor,
            child: IconButtonTheme(
              data: IconButtonThemeData(
                style: composerToolButtonStyle(context),
              ),
              child: Padding(padding: const EdgeInsets.all(4), child: child),
            ),
          ),
        ),
      );

  Widget _divider(Axis axis) => Padding(
    padding: axis == Axis.vertical
        ? const EdgeInsets.symmetric(vertical: 4, horizontal: 10)
        : const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
    child: axis == Axis.vertical
        ? const Divider(height: 1)
        : const VerticalDivider(width: 1),
  );

  Widget get _expand => ComposerToolsToggle(
    anchor: widget.anchor,
    active: widget.anchor?.expanded ?? false,
    compact: false,
    axis: ComposerDesktopViewport.maybeOf(context)!.useRail
        ? Axis.vertical
        : Axis.horizontal,
    onPressed: widget.onExpandTools,
  );

  @override
  Widget build(BuildContext context) {
    final viewport = ComposerDesktopViewport.maybeOf(context)!;
    final rail = viewport.useRail;
    final height = viewport.availableHeight;
    final showHistory = !viewport.compact;
    final history = [
      if (showHistory) ...widget.history,
      if (widget.contentActions != null) widget.contentActions!,
    ];
    final normalHeight = math.min(
      height - 48,
      8 +
          (widget.tools.length +
                  widget.controls.length +
                  1 +
                  (widget.onExpandTools == null ? 0 : 1)) *
              48 +
          18.0,
    );
    final barWidth = math.min(
      viewport.size.width - 32,
      16 +
          (history.length +
                  widget.tools.length +
                  widget.controls.length +
                  1 +
                  (widget.onExpandTools == null ? 0 : 1)) *
              48 +
          18.0,
    );
    final panelWidth = math.min(
      rail ? 440.0 : 560.0,
      viewport.size.width - (rail ? 224 : 32),
    );
    final panelHeight = math.max(
      0.0,
      math.min(rail ? 560.0 : 360.0, height - (rail ? 48 : 112)),
    );
    final panelTop = viewport.topInset + (height - panelHeight) / 2;

    return Stack(
      key: const ValueKey('composer-desktop-workbench'),
      clipBehavior: Clip.none,
      children: [
        if (rail && history.isNotEmpty)
          Positioned(
            left: 24,
            top: viewport.topInset + (height - (history.length * 48 + 8)) / 2,
            width: 56,
            child: _surface(
              child: Column(
                key: const ValueKey('composer-desktop-history'),
                mainAxisSize: MainAxisSize.min,
                children: history,
              ),
            ),
          ),
        Positioned(
          right: rail ? 24 : (viewport.size.width - barWidth) / 2,
          top: rail ? viewport.topInset + (height - normalHeight) / 2 : null,
          bottom: rail ? null : 16,
          width: rail ? 56 : barWidth,
          height: rail ? normalHeight : 56,
          child: _surface(
            anchor: widget.anchor,
            child: rail
                ? Column(
                    key: const ValueKey('composer-desktop-rail'),
                    children: [
                      widget.emoji,
                      _divider(Axis.vertical),
                      Expanded(
                        child: SingleChildScrollView(
                          key: const ValueKey('composer-desktop-pinned-tools'),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: widget.tools,
                          ),
                        ),
                      ),
                      _divider(Axis.vertical),
                      ...widget.controls,
                      if (widget.onExpandTools != null) _expand,
                    ],
                  )
                : Row(
                    key: const ValueKey('composer-format-row'),
                    children: [
                      ...history,
                      if (history.isNotEmpty) _divider(Axis.horizontal),
                      widget.emoji,
                      Expanded(
                        child: FadingEdgeScrollView(
                          fadeLeft: true,
                          fadeRight: true,
                          child: SingleChildScrollView(
                            key: const ValueKey(
                              'composer-desktop-pinned-tools',
                            ),
                            scrollDirection: Axis.horizontal,
                            child: Row(children: widget.tools),
                          ),
                        ),
                      ),
                      _divider(Axis.horizontal),
                      ...widget.controls,
                      if (widget.onExpandTools != null) _expand,
                    ],
                  ),
          ),
        ),
        if (_presenting && panelHeight > 0)
          Positioned(
            key: _panelKey,
            right: rail ? 92 : (viewport.size.width - panelWidth) / 2,
            top: rail ? panelTop : null,
            bottom: rail ? null : 84,
            width: panelWidth,
            height: panelHeight,
            child: FadeTransition(
              opacity: _panelAnimation,
              child: SlideTransition(
                position: Tween(
                  begin: rail ? const Offset(.05, 0) : const Offset(0, .05),
                  end: Offset.zero,
                ).animate(_panelAnimation),
                child: AnimatedBuilder(
                  animation: _animation,
                  builder: (context, child) => IgnorePointer(
                    ignoring: _animation.status != AnimationStatus.completed,
                    child: child,
                  ),
                  child: _surface(
                    child: Focus(
                      focusNode: _focus,
                      child: Column(
                        children: [
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: widget.anchor!.toggleCustomizing,
                              icon: Icon(
                                widget.anchor!.customizing
                                    ? AppIcons.check
                                    : AppIcons.edit,
                                size: 18,
                              ),
                              label: Text(
                                widget.anchor!.customizing
                                    ? S.current.common_done
                                    : S.current.toolPanel_customize,
                              ),
                            ),
                          ),
                          Expanded(
                            child: ComposerExpandedTools(
                              anchor: widget.anchor!,
                              animation: _animation,
                              flyingIds: const {},
                            ),
                          ),
                        ],
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
