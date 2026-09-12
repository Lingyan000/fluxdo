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
  });
  final ComposerToolsAnchor anchor;
  final Animation<double> animation;
  final Set<String> flyingIds;
  @override
  State<ComposerExpandedTools> createState() => _ComposerExpandedToolsState();
}

class _ComposerExpandedToolsState extends State<ComposerExpandedTools> {
  final _scroll = ScrollController();
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
              child: CustomScrollView(
                controller: _scroll,
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
                                style: Theme.of(context).textTheme.labelMedium
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
        ],
      );
    },
  );
}
