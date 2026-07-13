import "dart:math" as math;

import "package:flutter/rendering.dart";
import "package:flutter/widgets.dart";
import "package:logging/logging.dart";

import "animate_to_item.dart";
import "element.dart";
import "extent_manager.dart";
import "layout_budget.dart";
import "render_object.dart";

final _log = Logger("SuperSliverList");

@Deprecated("Use ListController instead.")
typedef ExtentController = ListController;

/// Interface to the sliver list.
///
/// List controller can be used to
/// - jump or animate to a specific item in the list
/// - query the extent of an item
/// - query total number of item as well as number of items with estimated extents
/// - invalidate extent of an item to force recalculation
///
/// List controller can only be attached to a single [SuperSliverList] at a time.
/// All methods except [isAttached] will throw if the controller is not attached.
///
/// List controller is also a [ChangeNotifier] and will notify its listeners
/// if the underlying list or item extents change.
///
/// Example usage:
/// ```dart
///class _MyState extends State<MyWidget> {
///  final _listController = ListController();
///  final _scrollController = ScrollController();
///
///  @override
///  Widget build(BuildContext context) {
///    return SuperListView.builder(
///      listController: _listController,
///      controller: _scrollController,
///      itemCount: 1000,
///      itemBuilder: (context, index) {
///        return ListTile(title: Text('Item $index'));
///      },
///    );
///  }
///
///  void jumpToItem(int index) {
///    _listController.jumpToItem(
///      index: index,
///      scrollController: _scrollController,
///      alignment: 0.5,
///    );
///  }
///}
///```
class ListController extends ChangeNotifier {
  ListController({
    this.onAttached,
    this.onDetached,
  });

  /// Callback invoked when the controller is attached to a [SuperSliverList].
  final VoidCallback? onAttached;

  /// Callback invoked when the controller is detached from a [SuperSliverList].
  final VoidCallback? onDetached;

  /// Returns `true` if the controller is attached to a [SuperSliverList].
  bool get isAttached => _delegate != null;

  /// Immediately positions the scroll view such that the item at [index] is
  /// revealed in the viewport.
  ///
  /// The optional [rect] parameter describes which area of that target item
  /// should be revealed in the viewport. If omitted, the entire item
  /// will be revealed (subject to the constraints of the viewport).
  ///
  /// The [alignment] parameter controls where the item is positioned in the
  /// viewport. If the value is 0.0, the item will be positioned at the leading
  /// edge of the viewport. If the value is 0.5, the item will be positioned in
  /// the middle of the viewport. If the value is 1.0, the item will be
  /// positioned at the trailing edge of the viewport.
  void jumpToItem({
    required int index,
    required ScrollController scrollController,
    required double alignment,
    Rect? rect,
  }) {
    assert(_delegate != null, "ListController is not attached.");
    final offset = getOffsetToReveal(index, alignment, rect: rect);
    if (offset.isFinite) {
      final minExtent = scrollController.position.minScrollExtent;
      final maxExtent = scrollController.position.maxScrollExtent;
      final pixels = scrollController.position.pixels;
      // If the scroll view is already at the edge don't do anything.
      // Otherwise this may result in scrollbar handle artifacts.
      if ((offset <= minExtent && pixels == minExtent) ||
          (offset >= maxExtent && pixels == maxExtent)) {
        return;
      }
      scrollController.jumpTo(offset);
    } else {
      _log.warning("getOffsetToReveal returned non-finite value.");
    }
  }

  /// Animates the position of the scroll view such that the item at [index] is
  /// revealed in the viewport.
  ///
  /// The index getter will be called repeatedly on every animation tick, which
  /// allows for accommodating index changes when items are inserted or removed
  /// during the animation. Returning `null` from the index getter will stop
  /// the animation.
  ///
  /// The optional [rect] parameter describes which area of that target item
  /// should be revealed in the viewport. If omitted, the entire item
  /// will be revealed (subject to the constraints of the viewport).
  ///
  /// The [alignment] parameter controls where the item is positioned in the
  /// viewport. If the value is 0.0, the item will be positioned at the leading
  /// edge of the viewport. If the value is 0.5, the item will be positioned in
  /// the middle of the viewport. If the value is 1.0, the item will be
  /// positioned at the trailing edge of the viewport.
  void animateToItem({
    required ValueGetter<int?> index,
    required ScrollController scrollController,
    required double alignment,
    required Duration Function(double estimatedDistance) duration,
    required Curve Function(double estimatedDistance) curve,
    Rect? rect,
  }) {
    assert(_delegate != null, "ListController is not attached.");
    for (final position in scrollController.positions) {
      AnimateToItem(
        extentManager: _delegate!,
        index: index,
        alignment: alignment,
        rect: rect,
        position: position,
        curve: curve,
        duration: duration,
      ).animate();
    }
  }

  /// Returns the range of items indices currently visible in the viewport.
  (int, int)? get visibleRange {
    assert(_delegate != null, "ListController is not attached.");
    return _delegate!.visibleRange;
  }

  /// Returns range of items indices currently visible in the viewport
  /// unobstructed by sticky headers or other obstructions.
  (int, int)? get unobstructedVisibleRange {
    assert(_delegate != null, "ListController is not attached.");
    return _delegate!.unobstructedVisibleRange;
  }

  /// Returns the total number of items in the list.
  int get numberOfItems {
    assert(_delegate != null, "ListController is not attached.");
    return _delegate!.numberOfItems;
  }

  /// Returns the number of items in the list with estimated extent.
  int get numberOfItemsWithEstimatedExtent {
    assert(_delegate != null, "ListController is not attached.");
    return _delegate!.numberOfItemsWithEstimatedExtent;
  }

  /// Returns the extent of the item at [index].
  ///
  /// If `isEstimated` is `true`, the returned extent is an estimate and may not
  /// have been obtained by laying out the item and measuring the item.
  ///
  /// If `isEstimated` is `false`, the returned extent is the actual extent of
  /// the item. However if the item is not currently in the cache area the
  /// returned extent may be outdated and will be updated when the item is
  /// scrolled into view, laid out and measured.
  (double, bool isEstimated) extentForIndex(int index) {
    assert(_delegate != null, "ListController is not attached.");
    return _delegate!.extentForIndex(index);
  }

  /// Returns the sum of all the extents of the items in the list.
  double get totalExtent {
    assert(_delegate != null, "ListController is not attached.");
    return _delegate!.totalExtent;
  }

  /// Returns whether the underlying list is currently locked.
  ///
  /// Methods that modify the underlying extent list, such as [invalidateExtent],
  /// [invalidateAllExtents], [addItem], and [removeItem], will throw if called
  /// when list is locked.
  ///
  /// The list is locked during layout and unlock after the layout is complete.
  bool get isLocked {
    assert(_delegate != null, "ListController is not attached.");
    return _delegate!.isLocked;
  }

  /// Invalidates the extent of the item at [index]. Invalidating extent will
  /// treat the extent as an estimation and will recalculate the extent if the
  /// [ExtentPrecalculationPolicy] allows for eagerly precalculating extents.
  void invalidateExtent(int index) {
    assert(_delegate != null, "ListController is not attached.");
    _delegate!.invalidateExtent(index);
  }

  /// Invalidates the extent of all items in the list.
  /// All extents will be treated as estimations and will be recalculated if the
  /// [ExtentPrecalculationPolicy] allows for eagerly precalculating extents.
  void invalidateAllExtents() {
    assert(_delegate != null, "ListController is not attached.");
    _delegate!.invalidateAllExtents();
  }

  /// Signals that a new item has been added to the list at [index].
  /// This shift all extents after the [index] by one and will create new
  /// estimated extent for the new item.
  ///
  /// Being able to notify the list of an item being added is useful when
  /// eagerly precalculating extents.
  void addItem(int index) {
    assert(_delegate != null, "ListController is not attached.");
    _delegate!.addItem(index);
  }

  /// Signals that an item has been removed from the list at [index].
  /// This shift all extents after the [index] by one and will remove the
  /// extent of the removed item.
  ///
  /// Being able to notify the list of an item being removed is useful when
  /// eagerly precalculating extents.
  void removeItem(int index) {
    assert(_delegate != null, "ListController is not attached.");
    _delegate!.removeItem(index);
  }

  @override
  void dispose() {
    if (_delegate != null) {
      unsetDelegate(_delegate!);
    }
    super.dispose();
  }

  ExtentManager? _delegate;

  void setDelegate(ExtentManager delegate) {
    if (_delegate == delegate) {
      return;
    }
    if (_delegate != null) {
      onDetached?.call();
    }
    _delegate?.removeListener(notifyListeners);
    _delegate = delegate;
    _delegate?.addListener(notifyListeners);
    if (_delegate != null) {
      onAttached?.call();
    }
  }

  void unsetDelegate(ExtentManager delegate) {
    if (_delegate == delegate) {
      _delegate?.removeListener(notifyListeners);
      _delegate = null;
      onDetached?.call();
    }
  }

  @visibleForTesting
  double getOffsetToReveal(int index, double alignment, {Rect? rect}) {
    assert(_delegate != null, "ListController is not attached.");
    return _delegate!.getOffsetToReveal(
      index,
      alignment,
      rect: rect,
      estimationOnly: false,
    );
  }
}

typedef ExtentEstimationProvider = double Function(
  int? index,
  double crossAxisExtent,
);

abstract class ExtentPrecalculationPolicyDelegate {
  void valueDidChange();
}

class ExtentPrecalculationContext {
  ExtentPrecalculationContext({
    required this.viewportMainAxisExtent,
    required this.contentTotalExtent,
    required this.numberOfItems,
    required this.numberOfItemsWithEstimatedExtent,
  });

  /// The main axis extent of the viewport. May not be available initially.
  final double? viewportMainAxisExtent;

  /// The main axis extent of the content. May not be available initially.
  final double? contentTotalExtent;

  /// Number of items in the sliver.
  final int numberOfItems;

  /// Number of items in the sliver with estimated extent.
  final int numberOfItemsWithEstimatedExtent;
}

/// Subclass of [ExtentPrecalculationPolicy] can be used to control whether and
/// how many extents of the items in the list should be eagerly precalculated.
///
/// Extent precalculation may be helpful when precise scrollbar behavior is
/// desired. This is relevant for smaller lists, where the difference between
/// estimated and actual extents may affect the scrollbar position noticeably.
///
/// For larger lists, precalculating extents has diminishing benefits since the
/// difference between estimated and actual extent for each item has much
/// smaller impact on the scrollbar position.
///
/// There is no perfect answer for when or whether at all to precalculate
/// extents It depends on the specific application requirements.
abstract class ExtentPrecalculationPolicy {
  /// Called when the policy is attached to a [SuperSliverList]. Single policy may
  /// be attached to multiple [SuperSliverList]s.
  void onAttached() {}

  /// Called when the policy is detached from a [SuperSliverList].
  void onDetached() {}

  /// Called during layout to determine whether more extents should be precalculated.
  ///
  /// - If `true` is returned, the [SuperSliverList] will attempt to precalculate
  /// more extents for the list.
  /// - If `false is returned, the precalculation will stop.
  ///
  /// The [context] provides information about the current state of the list.
  ///
  /// If the conditions for precalculation change, the policy should call
  /// [valueDidChange] to notify the [SuperSliverList] that the policy has changed.
  bool shouldPrecalculateExtents(ExtentPrecalculationContext context);

  /// Notifies the [SuperSliverList] that the policy has changed. If the policy returned
  /// `false` from [shouldPrecalculateExtents] and then the condition changed and
  /// more extents should be precalculated, the policy calls [valueDidChange] to
  /// let the SliverList know that the policy has changed and the precalculation
  /// should be attempted again.
  void valueDidChange() {
    for (final delegate in _delegates) {
      delegate.valueDidChange();
    }
  }

  void addDelegate(ExtentPrecalculationPolicyDelegate? value) {
    _delegates.add(value!);
    if (_delegates.length == 1) {
      onAttached();
    }
  }

  void removeDelegate(ExtentPrecalculationPolicyDelegate? value) {
    _delegates.remove(value);
    if (_delegates.isEmpty) {
      onDetached();
    }
  }

  final _delegates = <ExtentPrecalculationPolicyDelegate>{};
}

/// Drop-in replacement for [SliverList] that can handle arbitrary large amount
/// of items with variable extent.
///
/// Through [listController] it [SuperSliverList] also provides a way to
/// jump to any item in the list, even if the item is not currently visible
/// or has not been laid out.
class SuperSliverList extends SliverMultiBoxAdaptorWidget {
  const SuperSliverList({
    super.key,
    required super.delegate,
    this.extentPrecalculationPolicy,
    this.listController,
    this.extentEstimation,
    this.delayPopulatingCacheArea = true,
    this.layoutKeptAliveChildren = false,
  });

  /// Creates a SuperSliverList from widget builder.
  ///
  /// See [SliverList.builder] for details.
  SuperSliverList.builder({
    super.key,
    required NullableIndexedWidgetBuilder itemBuilder,
    ChildIndexGetter? findChildIndexCallback,
    int? itemCount,
    this.extentPrecalculationPolicy,
    this.listController,
    this.extentEstimation,
    this.delayPopulatingCacheArea = true,
    this.layoutKeptAliveChildren = false,
    bool addAutomaticKeepAlives = true,
    bool addRepaintBoundaries = true,
    bool addSemanticIndexes = true,
  }) : super(
          delegate: SliverChildBuilderDelegate(
            itemBuilder,
            findChildIndexCallback: findChildIndexCallback,
            childCount: itemCount,
            addAutomaticKeepAlives: addAutomaticKeepAlives,
            addRepaintBoundaries: addRepaintBoundaries,
            addSemanticIndexes: addSemanticIndexes,
          ),
        );

  /// Creates a SuperSliverList from widget builder separated by separator
  /// widgets.
  ///
  /// See [SliverList.separated] for details.
  SuperSliverList.separated({
    super.key,
    required NullableIndexedWidgetBuilder itemBuilder,
    ChildIndexGetter? findChildIndexCallback,
    required NullableIndexedWidgetBuilder separatorBuilder,
    this.extentPrecalculationPolicy,
    this.listController,
    this.extentEstimation,
    this.delayPopulatingCacheArea = true,
    this.layoutKeptAliveChildren = false,
    int? itemCount,
    bool addAutomaticKeepAlives = true,
    bool addRepaintBoundaries = true,
    bool addSemanticIndexes = true,
  }) : super(
          delegate: SliverChildBuilderDelegate(
            (BuildContext context, int index) {
              final int itemIndex = index ~/ 2;
              final Widget? widget;
              if (index.isEven) {
                widget = itemBuilder(context, itemIndex);
              } else {
                widget = separatorBuilder(context, itemIndex);
                assert(() {
                  if (widget == null) {
                    throw FlutterError("separatorBuilder cannot return null.");
                  }
                  return true;
                }());
              }
              return widget;
            },
            findChildIndexCallback: findChildIndexCallback,
            childCount:
                itemCount == null ? null : math.max(0, itemCount * 2 - 1),
            addAutomaticKeepAlives: addAutomaticKeepAlives,
            addRepaintBoundaries: addRepaintBoundaries,
            addSemanticIndexes: addSemanticIndexes,
            semanticIndexCallback: (Widget _, int index) {
              return index.isEven ? index ~/ 2 : null;
            },
          ),
        );

  /// Creates a SuperSliverList from list of child widgets.
  ///
  /// See [SliverList.list] for details.
  SuperSliverList.list({
    super.key,
    required List<Widget> children,
    this.extentPrecalculationPolicy,
    this.listController,
    this.extentEstimation,
    this.delayPopulatingCacheArea = true,
    this.layoutKeptAliveChildren = false,
    bool addAutomaticKeepAlives = true,
    bool addRepaintBoundaries = true,
    bool addSemanticIndexes = true,
  }) : super(
          delegate: SliverChildListDelegate(
            children,
            addAutomaticKeepAlives: addAutomaticKeepAlives,
            addRepaintBoundaries: addRepaintBoundaries,
            addSemanticIndexes: addSemanticIndexes,
          ),
        );

  /// When set provides access to extents of individual children.
  /// [ListController] can also be used to jump to a specific item in the list.
  final ListController? listController;

  /// Optional method that can be used to override default estimated extent for
  /// each item. Initially all extents are estimated and then as the items are laid
  /// out, either through scrolling or [extentPrecalculationPolicy], the actual
  /// extents are calculated and the scroll offset is adjusted to account for
  /// the difference between estimated and actual extents.
  ///
  /// The item index argument is nullable. If all estimated items have same extent,
  /// the implementation should return non-zero extent for the `null` index. This saves
  /// calls to extent estimation provider for large lists.
  /// If each item has different extent, return zero for the `null` index.
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

  /// Whether children with keepAlive should be laid out.
  /// Setting this to `true` ensures that layout for kept alive children is
  /// maintained and proper paint transform is applied.
  final bool layoutKeptAliveChildren;

  static SuperSliverListLayoutBudget layoutBudget =
      _TimeSuperSliverListLayoutBudget(
    budget: const Duration(milliseconds: 3),
  );

  @override
  SliverMultiBoxAdaptorElement createElement() =>
      SuperSliverMultiBoxAdaptorElement(this, replaceMovedChildren: true);

  @override
  RenderSliverMultiBoxAdaptor createRenderObject(BuildContext context) {
    final element = context as SuperSliverMultiBoxAdaptorElement;
    return RenderSuperSliverList(
      childManager: element,
      extentPrecalculationPolicy: extentPrecalculationPolicy,
      estimateExtent: extentEstimation ?? _defaultEstimateExtent,
      delayPopulatingCacheArea: delayPopulatingCacheArea,
      layoutKeptAliveChildren: layoutKeptAliveChildren,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    super.updateRenderObject(context, renderObject);
    final renderSliverList = renderObject as RenderSuperSliverList;
    renderSliverList.extentPrecalculationPolicy = extentPrecalculationPolicy;
    renderSliverList.estimateExtent =
        extentEstimation ?? _defaultEstimateExtent;
    renderSliverList.delayPopulatingCacheArea = delayPopulatingCacheArea;
    renderSliverList.layoutKeptAliveChildren = layoutKeptAliveChildren;
  }
}

class _TimeSuperSliverListLayoutBudget extends SuperSliverListLayoutBudget {
  _TimeSuperSliverListLayoutBudget({
    required this.budget,
  });

  @override
  void reset() {
    _stopwatch.reset();
  }

  @override
  void beginLayout() {
    _stopwatch.start();
  }

  @override
  void endLayout() {
    _stopwatch.stop();
  }

  @override
  bool shouldLayoutNextItem() {
    return _stopwatch.elapsed < budget;
  }

  final _stopwatch = Stopwatch();

  final Duration budget;
}

double _defaultEstimateExtent(int? index, double crossAxisExtent) {
  return 100.0;
}
