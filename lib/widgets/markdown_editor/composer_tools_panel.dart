import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'composer_chrome.dart';
import 'composer_tool_action.dart';
import 'composer_tool_cell.dart';
import 'composer_tools_anchor.dart';
export 'composer_tool_action.dart';

/// 工具属于浮岛的展开态，不推路由、不创建另一个表面。
Future<bool> showComposerTools(
  BuildContext context,
  List<ComposerToolAction> actions, {
  ComposerToolsAnchor? anchor,
  List<String> pinnedIds = const [],
}) async {
  if (anchor == null) return false;
  final release = ComposerChromeScope.maybeOf(context)?.hold();
  ComposerToolAction? picked;
  try {
    picked = await anchor.expand(actions, pinnedIds);
  } finally {
    release?.call();
  }
  if (!context.mounted || picked == null || !picked.enabled) return false;
  picked.run();
  return true;
}

class ComposerExpandedTools extends StatefulWidget {
  const ComposerExpandedTools({
    super.key,
    required this.anchor,
    required this.animation,
    required this.flyingIds,
    this.onCollapseStart,
    this.onCollapseUpdate,
    this.onCollapseEnd,
    this.onCollapseCancel,
  });
  final ComposerToolsAnchor anchor;
  final Animation<double> animation;
  final Set<String> flyingIds;
  final GestureDragStartCallback? onCollapseStart;

  /// 返回未被面板消耗的距离，用于反向还原后继续滚动工具列表。
  final double Function(double delta)? onCollapseUpdate;
  final ValueChanged<double>? onCollapseEnd;
  final VoidCallback? onCollapseCancel;
  @override
  State<ComposerExpandedTools> createState() => _ComposerExpandedToolsState();
}

class _ComposerExpandedToolsState extends State<ComposerExpandedTools> {
  final _scroll = ScrollController();
  bool _pulling = false;
  late final _physics = _ToolsPullPhysics(
    pulling: () => _pulling,
    updatePull: _updatePull,
    parent: const AlwaysScrollableScrollPhysics(),
  );

  double _updatePull(double delta) {
    final remaining = widget.onCollapseUpdate!(delta);
    if (delta < 0 && remaining < -.01) {
      _pulling = false;
      widget.onCollapseEnd?.call(0);
      return remaining;
    }
    return 0;
  }

  void _cancelPull() {
    if (!_pulling) return;
    _pulling = false;
    widget.onCollapseCancel?.call();
  }

  bool _onScroll(ScrollNotification notification) {
    if (widget.onCollapseUpdate == null || notification.depth != 0) {
      return false;
    }
    if (notification is OverscrollNotification &&
        notification.dragDetails != null &&
        notification.overscroll < 0 &&
        notification.metrics.pixels <=
            notification.metrics.minScrollExtent + .5 &&
        !_pulling) {
      final details = notification.dragDetails!;
      _pulling = true;
      widget.onCollapseStart?.call(
        DragStartDetails(
          sourceTimeStamp: details.sourceTimeStamp,
          globalPosition: details.globalPosition,
          localPosition: details.localPosition,
        ),
      );
      // 列表已经消耗了滚回顶部的距离，只交出边界之外的余量。
      _updatePull(-notification.overscroll);
    } else if (notification is ScrollEndNotification && _pulling) {
      final details = notification.dragDetails;
      if (details == null) {
        _cancelPull();
      } else {
        _pulling = false;
        widget.onCollapseEnd?.call(
          details.primaryVelocity ?? details.velocity.pixelsPerSecond.dy,
        );
      }
    }
    return false;
  }

  late final _initialPinned = <ComposerToolAction>[
    for (final id in widget.anchor.pinnedIds)
      ...widget.anchor.actions.where(
        (a) => a.keyId == id && a.isPinned?.call() == true,
      ),
    ...widget.anchor.actions.where(
      (a) =>
          a.isPinned?.call() == true &&
          !widget.anchor.pinnedIds.contains(a.keyId),
    ),
  ];
  ComposerToolAction? _parent;
  @override
  void initState() {
    super.initState();
    widget.anchor.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.anchor.removeListener(_refresh);
    _scroll.dispose();
    super.dispose();
  }

  void _choose(ComposerToolAction action) {
    if (widget.anchor.customizing) {
      if (action.togglePinned != null) setState(action.togglePinned!);
    } else if (action.children.isNotEmpty) {
      setState(() => _parent = action);
      _scroll.jumpTo(0);
    } else if (action.enabled) {
      widget.anchor.collapse(action);
    }
  }

  Widget _cell(ComposerToolAction action) {
    final canPin = action.togglePinned != null;
    final targetKey = widget.anchor.targets.putIfAbsent(
      action.keyId,
      GlobalKey.new,
    );
    final icon = ComposerToolGlyph(key: targetKey, icon: action.icon);
    return Semantics(
      button: true,
      label: action.label,
      toggled: widget.anchor.customizing && canPin
          ? action.isPinned?.call() == true
          : null,
      child: Opacity(
        opacity: (widget.anchor.customizing ? canPin : action.enabled)
            ? 1
            : .38,
        child: ToolCell(
          key: ValueKey('composer-tool-${action.keyId}'),
          onLongPress: canPin && !widget.anchor.customizing
              ? widget.anchor.toggleCustomizing
              : null,
          icon: AnimatedBuilder(
            animation: widget.animation,
            builder: (_, child) => Opacity(
              opacity:
                  widget.flyingIds.contains(action.keyId) &&
                      widget.animation.status != AnimationStatus.completed
                  ? 0
                  : 1,
              child: child,
            ),
            child: icon,
          ),
          label: action.label,
          pinned: widget.anchor.customizing
              ? action.isPinned?.call() == true
              : action.active,
          showPinBadge: widget.anchor.customizing && canPin,
          onTap: (widget.anchor.customizing ? canPin : action.enabled)
              ? () => _choose(action)
              : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final scaler = MediaQuery.textScalerOf(context);
      final columns = (bounds.maxWidth / math.max(80.0, scaler.scale(56) + 24))
          .floor()
          .clamp(2, 6);
      const gridInset = 8.0;
      final columnWidth = (bounds.maxWidth - gridInset * 2) / columns;
      // 图标卡片在列内居中，分类名对齐卡片边缘，而不是列的外边缘。
      final headingInset =
          gridInset +
          math.max(0.0, (columnWidth - ToolCellBody.iconExtent) / 2);
      final gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisExtent: math.max(84, scaler.scale(12) * 1.4 + 64),
        mainAxisSpacing: 4,
      );
      Widget grid(List<ComposerToolAction> actions) => SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: gridInset),
        sliver: SliverGrid(
          gridDelegate: gridDelegate,
          delegate: SliverChildBuilderDelegate(
            (_, index) => _cell(actions[index]),
            childCount: actions.length,
          ),
        ),
      );
      final nested = _parent != null && !widget.anchor.customizing;
      final groups = {
        for (final group in ComposerToolGroup.values)
          group: widget.anchor.actions
              .where((a) => a.group == group && !_initialPinned.contains(a))
              .toList(),
      };
      return Column(
        key: const ValueKey('composer-tools-panel'),
        children: [
          if (nested)
            Align(
              alignment: Alignment.centerLeft,
              child: BackButton(
                onPressed: () => setState(() => _parent = null),
              ),
            ),
          Expanded(
            child: ClipRect(
              child: Listener(
                onPointerCancel: (_) => _cancelPull(),
                child: NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: NotificationListener<OverscrollIndicatorNotification>(
                    onNotification: (notification) {
                      if (widget.onCollapseUpdate != null &&
                          notification.leading) {
                        notification.disallowIndicator();
                      }
                      return false;
                    },
                    child: CustomScrollView(
                      controller: _scroll,
                      physics: widget.onCollapseUpdate == null
                          ? null
                          : _physics,
                      slivers: [
                        const SliverToBoxAdapter(child: SizedBox(height: 4)),
                        if (nested)
                          grid(_parent!.children)
                        else ...[
                          // 固定工具保留原顺序和起始位置，继续承接底栏的迁移动画。
                          if (_initialPinned.isNotEmpty) grid(_initialPinned),
                          for (final entry in groups.entries)
                            if (entry.value.isNotEmpty) ...[
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: EdgeInsets.fromLTRB(
                                    headingInset,
                                    10,
                                    headingInset,
                                    4,
                                  ),
                                  child: Semantics(
                                    header: true,
                                    child: Text(
                                      entry.key.label,
                                      key: ValueKey(
                                        'composer-tools-group-${entry.key.name}',
                                      ),
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelMedium
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                    ),
                                  ),
                                ),
                              ),
                              grid(entry.value),
                            ],
                        ],
                        const SliverToBoxAdapter(child: SizedBox(height: 8)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// 沿用 Scrollable 的同一个拖拽识别器。面板接管期间冻结列表；
/// 反向还原后的余量再交回列表，不抢手势，也不带出惯性滚动。
class _ToolsPullPhysics extends ClampingScrollPhysics {
  const _ToolsPullPhysics({
    required this.pulling,
    required this.updatePull,
    super.parent,
  });
  final bool Function() pulling;
  final double Function(double) updatePull;

  @override
  _ToolsPullPhysics applyTo(ScrollPhysics? ancestor) => _ToolsPullPhysics(
    pulling: pulling,
    updatePull: updatePull,
    parent: buildParent(ancestor),
  );

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) =>
      pulling()
      ? updatePull(offset)
      : super.applyPhysicsToUserOffset(position, offset);

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) => pulling() ? null : super.createBallisticSimulation(position, velocity);
}
