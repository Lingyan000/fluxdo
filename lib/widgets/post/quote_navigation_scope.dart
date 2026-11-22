import 'package:flutter/widgets.dart';

class QuoteNavigationScope extends InheritedWidget {
  const QuoteNavigationScope({
    super.key,
    required this.topicId,
    required this.onJump,
    required super.child,
  });

  final int topicId;
  final ValueChanged<int> onJump;

  static ValueChanged<int>? jumpFor(BuildContext context, int topicId) {
    final scope = context.getInheritedWidgetOfExactType<QuoteNavigationScope>();
    return scope != null && scope.topicId == topicId ? scope.onJump : null;
  }

  @override
  bool updateShouldNotify(QuoteNavigationScope oldWidget) =>
      topicId != oldWidget.topicId || onJump != oldWidget.onJump;
}
