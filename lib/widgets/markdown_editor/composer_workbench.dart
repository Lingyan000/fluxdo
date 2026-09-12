import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../utils/platform_utils.dart';
import 'composer_island.dart';
import 'composer_tools_anchor.dart';
import '../../l10n/s.dart';
import 'composer_view_mode_switcher.dart';
import 'composer_chrome.dart';
import 'composer_keyboard_dismiss.dart';
import 'composer_tools_panel.dart';
import 'composer_tool_cell.dart' show ComposerToolGlyph;
import 'package:flutter/services.dart';

/// 同一个工具岛：展开只增加内部工具区高度，保留原有外壳与底栏。
class ComposerWorkbench extends StatefulWidget {
  const ComposerWorkbench({
    super.key,
    this.metadata,
    required this.controls,
    required this.tools,
    required this.editing,
    this.toolsAnchor,
    this.onExpandTools,
  });
  final Widget? metadata;
  final List<Widget> controls;
  final Widget tools;
  final bool editing;
  final ComposerToolsAnchor? toolsAnchor;
  final VoidCallback? onExpandTools;
  static double rowHeight(BuildContext context) =>
      math.max(48, MediaQuery.textScalerOf(context).scale(14) + 24);
  static double occupiedHeight(BuildContext context, bool editing) {
    final row = rowHeight(context);
    return (PlatformUtils.isDesktop
            ? row + 4
            : row + ComposerToolsHandle.height + (editing ? row + 4 : 0)) +
        8 +
        kComposerIslandBottomGap;
  }

  @override
  State<ComposerWorkbench> createState() => _ComposerWorkbenchState();
}

class _ComposerWorkbenchState extends State<ComposerWorkbench>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
    reverseDuration: const Duration(milliseconds: 260),
  );
  final _contentKey = GlobalKey();
  final _focus = FocusNode();
  List<String> _flightIds = [];
  List<Widget> _flightChildren = [];
  bool _dragging = false;
  ComposerKeyboardDismissController? _keyboardGesture;
  bool _dragWasExpanded = false;
  double _expansionHeight = 400;
  Map<String, Rect> _sourceIcons = {};
  LocalHistoryEntry? _history;
  bool _presenting = false;
  Widget? _expandedTools;

  @override
  void initState() {
    super.initState();
    widget.toolsAnchor?.addListener(_changed);
    _animation.addStatusListener(_status);
  }

  @override
  void didUpdateWidget(covariant ComposerWorkbench oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.toolsAnchor != widget.toolsAnchor) {
      oldWidget.toolsAnchor?.removeListener(_changed);
      widget.toolsAnchor?.addListener(_changed);
    }
  }

  void _changed() {
    final anchor = widget.toolsAnchor!;
    if (anchor.expanded && !_presenting) {
      _sourceIcons = anchor.visibleIcons();
      final byId = {for (final action in anchor.actions) action.keyId: action};
      _flightIds = MediaQuery.disableAnimationsOf(context)
          ? []
          : _sourceIcons.keys.where(byId.containsKey).toList();
      _flightChildren = [
        for (final id in _flightIds)
          IconTheme(
            data: IconThemeData(
              size: 20,
              color: byId[id]!.active
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            child: ComposerToolGlyph(icon: byId[id]!.icon),
          ),
      ];
      _presenting = true;
      _expandedTools = ComposerExpandedTools(
        anchor: anchor,
        animation: _animation,
        flyingIds: _flightIds.toSet(),
      );
      anchor.animation = _animation;
      _history = LocalHistoryEntry(
        impliesAppBarDismissal: false,
        onRemove: () {
          _history = null;
          anchor.collapse();
        },
      );
      ModalRoute.of(context)?.addLocalHistoryEntry(_history!);
      setState(() {});
      if (MediaQuery.disableAnimationsOf(context)) {
        _animation.value = 1;
      } else if (!_dragging) {
        _animation.forward();
      }
      if (!_dragging) _focus.requestFocus();
    } else if (!anchor.expanded && _presenting) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _animation.value = 0;
      } else {
        _animation.reverse();
      }
    } else if (mounted) {
      setState(() {});
    }
  }

  void _status(AnimationStatus status) {
    if (status != AnimationStatus.dismissed || !_presenting || _dragging) {
      return;
    }
    _sourceIcons = {};
    _presenting = false;
    _expandedTools = null;
    final history = _history;
    _history = null;
    history?.remove();
    widget.toolsAnchor?.finish();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.toolsAnchor?.removeListener(_changed);
    widget.toolsAnchor?.finish();
    _history?.remove();
    _animation.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _toggle() {
    if (widget.toolsAnchor?.expanded == true) {
      widget.toolsAnchor!.collapse();
    } else {
      widget.onExpandTools?.call();
    }
  }

  void _startDrag() {
    _dragWasExpanded = widget.toolsAnchor?.expanded ?? false;
    _dragging = true;
    _keyboardGesture = null;
    if (_presenting) _animation.stop();
  }

  void _drag(double delta) {
    if (_keyboardGesture != null) {
      _keyboardGesture!.update(delta);
      return;
    }
    if (!_presenting) {
      // 折叠态先判方向：下拖接管键盘，上拖才展开工具，不能先抢输入焦点。
      if (delta > 0) {
        final keyboard = ComposerKeyboardDismissScope.maybeOf(context);
        if (keyboard?.begin(View.of(context)) == true) {
          _keyboardGesture = keyboard;
          keyboard!.update(delta);
        }
        return;
      }
      if (delta == 0) return;
      widget.onExpandTools?.call();
      _animation.stop();
    }
    if (!_presenting || _expansionHeight <= 0) return;
    final curve = Curves.easeInOutCubicEmphasized;
    final progress =
        (curve.transform(_animation.value) - delta / _expansionHeight).clamp(
          0.0,
          1.0,
        );
    // 手指控制实际高度，反解时序曲线，松手时不会换曲线跳一下。
    var low = 0.0;
    var high = 1.0;
    for (var i = 0; i < 16; i++) {
      final mid = (low + high) / 2;
      if (curve.transform(mid) < progress) {
        low = mid;
      } else {
        high = mid;
      }
    }
    _animation.value = (low + high) / 2;
  }

  void _cancelDrag() {
    // 轻点按钮赢得手势竞争时也会收到 cancel，此时并没有开始拖动。
    if (!_dragging) return;
    _dragging = false;
    final keyboard = _keyboardGesture;
    _keyboardGesture = null;
    if (keyboard != null) {
      keyboard.end(0, cancel: true);
    } else if (_presenting) {
      if (_dragWasExpanded) {
        _animation.forward();
      } else {
        widget.toolsAnchor?.collapse();
      }
    }
  }

  void _endDrag(double velocity) {
    if (!_dragging) return;
    _dragging = false;
    final keyboard = _keyboardGesture;
    _keyboardGesture = null;
    if (keyboard != null) {
      keyboard.end(velocity);
      return;
    }
    if (!_presenting) return;
    final progress = Curves.easeInOutCubicEmphasized.transform(
      _animation.value,
    );
    final open =
        velocity < -240 ||
        (velocity <= 240 && progress > (_dragWasExpanded ? .84 : .16));
    if (open) {
      _animation.forward();
      _focus.requestFocus();
    } else {
      widget.toolsAnchor?.collapse();
      if (_animation.value == 0) _status(AnimationStatus.dismissed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktop = PlatformUtils.isDesktop;
    final row = ComposerWorkbench.rowHeight(context);
    final handleHeight = !desktop && widget.onExpandTools != null
        ? ComposerToolsHandle.height
        : 0.0;
    final footerHeight = desktop
        ? row + 4
        : row + (widget.editing ? row + 4 : 0);
    final baseHeight = footerHeight + handleHeight;
    final available =
        context
            .dependOnInheritedWidgetOfExactType<_WorkbenchViewport>()
            ?.height ??
        MediaQuery.sizeOf(context).height;
    final expansionHeight = math.min(
      desktop ? 360.0 : 400.0,
      math.max(0.0, available - baseHeight - 40),
    );
    _expansionHeight = expansionHeight;
    final theme = Theme.of(context);
    final footer = desktop
        ? SizedBox(
            key: const ValueKey('composer-format-row'),
            height: footerHeight,
            child: Row(
              children: [
                Expanded(child: widget.tools),
                if (widget.controls.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  SizedBox(
                    height: 20,
                    child: VerticalDivider(
                      width: 8,
                      color: theme.colorScheme.outlineVariant,
                    ),
                  ),
                  ...widget.controls,
                ],
              ],
            ),
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                key: const ValueKey('composer-context-row'),
                height: row,
                child: Row(
                  children: [
                    Expanded(child: widget.metadata ?? const SizedBox.shrink()),
                    ...widget.controls,
                  ],
                ),
              ),
              Visibility(
                visible: widget.editing,
                maintainState: true,
                maintainAnimation: true,
                child: Container(
                  key: const ValueKey('composer-format-row'),
                  height: row + 4,
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: theme.colorScheme.outlineVariant.withValues(
                          alpha: .45,
                        ),
                      ),
                    ),
                  ),
                  child: widget.tools,
                ),
              ),
            ],
          );
    return TextFieldTapRegion(
      child: TapRegion(
        onTapOutside: _presenting
            ? (_) => widget.toolsAnchor?.collapse()
            : null,
        child: Listener(
          onPointerCancel: (_) => _cancelDrag(),
          child: CallbackShortcuts(
            bindings: {
              if (_presenting)
                const SingleActivator(LogicalKeyboardKey.escape): () =>
                    widget.toolsAnchor?.collapse(),
            },
            child: Focus(
              focusNode: _focus,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: desktop ? 640 : 720),
                child: ComposerIsland(
                  key: const ValueKey('composer-workbench'),
                  toolsAnchor: widget.toolsAnchor,
                  child: IconButtonTheme(
                    data: IconButtonThemeData(
                      style: IconButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        maximumSize: const Size(48, 48),
                        padding: const EdgeInsets.all(12),
                        visualDensity: VisualDensity.standard,
                        foregroundColor: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: AnimatedBuilder(
                        animation: _animation,
                        builder: (context, _) {
                          final progress = Curves.easeInOutCubicEmphasized
                              .transform(_animation.value);
                          return SizedBox(
                            key: _contentKey,
                            height: baseHeight + expansionHeight * progress,
                            child: Stack(
                              clipBehavior: Clip.hardEdge,
                              children: [
                                if (_presenting)
                                  Positioned(
                                    key: const ValueKey(
                                      'composer-tools-grid-region',
                                    ),
                                    left: 0,
                                    right: 0,
                                    top: handleHeight,
                                    height: expansionHeight,
                                    child: IgnorePointer(
                                      ignoring:
                                          _animation.status !=
                                          AnimationStatus.completed,
                                      child: Opacity(
                                        opacity: const Interval(
                                          .22,
                                          .82,
                                        ).transform(_animation.value),
                                        child: _expandedTools!,
                                      ),
                                    ),
                                  ),
                                Positioned(
                                  key: const ValueKey(
                                    'composer-toolbar-region',
                                  ),
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.translucent,
                                    onVerticalDragStart: (_) => _startDrag(),
                                    onVerticalDragUpdate: (details) =>
                                        _drag(details.delta.dy),
                                    onVerticalDragEnd: (details) =>
                                        _endDrag(details.primaryVelocity ?? 0),
                                    onVerticalDragCancel: _cancelDrag,
                                    child: footer,
                                  ),
                                ),
                                if (handleHeight > 0)
                                  Positioned(
                                    key: const ValueKey(
                                      'composer-handle-region',
                                    ),
                                    left: 0,
                                    right: 0,
                                    top: 0,
                                    child: ComposerToolsHandle(
                                      key: const ValueKey(
                                        'composer-tools-handle',
                                      ),
                                      label:
                                          widget.toolsAnchor?.expanded == true
                                          ? S.current.composer_collapseToolbar
                                          : S.current.composer_expandToolbar,
                                      expanded:
                                          widget.toolsAnchor?.expanded ?? false,
                                      onActivate: _toggle,
                                      onDragStart: _startDrag,
                                      onDragUpdate: _drag,
                                      onDragEnd: _endDrag,
                                      onDragCancel: _cancelDrag,
                                    ),
                                  ),
                                if (_flightIds.isNotEmpty &&
                                    (_animation.isAnimating || _dragging))
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: Flow(
                                        delegate: _ToolFlights(
                                          ids: _flightIds,
                                          sources: _sourceIcons,
                                          anchor: widget.toolsAnchor!,
                                          contentKey: _contentKey,
                                          progress: _animation.value,
                                          remainingHeight:
                                              expansionHeight * (1 - progress),
                                        ),
                                        children: _flightChildren,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 用真实图标 Widget 迁移；布局只做一次，逐帧只更新绘制变换。
class _ToolFlights extends FlowDelegate {
  _ToolFlights({
    required this.ids,
    required this.sources,
    required this.anchor,
    required this.contentKey,
    required this.progress,
    required this.remainingHeight,
  });
  final List<String> ids;
  final Map<String, Rect> sources;
  final ComposerToolsAnchor anchor;
  final GlobalKey contentKey;
  final double progress;
  final double remainingHeight;
  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      const BoxConstraints.tightFor(
        width: ComposerToolGlyph.extent,
        height: ComposerToolGlyph.extent,
      );
  @override
  void paintChildren(FlowPaintingContext context) {
    final content = contentKey.currentContext?.findRenderObject();
    if (content is! RenderBox || !content.hasSize) return;
    final offset = content.localToGlobal(Offset.zero);
    final currentSources = anchor.visibleIcons();
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      final target = anchor.targets[id]?.currentContext?.findRenderObject();
      if (target is! RenderBox || !target.attached || !target.hasSize) continue;
      final destination =
          (target.localToGlobal(Offset.zero) - Offset(0, remainingHeight)) &
          target.size;
      final start = currentSources[id] ?? sources[id]!;
      final delay = math.min(i, 5) * .012;
      final t = Interval(
        .04 + delay,
        .92 + delay,
        curve: Curves.easeInOutCubicEmphasized,
      ).transform(progress);
      // FaIcon 的字形宽度不等于字号，不能把字形边界拉伸到方形容器。
      // 插值中心与字号，保持两轴同比例，首尾才能与原图标无缝交接。
      final center = Offset.lerp(start.center, destination.center, t)! - offset;
      final extent = start.height + (destination.height - start.height) * t;
      final scale = extent / ComposerToolGlyph.extent;
      context.paintChild(
        i,
        transform: Matrix4.identity()
          ..translateByDouble(
            center.dx - extent / 2,
            center.dy - extent / 2,
            0,
            1,
          )
          ..scaleByDouble(scale, scale, 1, 1),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ToolFlights oldDelegate) => true;
}

class _WorkbenchViewport extends InheritedWidget {
  const _WorkbenchViewport({required this.height, required super.child});
  final double height;
  @override
  bool updateShouldNotify(_WorkbenchViewport oldWidget) =>
      height != oldWidget.height;
}

/// 正文占满画布，工具岛覆盖其底部。只有键盘/扩展面板占独立布局空间。
class ComposerEditorLayout extends StatefulWidget {
  const ComposerEditorLayout({
    super.key,
    required this.editing,
    required this.bodyBuilder,
    required this.toolbar,
    required this.panel,
  });
  final bool editing;
  final Widget Function(
    BuildContext context,
    double bottomInset,
    double viewportHeight,
  )
  bodyBuilder;
  final Widget toolbar;
  final Widget panel;

  @override
  State<ComposerEditorLayout> createState() => _ComposerEditorLayoutState();
}

class _ComposerEditorLayoutState extends State<ComposerEditorLayout>
    with SingleTickerProviderStateMixin {
  late final _keyboard = ComposerKeyboardDismissController(vsync: this);
  @override
  void dispose() {
    _keyboard.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ComposerKeyboardDismissScope(
    controller: _keyboard,
    child: Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, viewport) => Stack(
              key: const ValueKey('composer-writing-canvas'),
              fit: StackFit.expand,
              children: [
                MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    size: Size(
                      viewport.maxWidth,
                      MediaQuery.sizeOf(context).height,
                    ),
                  ),
                  child: widget.bodyBuilder(
                    context,
                    ComposerWorkbench.occupiedHeight(context, widget.editing) +
                        12,
                    viewport.maxHeight,
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ComposerChromeVisibility(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: _WorkbenchViewport(
                        height: viewport.maxHeight,
                        child: widget.toolbar,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedBuilder(
          animation: _keyboard,
          child: widget.panel,
          builder: (_, child) => SizedBox(
            key: const ValueKey('composer-keyboard-space'),
            height: _keyboard.active ? _keyboard.visibleHeight : null,
            child: ClipRect(child: child),
          ),
        ),
      ],
    ),
  );
}

/// 桌面属性属于文档头部，不进入悬浮格式工具栏。
class ComposerDesktopMetadata extends StatelessWidget {
  const ComposerDesktopMetadata({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => TextFieldTapRegion(
    child: Padding(
      key: const ValueKey('composer-document-metadata'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: child,
        ),
      ),
    ),
  );
}

/// 预览覆盖当前编辑器，保留其输入状态、选区和撤销历史。
class ComposerPreviewPane extends StatelessWidget {
  const ComposerPreviewPane({
    super.key,
    required this.previewing,
    required this.editor,
    required this.preview,
    this.previewFooter,
  });
  final bool previewing;
  final Widget editor;
  final Widget preview;
  final Widget? previewFooter;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Offstage(
        offstage: previewing,
        child: TickerMode(
          enabled: !previewing,
          child: ExcludeFocus(excluding: previewing, child: editor),
        ),
      ),
      if (previewing) ...[
        preview,
        if (previewFooter != null)
          Positioned(left: 0, right: 0, bottom: 0, child: previewFooter!),
      ],
    ],
  );
}

class ComposerPreviewFooter extends StatelessWidget {
  const ComposerPreviewFooter({super.key, this.metadata, required this.rich});
  final Widget? metadata;
  final bool rich;
  @override
  Widget build(BuildContext context) {
    if (PlatformUtils.isDesktop) return const SizedBox.shrink();
    return ComposerChromeVisibility(
      child: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ComposerWorkbench(
            metadata: metadata == null ? null : IgnorePointer(child: metadata),
            editing: false,
            controls: [ComposerModeButton(rich: rich)],
            tools: const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
