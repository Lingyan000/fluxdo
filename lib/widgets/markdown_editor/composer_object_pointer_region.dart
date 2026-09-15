import 'package:flutter/gestures.dart' show kSecondaryMouseButton, kTouchSlop;
import 'package:flutter/widgets.dart';

/// 自动滚动会屏蔽正文命中。只接管这段时间内的右键，避免吞掉正常手势。
class ComposerObjectPointerRegion extends StatefulWidget {
  const ComposerObjectPointerRegion({
    super.key,
    required this.scrollController,
    required this.onContextMenu,
    required this.child,
    this.onPointerDown,
    this.onScroll,
  });
  final ScrollController scrollController;
  final ValueChanged<Offset> onContextMenu;
  final Widget child;
  final ValueChanged<Offset>? onPointerDown;
  final VoidCallback? onScroll;
  @override
  State<ComposerObjectPointerRegion> createState() =>
      _ComposerObjectPointerRegionState();
}

class _ComposerObjectPointerRegionState
    extends State<ComposerObjectPointerRegion> {
  int? _pointer;
  Offset? _down;
  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) {
      widget.onPointerDown?.call(event.position);
      final scroll = widget.scrollController;
      if (event.buttons != kSecondaryMouseButton ||
          !scroll.hasClients ||
          !scroll.position.shouldIgnorePointer) {
        return;
      }
      _pointer = event.pointer;
      _down = event.position;
      scroll.jumpTo(scroll.offset);
    },
    onPointerUp: (event) {
      if (_pointer != event.pointer) return;
      final down = _down;
      _pointer = null;
      _down = null;
      if (down != null && (event.position - down).distance <= kTouchSlop) {
        widget.onContextMenu(event.position);
      }
    },
    onPointerCancel: (event) {
      if (_pointer == event.pointer) {
        _pointer = null;
        _down = null;
      }
    },
    child: NotificationListener<ScrollUpdateNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.vertical &&
            notification.scrollDelta != 0) {
          widget.onScroll?.call();
        }
        return false;
      },
      child: widget.child,
    ),
  );
}
