import 'package:flutter/material.dart';

class ComposerObjectAction {
  const ComposerObjectAction(
    this.label,
    this.icon,
    this.run, {
    this.destructive = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback? run;
  final bool destructive;
}

/// 对象菜单与底栏共用同一组动作，回调捕获对象身份，弹层失焦不会换目标。
class ComposerObjectSelection {
  const ComposerObjectSelection({
    required this.label,
    required this.rect,
    required this.dismiss,
    required this.after,
    required this.actions,
    this.primary,
    this.onMenuVisibilityChanged,
    this.onContextMenu,
    this.onMenuRequested,
    this.contentRects,
    this.menuViewport,
    this.interactionPosition,
  });
  final String label;
  final Rect rect;
  final VoidCallback dismiss;
  final VoidCallback after;
  final ComposerObjectAction? primary;
  final ValueChanged<bool>? onMenuVisibilityChanged;
  final ValueChanged<Offset>? onContextMenu;
  final ValueChanged<Rect>? onMenuRequested;
  final List<ComposerObjectAction> actions;

  /// Only measured when opening a menu; scrolling does not perform layout scans.
  final List<Rect> Function()? contentRects;
  final Rect? Function()? menuViewport;

  /// The click that selected this object; follows the object during reflow.
  final Offset? interactionPosition;

  ComposerObjectSelection withRect(Rect rect, {Offset? interactionPosition}) =>
      ComposerObjectSelection(
        label: label,
        rect: rect,
        dismiss: dismiss,
        after: after,
        actions: actions,
        primary: primary,
        onMenuVisibilityChanged: onMenuVisibilityChanged,
        onContextMenu: onContextMenu,
        onMenuRequested: onMenuRequested,
        contentRects: contentRects,
        menuViewport: menuViewport,
        interactionPosition:
            interactionPosition ??
            (this.interactionPosition == null
                ? null
                : this.interactionPosition! + rect.topLeft - this.rect.topLeft),
      );
}
