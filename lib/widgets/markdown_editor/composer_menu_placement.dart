import 'dart:math' as math;
import 'dart:ui';

/// Find a full-height menu space beside painted content. Coordinates are local
/// to the navigator overlay. This runs once per opening, never during scrolling.
Rect placeComposerMenu({
  required Rect viewport,
  required Rect preferred,
  required Rect trigger,
  required Iterable<Rect> avoidRects,
  Rect? keepVisibleRect,
  bool stayNearTrigger = false,
}) {
  final size = Size(
    math.min(preferred.width, viewport.width),
    math.min(preferred.height, viewport.height),
  );
  Rect at(double x, double y) =>
      Offset(
        x.clamp(viewport.left, viewport.right - size.width),
        y.clamp(viewport.top, viewport.bottom - size.height),
      ) &
      size;
  final fallback = at(preferred.left, preferred.top);
  bool nearTrigger(Rect candidate) =>
      !stayNearTrigger || candidate.inflate(32).contains(trigger.center);
  final obstacles = [
    for (final rect in [...avoidRects, ?keepVisibleRect, trigger])
      if (rect.isFinite && !rect.isEmpty && rect.inflate(8).overlaps(viewport))
        rect.inflate(8).intersect(viewport),
  ];
  final xs = <double>{
    fallback.left,
    viewport.left,
    viewport.right - size.width,
    for (final rect in obstacles) ...[
      (rect.left - size.width).clamp(
        viewport.left,
        viewport.right - size.width,
      ),
      rect.right.clamp(viewport.left, viewport.right - size.width),
    ],
  };
  Rect? best;
  Rect? scrollable;
  var bestDistance = double.infinity;
  var scrollableDistance = double.infinity;
  void considerFree(double x, double top, double bottom) {
    if (bottom - top < size.height) {
      // Keep several complete rows visible, never a one-row sliver.
      if (bottom - top < math.min(208, size.height)) return;
      final candidate = Rect.fromLTWH(x, top, size.width, bottom - top);
      if (!nearTrigger(candidate)) return;
      final distance = (candidate.center - fallback.center).distanceSquared;
      if (scrollable == null ||
          candidate.height > scrollable!.height ||
          (candidate.height == scrollable!.height &&
              distance < scrollableDistance)) {
        scrollable = candidate;
        scrollableDistance = distance;
      }
      return;
    }
    final candidate = at(x, fallback.top.clamp(top, bottom - size.height));
    if (!nearTrigger(candidate)) return;
    final distance = (candidate.center - fallback.center).distanceSquared;
    if (distance < bestDistance) {
      best = candidate;
      bestDistance = distance;
    }
  }

  // At each content edge, merge occupied vertical intervals. Unlike sampling
  // just four corners, this also finds blank space within an image grid row.
  for (final x in xs) {
    final intersecting =
        obstacles
            .where((rect) => rect.left < x + size.width && rect.right > x)
            .toList()
          ..sort((a, b) => a.top.compareTo(b.top));
    var top = viewport.top;
    for (final rect in intersecting) {
      considerFree(x, top, rect.top);
      top = math.max(top, rect.bottom);
    }
    considerFree(x, top, viewport.bottom);
  }
  if (best != null) return best!;
  // Desktop menus keep all actions visible when the viewport permits it.
  // Don't add a scroll step just to avoid an unselected neighboring paragraph.
  if (scrollable != null && !stayNearTrigger) return scrollable!;

  // A crowded phone/keyboard viewport may have no empty space large enough.
  // Keep the whole menu usable and prefer the least obscured position.
  var leastOverlap = double.infinity;
  var leastSelectedOverlap = double.infinity;
  double area(Rect rect) => rect.isEmpty ? 0 : rect.width * rect.height;
  for (final x in xs) {
    for (final y in [
      fallback.top,
      viewport.top,
      viewport.bottom - size.height,
      if (keepVisibleRect != null) ...[
        keepVisibleRect.top - size.height - 8,
        keepVisibleRect.bottom + 8,
      ],
    ]) {
      final candidate = at(x, y);
      if (!nearTrigger(candidate)) continue;
      final overlap = obstacles.fold<double>(0, (sum, obstacle) {
        final intersection = candidate.intersect(obstacle);
        return sum +
            (intersection.isEmpty
                ? 0
                : intersection.width * intersection.height);
      });
      final distance = (candidate.center - fallback.center).distanceSquared;
      final selectedOverlap = keepVisibleRect == null
          ? 0.0
          : area(candidate.intersect(keepVisibleRect.inflate(8)));
      if (selectedOverlap < leastSelectedOverlap ||
          (selectedOverlap == leastSelectedOverlap &&
              (overlap < leastOverlap ||
                  (overlap == leastOverlap && distance < bestDistance)))) {
        best = candidate;
        leastSelectedOverlap = selectedOverlap;
        leastOverlap = overlap;
        bestDistance = distance;
      }
    }
  }
  return best ?? fallback;
}
