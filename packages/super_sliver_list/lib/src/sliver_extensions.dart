import "package:flutter/rendering.dart";

class ChildObstructionExtent {
  ChildObstructionExtent({
    required this.leading,
    required this.trailing,
  });

  /// Amount of space from the leading edge where this sliver obstructs its child.
  final double leading;

  /// Amount of space from the trailing edge where this sliver obstructs its child.
  final double trailing;

  ChildObstructionExtent operator +(ChildObstructionExtent other) {
    return ChildObstructionExtent(
      leading: leading + other.leading,
      trailing: trailing + other.trailing,
    );
  }

  ChildObstructionExtent operator -(ChildObstructionExtent other) {
    return ChildObstructionExtent(
      leading: leading - other.leading,
      trailing: trailing - other.trailing,
    );
  }
}

extension SliverGeometryChildObstruction on SliverGeometry {
  /// Returns the extent from edges in which this sliver obstructs
  /// its child.
  ///
  /// This similar to [maxScrollObstructionExtent], with the biggest difference
  /// being that [maxScrollObstructionExtent] affects slivers after this one,
  /// while this one affects child slivers.
  ///
  /// For pinned headers this should be the extent of the header, regardless
  /// of the scroll offset, layout or paint extent.
  ///
  /// The value is used to determine offset when revealing child and as such
  /// should not be affected by the scroll offset.
  ChildObstructionExtent? get childObstructionExtent {
    if (this is _SliverGeometryWithChildObstructionExtent) {
      return (this as _SliverGeometryWithChildObstructionExtent)
          ._childObstructionExtent;
    } else {
      return null;
    }
  }

  /// Sets the extent from the edges in which this sliver obstructs
  /// its child.
  ///
  /// See [childObstructionExtent].
  SliverGeometry withChildObstructionExtent(
    ChildObstructionExtent? value,
  ) {
    return _SliverGeometryWithChildObstructionExtent(
      scrollExtent: scrollExtent,
      paintExtent: paintExtent,
      paintOrigin: paintOrigin,
      layoutExtent: layoutExtent,
      maxPaintExtent: maxPaintExtent,
      maxScrollObstructionExtent: maxScrollObstructionExtent,
      crossAxisExtent: crossAxisExtent,
      hitTestExtent: hitTestExtent,
      visible: visible,
      hasVisualOverflow: hasVisualOverflow,
      cacheExtent: cacheExtent,
      scrollOffsetCorrection: scrollOffsetCorrection,
      childObstructionExtent: value,
    );
  }
}

extension RenderObjectChildObstuctionExtent on RenderObject {
  /// Returns the total child obstruction extent of all slivers
  /// above and this render object.
  ChildObstructionExtent getParentChildObstructionExtent() {
    var childObstructionExtent =
        ChildObstructionExtent(leading: 0, trailing: 0);
    var parent = this.parent;
    while (parent != null && parent is! RenderViewport) {
      if (parent is RenderSliver) {
        final geometry = parent.geometry;
        if (geometry?.childObstructionExtent != null) {
          childObstructionExtent += geometry!.childObstructionExtent!;
        }
      }
      parent = parent.parent;
    }
    return childObstructionExtent;
  }
}

class OffsetToRevealContext {
  OffsetToRevealContext({
    required this.viewport,
    required this.target,
    required this.alignment,
    required this.estimationOnly,
    required this.rect,
    required this.axis,
  });

  final RenderAbstractViewport viewport;
  final RenderObject target;
  final double alignment;
  final bool estimationOnly;
  final Rect? rect;
  final Axis? axis;

  void registerOffsetResolvedCallback(ValueSetter<RevealedOffset> callback) {
    _offsetResolvedCallbacks.add(callback);
  }

  final _offsetResolvedCallbacks = <ValueSetter<RevealedOffset>>[];

  static final _contexts = <OffsetToRevealContext>[];

  static OffsetToRevealContext? current() {
    if (_contexts.isEmpty) return null;
    return _contexts.last;
  }
}

extension RenderViewportExt on RenderAbstractViewport {
  /// Extended version of [RenderAbstractViewport.getOffsetToReveal] that
  /// takes child scroll obstruction into account and thus works properly
  /// with sliver that have [childObstructionExtent] set.
  ///
  /// In addition this method allows the underlying sliver that is being
  /// queried for child scroll offset to access [OffsetToRevealContext] that
  /// contains information about the current query.
  RevealedOffset getOffsetToRevealExt(
    RenderObject target,
    double alignment, {
    bool esimationOnly = false,
    Rect? rect,
    Axis? axis,
  }) {
    final context = OffsetToRevealContext(
      viewport: this,
      target: target,
      alignment: alignment,
      estimationOnly: esimationOnly,
      rect: rect,
      axis: axis,
    );
    OffsetToRevealContext._contexts.add(context);
    var result = getOffsetToReveal(target, alignment, rect: rect);
    OffsetToRevealContext._contexts.removeLast();
    final obstruction = target.getParentChildObstructionExtent();

    final resolvedAxis =
        (this is RenderViewportBase ? (this as RenderViewportBase).axis : axis);

    Rect shiftRect(Rect rect, double offset) {
      if (resolvedAxis == Axis.vertical) {
        return rect.shift(Offset(0, offset));
      } else {
        return rect.shift(Offset(offset, 0));
      }
    }

    if (obstruction.leading > 0) {
      final offset = obstruction.leading * (1.0 - alignment);
      result = RevealedOffset(
        offset: result.offset - offset,
        rect: shiftRect(result.rect, offset),
      );
    }
    if (obstruction.trailing > 0) {
      final offset = obstruction.trailing * alignment;
      result = RevealedOffset(
        offset: result.offset + offset,
        rect: shiftRect(result.rect, -offset),
      );
    }
    for (final callback in context._offsetResolvedCallbacks) {
      callback(result);
    }
    return result;
  }
}

class _SliverGeometryWithChildObstructionExtent extends SliverGeometry {
  const _SliverGeometryWithChildObstructionExtent({
    required super.scrollExtent,
    required super.paintExtent,
    required super.paintOrigin,
    required super.layoutExtent,
    required super.maxPaintExtent,
    required super.maxScrollObstructionExtent,
    required super.crossAxisExtent,
    required super.hitTestExtent,
    required super.visible,
    required super.hasVisualOverflow,
    required super.scrollOffsetCorrection,
    required super.cacheExtent,
    required ChildObstructionExtent? childObstructionExtent,
  }) : _childObstructionExtent = childObstructionExtent;

  @override
  SliverGeometry copyWith({
    double? scrollExtent,
    double? paintExtent,
    double? paintOrigin,
    double? layoutExtent,
    double? maxPaintExtent,
    double? maxScrollObstructionExtent,
    double? crossAxisExtent,
    double? hitTestExtent,
    bool? visible,
    bool? hasVisualOverflow,
    double? cacheExtent,
  }) {
    return _SliverGeometryWithChildObstructionExtent(
      scrollExtent: scrollExtent ?? this.scrollExtent,
      paintExtent: paintExtent ?? this.paintExtent,
      paintOrigin: paintOrigin ?? this.paintOrigin,
      layoutExtent: layoutExtent ?? this.layoutExtent,
      maxPaintExtent: maxPaintExtent ?? this.maxPaintExtent,
      maxScrollObstructionExtent:
          maxScrollObstructionExtent ?? this.maxScrollObstructionExtent,
      crossAxisExtent: crossAxisExtent ?? this.crossAxisExtent,
      hitTestExtent: hitTestExtent ?? this.hitTestExtent,
      visible: visible ?? this.visible,
      hasVisualOverflow: hasVisualOverflow ?? this.hasVisualOverflow,
      cacheExtent: cacheExtent ?? this.cacheExtent,
      scrollOffsetCorrection: scrollOffsetCorrection,
      childObstructionExtent: _childObstructionExtent,
    );
  }

  final ChildObstructionExtent? _childObstructionExtent;
}
