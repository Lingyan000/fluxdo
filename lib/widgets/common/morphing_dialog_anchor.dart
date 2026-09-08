import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 预览的真实来源。只在打开时截取一帧，飞行期间保留列表占位。
class MorphingDialogAnchor extends StatefulWidget {
  const MorphingDialogAnchor({
    super.key,
    required this.builder,
    this.enabled = true,
    this.bottomGap = 8,
  });

  final WidgetBuilder builder;
  final bool enabled;
  final double bottomGap;

  static MorphingDialogSnapshot? capture(BuildContext context) =>
      context.findAncestorStateOfType<_MorphingDialogAnchorState>()?._capture();

  static Rect? rectOf(BuildContext context) => context
      .findAncestorStateOfType<_MorphingDialogAnchorState>()
      ?._visibleRect();

  @override
  State<MorphingDialogAnchor> createState() => _MorphingDialogAnchorState();
}

class _MorphingDialogAnchorState extends State<MorphingDialogAnchor> {
  final _boundaryKey = GlobalKey();
  final _visible = ValueNotifier(true);
  MorphingDialogSnapshot? _snapshot;

  RenderRepaintBoundary? get _boundary =>
      _boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;

  Rect? _visibleRect() {
    final boundary = _boundary;
    if (!mounted || boundary == null || !boundary.hasSize) return null;
    final bounds = Rect.fromLTWH(
      0,
      0,
      boundary.size.width,
      math.max(0, boundary.size.height - widget.bottomGap),
    );
    var rect = MatrixUtils.transformRect(boundary.getTransformTo(null), bounds);
    // 部分滚出列表的卡片，从实际可见区域起飞，不能盖到列表上方的工具栏。
    RenderObject descendant = boundary;
    for (
      var ancestor = boundary.parent;
      ancestor != null;
      ancestor = ancestor.parent
    ) {
      final clip = ancestor.describeApproximatePaintClip(descendant);
      if (clip != null) {
        rect = rect.intersect(
          MatrixUtils.transformRect(ancestor.getTransformTo(null), clip),
        );
      }
      descendant = ancestor;
    }
    return rect.isEmpty || !rect.isFinite ? null : rect;
  }

  MorphingDialogSnapshot? _capture() {
    if (!widget.enabled || _snapshot != null) return null;
    final boundary = _boundary;
    final rect = _visibleRect();
    if (boundary == null || rect == null) return null;
    // 复用上一帧的图层，按压反馈此时可能已标记重绘，无需等待下一帧。
    // ignore: invalid_use_of_protected_member
    final layer = boundary.layer;
    if (layer is! OffsetLayer) return null;
    final transform = boundary.getTransformTo(null)..invert();
    final bounds = MatrixUtils.transformRect(transform, rect);
    ui.Image image;
    try {
      image = layer.toImageSync(
        bounds,
        pixelRatio: math.min(MediaQuery.devicePixelRatioOf(context), 2),
      );
    } catch (_) {
      // 图层尚未提交等情况下，仍可正常打开预览。
      return null;
    }
    final snapshot = MorphingDialogSnapshot._(
      rect: rect,
      image: image,
      currentRect: _visibleRect,
      onRestore: () {
        if (!mounted) return;
        _snapshot = null;
        _visible.value = true;
      },
    );
    _snapshot = snapshot;
    _visible.value = false;
    return snapshot;
  }

  @override
  void dispose() {
    _visible.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return Builder(builder: widget.builder);
    return ValueListenableBuilder<bool>(
      valueListenable: _visible,
      builder: (context, visible, child) => ExcludeSemantics(
        excluding: !visible,
        child: Opacity(opacity: visible ? 1 : 0, child: child),
      ),
      child: RepaintBoundary(
        key: _boundaryKey,
        child: Builder(builder: widget.builder),
      ),
    );
  }
}

/// 图片归预览路由所有，路由完全退出后释放；源卡片可以先于路由卸载。
class MorphingDialogSnapshot {
  MorphingDialogSnapshot._({
    required this.rect,
    required this.image,
    required this.currentRect,
    required VoidCallback onRestore,
  }) : _onRestore = onRestore;

  final Rect rect;
  final ui.Image image;
  final Rect? Function() currentRect;
  VoidCallback? _onRestore;
  bool _disposed = false;

  void restore() {
    _onRestore?.call();
    _onRestore = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    restore();
    image.dispose();
  }
}
