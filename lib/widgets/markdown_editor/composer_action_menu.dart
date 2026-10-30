import 'dart:math' as math;
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'composer_object_surface.dart';
import 'composer_menu_placement.dart';

double composerActionMenuWidth(BuildContext context) {
  final overlay = Navigator.of(context).overlay?.context.findRenderObject();
  final media = MediaQuery.of(context);
  return math.min(
    280.0,
    (overlay is RenderBox ? overlay.size.width : media.size.width) -
        media.viewPadding.horizontal -
        16,
  );
}

/// 编辑中的操作菜单不抢输入焦点，按完整菜单所需空间选择上下方向。
Future<T?> showComposerActionMenu<T>({
  required BuildContext context,
  required List<PopupMenuEntry<T>> items,
  double cornerRadius = 12,
  bool useGlass = false,
  Offset? globalPosition,
  Rect? globalAnchorRect,
  List<Rect> avoidRects = const [],
  Rect? globalViewport,
  Rect? keepVisibleRect,
  bool stayNearTrigger = false,
}) async {
  final box = context.findRenderObject();
  final navigator = Navigator.of(context);
  final overlay = navigator.overlay?.context.findRenderObject();
  if (items.isEmpty || box is! RenderBox || overlay is! RenderBox) return null;
  final rect = globalPosition != null
      ? overlay.globalToLocal(globalPosition) & Size.zero
      : globalAnchorRect != null
      ? Rect.fromPoints(
          overlay.globalToLocal(globalAnchorRect.topLeft),
          overlay.globalToLocal(globalAnchorRect.bottomRight),
        )
      : box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  final media = MediaQuery.of(context);
  final editorViewport = globalPosition == null && globalViewport != null
      ? Rect.fromPoints(
          overlay.globalToLocal(globalViewport.topLeft),
          overlay.globalToLocal(globalViewport.bottomRight),
        )
      : null;
  final visibleBottom = math.min(
    editorViewport?.bottom ?? overlay.size.height,
    overlay.size.height -
        math.max(media.viewInsets.bottom, media.viewPadding.bottom) -
        8,
  );
  final minimumTop =
      math.max(media.viewPadding.top, editorViewport?.top ?? 0) + 8;
  if (visibleBottom <= minimumTop) return null;
  final naturalHeight = items.fold<double>(
    16,
    (height, item) => height + item.height,
  );
  final aboveBottom = (rect.top - 8).clamp(minimumTop, visibleBottom);
  final belowTop = (rect.bottom + 8).clamp(minimumTop, visibleBottom);
  final above = aboveBottom - minimumTop;
  final below = visibleBottom - belowTop;
  final height = math.min(naturalHeight, visibleBottom - minimumTop);
  final double top;
  if (globalPosition != null) {
    top = rect.top.clamp(minimumTop, visibleBottom - height);
  } else if (above >= naturalHeight) {
    top = aboveBottom - height;
  } else if (below >= naturalHeight) {
    top = belowTop;
  } else {
    // 两侧都放不下时利用整个可视区；只在可视区本身不足时滚动。
    // 不能把上方的一小截空间直接作为 maxHeight，挤掉下方的操作。
    final preferredTop = above >= below ? aboveBottom - height : belowTop;
    top = preferredTop.clamp(minimumTop, visibleBottom - height);
  }
  final width = composerActionMenuWidth(context);
  Rect position = Rect.fromLTRB(rect.left, top, rect.right, top + height);
  // Desktop popups must use the actual button edges. A planned 280px-wide
  // empty rectangle is not the menu's intrinsic width: right-aligning a narrow
  // menu inside it can move the popup far away from the clicked button.
  if (globalPosition == null && avoidRects.isNotEmpty && !stayNearTrigger) {
    final viewport = Rect.fromLTRB(
      media.viewPadding.left + 8,
      minimumTop,
      overlay.size.width - media.viewPadding.right - 8,
      visibleBottom,
    );
    final preferredLeft = rect.center.dx > overlay.size.width / 2
        ? rect.right - width
        : rect.left;
    position = placeComposerMenu(
      viewport: viewport,
      preferred: Rect.fromLTWH(preferredLeft, top, width, height),
      trigger: rect,
      stayNearTrigger: stayNearTrigger,
      keepVisibleRect: keepVisibleRect == null
          ? null
          : Rect.fromPoints(
              overlay.globalToLocal(keepVisibleRect.topLeft),
              overlay.globalToLocal(keepVisibleRect.bottomRight),
            ),
      avoidRects: [
        for (final occupied in avoidRects)
          Rect.fromPoints(
            overlay.globalToLocal(occupied.topLeft),
            overlay.globalToLocal(occupied.bottomRight),
          ),
      ],
    );
  }
  final theme = Theme.of(context);
  return showSwipeDismissibleMenu<T>(
    context: context,
    navigator: navigator,
    requestFocus: false,
    position: RelativeRect.fromRect(position, Offset.zero & overlay.size),
    animationAnchorRect: rect,
    surfaceBuilder: useGlass
        ? (context, child) =>
              ComposerObjectSurface(radius: cornerRadius, child: child)
        : null,
    constraints: BoxConstraints(
      minWidth: math.min(160.0, width),
      maxWidth: width,
      maxHeight: position.height,
    ),
    menuPadding: const EdgeInsets.symmetric(vertical: 8),
    color: theme.colorScheme.surfaceContainerLow,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(cornerRadius),
      side: BorderSide(
        color: theme.colorScheme.outlineVariant.withValues(alpha: .5),
        width: .6,
      ),
    ),
    items: items,
  );
}
