import 'package:flutter/widgets.dart';

/// Records object interaction positions and hides transient tools on scroll.
/// Desktop scroll interruption is owned by the application's shared policy.
class ComposerObjectPointerRegion extends StatelessWidget {
  const ComposerObjectPointerRegion({
    super.key,
    required this.child,
    this.onPointerDown,
    this.onScroll,
  });

  final Widget child;
  final ValueChanged<Offset>? onPointerDown;
  final VoidCallback? onScroll;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) => onPointerDown?.call(event.position),
    child: NotificationListener<ScrollUpdateNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.vertical &&
            notification.scrollDelta != 0) {
          onScroll?.call();
        }
        return false;
      },
      child: child,
    ),
  );
}
