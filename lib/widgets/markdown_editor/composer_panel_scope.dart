import 'package:flutter/material.dart';

typedef ComposerPanelBuilder = Widget Function(ValueChanged<Object?> close);

/// 分类、标签借用编辑器已有的键盘面板区域。
class ComposerPanelScope extends InheritedWidget {
  const ComposerPanelScope({
    super.key,
    required this.open,
    required super.child,
  });

  final Future<Object?> Function(ComposerPanelBuilder builder) open;

  static ComposerPanelScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ComposerPanelScope>();

  @override
  bool updateShouldNotify(ComposerPanelScope oldWidget) =>
      open != oldWidget.open;
}
