import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/preferences_provider.dart';
import 'package:common_ui/common_ui.dart';
import 'editor_tools.dart';
import 'markdown_toolbar.dart';
import '../../../../../l10n/s.dart';

/// 编辑器扩展工具面板
///
/// 移动端与表情面板共用 ChatBottomPanelContainer 机制，以网格形式展示
/// 全部 Markdown 工具（图标 + 文字标签）。支持「自定义」模式：点击格子
/// 切换工具是否常驻外显在工具栏中部（持久化到偏好）。
/// 实际的文本操作复用 [MarkdownToolbarState] 的公开方法。
class MarkdownToolPanel extends ConsumerStatefulWidget {
  /// 工具栏状态 key（复用工具栏的文本操作和上传逻辑）
  final GlobalKey<MarkdownToolbarState> toolbarKey;

  /// 工具执行后的回调（用于收起面板、切回键盘）
  final VoidCallback onAction;

  /// 混排优化回调（为 null 时不显示该工具，如已开启自动混排）
  final VoidCallback? onApplyPangu;

  const MarkdownToolPanel({
    super.key,
    required this.toolbarKey,
    required this.onAction,
    this.onApplyPangu,
  });

  @override
  ConsumerState<MarkdownToolPanel> createState() => _MarkdownToolPanelState();
}

class _MarkdownToolPanelState extends ConsumerState<MarkdownToolPanel> {
  /// 是否处于自定义模式（点击格子切换外显，而非执行工具）
  bool _customizing = false;

  /// 执行工具操作后收起面板。
  /// 先执行操作（弹窗类操作会在调用时捕获 Navigator），再收起面板。
  void _run(void Function(MarkdownToolbarState toolbar) action) {
    final toolbar = widget.toolbarKey.currentState;
    if (toolbar == null) return;
    action(toolbar);
    widget.onAction();
  }

  /// 切换工具是否外显在工具栏
  void _togglePinned(String id) {
    final current =
        List<String>.of(ref.read(preferencesProvider).editorToolbarTools);
    if (!current.remove(id)) {
      current.add(id);
    }
    ref.read(preferencesProvider.notifier).setEditorToolbarTools(current);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.l10n;
    final theme = Theme.of(context);
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    final pinnedIds = ref.watch(preferencesProvider).editorToolbarTools;

    return Column(
      children: [
        // 头部：标题/自定义提示 + 自定义/完成按钮
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _customizing ? s.toolPanel_customizeHint : s.toolbar_moreTools,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _customizing = !_customizing),
                child: Text(_customizing ? s.common_done : s.toolPanel_customize),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.count(
            crossAxisCount: 4,
            childAspectRatio: 0.92,
            mainAxisSpacing: 4,
            padding: EdgeInsets.fromLTRB(12, 8, 12, 16 + safeBottom),
            children: [
              for (final tool in editorTools) _buildCell(tool, pinnedIds),
              // 混排优化：依赖编辑器回调，不参与外显自定义
              if (widget.onApplyPangu != null && !_customizing)
                _ToolCell(
                  icon: const Icon(Icons.auto_fix_high_rounded),
                  label: s.toolbar_mixOptimize,
                  onTap: () {
                    widget.onApplyPangu!();
                    widget.onAction();
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCell(EditorTool tool, List<String> pinnedIds) {
    final s = context.l10n;
    final pinned = pinnedIds.contains(tool.id);

    // 自定义模式：点击切换外显，显示角标
    if (_customizing) {
      return _ToolCell(
        icon: tool.icon,
        label: tool.label(s),
        pinned: pinned,
        showPinBadge: true,
        onTap: () => _togglePinned(tool.id),
      );
    }

    if (tool.hasMenu) {
      return _ToolMenuCell(
        icon: tool.icon,
        label: tool.label(s),
        itemBuilder: (context) => tool.menuItems!(s),
        onSelected: (value) => _run((t) => tool.onMenuSelected!(t, value)),
      );
    }

    return _ToolCell(
      icon: tool.icon,
      label: tool.label(s),
      onTap: () => _run((t) => tool.action!(t)),
    );
  }
}

/// 网格单元格内容：圆角图标块 + 文字标签（自定义模式下带外显角标）
class _ToolCellBody extends StatelessWidget {
  final Widget icon;
  final String label;
  final bool pinned;
  final bool showPinBadge;

  const _ToolCellBody({
    required this.icon,
    required this.label,
    this.pinned = false,
    this.showPinBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final highlight = showPinBadge && pinned;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: highlight
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              // 通过 IconTheme 统一图标尺寸和颜色（兼容 FaIcon 和 Icon）
              child: IconTheme.merge(
                data: IconThemeData(
                  size: 20,
                  color: highlight
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurfaceVariant,
                ),
                child: icon,
              ),
            ),
            // 自定义模式角标：已外显 ✓ / 未外显 ＋
            if (showPinBadge)
              Positioned(
                right: -4,
                top: -4,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: pinned
                        ? theme.colorScheme.primary
                        : theme.colorScheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                    border: Border.fromBorderSide(
                      BorderSide(color: theme.colorScheme.surface, width: 1.5),
                    ),
                  ),
                  child: Icon(
                    pinned ? Icons.check : Icons.add,
                    size: 12,
                    color: pinned
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// 普通工具单元格（点击直接执行）
class _ToolCell extends StatelessWidget {
  final Widget icon;
  final String label;
  final VoidCallback onTap;
  final bool pinned;
  final bool showPinBadge;

  const _ToolCell({
    required this.icon,
    required this.label,
    required this.onTap,
    this.pinned = false,
    this.showPinBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: _ToolCellBody(
        icon: icon,
        label: label,
        pinned: pinned,
        showPinBadge: showPinBadge,
      ),
    );
  }
}

/// 带二级弹出菜单的工具单元格（标题级别、Callout 类型）
class _ToolMenuCell extends StatelessWidget {
  final Widget icon;
  final String label;
  final PopupMenuItemBuilder<String> itemBuilder;
  final PopupMenuItemSelected<String> onSelected;

  const _ToolMenuCell({
    required this.icon,
    required this.label,
    required this.itemBuilder,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SwipeDismissiblePopupMenuButton<String>(
      tooltip: label,
      borderRadius: BorderRadius.circular(14),
      itemBuilder: itemBuilder,
      onSelected: onSelected,
      child: _ToolCellBody(icon: icon, label: label),
    );
  }
}
