import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../utils/platform_utils.dart';
import 'composer_island.dart';
import 'composer_tools_anchor.dart';
import '../../l10n/s.dart';
import 'composer_view_mode_switcher.dart';
import 'composer_chrome.dart';
import 'composer_keyboard_dismiss.dart';
import 'composer_input_handoff.dart';
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
  static double occupiedHeight(
    BuildContext context,
    bool editing, {
    double? inputProgress,
  }) {
    final row = rowHeight(context);
    final progress = inputProgress ?? (editing ? 1.0 : 0.0);
    return (PlatformUtils.isDesktop
            ? row + 4
            : row + (ComposerToolsHandle.height + row + 4) * progress) +
        8 +
        kComposerIslandBottomGap;
  }

  @override
  State<ComposerWorkbench> createState() => _ComposerWorkbenchState();
}

class _ComposerWorkbenchState extends State<ComposerWorkbench>
    with TickerProviderStateMixin {
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
    reverseDuration: const Duration(milliseconds: 260),
  );
  late final _visualAnimation = AnimationController(vsync: this);
  late final _toolAnimation = _ToolTransitionAnimation(
    _visualAnimation,
    () => _animation.isAnimating || _dragging,
    () => _animation.status == AnimationStatus.reverse
        ? AnimationStatus.reverse
        : AnimationStatus.forward,
  );
  ComposerInputHandoff? _input;
  final _contentKey = GlobalKey();
  final _focus = FocusNode();
  List<String> _flightIds = [];
  List<Widget> _flightChildren = [];
  bool _dragging = false;
  bool _closingForInput = false;
  ComposerKeyboardDismissController? _keyboardGesture;
  bool _dragWasExpanded = false;
  double _expansionHeight = 400;
  double _gestureExtent = 400;
  double? _lastDragY;
  Offset _sourceBottomLeft = Offset.zero;
  Map<String, Rect> _sourceIcons = {};
  LocalHistoryEntry? _history;
  bool _presenting = false;
  Widget? _expandedTools;

  @override
  void initState() {
    super.initState();
    widget.toolsAnchor?.addListener(_changed);
    _animation.addStatusListener(_status);
    _animation.addListener(_moveInput);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _input = context
        .dependOnInheritedWidgetOfExactType<_WorkbenchViewport>()
        ?.input;
  }

  void _moveInput() {
    if (_presenting) _input?.update(_animation.value, dragging: _dragging);
  }

  bool _onHardwareKey(KeyEvent event) {
    if (!_presenting ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        ModalRoute.of(context)?.isCurrent != true) {
      return false;
    }
    widget.toolsAnchor?.collapse();
    return true;
  }

  @override
  void didUpdateWidget(covariant ComposerWorkbench oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.toolsAnchor != widget.toolsAnchor) {
      oldWidget.toolsAnchor?.removeListener(_changed);
      widget.toolsAnchor?.addListener(_changed);
    }
    if (!PlatformUtils.isDesktop &&
        !widget.editing &&
        _input?.active != true &&
        _presenting &&
        !_closingForInput) {
      _closingForInput = true;
      _gestureExtent = _expansionHeight;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.editing) return;
        _dragging = false;
        _lastDragY = null;
        widget.toolsAnchor?.collapse();
      });
    }
  }

  void _changed() {
    final anchor = widget.toolsAnchor!;
    if (anchor.expanded && !_presenting) {
      _sourceIcons = anchor.visibleIcons();
      _sourceBottomLeft = anchor.rect?.bottomLeft ?? Offset.zero;
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
      if (!PlatformUtils.isDesktop) {
        final viewport = context
            .dependOnInheritedWidgetOfExactType<_WorkbenchViewport>();
        _input?.begin(View.of(context), viewport?.panelHeight ?? 0);
      }
      _expandedTools = ComposerExpandedTools(
        anchor: anchor,
        animation: _toolAnimation,
        flyingIds: _flightIds.toSet(),
        onCollapseStart: PlatformUtils.isDesktop ? null : _startDrag,
        onCollapseUpdate: PlatformUtils.isDesktop ? null : _dragFromPanel,
        onCollapseEnd: PlatformUtils.isDesktop ? null : _endDrag,
        onCollapseCancel: PlatformUtils.isDesktop ? null : _cancelDrag,
      );
      anchor.animation = _toolAnimation;
      _history = LocalHistoryEntry(
        impliesAppBarDismissal: false,
        onRemove: () {
          final fromSystem = _history != null;
          _history = null;
          if (fromSystem) anchor.dismiss();
        },
      );
      ModalRoute.of(context)?.addLocalHistoryEntry(_history!);
      setState(() {});
      if (!_dragging) _settle(true);
      if (!_dragging && PlatformUtils.isDesktop) _focus.requestFocus();
    } else if (_presenting) {
      if (!_dragging) _settle(anchor.expanded);
      if (mounted) setState(() {});
    } else if (mounted) {
      setState(() {});
    }
  }

  void _status(AnimationStatus status) {
    if (!_dragging &&
        (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed)) {
      _input?.reachedTarget(status == AnimationStatus.completed);
    }
    if (status != AnimationStatus.dismissed || !_presenting || _dragging) {
      return;
    }
    if (_input?.active == true && !_input!.readyToFinish) return;
    _sourceIcons = {};
    _closingForInput = false;
    _presenting = false;
    _expandedTools = null;
    final history = _history;
    _history = null;
    history?.remove();
    widget.toolsAnchor?.finish();
    _input?.finish();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    widget.toolsAnchor?.removeListener(_changed);
    widget.toolsAnchor?.finish();
    _history?.remove();
    _input?.finish();
    _animation.dispose();
    _visualAnimation.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _toggle() {
    if (!PlatformUtils.isDesktop && !widget.editing && !_presenting) return;
    if (widget.toolsAnchor?.presenting == true) {
      _setExpansion(!widget.toolsAnchor!.expanded);
    } else {
      widget.onExpandTools?.call();
    }
  }

  void _setExpansion(bool open) {
    final anchor = widget.toolsAnchor;
    if (open && anchor?.expanded == false) {
      anchor!.reopen();
    } else if (!open && anchor?.expanded == true) {
      anchor!.collapse();
    } else {
      _settle(open);
    }
  }

  void _settle(bool open) {
    _input?.settle(
      open,
      restoreInput: widget.toolsAnchor?.restoreInput ?? true,
    );
    final target = open ? 1.0 : 0.0;
    final remaining = (target - _animation.value).abs();
    if (remaining == 0) {
      _input?.reachedTarget(open);
      if (!open) _status(AnimationStatus.dismissed);
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.value = target;
      return;
    }
    final duration = Duration(
      milliseconds:
          ((open
                      ? 380
                      : (!PlatformUtils.isDesktop &&
                                (!widget.editing || _input?.dismissing == true)
                            ? 160
                            : 260)) *
                  remaining)
              .round(),
    );
    if (open) {
      _animation.animateTo(
        target,
        duration: duration,
        curve: Curves.easeOutCubic,
      );
    } else {
      _animation.animateBack(
        target,
        duration: duration,
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _startDrag(DragStartDetails details) {
    if (!PlatformUtils.isDesktop && !widget.editing && !_presenting) return;
    _dragWasExpanded = widget.toolsAnchor?.expanded ?? false;
    _dragging = true;
    _lastDragY = details.globalPosition.dy;
    _gestureExtent = _input?.active == true
        ? math.max(48, _mobileLift)
        : _expansionHeight;
    _keyboardGesture = null;
    if (_presenting) _animation.stop();
  }

  void _dragUpdate(DragUpdateDetails details) {
    final y = details.globalPosition.dy;
    final delta = _lastDragY == null ? details.delta.dy : y - _lastDragY!;
    _lastDragY = y;
    _drag(delta);
  }

  void _drag(double delta) {
    if (!PlatformUtils.isDesktop && !widget.editing && !_presenting) return;
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
      if (_input?.active == true) _gestureExtent = math.max(48, _mobileLift);
    }
    if (!_presenting || _gestureExtent <= 0) return;
    // value 就是几何进度，拖动不经过补间曲线，也不依赖移动控件的局部坐标。
    _animation.value = (_animation.value - delta / _gestureExtent).clamp(
      0.0,
      1.0,
    );
  }

  double _mobileLift = 96;

  double _dragFromPanel(double delta) {
    final previous = _animation.value;
    _drag(delta);
    return delta - (previous - _animation.value) * _gestureExtent;
  }

  void _cancelDrag() {
    // 轻点按钮赢得手势竞争时也会收到 cancel，此时并没有开始拖动。
    if (!_dragging) return;
    setState(() => _dragging = false);
    final keyboard = _keyboardGesture;
    _keyboardGesture = null;
    if (keyboard != null) {
      keyboard.end(0, cancel: true);
    } else if (_presenting) {
      _setExpansion(_dragWasExpanded);
    }
  }

  void _endDrag(double velocity) {
    if (!_dragging) return;
    setState(() => _dragging = false);
    final keyboard = _keyboardGesture;
    _keyboardGesture = null;
    if (keyboard != null) {
      keyboard.end(velocity);
      return;
    }
    if (!_presenting) return;
    final progress = _animation.value;
    final open =
        velocity < -240 ||
        (velocity <= 240 && progress > (_dragWasExpanded ? .84 : .16));
    _setExpansion(open);
    if (open && PlatformUtils.isDesktop) _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final desktop = PlatformUtils.isDesktop;
    final row = ComposerWorkbench.rowHeight(context);
    final viewport = context
        .dependOnInheritedWidgetOfExactType<_WorkbenchViewport>();
    final inputProgress =
        viewport?.inputProgress ?? (widget.editing ? 1.0 : 0.0);
    final handleHeight = !desktop && widget.onExpandTools != null
        ? ComposerToolsHandle.height * inputProgress
        : 0.0;
    final keyboard = ComposerKeyboardDismissScope.maybeOf(context);
    final editing =
        widget.editing || _presenting || (keyboard?.active ?? false);
    final footerHeight = desktop ? row + 4 : row + (row + 4) * inputProgress;
    final baseHeight = footerHeight + handleHeight;
    final available = viewport?.height ?? MediaQuery.sizeOf(context).height;
    final takeover = !desktop && _input?.active == true;
    _mobileLift = _input?.extraLift(available, baseHeight) ?? 96;
    final expansionHeight = takeover
        ? math.min(
            math.max(
                  0,
                  _input!.inputHeight -
                      MediaQuery.viewPaddingOf(context).bottom,
                ) +
                _mobileLift,
            math.max(
              0.0,
              available +
                  _input!.visibleHeight -
                  MediaQuery.viewPaddingOf(context).bottom -
                  baseHeight -
                  40,
            ),
          )
        : math.min(
            _dragging || _closingForInput
                ? _gestureExtent
                : (desktop ? 360.0 : 400.0),
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
                visible: inputProgress > 0,
                maintainState: true,
                maintainAnimation: true,
                child: IgnorePointer(
                  ignoring: !editing,
                  child: ClipRect(
                    child: Align(
                      heightFactor: inputProgress,
                      alignment: Alignment.bottomCenter,
                      child: Opacity(
                        opacity: inputProgress,
                        child: Container(
                          key: const ValueKey('composer-format-row'),
                          height: row + 4,
                          decoration: BoxDecoration(
                            border: Border(
                              top: BorderSide(
                                color: theme.colorScheme.outlineVariant
                                    .withValues(alpha: .45),
                              ),
                            ),
                          ),
                          child: widget.tools,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
    return TextFieldTapRegion(
      child: TapRegion(
        onTapOutside: _presenting ? (_) => widget.toolsAnchor?.dismiss() : null,
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
                        animation: Listenable.merge([_animation, _input]),
                        builder: (context, _) {
                          final revealed = takeover
                              ? math.min(
                                  math.max(0, available - baseHeight - 40),
                                  _input!.replacementHeight +
                                      _mobileLift * _animation.value,
                                )
                              : expansionHeight * _animation.value;
                          final progress = expansionHeight > 0
                              ? (revealed / expansionHeight).clamp(0.0, 1.0)
                              : _animation.value;
                          _visualAnimation.value = progress;
                          if (_presenting &&
                              !_dragging &&
                              _animation.isDismissed &&
                              (_input?.readyToFinish ?? true)) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted && _animation.isDismissed) {
                                _status(AnimationStatus.dismissed);
                              }
                            });
                          }
                          return SizedBox(
                            key: _contentKey,
                            height: baseHeight + revealed,
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
                                          _toolAnimation.status !=
                                          AnimationStatus.completed,
                                      child: Opacity(
                                        opacity: const Interval(
                                          .22,
                                          .82,
                                        ).transform(progress),
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
                                    onVerticalDragStart: editing
                                        ? _startDrag
                                        : null,
                                    onVerticalDragUpdate: editing
                                        ? _dragUpdate
                                        : null,
                                    onVerticalDragEnd: editing
                                        ? (details) => _endDrag(
                                            details.primaryVelocity ?? 0,
                                          )
                                        : null,
                                    onVerticalDragCancel: editing
                                        ? _cancelDrag
                                        : null,
                                    child: footer,
                                  ),
                                ),
                                if (!desktop && widget.onExpandTools != null)
                                  Positioned(
                                    key: const ValueKey(
                                      'composer-handle-region',
                                    ),
                                    left: 0,
                                    right: 0,
                                    top: 0,
                                    height: handleHeight,
                                    child: Visibility(
                                      visible: handleHeight > 0,
                                      maintainState: true,
                                      maintainAnimation: true,
                                      child: Opacity(
                                        opacity: inputProgress,
                                        child: ComposerToolsHandle(
                                          key: const ValueKey(
                                            'composer-tools-handle',
                                          ),
                                          label:
                                              widget.toolsAnchor?.expanded ==
                                                  true
                                              ? S
                                                    .current
                                                    .composer_collapseToolbar
                                              : S
                                                    .current
                                                    .composer_expandToolbar,
                                          expanded:
                                              widget.toolsAnchor?.expanded ??
                                              false,
                                          onActivate: _toggle,
                                          onDragStart: _startDrag,
                                          onDragUpdate: _dragUpdate,
                                          onDragEnd: (details) => _endDrag(
                                            details.primaryVelocity ?? 0,
                                          ),
                                          onDragCancel: _cancelDrag,
                                        ),
                                      ),
                                    ),
                                  ),
                                if (_flightIds.isNotEmpty &&
                                    (_animation.isAnimating ||
                                        progress > 0 && progress < 1 ||
                                        _dragging))
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: Flow(
                                        delegate: _ToolFlights(
                                          ids: _flightIds,
                                          sources: _sourceIcons,
                                          sourceBottomLeft: _sourceBottomLeft,
                                          anchor: widget.toolsAnchor!,
                                          contentKey: _contentKey,
                                          progress: progress,
                                          remainingHeight:
                                              expansionHeight - revealed,
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

/// 几何由键盘和手势共同决定；首尾帧仍保留运动方向，图标才能从
/// 原槽位接入飞行层，不会在反向的第一帧重叠或消失。
class _ToolTransitionAnimation extends Animation<double>
    with AnimationWithParentMixin<double> {
  _ToolTransitionAnimation(this.parent, this.moving, this.direction);
  @override
  final Animation<double> parent;
  final bool Function() moving;
  final AnimationStatus Function() direction;
  @override
  double get value => parent.value;
  @override
  AnimationStatus get status => moving() ? direction() : parent.status;
}

/// 用真实图标 Widget 迁移；布局只做一次，逐帧只更新绘制变换。
class _ToolFlights extends FlowDelegate {
  _ToolFlights({
    required this.ids,
    required this.sources,
    required this.sourceBottomLeft,
    required this.anchor,
    required this.contentKey,
    required this.progress,
    required this.remainingHeight,
  });
  final List<String> ids;
  final Map<String, Rect> sources;
  final Offset sourceBottomLeft;
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
    // 只测一次浮岛的位置；不再逐帧遍历每个来源图标的全部祖先裁剪链。
    final sourceShift =
        (anchor.rect?.bottomLeft ?? sourceBottomLeft) - sourceBottomLeft;
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      final target = anchor.targets[id]?.currentContext?.findRenderObject();
      if (target is! RenderBox || !target.attached || !target.hasSize) continue;
      final destination =
          (target.localToGlobal(Offset.zero) - Offset(0, remainingHeight)) &
          target.size;
      final start = sources[id]!.shift(sourceShift);
      final delay = math.min(i, 5) * .012;
      final t = Interval(
        .04 + delay,
        .92 + delay,
        curve: Curves.linear,
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
            0.0,
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
  const _WorkbenchViewport({
    required this.height,
    required this.inputProgress,
    required this.panelHeight,
    this.input,
    required super.child,
  });
  final double height;
  final double inputProgress;
  final double panelHeight;
  final ComposerInputHandoff? input;
  @override
  bool updateShouldNotify(_WorkbenchViewport oldWidget) =>
      height != oldWidget.height ||
      inputProgress != oldWidget.inputProgress ||
      panelHeight != oldWidget.panelHeight ||
      input != oldWidget.input;
}

/// 正文占满画布，工具岛覆盖其底部。只有键盘/扩展面板占独立布局空间。
class ComposerEditorLayout extends StatefulWidget {
  const ComposerEditorLayout({
    super.key,
    required this.editing,
    required this.bodyBuilder,
    required this.toolbar,
    required this.panel,
    this.toolsAnchor,
    this.holdInputToolbar = false,
    this.onResumeKeyboard,
    this.customPanelVisible = false,
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
  final ComposerToolsAnchor? toolsAnchor;

  /// 表情面板及其返回键盘的交接期保持完整工具行。
  final bool holdInputToolbar;
  final VoidCallback? onResumeKeyboard;
  final bool customPanelVisible;

  @override
  State<ComposerEditorLayout> createState() => _ComposerEditorLayoutState();
}

class _ComposerEditorLayoutState extends State<ComposerEditorLayout>
    with TickerProviderStateMixin {
  late final _keyboard = ComposerKeyboardDismissController(vsync: this)
    ..addListener(_onKeyboardActivity);
  late final _toolsInput = ComposerInputHandoff(_keyboard, vsync: this)
    ..onResumeKeyboard = widget.onResumeKeyboard
    ..addListener(_onToolsInput);
  final _panelKey = GlobalKey();
  bool _keyboardActive = false;
  late final _inputVisibility = AnimationController(
    vsync: this,
    value: widget.editing ? 1 : 0,
  );
  double? _inputTarget;
  bool _active = true;
  bool _disableAnimations = false;
  double _keyboardInset = 0;
  double _safeBottom = 0;
  double _inputRevealExtent = 76;
  bool _trackingKeyboard = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = MediaQuery.disableAnimationsOf(context);
    _keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    _safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    _toolsInput.updateMetrics(
      _keyboardInset,
      _safeBottom,
      customPanel: widget.customPanelVisible,
      disableAnimations: _disableAnimations,
    );
    _inputRevealExtent =
        ComposerWorkbench.rowHeight(context) + ComposerToolsHandle.height + 4;
    _syncInputVisibility();
  }

  void _onToolsInput() {
    if (!mounted || !_active) return;
    _syncInputVisibility();
    setState(() {});
  }

  @override
  void deactivate() {
    _active = false;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
    _syncInputVisibility();
  }

  @override
  void initState() {
    super.initState();
    widget.toolsAnchor?.addListener(_syncInputVisibility);
  }

  @override
  void didUpdateWidget(covariant ComposerEditorLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.toolsAnchor != widget.toolsAnchor) {
      oldWidget.toolsAnchor?.removeListener(_syncInputVisibility);
      widget.toolsAnchor?.addListener(_syncInputVisibility);
    }
    _toolsInput.onResumeKeyboard = widget.onResumeKeyboard;
    _toolsInput.updateMetrics(
      _keyboardInset,
      _safeBottom,
      customPanel: widget.customPanelVisible,
      disableAnimations: _disableAnimations,
    );
    _syncInputVisibility();
  }

  void _syncInputVisibility() {
    if (!_active) return;
    final nativeDriven =
        !PlatformUtils.isDesktop &&
        !widget.holdInputToolbar &&
        !_toolsInput.active &&
        widget.toolsAnchor?.presenting != true;
    if (nativeDriven &&
        (_keyboardInset > 0 || _keyboardActive || _trackingKeyboard)) {
      final height = _keyboardActive ? _keyboard.visibleHeight : _keyboardInset;
      final progress = ((height - _safeBottom) / _inputRevealExtent).clamp(
        0.0,
        1.0,
      );
      _trackingKeyboard = _keyboardInset > 0 || _keyboardActive;
      _inputTarget = progress;
      // Flutter 已逐帧同步原生 IME inset。位置和显隐共用这一进度，
      // 不能在键盘落到底后，再补一段独立的工具行收起动画。
      if (_inputVisibility.value != progress || _inputVisibility.isAnimating) {
        _inputVisibility.value = progress;
      }
      return;
    }
    _trackingKeyboard = false;
    final visible =
        !_toolsInput.dismissing &&
        (widget.editing || _keyboardActive || _toolsInput.active);
    // 工具岛先收拢，再退去格式行；两种编辑器和正文避让共用同一进度。
    if (!visible &&
        widget.toolsAnchor?.presenting == true &&
        !_toolsInput.dismissing) {
      return;
    }
    final target = visible ? 1.0 : 0.0;
    if (!_disableAnimations &&
        _inputVisibility.isAnimating &&
        _inputTarget == target) {
      return;
    }
    _inputTarget = target;
    if (_disableAnimations) {
      _inputVisibility.value = target;
    } else if (_inputVisibility.value == target) {
      _inputVisibility.stop();
    } else {
      _inputVisibility.animateTo(
        target,
        duration: Duration(milliseconds: visible ? 180 : 150),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _onKeyboardActivity() {
    if (!mounted) return;
    if (_keyboardActive != _keyboard.active) {
      setState(() => _keyboardActive = _keyboard.active);
    }
    _syncInputVisibility();
  }

  @override
  void dispose() {
    widget.toolsAnchor?.removeListener(_syncInputVisibility);
    _inputVisibility.dispose();
    _toolsInput.removeListener(_onToolsInput);
    _toolsInput.dispose();
    _keyboard.removeListener(_onKeyboardActivity);
    _keyboard.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ComposerKeyboardDismissScope(
    controller: _keyboard,
    active: _keyboardActive,
    child: AnimatedBuilder(
      animation: Listenable.merge([_inputVisibility, _toolsInput]),
      builder: (context, _) => Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, viewport) => Stack(
                key: const ValueKey('composer-writing-canvas'),
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    bottom: math.min(
                      _toolsInput.replacementHeight,
                      viewport.maxHeight,
                    ),
                    child: MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        size: Size(
                          viewport.maxWidth,
                          MediaQuery.sizeOf(context).height,
                        ),
                      ),
                      child: widget.bodyBuilder(
                        context,
                        ComposerWorkbench.occupiedHeight(
                              context,
                              widget.editing || _keyboardActive,
                              inputProgress: _inputVisibility.value,
                            ) +
                            12 +
                            (_toolsInput.active
                                ? _toolsInput.extraLift(
                                        viewport.maxHeight -
                                            ComposerChromeScope.topInsetOf(
                                              context,
                                            ),
                                        ComposerWorkbench.occupiedHeight(
                                              context,
                                              widget.editing,
                                              inputProgress:
                                                  _inputVisibility.value,
                                            ) -
                                            8 -
                                            kComposerIslandBottomGap,
                                      ) *
                                      _toolsInput.progress
                                : 0),
                        math.max(
                          0,
                          viewport.maxHeight - _toolsInput.replacementHeight,
                        ),
                      ),
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
                          inputProgress: _inputVisibility.value,
                          input: PlatformUtils.isDesktop ? null : _toolsInput,
                          panelHeight:
                              (_panelKey.currentContext?.findRenderObject()
                                      as RenderBox?)
                                  ?.size
                                  .height ??
                              math.max(_keyboardInset, _safeBottom),
                          // 页面正文可延伸到 AppBar 后方，展开的工具岛必须避让。
                          height: math.max(
                            0,
                            viewport.maxHeight -
                                ComposerChromeScope.topInsetOf(context),
                          ),
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
            animation: Listenable.merge([_keyboard, _toolsInput]),
            child: widget.panel,
            builder: (_, child) => SizedBox(
              key: const ValueKey('composer-keyboard-space'),
              height: _toolsInput.active
                  ? _toolsInput.visibleHeight
                  : (_keyboard.active ? _keyboard.visibleHeight : null),
              child: ClipRect(key: _panelKey, child: child),
            ),
          ),
        ],
      ),
    ),
  );
}

/// 普通键盘只按当前遮挡高度占位。缓存的终态高度仅用于表情切回键盘。
class ComposerKeyboardSpace extends StatelessWidget {
  const ComposerKeyboardSpace({
    super.key,
    this.heldHeight,
    this.onHandoffComplete,
  });
  final double? heldHeight;
  final VoidCallback? onHandoffComplete;

  @override
  Widget build(BuildContext context) {
    final actualHeight = MediaQuery.viewInsetsOf(context).bottom;
    if (heldHeight != null &&
        actualHeight >= heldHeight! - 1 &&
        onHandoffComplete != null) {
      // 原生终态高度也可能晚于最后一帧到达，此时宿主不会再收到 metrics 变化。
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => onHandoffComplete?.call(),
      );
    }
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        width: double.infinity,
        height: math.max(
          heldHeight ?? actualHeight,
          MediaQuery.viewPaddingOf(context).bottom,
        ),
      ),
    );
  }
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
