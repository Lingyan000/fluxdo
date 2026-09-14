import 'package:flutter/material.dart';

/// 使用编辑区域的约束，而不是整台设备的屏幕尺寸。
class ComposerDesktopViewport extends InheritedWidget {
  const ComposerDesktopViewport({
    super.key,
    required this.size,
    required this.topInset,
    required super.child,
  });

  final Size size;
  final double topInset;
  static const sideMargin = 24.0;
  static const railWidth = 56.0;
  static const documentSideInset = sideMargin + railWidth + 24;

  double get availableHeight => size.height - topInset;
  bool get useRail => size.width >= 1040 && availableHeight >= 480;
  bool get compact => size.width < 640;
  double get documentBottomInset => useRail ? 24 : 88;

  static ComposerDesktopViewport? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ComposerDesktopViewport>();

  @override
  bool updateShouldNotify(ComposerDesktopViewport oldWidget) =>
      size != oldWidget.size || topInset != oldWidget.topInset;
}
