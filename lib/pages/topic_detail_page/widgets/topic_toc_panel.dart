import 'package:flutter/material.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

import '../../../l10n/s.dart';
import '../../../utils/dialog_utils.dart';
import '../controllers/topic_toc_controller.dart';

/// 话题目录(TOC)面板 —— 对齐 DiscoTOC 双形态:
/// - 宽屏:右侧常驻可折叠面板([TopicTocSidePanel]),scroll-spy 激活项
///   自动跟随进视口(用户拖拽面板滚动时不打扰);
/// - 窄屏:右下浮动按钮([TopicTocFab]) + bottom sheet,打开即定位到
///   当前阅读节点。

/// 宽屏右侧面板(展开 240 / 收起 44),高度随内容自适应、不超 [maxHeight]。
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

  /// 面板高度上限(页面按视口可用高度传入)。
  final double maxHeight;

  static const double expandedWidth = 240;
  static const double collapsedWidth = 44;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      width: visible ? expandedWidth : collapsedWidth,
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 1,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: visible
            ? OverflowBox(
                // 展开内容恒按 expandedWidth 布局:宽度动画(44↔240)途中
                // 不做窄布局,由 Card 的 clip 裁剪 —— 否则 header/深层目录项
                // 在中间宽度下 RenderFlex 溢出(对齐抽屉揭示动画做法)。
                // 高度方向保持有界(maxHeight),Column+Flexible 才合法。
                minWidth: expandedWidth,
                maxWidth: expandedWidth,
                minHeight: 0,
                maxHeight: maxHeight,
                alignment: Alignment.centerLeft,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _PanelHeader(
                      title: context.l10n.topicDetail_toc,
                      entryCount: controller.tocData?.flat.length ?? 0,
                      trailing: IconButton(
                        icon: const Icon(Icons.chevron_right, size: 20),
                        tooltip: context.l10n.topicDetail_tocCollapse,
                        visualDensity: VisualDensity.compact,
                        onPressed: onToggleVisible,
                      ),
                    ),
                    const Divider(height: 1),
                    // 展开即定位当前节点;后续 spy 激活变化自动跟随。
                    // Flexible+shrinkWrap:条目少时面板随之变矮,不留大段空白
                    Flexible(
                      child: _TocTree(
                        controller: controller,
                        onEntryTap: onEntryTap,
                        followActive: true,
                        shrinkWrap: true,
                      ),
                    ),
                  ],
                ),
              )
            : InkWell(
                onTap: onToggleVisible,
                child: SizedBox(
                  width: collapsedWidth,
                  height: collapsedWidth,
                  child: Center(
                    child: Tooltip(
                      message: context.l10n.topicDetail_tocExpand,
                      child: Icon(
                        Icons.format_list_bulleted,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.title, this.entryCount = 0, this.trailing});

  final String title;
  final int entryCount;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 14, right: 4),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            Icon(
              Icons.format_list_bulleted,
              size: 16,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (entryCount > 0)
              Text(
                '$entryCount',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// 窄屏浮动按钮:点击弹出目录 bottom sheet。
class TopicTocFab extends StatelessWidget {
  const TopicTocFab({
    super.key,
    required this.controller,
    required this.onEntryTap,
  });

  final TopicTocController controller;
  final ValueChanged<TocEntry> onEntryTap;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.small(
      heroTag: 'topic_toc_fab',
      tooltip: context.l10n.topicDetail_toc,
      onPressed: () => showTocBottomSheet(
        context: context,
        controller: controller,
        onEntryTap: onEntryTap,
      ),
      child: const Icon(Icons.format_list_bulleted, size: 20),
    );
  }
}

/// 目录 bottom sheet(窄屏点击 FAB 后弹出),打开即滚动到当前阅读节点。
Future<void> showTocBottomSheet({
  required BuildContext context,
  required TopicTocController controller,
  required ValueChanged<TocEntry> onEntryTap,
}) {
  return showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) {
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(sheetContext).size.height * 0.62,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PanelHeader(
              title: sheetContext.l10n.topicDetail_toc,
              entryCount: controller.tocData?.flat.length ?? 0,
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 20),
                visualDensity: VisualDensity.compact,
                onPressed: () => Navigator.of(sheetContext).pop(),
              ),
            ),
            const Divider(height: 1),
            // 弹框场景一次性定位(followActive=false:用户翻目录时
            // 帖子滚动不该把目录拽回去)
            Flexible(
              child: _TocTree(
                controller: controller,
                followActive: false,
                onEntryTap: (entry) {
                  Navigator.of(sheetContext).pop();
                  onEntryTap(entry);
                },
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// 目录树(面板与 bottom sheet 共用)。
///
/// 固定行高 + ListView.builder:激活项位置可精确计算,不依赖
/// ensureVisible(它会连帖子列表这个祖先 Scrollable 一起滚)。
/// 挂载完成先把激活项滚进视口;[followActive] 时后续 spy 激活变化
/// 自动跟随(用户正在拖拽滚动时跳过,不打断浏览)。
class _TocTree extends StatefulWidget {
  const _TocTree({
    required this.controller,
    required this.onEntryTap,
    required this.followActive,
    this.shrinkWrap = false,
  });

  final TopicTocController controller;
  final ValueChanged<TocEntry> onEntryTap;

  /// spy 激活变化时是否自动把激活项滚进视口(宽屏面板 true;
  /// bottom sheet false —— 打开定位一次即可)。
  final bool followActive;

  /// 宽屏面板传 true:条目少时高度随内容收缩。
  final bool shrinkWrap;

  /// 行高(itemExtent):固定才能按下标直接换算滚动偏移。
  static const double itemExtent = 40;

  @override
  State<_TocTree> createState() => _TocTreeState();
}

class _TocTreeState extends State<_TocTree> {
  final ScrollController _scrollController = ScrollController();

  /// 先序展开的扁平条目(与 TocData.flat 同序,带展示深度)。
  List<({TocEntry entry, int depth})> _items = const [];

  /// 上次跟随过的激活 id:controller 通知里据此判断激活项是否真变了
  /// (TOC 数据更新/重挂不该触发跟随)。
  String? _lastActiveId;
  TopicTocController get _toc => widget.controller;

  @override
  void initState() {
    super.initState();
    _items = _flatten(_toc.tocData);
    _lastActiveId = _toc.activeHeadingId;
    _toc.addListener(_onTocChanged);
    // 打开(或收起后展开)即定位到当前阅读节点
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollActiveIntoView(animate: false),
    );
  }

  @override
  void dispose() {
    _toc.removeListener(_onTocChanged);
    _scrollController.dispose();
    super.dispose();
  }

  static List<({TocEntry entry, int depth})> _flatten(TocData? data) {
    if (data == null) return const [];
    final out = <({TocEntry entry, int depth})>[];
    void walk(List<TocEntry> items, int depth) {
      for (final item in items) {
        out.add((entry: item, depth: depth));
        walk(item.subItems, depth + 1);
      }
    }

    walk(data.tree, 0);
    return out;
  }

  void _onTocChanged() {
    final next = _flatten(_toc.tocData);
    final activeId = _toc.activeHeadingId;
    final activeChanged = activeId != _lastActiveId;
    _lastActiveId = activeId;
    setState(() => _items = next);
    if (widget.followActive && activeChanged && activeId != null) {
      // 等 setState 落地、列表重建后再滚
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollActiveIntoView(animate: true),
      );
    }
  }

  int _activeIndexOf(List<({TocEntry entry, int depth})> items) {
    final activeId = _toc.activeHeadingId;
    if (activeId == null) return -1;
    return items.indexWhere((e) => e.entry.id == activeId);
  }

  /// 把激活项滚进视口;已在视口内/正在滚动(用户拖拽或跟随动画途中)
  /// 则不动。
  void _scrollActiveIntoView({required bool animate}) {
    if (!mounted || !_scrollController.hasClients) return;
    final index = _activeIndexOf(_items);
    if (index < 0) return;
    final pos = _scrollController.position;
    if (pos.isScrollingNotifier.value) return; // 用户拖拽/动画途中不打扰

    const extent = _TocTree.itemExtent;
    final itemTop = index * extent;
    final itemBottom = itemTop + extent;
    final viewTop = pos.pixels;
    final viewBottom = viewTop + pos.viewportDimension;
    if (itemTop >= viewTop && itemBottom <= viewBottom) return; // 已完整可见

    final target = (itemTop - pos.viewportDimension / 2 + extent / 2)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if (animate) {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const SizedBox.shrink();
    final activeId = _toc.activeHeadingId;
    final ancestors = _toc.activeAncestorIds;
    return ListView.builder(
      controller: _scrollController,
      shrinkWrap: widget.shrinkWrap,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemExtent: _TocTree.itemExtent,
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        return _TocTile(
          entry: item.entry,
          depth: item.depth,
          isActive: activeId == item.entry.id,
          isAncestorActive: ancestors.contains(item.entry.id),
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
    required this.isActive,
    required this.isAncestorActive,
    required this.onTap,
  });

  final TocEntry entry;
  final int depth;
  final bool isActive;
  final bool isAncestorActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // 对齐 DiscoTOC:direct-active 主色强调,active(祖先)主色弱化,
    // 其余 onSurfaceVariant;外加激活浅底 + 左指示条提升可辨识度。
    final Color textColor;
    final FontWeight weight;
    if (isActive) {
      textColor = scheme.primary;
      weight = FontWeight.w600;
    } else if (isAncestorActive) {
      textColor = scheme.primary.withValues(alpha: 0.75);
      weight = FontWeight.w500;
    } else {
      textColor = scheme.onSurfaceVariant;
      weight = FontWeight.w400;
    }

    return Padding(
      // 行高 40 = 上下各 2 间距 + 内部 36
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Material(
        color: isActive
            ? scheme.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          hoverColor: scheme.onSurface.withValues(alpha: 0.06),
          child: Padding(
            // 层级缩进:顶级 8,每深一级 +12
            padding: EdgeInsets.only(left: 8.0 + depth * 12, right: 6),
            child: Row(
              children: [
                // 激活指示条(非激活占位保对齐)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 3,
                  height: 16,
                  decoration: BoxDecoration(
                    color: isActive ? scheme.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    entry.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: textColor,
                      fontWeight: weight,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
