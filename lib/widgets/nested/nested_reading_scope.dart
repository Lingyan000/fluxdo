import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../models/nested_reading_position.dart';

/// 只测量各帖正文，不把整棵已构建/预缓存子树算成屏幕可见。
class NestedViewportController {
  final viewportKey = GlobalKey();
  final Set<RenderNestedPostAnchor> _posts = {};
  void Function(Set<int>, NestedReadingPosition?)? onSample;
  void Function(Set<int>, NestedReadingPosition?, bool)? onOverlaySample;
  int _overlayDepth = 0;
  void beginOverlay() {
    ++_overlayDepth;
    onSample?.call({}, null);
  }

  void endOverlay() {
    if (_overlayDepth > 0) --_overlayDepth;
    scheduleSample();
  }

  bool _scheduled = false;
  bool _disposed = false;

  void scheduleSample() {
    if (_scheduled || _disposed) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_disposed) sample();
    });
  }

  void sample() {
    if (_overlayDepth > 0) return;
    final viewport = viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize) {
      return;
    }
    final bounds = Offset.zero & viewport.size;
    final visible = <int>{};
    final candidates = <(RenderNestedPostAnchor, Rect)>[];
    for (final post in _posts) {
      if (!post.attached || !post.hasSize || !post.trackRead) continue;
      final rect =
          post.localToGlobal(Offset.zero, ancestor: viewport) & post.size;
      if (!rect.overlaps(bounds) || rect.intersect(bounds).height < 8) continue;
      visible.add(post.postNumber);
      candidates.add((post, rect));
    }
    // 以阅读区上部的实际正文为锚，楼层号大小与阅读先后无关。
    final eyeline = bounds.height * 0.2;
    candidates.sort((a, b) {
      double distance(Rect rect) => rect.top <= eyeline && rect.bottom > eyeline
          ? 0
          : (rect.top - eyeline).abs();
      return distance(a.$2).compareTo(distance(b.$2));
    });
    final anchor = candidates.firstOrNull;
    onSample?.call(
      visible,
      anchor == null
          ? null
          : NestedReadingPosition(
              postNumber: anchor.$1.postNumber,
              rootPostNumber: anchor.$1.rootPostNumber,
              offset: anchor.$2.top,
            ),
    );
  }

  RenderNestedPostAnchor? find(int postNumber) => _posts
      .where(
        (post) =>
            post.postNumber == postNumber && post.attached && post.hasSize,
      )
      .firstOrNull;

  double? topOf(int postNumber) {
    final viewport = viewportKey.currentContext?.findRenderObject();
    final post = find(postNumber);
    if (viewport is! RenderBox || post == null) return null;
    return post.localToGlobal(Offset.zero, ancestor: viewport).dy;
  }

  void dispose() {
    _disposed = true;
    _posts.clear();
    onSample = null;
    onOverlaySample = null;
  }
}

class NestedReadingScope extends InheritedWidget {
  const NestedReadingScope({
    super.key,
    required this.controller,
    required this.session,
    this.targetBanner,
    required super.child,
  });
  final NestedViewportController controller;
  final NestedReadingSession session;
  final Widget? targetBanner;
  static NestedReadingScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NestedReadingScope>();
  @override
  bool updateShouldNotify(NestedReadingScope oldWidget) =>
      controller != oldWidget.controller ||
      session != oldWidget.session ||
      targetBanner != oldWidget.targetBanner;
}

class NestedPostAnchor extends SingleChildRenderObjectWidget {
  const NestedPostAnchor({
    super.key,
    required this.controller,
    required this.postNumber,
    required this.rootPostNumber,
    this.trackRead = true,
    required super.child,
  });
  final NestedViewportController controller;
  final int postNumber;
  final int rootPostNumber;
  final bool trackRead;
  @override
  RenderNestedPostAnchor createRenderObject(BuildContext context) =>
      RenderNestedPostAnchor(controller, postNumber, rootPostNumber, trackRead);
  @override
  void updateRenderObject(
    BuildContext context,
    RenderNestedPostAnchor renderObject,
  ) {
    renderObject
      ..postNumber = postNumber
      ..rootPostNumber = rootPostNumber
      ..trackRead = trackRead;
    controller.scheduleSample();
  }
}

class RenderNestedPostAnchor extends RenderProxyBox {
  RenderNestedPostAnchor(
    this.controller,
    this.postNumber,
    this.rootPostNumber,
    this.trackRead,
  );
  final NestedViewportController controller;
  int postNumber;
  int rootPostNumber;
  bool trackRead;
  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    controller._posts.add(this);
    controller.scheduleSample();
  }

  @override
  void detach() {
    controller._posts.remove(this);
    controller.scheduleSample();
    super.detach();
  }

  @override
  void performLayout() {
    super.performLayout();
    controller.scheduleSample();
  }
}
