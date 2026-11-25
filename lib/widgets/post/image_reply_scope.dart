import 'package:flutter/widgets.dart';

import '../../models/topic.dart';
import 'quote_image_scope.dart';

/// 只包住帖子正文，查看器打开时取当前楼层和当前页面的回复回调。
class ImageReplyScope extends InheritedWidget {
  const ImageReplyScope({
    super.key,
    required this.post,
    this.fallbackHandler,
    required super.child,
  });

  final Post post;
  final void Function(String, Post)? fallbackHandler;

  static ValueChanged<String>? resolve(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ImageReplyScope>();
    if (scope == null) return null;
    final quoteElement = context
        .getElementForInheritedWidgetOfExactType<QuoteImageScope>();
    final quoteScope = quoteElement?.widget as QuoteImageScope?;
    final handler = quoteScope == null
        ? scope.fallbackHandler
        : quoteScope.handler;
    if (handler == null) return null;
    return (markdown) {
      final owner = quoteElement ?? context;
      if (!owner.mounted) return;
      final live = quoteElement?.widget as QuoteImageScope?;
      final currentHandler = live == null ? handler : live.handler;
      currentHandler?.call('$markdown\n', scope.post);
    };
  }

  @override
  bool updateShouldNotify(ImageReplyScope oldWidget) =>
      oldWidget.post != post || oldWidget.fallbackHandler != fallbackHandler;
}
