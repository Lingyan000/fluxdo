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

  /// 不订阅重建（一次性读取，跟 ref.read 语义一致，同 EmbeddedStackScope）：
  /// 调用方都在点击回调里取回调用，订阅只会让宿主重建时闭包身份变化
  /// 引发无意义的依赖重建。
  static HomeWorkspaceScope? maybeOf(BuildContext context) {
    final element = context
        .getElementForInheritedWidgetOfExactType<HomeWorkspaceScope>();
    return element?.widget as HomeWorkspaceScope?;
  }

  @override
  bool updateShouldNotify(HomeWorkspaceScope oldWidget) => false;
}
