import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit, ScrollDirection;
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:material_ui/material_ui.dart';
import 'package:positioned_sliver_list/positioned_sliver_list.dart';

import '../../../l10n/s.dart';
import '../../../utils/dialog_utils.dart';
import '../controllers/topic_toc_controller.dart';

/// 正文左侧的目录大纲。展开和收起时，靠近正文的一侧保持固定。
class TopicTocSidePanel extends StatelessWidget {
  const TopicTocSidePanel({
    super.key,
    required this.controller,
    required this.visible,
    required this.onToggleVisible,
    required this.onEntryTap,
    required this.maxHeight,
  });

  final TopicTocController controller;
  final bool visible;
  final VoidCallback onToggleVisible;
  final ValueChanged<TocEntry> onEntryTap;
  final double maxHeight;

  static const double expandedWidth = 240;
  static const double collapsedWidth = 44;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: _tocMotion(context),
      curve: Curves.easeOutCubic,
      width: visible ? expandedWidth : collapsedWidth,
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: ClipRect(
        child: Material(
          type: MaterialType.transparency,
          child: visible
              ? OverflowBox(
                  // 只裁剪宽度动画，面板高度取标题和列表的实际高度。
                  fit: OverflowBoxFit.deferToChild,
                  alignment: Alignment.topRight,
                  minWidth: expandedWidth,
                  maxWidth: expandedWidth,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Semantics(
                        button: true,
                        expanded: true,
                        child: Tooltip(
                          message: context.l10n.topicDetail_tocCollapse,
                          child: ListTile(
                            onTap: onToggleVisible,
                            minTileHeight: collapsedWidth,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            shape: RoundedSuperellipseBorder(
                              borderRadius: context.shapes.borderRadius(8),
                            ),
                            title: _TocTitle(controller: controller),
                            trailing: Icon(
                              AppIcons.chevronLeft,
                              size: 20,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                      Flexible(
                        child: _TocTree(
                          controller: controller,
                          onEntryTap: onEntryTap,
                        ),
                      ),
                    ],
                  ),
                )
              : Align(
                  alignment: Alignment.topRight,
                  heightFactor: 1,
                  child: Semantics(
                    expanded: false,
                    child: IconButton(
                      tooltip: context.l10n.topicDetail_tocExpand,
                      onPressed: onToggleVisible,
                      icon: const Icon(Symbols.toc_rounded),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

Duration _tocMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.reduceMotionOf(context)
    ? Duration.zero
    : const Duration(milliseconds: 180);

class _TocTitle extends StatelessWidget {
  const _TocTitle({required this.controller});

  final TopicTocController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(Symbols.toc_rounded, size: 20, color: context.emphasis.accent),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            context.l10n.topicDetail_toc,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 8),
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Text(
            '${controller.tocData?.flat.length ?? 0}',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// 正文两侧放不下大纲时从底栏上方打开目录。
class TopicTocFab extends StatelessWidget {
  const TopicTocFab({
    super.key,
    required this.controller,
    required this.onEntryTap,
  });

  final TopicTocController controller;
  final ValueChanged<TocEntry> onEntryTap;

  @override
  Widget build(BuildContext context) => FloatingActionButton.small(
    heroTag: null,
    tooltip: context.l10n.topicDetail_toc,
    onPressed: () => showTocBottomSheet(
      context: context,
      controller: controller,
      onEntryTap: onEntryTap,
    ),
    child: const Icon(Symbols.toc_rounded, size: 22),
  );
}

Future<void> showTocBottomSheet({
  required BuildContext context,
  required TopicTocController controller,
  required ValueChanged<TocEntry> onEntryTap,
}) async {
  final entry = await showAppBottomSheet<TocEntry>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    showDragHandle: false,
    builder: (_) => _TocSheet(controller: controller),
  );
  if (entry != null && context.mounted) onEntryTap(entry);
}

class _TocSheet extends StatefulWidget {
  const _TocSheet({required this.controller});

  final TopicTocController controller;

  @override
  State<_TocSheet> createState() => _TocSheetState();
}

class _TocSheetState extends State<_TocSheet> {
  static const _initialSize = .60;
  static const _minSize = .38;
  static const _maxSize = .95;
  final _extent = DraggableScrollableController();

  @override
  void dispose() {
    _extent.dispose();
    super.dispose();
  }

  Widget _buildContent(
    BuildContext context, [
    ScrollController? scrollController,
  ]) {
    return AppSheetScaffold(
      titleWidget: _TocTitle(controller: widget.controller),
      contentPadding: EdgeInsets.zero,
      expandToFill: scrollController != null,
      child: _TocTree(
        controller: widget.controller,
        inSheet: true,
        scrollController: scrollController,
        onEntryTap: (entry) => Navigator.of(context).pop(entry),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // 用弹层实际拿到的高度判断，旋转屏幕时也会重新排版。
      final listRoom =
          constraints.maxHeight * _initialSize -
          MediaQuery.paddingOf(context).bottom -
          kToolbarHeight -
          24;
      final count = widget.controller.tocData?.flat.length ?? 0;
      if (count * kMinInteractiveDimension <= listRoom) {
        return _buildContent(context);
      }

      return DraggableScrollableSheet(
        controller: _extent,
        initialChildSize: _initialSize,
        minChildSize: _minSize,
        maxChildSize: _maxSize,
        expand: false,
        builder: (context, scrollController) => GestureDetector(
          // 列表自己接管内容区的拖动。标题和把手可直接调整面板高度，
          // 即使打开时已定位到目录中段，也无需先翻回第一项。
          excludeFromSemantics: true,
          onVerticalDragUpdate: (drag) {
            final size = _extent.size - _extent.pixelsToSize(drag.delta.dy);
            _extent.jumpTo(size.clamp(_minSize, _maxSize));
          },
          child: _buildContent(context, scrollController),
        ),
      );
    },
  );
}

/// 侧栏与弹层共用同一棵目录树，标题可换行，定位按条目索引进行。
class _TocTree extends StatefulWidget {
  const _TocTree({
    required this.controller,
    required this.onEntryTap,
    this.inSheet = false,
    this.scrollController,
  });

  final TopicTocController controller;
  final ValueChanged<TocEntry> onEntryTap;
  final bool inSheet;
  final ScrollController? scrollController;

  @override
  State<_TocTree> createState() => _TocTreeState();
}

class _TocTreeState extends State<_TocTree> {
  final _list = ListController();
  TocData? _data;
  List<({TocEntry entry, int depth})> _items = const [];
  String? _activeId;

  @override
  void initState() {
    super.initState();
    _readController();
    widget.controller.addListener(_onTocChanged);
  }

  @override
  void didUpdateWidget(_TocTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTocChanged);
      widget.controller.addListener(_onTocChanged);
      _readController();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTocChanged);
    _list.dispose();
    super.dispose();
  }

  void _readController() {
    _activeId = widget.controller.activeHeadingId;
    final data = widget.controller.tocData;
    if (identical(data, _data)) return;
    _data = data;
    final items = <({TocEntry entry, int depth})>[];
    void walk(List<TocEntry> entries, int depth) {
      for (final entry in entries) {
        items.add((entry: entry, depth: depth));
        walk(entry.subItems, depth + 1);
      }
    }

    if (data != null) walk(data.tree, 0);
    _items = items;
  }

  void _onTocChanged() {
    final previous = _activeId;
    setState(_readController);
    // 弹层只在打开时定位，翻目录时不随正文移动。
    if (!widget.inSheet && _activeId != previous && _activeId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _followActive());
    }
  }

  int? get _activeIndex {
    if (_activeId == null) return null;
    final index = _items.indexWhere((item) => item.entry.id == _activeId);
    return index < 0 ? null : index;
  }

  void _followActive() {
    if (!mounted || !_list.isAttached) return;
    // 鼠标滚轮、拖动或惯性滚动期间，保留读者自行浏览的位置。
    if (_list.scrollPosition?.userScrollDirection != ScrollDirection.idle) {
      return;
    }
    final index = _activeIndex;
    if (index == null) return;
    final visible = _list.computeItemPositions();
    if (visible != null &&
        visible.any(
          (item) =>
              item.index == index &&
              item.itemLeadingEdge >= 0 &&
              item.itemTrailingEdge <= 1,
        )) {
      return;
    }
    _list.scrollToIndex(
      index,
      alignment: .35,
      duration: _tocMotion(context),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final inSheet = widget.inSheet;
    return SuperListView.builder(
      key: ObjectKey(widget.controller),
      primary: false,
      controller: widget.scrollController,
      listController: _list,
      shrinkWrap: widget.scrollController == null,
      initialIndex: _activeIndex,
      initialAlignment: .35,
      padding: EdgeInsets.fromLTRB(
        inSheet ? 16 : 8,
        2,
        inSheet ? 16 : 4,
        inSheet ? 12 : 4,
      ),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        return _TocTile(
          entry: item.entry,
          depth: item.depth,
          inSheet: inSheet,
          isActive: item.entry.id == _activeId,
          isAncestor: widget.controller.activeAncestorIds.contains(
            item.entry.id,
          ),
          onTap: () => widget.onEntryTap(item.entry),
        );
      },
    );
  }
}

class _TocTile extends StatelessWidget {
  const _TocTile({
    required this.entry,
    required this.depth,
    required this.inSheet,
    required this.isActive,
    required this.isAncestor,
    required this.onTap,
  });

  final TocEntry entry;
  final int depth;
  final bool inSheet;
  final bool isActive;
  final bool isAncestor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shape = RoundedSuperellipseBorder(
      borderRadius: context.shapes.borderRadius(8),
    );
    final selectedColor = context.emphasis.selected;
    final prominent = depth == 0 || isAncestor;
    final label = Text(
      entry.text,
      maxLines: inSheet ? null : 2,
      overflow: inSheet ? null : TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: isActive
            ? selectedColor
            : prominent
            ? scheme.onSurface
            : scheme.onSurfaceVariant,
        fontWeight: isActive || isAncestor
            ? FontWeight.w600
            : prominent
            ? FontWeight.w500
            : FontWeight.normal,
      ),
    );
    return Semantics(
      button: true,
      selected: isActive,
      child: Material(
        shape: shape,
        color: isActive
            ? selectedColor.withValues(alpha: .08)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          customBorder: shape,
          child: Stack(
            children: [
              PositionedDirectional(
                start: 1,
                top: isActive ? 5 : 0,
                bottom: isActive ? 5 : 0,
                width: isActive ? 3 : 1,
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    color: isActive ? selectedColor : scheme.outlineVariant,
                    shape: RoundedSuperellipseBorder(
                      borderRadius: context.shapes.borderRadius(2),
                    ),
                  ),
                ),
              ),
              ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: inSheet ? kMinInteractiveDimension : 36,
                ),
                child: Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(
                    14.0 + depth * 14,
                    inSheet ? 10 : 6,
                    8,
                    inSheet ? 10 : 6,
                  ),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    heightFactor: 1,
                    child: inSheet
                        ? label
                        : Tooltip(
                            message: entry.text,
                            excludeFromSemantics: true,
                            child: label,
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
