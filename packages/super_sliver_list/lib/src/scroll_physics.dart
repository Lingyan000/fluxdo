import "dart:math" as math;

import "package:flutter/widgets.dart";

/// Regular [RangeMaintainingScrollPhysics] will not keep the scroll position in range
/// when scroll position was corrected during the layout pass. That means removing
/// elements from the list will cause the scroll position to animate when it normally
/// wouldn't. As a workaround add [SuperRangeMaintainingScrollPhysics] to the physics
/// chain.
///
/// For example
/// ```dart
/// class _MyScrollBehavior extends ScrollBehavior {
///  const _MyScrollBehavior();
///
///  @override
///  ScrollPhysics getScrollPhysics(BuildContext context) {
///    return SuperRangeMaintainingScrollPhysics(
///        parent: super.getScrollPhysics(context));
///  }
/// }
/// ```
///
/// You can add use the [ScrollConfiguration] widget to apply the scroll behavior
/// to a subtree.
class SuperRangeMaintainingScrollPhysics extends ScrollPhysics {
  const SuperRangeMaintainingScrollPhysics({super.parent});

  @override
  SuperRangeMaintainingScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return SuperRangeMaintainingScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    if (velocity == 0.0 && !oldPosition.outOfRange) {
      // [RangeMaintainingScrollPhysics] have a check where it compares
      // pixels to oldPixels, but that fails with scroll correction applied.
      oldPosition = oldPosition.copyWith(
        pixels: newPosition.pixels,
        minScrollExtent: math.min(
          newPosition.pixels,
          oldPosition.minScrollExtent,
        ),
        maxScrollExtent: math.max(
          newPosition.pixels,
          oldPosition.maxScrollExtent,
        ),
      );
    }
    return super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
  }
}
