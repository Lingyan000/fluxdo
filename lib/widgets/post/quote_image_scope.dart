import 'package:flutter/widgets.dart';

import '../../models/topic.dart' show Post;

/// 图片「引用」handler 的树内作用域:长按菜单在 tap 时刻经活 ctx 就近
/// 现取当前 handler,替代 flatten/callbacks 闭包里的冻结引用。
///
/// ## 为什么需要
///
/// flatten 产物进了全局缓存(FlattenCache),imageContentBuilder 连同它
/// 捕获的 onQuoteImage(TopicDetailPage State 方法 tearoff)被冻结在缓存
/// 条目里 —— 页面销毁重进后缓存命中,长按「引用」会路由到已 dispose 的
/// 旧 State。挂本作用域后,菜单打开时(tap 时刻,活 ctx)向上查到**当前
/// 页面**的 handler,冻结引用只作无作用域场景(分享截图等)的兜底。
///
/// 叠栈(帖 A → 链接 → 帖 A)天然正确:各页面各自的子树里是各自的 scope。
///
/// [handler] 可为 null(未登录):有 scope 但 handler null = 明确"不可
/// 引用",菜单隐藏引用项,不回落冻结引用。
class QuoteImageScope extends InheritedWidget {
  const QuoteImageScope({
    super.key,
    required this.handler,
    required super.child,
  });

  final void Function(String quote, Post post)? handler;

  /// 就近的作用域;无(用户卡/分享卡等场景)返回 null,调用方回落冻结引用。
  static QuoteImageScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<QuoteImageScope>();

  @override
  bool updateShouldNotify(QuoteImageScope oldWidget) =>
      oldWidget.handler != handler;
}
