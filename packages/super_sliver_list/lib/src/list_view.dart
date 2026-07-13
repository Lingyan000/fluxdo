import "dart:math" as math;

import "package:flutter/widgets.dart";

import "super_sliver_list.dart";

/// This is a drop-in replacement Flutter [ListView] that provides much better
/// performance with large number of children with variable extents. Unlike
/// [ListView] the performance does not depend on the number of children and the
/// list can easily handle tens or hundreds of thousands of children without
/// having to specify hardcoded extent or prototype child.
///
/// On top of performance improvements, [SuperListView] also has the ability to
/// jump / animate to a specific item in the list.
///
/// See the [ListView] documentation for more details on how to use it.
class SuperListView extends BoxScrollView {
  SuperListView({
    super.key,
    super.scrollDirection,
    super.reverse,
    super.controller,
    super.primary,
    super.physics,
    super.shrinkWrap,
    super.padding,
    bool addAutomaticKeepAlives = true,
    bool addRepaintBoundaries = true,
    bool addSemanticIndexes = true,
    super.scrollCacheExtent,
    List<Widget> children = const <Widget>[],
    int? semanticChildCount,
    super.dragStartBehavior,
    super.keyboardDismissBehavior,
    super.restorationId,
    super.clipBehavior,
    this.listController,
    this.extentEstimation,
    this.extentPrecalculationPolicy,
    this.delayPopulatingCacheArea = false,
  })  : childrenDelegate = SliverChildListDelegate(
          children,
          addAutomaticKeepAlives: addAutomaticKeepAlives,
          addRepaintBoundaries: addRepaintBoundaries,
          addSemanticIndexes: addSemanticIndexes,
        ),
        super(
          semanticChildCount: semanticChildCount ?? children.length,
        );

  /// Creates a new [SuperListView] that builds its children dynamically.
  ///
  /// See [ListView.builder] for details.
  SuperListView.builder({
    super.key,
    super.scrollDirection,
    super.reverse,
    super.controller,
    super.primary,
    super.physics,
    super.shrinkWrap,
    super.padding,
    required NullableIndexedWidgetBuilder itemBuilder,
    ChildIndexGetter? findChildIndexCallback,
    int? itemCount,
    bool addAutomaticKeepAlives = true,
    bool addRepaintBoundaries = true,
    bool addSemanticIndexes = true,
    super.scrollCacheExtent,
    int? semanticChildCount,
    super.dragStartBehavior,
    super.keyboardDismissBehavior,
    super.restorationId,
    super.clipBehavior,
    this.listController,
    this.extentEstimation,
    this.extentPrecalculationPolicy,
    this.delayPopulatingCacheArea = false,
  })  : assert(itemCount == null || itemCount >= 0),
        assert(semanticChildCount == null || semanticChildCount <= itemCount!),
        childrenDelegate = SliverChildBuilderDelegate(
          itemBuilder,
          findChildIndexCallback: findChildIndexCallback,
          childCount: itemCount,
          addAutomaticKeepAlives: addAutomaticKeepAlives,
          addRepaintBoundaries: addRepaintBoundaries,
          addSemanticIndexes: addSemanticIndexes,
        ),
        super(
          semanticChildCount: semanticChildCount ?? itemCount,
        );

  /// Creates a [SuperListView] with "items" separated by list item "separators".
  ///
  /// See [ListView.separated] for details.
  SuperListView.separated({
    super.key,
    super.scrollDirection,
    super.reverse,
    super.controller,
    super.primary,
    super.physics,
    super.shrinkWrap,
    super.padding,
    required NullableIndexedWidgetBuilder itemBuilder,
    ChildIndexGetter? findChildIndexCallback,
    required IndexedWidgetBuilder separatorBuilder,
    required int itemCount,
    bool addAutomaticKeepAlives = true,
    bool addRepaintBoundaries = true,
    bool addSemanticIndexes = true,
    super.scrollCacheExtent,
    super.dragStartBehavior,
    super.keyboardDismissBehavior,
    super.restorationId,
    super.clipBehavior,
    this.listController,
    this.extentEstimation,
    this.extentPrecalculationPolicy,
    this.delayPopulatingCacheArea = false,
  })  : assert(itemCount >= 0),
        childrenDelegate = SliverChildBuilderDelegate(
          (BuildContext context, int index) {
            final int itemIndex = index ~/ 2;
            if (index.isEven) {
              return itemBuilder(context, itemIndex);
            }
            return separatorBuilder(context, itemIndex);
          },
          findChildIndexCallback: findChildIndexCallback,
          childCount: _computeActualChildCount(itemCount),
          addAutomaticKeepAlives: addAutomaticKeepAlives,
          addRepaintBoundaries: addRepaintBoundaries,
          addSemanticIndexes: addSemanticIndexes,
          semanticIndexCallback: (Widget widget, int index) {
            return index.isEven ? index ~/ 2 : null;
          },
        ),
        super(
          semanticChildCount: itemCount,
        );

  /// Creates [SuperListView] with a custom child model.
  ///
  /// See [ListView.custom] for details.
  const SuperListView.custom({
    super.key,
    super.scrollDirection,
    super.reverse,
    super.controller,
    super.primary,
    super.physics,
    super.shrinkWrap,
    super.padding,
    required this.childrenDelegate,
    super.scrollCacheExtent,
    super.semanticChildCount,
    super.dragStartBehavior,
    super.keyboardDismissBehavior,
    super.restorationId,
    super.clipBehavior,
    this.listController,
    this.extentEstimation,
    this.extentPrecalculationPolicy,
    this.delayPopulatingCacheArea = false,
  });

  /// A delegate that provides the children for the [ListView].
  ///
  /// The [ListView.custom] constructor lets you specify this delegate
  /// explicitly. The [ListView] and [ListView.builder] constructors create a
  /// [childrenDelegate] that wraps the given [List] and [IndexedWidgetBuilder],
  /// respectively.
  final SliverChildDelegate childrenDelegate;

  /// When set provides access to extents of individual children.
  /// [ListController] can also be used to jump to a specific item in the list.
  final ListController? listController;

  /// Optional method that can be used to override default estimated extent for
  /// each item. Initially all extents are estimated and then as the items are laid
  /// out, either through scrolling or [extentPrecalculationPolicy], the actual
  /// extents are calculated and the scroll offset is adjusted to account for
  /// the difference between estimated and actual extents.
  final ExtentEstimationProvider? extentEstimation;

  /// Optional policy that can be used to asynchronously precalculate the extents
  /// of the items in the list. This can be useful allow precise scrolling on small
  /// lists where the difference between estimated and actual extents may be noticeable
  /// when interacting with the scrollbar. For larger lists precalculating extent
  /// has diminishing benefits since the error for each item does not impact the
  /// overall scroll position as much.
  final ExtentPrecalculationPolicy? extentPrecalculationPolicy;

  /// Whether the items in cache area should be built delayed.
  /// This is an optimization that kicks in during fast scrolling, when
  /// all items are being replaced on every frame.
  /// With [delayPopulatingCacheArea] set to `true`, the items in cache area
  /// are only built after the scrolling slows down.
  final bool delayPopulatingCacheArea;

  @override
  Widget buildChildLayout(BuildContext context) {
    return SuperSliverList(
      delegate: childrenDelegate,
      listController: listController,
      delayPopulatingCacheArea: delayPopulatingCacheArea,
      extentEstimation: extentEstimation,
      extentPrecalculationPolicy: extentPrecalculationPolicy,
    );
  }

  // Helper method to compute the actual child count for the separated constructor.
  static int _computeActualChildCount(int itemCount) {
    return math.max(0, itemCount * 2 - 1);
  }
}
