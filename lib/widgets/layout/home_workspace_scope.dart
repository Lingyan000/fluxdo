import 'package:flutter/widgets.dart';

import '../../models/category.dart';

/// 首页平行视界的左栏内容控制器。
class HomeWorkspaceScope extends InheritedWidget {
  const HomeWorkspaceScope({
    super.key,
    required this.onShowFeed,
    required this.onShowCategory,
    required this.onShowTag,
    required super.child,
  });

  final VoidCallback onShowFeed;
  final ValueChanged<Category> onShowCategory;
  final ValueChanged<String> onShowTag;

  static HomeWorkspaceScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HomeWorkspaceScope>();

  @override
  bool updateShouldNotify(HomeWorkspaceScope oldWidget) =>
      onShowFeed != oldWidget.onShowFeed ||
      onShowCategory != oldWidget.onShowCategory ||
      onShowTag != oldWidget.onShowTag;
}
