import 'dart:math' as math;
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';

/// 编辑中的操作菜单不抢输入焦点，优先在按钮上方、键盘之外展开。
Future<T?> showComposerActionMenu<T>({
  required BuildContext context,
  required List<PopupMenuEntry<T>> items,
}) async {
  final box = context.findRenderObject();
  final navigator = Navigator.of(context);
  final overlay = navigator.overlay?.context.findRenderObject();
  if (items.isEmpty || box is! RenderBox || overlay is! RenderBox) return null;
  final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  final media = MediaQuery.of(context);
  final visibleBottom =
      overlay.size.height -
      math.max(media.viewInsets.bottom, media.viewPadding.bottom) -
      8;
  final minimumTop = media.viewPadding.top + 8;
  var bottom = math.min(rect.top - 8, visibleBottom);
  if (bottom - minimumTop < 48) bottom = visibleBottom;
  final available = math.max(0.0, bottom - minimumTop);
  final height = math.min(
    available,
    items.fold<double>(16, (height, item) => height + item.height),
  );
  final width = math.min(
    280.0,
    overlay.size.width - media.viewPadding.horizontal - 16,
  );
  final theme = Theme.of(context);
  return showSwipeDismissibleMenu<T>(
    context: context,
    navigator: navigator,
    requestFocus: false,
    position: RelativeRect.fromRect(
      Rect.fromLTRB(rect.left, bottom - height, rect.right, bottom),
      Offset.zero & overlay.size,
    ),
    animationAnchorRect: rect,
    constraints: BoxConstraints(
      minWidth: math.min(160.0, width),
      maxWidth: width,
      maxHeight: height,
    ),
    menuPadding: const EdgeInsets.symmetric(vertical: 8),
    color: theme.colorScheme.surfaceContainerLow,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(
        color: theme.colorScheme.outlineVariant.withValues(alpha: .5),
        width: .6,
      ),
    ),
    items: items,
  );
}
