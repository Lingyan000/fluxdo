// ignore_for_file: unnecessary_null_comparison, always_put_control_body_on_new_line

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';

import '../rendering/sliver_fill.dart';

/// A sliver that contains multiple box children that each fills the viewport.
///
/// [ExtendedSliverFillViewport] places its children in a linear array along the main
/// axis. Each child is sized to fill the viewport, both in the main and cross
/// axis.
///
/// See also:
///
///  * [SliverFixedExtentList], which has a configurable
///    [SliverFixedExtentList.itemExtent].
///  * [SliverPrototypeExtentList], which is similar to [SliverFixedExtentList]
///    except that it uses a prototype list item instead of a pixel value to define
///    the main axis extent of each item.
///  * [SliverList], which does not require its children to have the same
///    extent in the main axis.
class ExtendedSliverFillViewport extends StatelessWidget {
  /// Creates a sliver whose box children that each fill the viewport.
  const ExtendedSliverFillViewport({
    super.key,
    required this.delegate,
    this.viewportFraction = 1.0,
    this.padEnds = true,
    this.pageSpacing = 0.0,
  }) : assert(viewportFraction != null),
       assert(viewportFraction > 0.0),
       assert(pageSpacing != null),
       assert(pageSpacing >= 0.0),
       assert(padEnds != null);

  /// The fraction of the viewport that each child should fill in the main axis.
  ///
  /// If this fraction is less than 1.0, more than one child will be visible at
  /// once. If this fraction is greater than 1.0, each child will be larger than
  /// the viewport in the main axis.
  final double viewportFraction;

  /// Whether to add padding to both ends of the list.
  ///
  /// If this is set to true and [viewportFraction] < 1.0, padding will be added
  /// such that the first and last child slivers will be in the center of
  /// the viewport when scrolled all the way to the start or end, respectively.
  /// You may want to set this to false if this [ExtendedSliverFillViewport] is not the only
  /// widget along this main axis, such as in a [CustomScrollView] with multiple
  /// children.
  ///
  /// This option cannot be null. If [viewportFraction] >= 1.0, this option has no
  /// effect. Defaults to true.
  final bool padEnds;

  /// {@macro flutter.widgets.SliverMultiBoxAdaptorWidget.delegate}
  final SliverChildDelegate delegate;

  /// The number of logical pixels between each page.
  final double pageSpacing;
  @override
  Widget build(BuildContext context) {
    return _SliverFractionalPadding(
      viewportFraction: padEnds ? (1 - viewportFraction).clamp(0, 1) / 2 : 0,
      sliver: _SliverFillViewportRenderObjectWidget(
        viewportFraction: viewportFraction,
        delegate: delegate,
        pageSpacing: pageSpacing,
      ),
    );
  }
}

class _SliverFillViewportRenderObjectWidget
    extends SliverMultiBoxAdaptorWidget {
  const _SliverFillViewportRenderObjectWidget({
    required super.delegate,
    this.viewportFraction = 1.0,
    this.pageSpacing = 0.0,
  }) : assert(viewportFraction != null),
       assert(viewportFraction > 0.0),
       assert(pageSpacing != null),
       assert(pageSpacing >= 0.0);

  final double viewportFraction;
  final double pageSpacing;
  @override
  ExtendedRenderSliverFillViewport createRenderObject(BuildContext context) {
    final SliverMultiBoxAdaptorElement element =
        context as SliverMultiBoxAdaptorElement;
    return ExtendedRenderSliverFillViewport(
      childManager: element,
      viewportFraction: viewportFraction,
      pageSpacing: pageSpacing,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    ExtendedRenderSliverFillViewport renderObject,
  ) {
    renderObject.viewportFraction = viewportFraction;
    renderObject.pageSpacing = pageSpacing;
  }
}

class _SliverFractionalPadding extends SingleChildRenderObjectWidget {
  const _SliverFractionalPadding({this.viewportFraction = 0, Widget? sliver})
    : assert(viewportFraction != null),
      assert(viewportFraction >= 0),
      assert(viewportFraction <= 0.5),
      super(child: sliver);

  final double viewportFraction;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSliverFractionalPadding(viewportFraction: viewportFraction);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSliverFractionalPadding renderObject,
  ) {
    renderObject.viewportFraction = viewportFraction;
  }
}

class _RenderSliverFractionalPadding extends RenderSliverEdgeInsetsPadding {
  _RenderSliverFractionalPadding({double viewportFraction = 0})
    : assert(viewportFraction != null),
      assert(viewportFraction <= 0.5),
      assert(viewportFraction >= 0),
      _viewportFraction = viewportFraction;

  SliverConstraints? _lastResolvedConstraints;

  double get viewportFraction => _viewportFraction;
  double _viewportFraction;
  set viewportFraction(double newValue) {
    assert(newValue != null);
    if (_viewportFraction == newValue) return;
    _viewportFraction = newValue;
    _markNeedsResolution();
  }

  @override
  EdgeInsets? get resolvedPadding => _resolvedPadding;
  EdgeInsets? _resolvedPadding;

  void _markNeedsResolution() {
    _resolvedPadding = null;
    markNeedsLayout();
  }

  void _resolve() {
    if (_resolvedPadding != null && _lastResolvedConstraints == constraints) {
      return;
    }

    assert(constraints.axis != null);
    final double paddingValue =
        constraints.viewportMainAxisExtent * viewportFraction;
    _lastResolvedConstraints = constraints;
    switch (constraints.axis) {
      case Axis.horizontal:
        _resolvedPadding = EdgeInsets.symmetric(horizontal: paddingValue);
        break;
      case Axis.vertical:
        _resolvedPadding = EdgeInsets.symmetric(vertical: paddingValue);
        break;
    }

    return;
  }

  @override
  void performLayout() {
    _resolve();
    super.performLayout();
  }
}
