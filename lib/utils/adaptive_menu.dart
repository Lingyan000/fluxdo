import 'package:flutter/material.dart';
import 'package:common_ui/common_ui.dart';

import '../widgets/common/app_bottom_sheet.dart';
import 'platform_utils.dart';

/// 双模式菜单项:动作用数据描述一次,展示层按端自动分流
class AdaptiveMenuItem<T> {
  final T value;
  final IconData icon;
  final String label;
  final String? subtitle;
  final bool destructive;

  const AdaptiveMenuItem({
    required this.value,
    required this.icon,
    required this.label,
    this.subtitle,
    this.destructive = false,
  });
}

/// 分隔线占位(两个平台各自渲染合适的分隔形态)
class AdaptiveMenuDivider<T> extends AdaptiveMenuItem<T?> {
  const AdaptiveMenuDivider()
    : super(value: null, icon: Icons.remove, label: '');
}

/// 双模式菜单:桌面 = 锚点弹出菜单(showSwipeDismissibleMenu,项目标准
/// 右键/按钮菜单外壳);移动 = AppBottomSheet 底部弹层。
///
/// 目的:消灭散落各处的 `isDesktop ? 锚点 : 弹层` 手写分叉——菜单内容
/// 只声明一次,新增动作两端同时生效。
///
/// [anchorContext] 桌面锚点:优先用触发按钮的 context(菜单挂其下缘);
/// [globalPosition] 次优(右键场景传鼠标位置);都缺省时退化为移动弹层。
Future<T?> showAdaptiveMenu<T>({
  required BuildContext context,
  required List<AdaptiveMenuItem<T?>> items,
  BuildContext? anchorContext,
  Offset? globalPosition,
  String? title,
}) {
  final desktop = PlatformUtils.isDesktop;

  if (desktop) {
    Offset? anchor = globalPosition;
    Rect? anchorRect;
    if (anchor == null && anchorContext != null) {
      final box = anchorContext.findRenderObject() as RenderBox?;
      if (box != null && box.attached) {
        anchorRect = box.localToGlobal(Offset.zero) & box.size;
        anchor = anchorRect.bottomLeft;
      }
    }
    if (anchor != null) {
      final overlay =
          Overlay.of(context).context.findRenderObject() as RenderBox;
      // 锚点在屏幕下半部(输入条按钮等)时向上弹:菜单底缘贴按钮上缘,
      // 按钮不被盖,可以连续点开/点关。菜单高按条目估算。
      final estimatedHeight = items.fold<double>(
        16,
        (h, i) => h + (i is AdaptiveMenuDivider ? 8 : 42),
      );
      final openUpward =
          anchorRect != null &&
          anchorRect.bottom + estimatedHeight > overlay.size.height - 16;
      final RelativeRect position;
      if (openUpward) {
        position = RelativeRect.fromLTRB(
          anchorRect.left,
          (anchorRect.top - estimatedHeight - 4).clamp(8, double.infinity),
          overlay.size.width - anchorRect.left,
          overlay.size.height - anchorRect.top + 4,
        );
      } else {
        position = RelativeRect.fromLTRB(
          anchor.dx,
          anchor.dy,
          overlay.size.width - anchor.dx,
          overlay.size.height - anchor.dy,
        );
      }
      return showSwipeDismissibleMenu<T>(
        context: context,
        position: position,
        items: [
          for (final item in items)
            if (item is AdaptiveMenuDivider)
              const PopupMenuDivider(height: 8) as PopupMenuEntry<T>
            else
              PopupMenuItem<T>(
                value: item.value as T,
                height: 42,
                child: Row(
                  children: [
                    Icon(
                      item.icon,
                      size: 20,
                      color: item.destructive
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      item.label,
                      style: item.destructive
                          ? TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            )
                          : null,
                    ),
                  ],
                ),
              ),
        ],
      );
    }
  }

  // 移动端(或桌面无锚点兜底):底部弹层
  return AppBottomSheet.show<T>(
    context: context,
    title: title,
    showCloseButton: false,
    contentPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
    builder: (sheetContext) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final item in items)
          if (item is AdaptiveMenuDivider)
            Divider(
              height: 8,
              indent: 16,
              endIndent: 16,
              color: Theme.of(
                sheetContext,
              ).colorScheme.outlineVariant.withValues(alpha: 0.4),
            )
          else
            ListTile(
              leading: Icon(
                item.icon,
                color: item.destructive
                    ? Theme.of(sheetContext).colorScheme.error
                    : null,
              ),
              title: Text(
                item.label,
                style: item.destructive
                    ? TextStyle(color: Theme.of(sheetContext).colorScheme.error)
                    : null,
              ),
              subtitle: item.subtitle != null ? Text(item.subtitle!) : null,
              onTap: () => Navigator.pop(sheetContext, item.value),
            ),
      ],
    ),
  );
}
