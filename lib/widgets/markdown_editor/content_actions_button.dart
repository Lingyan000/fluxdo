/// 「内容操作」按钮：把作用于**文字本身**的操作收进一个入口。
///
/// **为什么要单独一个按钮**：底部工具栏原来把两类完全不同的东西混在一条
/// 横栏里 —— 作用于「文字内容」的（全选/撤销/恢复/复制/粘贴/剪切）和作用
/// 于「文字样式」的（粗体/列表/引用…）。前者有 6 个，各占一个 40pt 常驻
/// 位，把后者挤到 320pt 屏上只剩 46~82pt 的可滚区（滚动比高达 12:1）。
///
/// 收成一个按钮后：
/// - 点按 → 弹菜单选；
/// - 长按滑动 → 径向速选，松手即执行（复用 [RadialLongPressMenu]，与话题
///   进度条/头像菜单同一套手势语言）。
///
/// 菜单位置保持稳定；撤销/恢复随历史栈启用，复制/剪切随选区启用。
/// 点按与长按速选共用同一份动作和可用性判断。
library;

import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';

import '../../../../../l10n/s.dart';
import '../common/radial_long_press_menu.dart';

/// 内容操作的能力提供方。
///
/// 富文本走 `FluxdoEditorContentActions`（编辑器内核句柄），源码模式走
/// `TextEditingController` + `UndoHistoryController` —— 两者动作语义相同、
/// 实现完全不同，用这个接口抹平，按钮本身不关心背后是谁。
abstract class ContentActionsProvider {
  bool get canUndo;
  bool get canRedo;

  /// 是否有非折叠选区（决定复制/剪切是否可用）。
  bool get hasSelection;

  /// 编辑目标当前是否可用（未挂载/失焦时整个按钮禁用）。
  bool get isAvailable;

  void undo();
  void redo();
  void selectAll();
  void copy();
  void cut();
  void paste();
}

/// 内容操作按钮。
class ContentActionsButton extends StatelessWidget {
  const ContentActionsButton({
    super.key,
    required this.provider,
    required this.listenable,
    this.iconSize = 20,
  });

  final ContentActionsProvider provider;

  /// 驱动重建的信号源（编辑器状态 / controller）——菜单可用性随它变化。
  final Listenable listenable;

  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) {
        // 「撤销可用」是这个按钮最主要的活跃信号：有历史 = 用户已经在写了
        final active = provider.canUndo;
        return RadialLongPressMenu(
          itemsBuilder: () => _buildItems(context),
          onTap: () => _showTapMenu(context),
          child: Tooltip(
            message: S.current.toolbar_contentActions,
            child: SizedBox(
              width: 48,
              height: 48,
              child: Center(
                child: AppIcon(
                  AppIcons.contentActions,
                  size: iconSize,
                  color: active
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.45,
                        ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 构造当前可用的菜单项（顺序 = 使用频率降序）。
  List<RadialMenuItem> _buildItems(BuildContext context) {
    if (!provider.isAvailable) return const [];
    final s = S.current;
    final items = [
      RadialMenuItem(
        icon: Symbols.undo_rounded,
        label: s.toolbar_undo,
        onSelected: provider.undo,
        enabled: provider.canUndo,
      ),
      RadialMenuItem(
        icon: Symbols.redo_rounded,
        label: s.toolbar_redo,
        onSelected: provider.redo,
        enabled: provider.canRedo,
      ),
      RadialMenuItem(
        icon: Symbols.select_all_rounded,
        label: s.toolbar_selectAll,
        onSelected: provider.selectAll,
      ),
      RadialMenuItem(
        icon: Symbols.content_copy_rounded,
        label: s.common_copy,
        onSelected: provider.copy,
        enabled: provider.hasSelection,
      ),
      RadialMenuItem(
        icon: Symbols.content_cut_rounded,
        label: s.toolbar_cut,
        onSelected: provider.cut,
        enabled: provider.hasSelection,
      ),
      RadialMenuItem(
        icon: Symbols.content_paste_rounded,
        label: s.common_paste,
        onSelected: provider.paste,
      ),
    ];
    return items;
  }

  /// 点按路径：弹常规菜单（不是所有人都会用长按滑动，也便于无障碍）。
  Future<void> _showTapMenu(BuildContext context) async {
    final items = _buildItems(context);
    if (items.isEmpty) return;

    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;

    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final position = RelativeRect.fromLTRB(
      topLeft.dx,
      topLeft.dy - 8,
      overlay.size.width - topLeft.dx - box.size.width,
      overlay.size.height - topLeft.dy,
    );

    final theme = Theme.of(context);
    final picked = await showMenu<int>(
      context: context,
      position: position,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      items: [
        for (var i = 0; i < items.length; i++)
          PopupMenuItem<int>(
            value: i,
            height: 48,
            enabled: items[i].enabled,
            child: Row(
              children: [
                Icon(
                  items[i].icon,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Text(items[i].label),
              ],
            ),
          ),
      ],
    );
    if (context.mounted &&
        picked != null &&
        picked < items.length &&
        items[picked].enabled) {
      items[picked].onSelected();
    }
  }
}
