import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter/rendering.dart";
import "package:flutter/widgets.dart";
import "package:logging/logging.dart";

import "element.dart";
import "extent_manager.dart";
import "layout_budget.dart";
import "layout_pass.dart";
import "sliver_extensions.dart";
import "super_sliver_list.dart";

final _log = Logger("SuperSliverList");

/// When providing child scroll offset for a child that is not currently visible
/// the list will estimate offset for the child and then will attempt to correct
/// the correct the scroll offset during layout;
class _ChildScrollOffsetEstimation {
  _ChildScrollOffsetEstimation({
    required this.index,
    required this.offset,
    required this.extent,
    required this.precedingScrollExtent,
    required this.revealingRect,
    required this.alignment,
    required this.childObstructionExtent,
  });

  /// Index of child for which the offset was estimated.
  final int index;

  /// Estimated offset returned from childScrollOffset. This will be compared
  /// to actual child offset during layout and if different, the scroll offset
  /// will be corrected.
  final double offset;

  /// Last known extent of child when determining estimated scroll offset. Depending
  /// on child alignment within viewport the extent difference my affect the
  /// scroll offset correction.
  final double extent;

  /// Preceding scroll extent at the moment when offset was estimated. Used to compensate
  /// for change in preceding sliver extent change during layout.
  final double precedingScrollExtent;

  /// Whether the entire element or only a rect should be revealed.
  final bool revealingRect;

  /// Child alignment within viewport.
  final double alignment;

  /// Child obstruction extent when estimation was made.
  final ChildObstructionExtent childObstructionExtent;

  /// Scroll offset of viewport when estimation was made.
  double? viewportScrollOffset;
}

class RenderSuperSliverList extends RenderSliverMultiBoxAdaptor
    implements ExtentPrecalculationPolicyDelegate {
  RenderSuperSliverList({
    required super.childManager,
    ExtentPrecalculationPolicy? extentPrecalculationPolicy,
    required this.estimateExtent,
    required this.delayPopulatingCacheArea,
    required this.layoutKeptAliveChildren,
  }) {
    this.extentPrecalculationPolicy = extentPrecalculationPolicy;
  }

  @override
  SuperSliverMultiBoxAdaptorElement get childManager =>
      super.childManager as SuperSliverMultiBoxAdaptorElement;

  set extentPrecalculationPolicy(ExtentPrecalculationPolicy? value) {
    if (value == _extentPrecalculationPolicy) {
      return;
    }
    _extentPrecalculationPolicy?.removeDelegate(this);
    _extentPrecalculationPolicy = value;
    _extentPrecalculationPolicy?.addDelegate(this);
  }

  ExtentPrecalculationPolicy? _extentPrecalculationPolicy;
  ExtentEstimationProvider estimateExtent;
  bool delayPopulatingCacheArea;
  bool layoutKeptAliveChildren = false;

  bool _shouldPrecalculateExtents(LayoutPass pass) {
    final state = pass.getLayoutState(this);
    final viewport = getViewport()!;
    final position = viewport.offset as ScrollPosition;
    final context = ExtentPrecalculationContext(
      viewportMainAxisExtent:
          position.hasViewportDimension ? position.viewportDimension : null,
      contentTotalExtent: position.hasContentDimensions
          ? position.maxScrollExtent - position.minScrollExtent
          : null,
      numberOfItems: _extentManager.numberOfItems,
      numberOfItemsWithEstimatedExtent:
          _extentManager.numberOfItemsWithEstimatedExtent,
    );
    state.precalculateExtents ??=
        _extentPrecalculationPolicy?.shouldPrecalculateExtents(context) ??
            false;
    return state.precalculateExtents!;
  }

  // If this sliver list is not visible it should not precalculate extents
  // while there are any visible lists that have dirty extents and want
  // extent precalculation.
  bool _shouldSkipExtentPrecalculationForInvisibleList(LayoutPass pass) {
    for (final sliver in pass.slivers) {
      if (sliver.firstChild != null &&
          sliver._extentManager.hasDirtyItems &&
          sliver._shouldPrecalculateExtents(pass)) {
        return true;
      }
    }
    return false;
  }

  @override
  void dispose() {
    super.dispose();
    _extentPrecalculationPolicy?.removeDelegate(this);
  }

  ExtentManager get _extentManager => childManager.extentManager;
  SliverConstraints? previousConstraints;

  _ChildScrollOffsetEstimation? _childScrollOffsetEstimation;

  void sanitizeChildScrollOffsetEstimation(RenderViewportBase viewport) {
    if (_childScrollOffsetEstimation != null) {
      final offset = viewport.offset.pixels;
      if (_childScrollOffsetEstimation!.viewportScrollOffset != null &&
          (_childScrollOffsetEstimation!.viewportScrollOffset! - offset).abs() >
              1.0) {
        _log.fine(
          "Viewport scroll offset changed since estimation. Discarding",
        );
        _childScrollOffsetEstimation = null;
      }
    }
  }

  @override
  double? childScrollOffset(covariant RenderObject child) {
    for (var c = firstChild; c != null; c = childAfter(c)) {
      if (child == c) {
        return super.childScrollOffset(child);
      }
    }

    final offsetToRevealContext = OffsetToRevealContext.current();
    if (offsetToRevealContext == null) {
      return super.childScrollOffset(child);
    }

    // Trying to query child offset of child that's not currently visible;
    // Assume this is from viewPort.getOffsetToReveal, in which case we'll
    // estimate the offset, but also remember the index and offset so that
    // we can possibly correct scrollOffset in next performLayout call.
    final index = indexOf(child as RenderBox);

    assert(
      offsetToRevealContext.viewport == getViewport(),
    );

    if (offsetToRevealContext.estimationOnly == true) {
      return _extentManager.offsetForIndex(index);
    }

    // This should be as simple as reading precedingScrollExtent from the constraints,
    // but it is not. precedingScrollExtent is not included in SliverConstraints operator==
    // which means that all other fields being same the constraints will not be updated.
    // As a workaround, the preceding scroll extent is determined by summing all preceding
    // sliver scroll extents and the difference between preceding scroll extent of top
    // level parent of this sliver (viewport) and this sliver precedingScrollExtent.
    double getActualPrecedingScrollExtent() {
      final viewport = getViewport()!;
      bool isParent(RenderObject object) {
        var parent = this.parent;
        while (parent != null && parent != viewport) {
          if (parent == object) {
            return true;
          }
          parent = parent.parent;
        }
        return false;
      }

      double offset = 0;
      bool finished = false;
      viewport.visitChildren((child) {
        if (finished) {
          return;
        }
        if (child is! RenderSliver) {
          assert(false, "Unexpected non-sliver child of viewport");
          return;
        }
        if (isParent(child)) {
          final difference = constraints.precedingScrollExtent -
              child.constraints.precedingScrollExtent;
          offset += difference;
          finished = true;
          return;
        }
        if (child == this) {
          finished = true;
          return;
        }
        offset += child.geometry!.scrollExtent;
      });
      assert(finished, "Viewport doesn't seem to contain current sliver?");
      return offset;
    }

    final precedingScrollExtent = getActualPrecedingScrollExtent();
    if (constraints.precedingScrollExtent != precedingScrollExtent) {
      _log.fine(
        "Constraints have outdated preceding scroll extent ${constraints.precedingScrollExtent.format()}, actual is ${precedingScrollExtent.format()}",
      );
    }

    _childScrollOffsetEstimation = _ChildScrollOffsetEstimation(
      index: index,
      offset: _extentManager.offsetForIndex(index),
      extent: _extentManager.getExtent(index),
      precedingScrollExtent: precedingScrollExtent,
      revealingRect: offsetToRevealContext.rect != null,
      alignment: offsetToRevealContext.alignment,
      childObstructionExtent: child.getParentChildObstructionExtent(),
    );

    assert(offsetToRevealContext.estimationOnly == false);
    offsetToRevealContext.registerOffsetResolvedCallback((value) {
      final offset = value.offset;
      // Remember the target scroll position. Scroll correction will only be enforced
      // when the viewport scroll position is the same as when the estimation was made.
      // This is enforced by [LayoutPass.sanitizeChildScrollOffsetEstimation].
      final position = getViewport()!.offset as ScrollPosition;
      // Only remember position if it is within scroll extent. Otherwise
      // it will be corrected and it is not possible to check against it.
      if (offset >= position.minScrollExtent &&
          offset <= position.maxScrollExtent) {
        _childScrollOffsetEstimation?.viewportScrollOffset = offset;
      }
    });

    _log.fine(
      "$_logIdentifier remembering estimated offset ${_childScrollOffsetEstimation!.offset} for child $index (preceding extent ${constraints.precedingScrollExtent})",
    );
    final slivers = getSuperSliverLists();
    for (final sliver in slivers) {
      sliver.markNeedsLayout();
      if (sliver != this) {
        // Only one sliver should have active estimation.
        sliver._childScrollOffsetEstimation = null;
      } else if (sliver == this) {
        break;
      }
    }
    return _childScrollOffsetEstimation!.offset;
  }

  /// Moves the layout offset of this and subsequent children by the given delta.
  void _shiftLayoutOffsets(RenderBox? child, double delta) {
    while (child != null) {
      final data = child.parentData! as SliverMultiBoxAdaptorParentData;
      if (data.layoutOffset != null) {
        data.layoutOffset = data.layoutOffset! + delta;
      }
      child = childAfter(child);
    }
  }

  /// Layouts single child. Will return scrollOffset of the child, or `null`
  /// if scroll offset couldn't have been determined.
  ///
  /// Resets the layoutOffset of the child after.
  double? layoutChild(
    RenderBox child,
    BoxConstraints childConstraints, {
    RenderBox? lastChildWithScrollOffset,
  }) {
    // If child offset can't be determined, there's no point laying out the child.
    if (childScrollOffset(child) == null && lastChildWithScrollOffset == null) {
      return null;
    }
    if (childScrollOffset(child) == null) {
      final data = child.parentData! as SliverMultiBoxAdaptorParentData;
      data.layoutOffset = childScrollOffset(lastChildWithScrollOffset!)! +
          paintExtentOf(lastChildWithScrollOffset);
    }
    child.layout(childConstraints, parentUsesSize: true);
    final index = indexOf(child);
    _extentManager.setExtent(index, paintExtentOf(child));
    final nextChild = childAfter(child);
    if (nextChild != null) {
      final nextChildData =
          nextChild.parentData! as SliverMultiBoxAdaptorParentData;
      nextChildData.layoutOffset = null;
    }
    return childScrollOffset(child);
  }

  static SuperSliverListLayoutBudget? _currentLayoutBudget;

  SuperSliverListLayoutBudget _getLayoutBudget() {
    if (_currentLayoutBudget == null) {
      _currentLayoutBudget = SuperSliverList.layoutBudget;
      Future.microtask(() {
        _currentLayoutBudget!.reset();
        _currentLayoutBudget = null;
      });
    }
    return _currentLayoutBudget!;
  }

  double _layoutKeptAliveChildren() {
    if (!layoutKeptAliveChildren) {
      return 0.0;
    }
    double correction = 0.0;
    final firstChildIndex = firstChild != null ? indexOf(firstChild!) : -1;
    // First step - layout all kept alive children.
    visitChildren((child_) {
      final child = child_ as RenderBox;
      final data = child.parentData! as SliverMultiBoxAdaptorParentData;
      if (data.keptAlive) {
        final index = indexOf(child);
        final constraints = this.constraints.asBoxConstraints();
        final prevExtent = _extentManager.getExtent(index);
        child.layout(constraints, parentUsesSize: true);
        final extentAfter = paintExtentOf(child);
        _extentManager.setExtent(index, extentAfter);
        if (index < firstChildIndex) {
          correction += extentAfter - prevExtent;
        }
      }
    });
    // Second step - update layout offset. This is done after all children have
    // been laid out.
    visitChildren((child_) {
      final child = child_ as RenderBox;
      final data = child.parentData! as SliverMultiBoxAdaptorParentData;
      if (data.keptAlive) {
        final index = indexOf(child);
        final data = child.parentData! as SliverMultiBoxAdaptorParentData;
        data.layoutOffset = _extentManager.offsetForIndex(index);
      }
    });
    return correction;
  }

  /// Calculates layout info for dirty items. Returns scroll offset correction.
  double _calculatePendingLayout({
    required LayoutPass layoutPass,
    required bool allowScrollOffsetCorrection,
    required bool precalculateExtents,
  }) {
    final SliverConstraints constraints = this.constraints;

    if (!_extentManager.hasDirtyItems || !precalculateExtents) {
      return 0;
    }

    double correction = 0;

    final budget = _getLayoutBudget();

    final childCount = childManager.childCount;

    budget.beginLayout();

    while (precalculateExtents &&
        _extentManager.hasDirtyItems &&
        budget.shouldLayoutNextItem()) {
      var start = _extentManager.cleanRangeStart;
      var end = _extentManager.cleanRangeEnd;

      if (start == null && end == null) {
        start = childCount;
        end = childCount;
      } else {
        start = start!;
        end = end!;
      }

      // Only layout items before clean range if scroll correction is allowed.
      // There is limited amount of scroll correction attempts during layout pass
      // and if exceeded viewport layout will throw an exception.
      if (start > 0 && allowScrollOffsetCorrection) {
        final index = start - 1;
        invokeLayoutCallback((_) {
          final extent = childManager.measureExtentForItem(index, constraints);
          final prevExtent = _extentManager.getExtent(index);
          _extentManager.setExtent(index, extent);
          correction += extent - prevExtent;
        });
      }

      if (end < childCount - 1) {
        final index = end + 1;
        invokeLayoutCallback((_) {
          final extent = childManager.measureExtentForItem(index, constraints);
          _extentManager.setExtent(index, extent);
        });
      }
    }

    budget.endLayout();

    if (precalculateExtents && _extentManager.hasDirtyItems) {
      _log.finer(
          "Did not manage to calculate extents within budget. Scheduling layout pass.");
      _markNeedsLayoutDelayed(layoutPass);
    }
    return correction;
  }

  void _markNeedsLayoutDelayed(LayoutPass pass) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final thisIndex = pass.sliversDuringLayout.indexOf(this);
      // When scheduling layout pass, make sure that all slivers laid out after this
      // also get their layout invalidated. This is necessary because this sliver layout
      // may change precedingScrollExtent of slivers after. Preceding scroll extent is used
      // during correction for jump to index estimation.
      for (final s in pass.slivers) {
        final theirIndex = pass.sliversDuringLayout.indexOf(s);
        if (theirIndex == -1 || theirIndex >= thisIndex) {
          s.markNeedsLayout();
        }
      }
    });
  }

  double estimateExtentForItem(int? index) {
    return estimateExtent(index, constraints.crossAxisExtent);
  }

  @override
  void performLayout() {
    _extentManager.performLayout(_performLayoutInner);
  }

  @override
  void layout(Constraints constraints, {bool parentUsesSize = false}) {
    super.layout(constraints, parentUsesSize: parentUsesSize);
    // It is possible that after requesting scroll offset correction the
    // constraints during next layout call are same as before, which will skip
    // performLayout meaning the scrollCorrection gets stuck and viewport will
    // throw exception. To work around this force layout if there is scroll
    // offset correction requested.
    if (geometry?.scrollOffsetCorrection != null &&
        geometry?.scrollOffsetCorrection != 0) {
      parent?.invokeLayoutCallback((constraints) {
        markNeedsLayout();
      });
    }
  }

  bool get hasChildScrollOffsetEstimation =>
      _childScrollOffsetEstimation != null;

  String get _logIdentifier =>
      identityHashCode(this).toRadixString(16).padLeft(8, "0");

  void _performLayoutInner() {
    final layoutPass = getLayoutPass(this)!;
    if (layoutPass.isNew) {
      _log.fine(
        "Begin layout pass (${layoutPass.slivers.length} SuperSliverList instances)",
      );
      layoutPass.isNew = false;
    }

    // State for this sliver (will be same instance for all layout attempts).
    final layoutState = layoutPass.getLayoutState(this);

    final SliverConstraints constraints = this.constraints;
    final BoxConstraints childConstraints = constraints.asBoxConstraints();
    final totalChildCount = childManager.childCount;

    _extentManager.resize(totalChildCount);

    final bool crossAxisResizing;

    if (previousConstraints != null &&
        previousConstraints!.crossAxisExtent != constraints.crossAxisExtent) {
      _extentManager.markAllDirty();
      crossAxisResizing = true;
    } else {
      crossAxisResizing = false;
    }

    // Layout can be called multiple times, make sure we don't overwrite
    // previousConstraints during same layout pass.
    if (!layoutState.didSetPreviousConstraint) {
      layoutState.didSetPreviousConstraint = true;
      previousConstraints = constraints;
    }

    childManager.didStartLayout();
    childManager.setDidUnderflow(false);

    // This is also the last extent that this sliver list reported.
    final initialExtent = _totalExtent();

    // Viewport is not at the beginning.
    final viewportIsScrolled = (constraints.viewportMainAxisExtent -
                constraints.remainingPaintExtent) <
            constraints.precedingScrollExtent ||
        constraints.scrollOffset > 0;

    // This sliver ends in visible area of viewport and viewport is scrolled.
    // When this is true the SuperSliverList will try to keep the bottom of the
    // list at the same position when updating the extents by adjusting the scroll
    // offset.
    final anchoredAtEnd = viewportIsScrolled &&
        (constraints.scrollOffset + constraints.remainingPaintExtent) +
                precisionErrorTolerance >=
            initialExtent &&
        (layoutPass.childScrollOffsetEstimation == false ||
            layoutPass.sliverIsBeforeSliverWithOffsetEstimation(this));

    _log.fine(
      "Laying out $_logIdentifier "
      "("
      "anchored at end: $anchoredAtEnd, "
      "initial extent: ${initialExtent.format()}, "
      "scroll offset: ${constraints.scrollOffset.format()}, "
      "overlap: ${constraints.overlap}, "
      "remaining paint extent: ${constraints.remainingPaintExtent.format()}, "
      "cache: ${constraints.cacheOrigin.format()} - "
      "${constraints.remainingCacheExtent.format()}, "
      "preceding: ${constraints.precedingScrollExtent.format()}"
      ")",
    );

    // Scroll offset including cache area.
    var startOffset = constraints.scrollOffset + constraints.cacheOrigin;
    var remainingExtent = constraints.remainingCacheExtent;

    // First go through all children, remove those that are no longer
    // in cache area and layout those that are in the cache area.
    int leadingGarbage = 0;
    int trailingGarbage = 0;
    RenderBox? lastChildWithScrollOffset;

    final firstVisible = _firstWholeVisibleChild();
    final double? firstVisibleLayoutOffset =
        firstVisible != null ? childScrollOffset(firstVisible) : null;

    RenderBox? previousChild;
    int index = firstChild != null ? indexOf(firstChild!) : 0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      // all items after first trailing garbage are automatically garbage
      if (trailingGarbage > 0) {
        ++trailingGarbage;
      } else {
        if (indexOf(child) != index) {
          final newChild =
              insertAndLayoutChild(childConstraints, after: previousChild);
          // This should not normally happen. If there is GAP between children we should be
          // able to fill it, otherwise it would be an inconsistency in childManager.
          assert(newChild != null, "Unexpected trailing child.");
          if (newChild == null) {
            ++trailingGarbage;
            continue;
          } else {
            child = newChild;
          }
        }
        final offset = layoutChild(
          child,
          childConstraints,
          lastChildWithScrollOffset: lastChildWithScrollOffset,
        );

        if (offset == null) {
          // Could not determine scroll offset, treat as leading garbage.
          ++leadingGarbage;
        } else {
          lastChildWithScrollOffset = child;
          final endOffset = offset + paintExtentOf(child);
          if (offset > startOffset + remainingExtent) {
            ++trailingGarbage;
          } else if (endOffset < startOffset) {
            ++leadingGarbage;
          }
        }
      }
      previousChild = child;
      ++index;
    }

    if (leadingGarbage > 0 || trailingGarbage > 0) {
      layoutState.didRemoveChildren |= true;
      _log.finer(
        "Garbage collection: $leadingGarbage leading, $trailingGarbage trailing",
      );
    }
    collectGarbage(leadingGarbage, trailingGarbage);

    var didDelayPopulatingCacheArea = false;

    if (firstChild == null) {
      layoutState.didAddInitialChild |= true;
      final int firstChildInCacheAreaIndex =
          indexForOffset(startOffset) ?? totalChildCount;
      if (_childScrollOffsetEstimation == null &&
          (firstChildInCacheAreaIndex >= totalChildCount ||
              constraints.remainingCacheExtent == 0)) {
        // The user either did not reach this sliver or scrolled past it.
        final extentBefore = _totalExtent();
        final stopwatch = Stopwatch()..start();
        if (_extentManager.hasDirtyItems &&
            _shouldPrecalculateExtents(layoutPass)) {
          if (_shouldSkipExtentPrecalculationForInvisibleList(layoutPass)) {
            _log.finer(
              "Want to precalculate extents but there is visibile that has higher priority.",
            );
            _markNeedsLayoutDelayed(layoutPass);
          } else if (layoutPass.correctionCount > 3) {
            _log.finer(
              "Want to precalculate extents but correction count is too high "
              "high (${layoutPass.correctionCount}). Scheduling layout pass.",
            );
            _markNeedsLayoutDelayed(layoutPass);
          } else {
            _calculatePendingLayout(
              layoutPass: layoutPass,
              allowScrollOffsetCorrection: true,
              precalculateExtents: true,
            );
          }
        }
        _layoutKeptAliveChildren();
        final extentDelta = _totalExtent() - extentBefore;
        if (stopwatch.elapsed > const Duration(microseconds: 50) ||
            extentDelta.abs() > precisionErrorTolerance) {
          _log.finer(
            "Spent ${stopwatch.elapsed} calculating layout info (extent delta: ${extentDelta.format()}).",
          );
        }
        if (extentDelta.abs() > precisionErrorTolerance &&
            constraints.remainingPaintExtent > 0) {
          ++layoutPass.correctionCount;
          _log.fine("Scroll offset correction: ${extentDelta.format()} "
              "(reason: async layout of scrolled-away slivers, correction count ${layoutPass.correctionCount})");
          geometry = SliverGeometry(scrollOffsetCorrection: extentDelta);
          childManager.didFinishLayout();
          return;
        }
        if (constraints.remainingCacheExtent == 0) {
          _log.finer(
            "Did not reach this sliver, reporting extent ${_totalExtent().format()} "
            "(has dirty items: ${_extentManager.hasDirtyItems})",
          );
        } else {
          _log.finer(
            "Scrolled past this sliver, reporting extent ${_totalExtent().format()} "
            "(has dirty items: ${_extentManager.hasDirtyItems})",
          );
        }
        // This would be normally done by addInitialChild, but layout terminates
        // before that.
        if (totalChildCount == 0) {
          childManager.setDidUnderflow(true);
        }
        geometry = SliverGeometry(
          paintExtent: 0,
          maxPaintExtent: _totalExtent(),
          scrollExtent: _totalExtent(),
        );
        childManager.didFinishLayout();
        return;
      }

      // Put first child at the scroll offset, not the beginning of cache area
      final firstChildScrollOffset = constraints.scrollOffset;
      final firstChildIndex = anchoredAtEnd
          ? totalChildCount - 1
          : indexForOffset(firstChildScrollOffset) ?? totalChildCount - 1;

      _log.fine("Adding initial child with index $firstChildIndex");

      if (!addInitialChild(
        index: firstChildIndex,
        layoutOffset: offsetForIndex(firstChildIndex),
      )) {
        return _zeroGeometry();
      }

      final reducedStartOffset = constraints.scrollOffset;
      final reducedRemainingExtent = constraints.remainingPaintExtent;

      // If children were removed during this pass and new children are added
      // from empty assume fast scrolling, in which case only the visible area
      // is populated (ignoring cache area) and then in next layout pass the
      // cache area is populated.
      if (delayPopulatingCacheArea &&
          layoutState.didRemoveChildren &&
          (startOffset != reducedStartOffset ||
              remainingExtent != reducedRemainingExtent)) {
        startOffset = reducedStartOffset;
        remainingExtent = reducedRemainingExtent;
        didDelayPopulatingCacheArea = true;
        _markNeedsLayoutDelayed(layoutPass);
      }
    }

    firstChild!.layout(childConstraints, parentUsesSize: true);
    _extentManager.setExtent(indexOf(firstChild!), paintExtentOf(firstChild!));

    // At this point there is at least one child.
    // First we need to create children before current child all the way to the
    // beginning of cached area

    double scrollCorrection = 0; // Accumulated scroll offset correction.

    // When cross axis is resized, try preserving the first visible leading edge of
    // a child.
    if (crossAxisResizing &&
        !anchoredAtEnd &&
        firstVisible != null &&
        firstVisible.parent == this) {
      scrollCorrection =
          childScrollOffset(firstVisible)! - firstVisibleLayoutOffset!;
    }

    // Start offset with applied scroll correction.
    var correctedStartOffset = startOffset + scrollCorrection;

    // Adding preceding children.
    while ((indexOf(firstChild!) > 0 &&
            childScrollOffset(firstChild!)! > correctedStartOffset) ||
        (_childScrollOffsetEstimation != null &&
            indexOf(firstChild!) > _childScrollOffsetEstimation!.index)) {
      final prevOffset = childScrollOffset(firstChild!)!;
      final previousExtent = _extentManager.getExtent(indexOf(firstChild!) - 1);
      final box =
          insertAndLayoutLeadingChild(childConstraints, parentUsesSize: true);
      if (box == null) {
        break;
      }
      final data = box.parentData! as SliverMultiBoxAdaptorParentData;
      data.layoutOffset = prevOffset - previousExtent;
      final correction = paintExtentOf(box) - previousExtent;
      _log.finest(
        "Adding preceding child with index ${indexOf(box)} "
        "extent: ${paintExtentOf(box)} "
        "(${correction.format()} correction)",
      );
      _shiftLayoutOffsets(childAfter(box), correction);
      // Do not correct when anchored at end and started from nothing.
      // And only correct when there are no other slivers visible.
      if ((!anchoredAtEnd || !layoutState.didAddInitialChild) &&
          constraints.remainingPaintExtent ==
              constraints.viewportMainAxisExtent) {
        scrollCorrection += correction;
      }

      // If start offset is 0, we must end up at initial item, so do not correct the
      // start offset.
      // If start offset > 0 we care about filling up the cache area, so correct the
      // offset depending on the extent of the child. TODO(knopp): It might be enough
      // to just ensure that we have a single completely hidden child in the cache
      // area. See https://github.com/flutter/flutter/issues/128601
      if (startOffset > 0) {
        correctedStartOffset += correction;
      }
    }

    // Additional correction: first child is not at the very beginning
    if (indexOf(firstChild!) == 0 && childScrollOffset(firstChild!)! != 0) {
      final correction = -childScrollOffset(firstChild!)!;
      _shiftLayoutOffsets(firstChild, correction);
      scrollCorrection += correction;
    }

    bool addTrailingChild() {
      final lastChildIndex = indexOf(lastChild!);
      if (lastChildIndex >= totalChildCount - 1) {
        return false;
      }

      if (childScrollOffset(lastChild!)! + paintExtentOf(lastChild!) >=
          startOffset + remainingExtent) {
        // If there is child scroll offset estimation active produce as many children
        // as necessary. These will be removed after correcting scroll offset during
        // garbage collection.
        if (_childScrollOffsetEstimation != null &&
            _childScrollOffsetEstimation!.index < lastChildIndex) {
          return false;
        }
        if (layoutPass.childScrollOffsetEstimation == false) {
          return false;
        }
        if (_childScrollOffsetEstimation == null &&
            !layoutPass.sliverIsBeforeSliverWithOffsetEstimation(this)) {
          return false;
        }
      }

      final newLayoutOffset =
          childScrollOffset(lastChild!)! + paintExtentOf(lastChild!);

      final box = insertAndLayoutChild(childConstraints,
          after: lastChild, parentUsesSize: true);
      if (box == null) {
        return false;
      }
      _extentManager.setExtent(indexOf(box), paintExtentOf(box));
      final data = box.parentData! as SliverMultiBoxAdaptorParentData;
      data.layoutOffset = newLayoutOffset;
      return true;
    }

    // Add remaining children to fill the cache area.
    while (addTrailingChild()) {}

    // Assume this is viewport trying to reveal particular child that was out of
    // cache area originally. We provided estimated offset for the child, but
    // the actual one might be different. If that's the case, correct the
    // position now.
    final estimation = _childScrollOffsetEstimation;
    if (estimation != null) {
      for (var c = firstChild; c != null; c = childAfter(c)) {
        if (estimation.index == indexOf(c)) {
          _childScrollOffsetEstimation = null;
          final childScrollOffset = this.childScrollOffset(c)!;

          var correction = childScrollOffset - estimation.offset;
          correction += constraints.precedingScrollExtent -
              estimation.precedingScrollExtent;

          final currentScrollPosition = getViewport()?.offset.pixels ?? 0.0;
          correction +=
              layoutPass.initialScrollPosition - currentScrollPosition;

          if (!estimation.revealingRect) {
            final childAlignmentWithinViewport = estimation.alignment;

            // Depending on child alignment within viewport the scroll offset correction
            // needs to account for extent difference. When child is aligned at the start
            // of viewport, the correction is 0. When child is aligned at the end of viewport,
            // the correction is equal to extent difference.
            final extentDifference = paintExtentOf(c) - estimation.extent;
            correction += extentDifference * childAlignmentWithinViewport;

            // Obstruction extent on this sliver might have been outdated during the estimation
            // so account of the difference.
            final obstructionExtentDifference =
                c.getParentChildObstructionExtent() -
                    estimation.childObstructionExtent;
            correction -= obstructionExtentDifference.leading *
                (1.0 - childAlignmentWithinViewport);
            correction += obstructionExtentDifference.trailing *
                childAlignmentWithinViewport;
          }

          final position = getViewport()!.offset as ScrollPosition;

          // Max scroll extent with applied corrections for this layout pass.
          final maxScrollExtent = position.maxScrollExtent -
              initialExtent +
              _totalExtent() +
              constraints.precedingScrollExtent -
              estimation.precedingScrollExtent;

          // Try to prevent overscroll.
          final target = position.pixels + correction;
          if (target < 0) {
            correction -= target;
          } else if (target > maxScrollExtent) {
            correction -= target - maxScrollExtent;
          }

          if (correction.abs() > precisionErrorTolerance) {
            _log.fine("Scroll offset correction: ${correction.format()} "
                "(reason: jumping to estimated offset, index ${estimation.index})");

            geometry = SliverGeometry(scrollOffsetCorrection: correction);
            childManager.didFinishLayout();
            return;
          } else {
            // When jumping to item ignore cache area scroll correction.
            scrollCorrection = 0;
          }
        }
      }
    }

    // When extent changes during resizing while anchored at the end, keep the
    // trailing edge in place. Also when anchored at the end while adding initial
    // child. Note that it may take multiple layout tries to reach the final layout
    // so didAddInitialChild must be tracked through entire layout pass.
    if (anchoredAtEnd &&
        (crossAxisResizing || layoutState.didAddInitialChild) &&
        _totalExtent() != initialExtent) {
      _log.fine(
          "Adjusting correction for extent change by ${_totalExtent() - initialExtent}");
      scrollCorrection += _totalExtent() - initialExtent;
    }

    if (scrollCorrection.abs() > precisionErrorTolerance) {
      _log.fine("Scroll offset correction: ${scrollCorrection.format()} "
          "(reason: accumulated while laying out cache area)");
      ++layoutPass.correctionCount;
      geometry = SliverGeometry(scrollOffsetCorrection: scrollCorrection);
      childManager.didFinishLayout();
      return;
    }

    var correction = _calculatePendingLayout(
      layoutPass: layoutPass,
      allowScrollOffsetCorrection: layoutPass.correctionCount < 3,
      precalculateExtents: _shouldPrecalculateExtents(layoutPass),
    );
    final keptAliveCorrection = _layoutKeptAliveChildren();
    if (keptAliveCorrection != 0) {
      _log.finer(
          "Correction due to kept alive children: ${keptAliveCorrection.format()}");
      correction += keptAliveCorrection;
    }

    if (correction.abs() > precisionErrorTolerance) {
      ++layoutPass.correctionCount;
      _shiftLayoutOffsets(firstChild, correction);
      _log.fine("Scroll offset correction: ${correction.format()} "
          "(reason: layout correction of invisible items or kept alive children)");
      geometry = SliverGeometry(scrollOffsetCorrection: correction);
      childManager.didFinishLayout();
      return;
    }

    final endScrollOffset = _totalExtent();
    final cacheStart = constraints.scrollOffset + constraints.cacheOrigin;
    final lastChildEnd =
        childScrollOffset(lastChild!)! + paintExtentOf(lastChild!);
    var cacheConsumed = (lastChildEnd - cacheStart)
        .clamp(0.0, constraints.remainingCacheExtent);
    var paintExtent = calculatePaintOffset(constraints,
        from: childScrollOffset(firstChild!)!, to: endScrollOffset);

    // If remaining paint extent is consumed, make sure to use the *exact* value.
    // Otherwise, even if the delta is extremely small, Flutter will consider
    // next sliver visible, which means that our layoutOffset will be used
    // determine paint position of render boxes inside next sliver (even if
    // invisible these affects directional focus for example). That leads
    // to incorrect results if we're in the middle of sliver.
    if ((constraints.remainingPaintExtent - paintExtent).abs() <
        precisionErrorTolerance) {
      paintExtent = constraints.remainingPaintExtent;
    }

    if (paintExtent == constraints.remainingPaintExtent &&
        didDelayPopulatingCacheArea) {
      cacheConsumed = constraints.remainingCacheExtent;
    }

    _updateVisibleChildren(paintExtent: paintExtent);

    geometry = SliverGeometry(
      scrollExtent: endScrollOffset,
      paintExtent: paintExtent,
      maxPaintExtent: endScrollOffset,
      cacheExtent: cacheConsumed,
      hasVisualOverflow: endScrollOffset > constraints.remainingPaintExtent ||
          constraints.scrollOffset > 0.0,
    );
    _log.fine(
      "Have geometry for $_logIdentifier (scroll extent: $endScrollOffset, paint extent: $paintExtent, cache consumed: $cacheConsumed, dirty extents: ${_extentManager.hasDirtyItems})",
    );

    if (paintExtent < constraints.remainingPaintExtent) {
      childManager.setDidUnderflow(true);
    }

    childManager.didFinishLayout();
  }

  RenderBox? _firstWholeVisibleChild() {
    RenderBox? child = firstChild;
    while (child != null) {
      final data = child.parentData! as SliverMultiBoxAdaptorParentData;
      if ((data.layoutOffset ?? double.negativeInfinity) >=
          constraints.scrollOffset) {
        return child;
      }
      child = childAfter(child);
    }
    return null;
  }

  void _updateVisibleChildren({required double paintExtent}) {
    if (paintExtent == 0) {
      return;
    }

    final minStart = constraints.scrollOffset;
    final maxStart = minStart + paintExtent;

    final unobstructedMinStart = minStart + constraints.overlap;
    final unobstructedMaxStart = maxStart;

    int min = -1;
    int max = -1;
    int unobstructedMin = -1;
    int unobstructedMax = -1;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final data = child.parentData! as SliverMultiBoxAdaptorParentData;
      final start = data.layoutOffset!;
      final end = start + paintExtentOf(child);
      final index = indexOf(child);
      if (end > minStart && min == -1) {
        min = index;
        max = index;
      } else if (start < maxStart) {
        max = index;
      }
      if (end > unobstructedMinStart && unobstructedMin == -1) {
        unobstructedMin = index;
        unobstructedMax = index;
      } else if (start < unobstructedMaxStart) {
        unobstructedMax = index;
      }
    }
    if (min != -1) {
      assert(max != -1);
      _extentManager.reportVisibleChildren((min, max));
    }

    if (unobstructedMin != -1) {
      assert(unobstructedMax != -1);
      _extentManager.reportUnobstructedVisibleChildren(
          (unobstructedMin, unobstructedMax));
    }
  }

  void _zeroGeometry() {
    geometry = SliverGeometry.zero;
    childManager.didFinishLayout();
  }

  int? indexForOffset(double offset) {
    return _extentManager.indexForOffset(offset);
  }

  double offsetForIndex(int index) {
    return _extentManager.offsetForIndex(index);
  }

  double _totalExtent() {
    return _extentManager.totalExtent;
  }

  @override
  @protected
  RenderBox? insertAndLayoutLeadingChild(
    BoxConstraints childConstraints, {
    bool parentUsesSize = false,
  }) {
    final res = super.insertAndLayoutLeadingChild(
      childConstraints,
      parentUsesSize: parentUsesSize,
    );
    if (res != null) {
      _extentManager.setExtent(indexOf(res), paintExtentOf(res));
    }
    return res;
  }

  double getOffsetToReveal(
    int index,
    double alignment, {
    required bool estimationOnly,
    Rect? rect,
  }) {
    final renderObject = _FakeRenderObject(
      parent: this,
      index: index,
      extent: _extentManager.getExtent(index),
    );
    final viewport = getViewport()!;
    return viewport
        .getOffsetToRevealExt(
          renderObject,
          alignment,
          esimationOnly: estimationOnly,
          rect: rect,
        )
        .offset;
  }

  @override
  void valueDidChange() {
    markNeedsLayout();
  }

  @override
  void applyPaintTransform(covariant RenderBox child, Matrix4 transform) {
    // We actually lay out kept alive children, and as such we can provide valid
    // paint transform.
    final parentData = child.parentData! as SliverMultiBoxAdaptorParentData;
    if (layoutKeptAliveChildren &&
        parentData.keptAlive &&
        parentData.layoutOffset != null) {
      applyPaintTransformForBoxChild(child, transform);
    } else {
      super.applyPaintTransform(child, transform);
    }
  }
}

// This is little bit hacky way to reuse logic of RenderViewport.getOffsetToReveal in case
// where we don't really have a render object.
class _FakeRenderObject extends RenderBox {
  @override
  final RenderObject parent;
  final double extent;

  _FakeRenderObject({
    required this.parent,
    required int index,
    required this.extent,
  }) {
    parentData = SliverMultiBoxAdaptorParentData()..index = index;
  }

  @override
  Size get size => Size(extent, extent);

  @override
  Matrix4 getTransformTo(RenderObject? ancestor) {
    return Matrix4.identity();
  }
}

extension on double {
  String format() {
    final res = toStringAsFixed(5);
    var len = res.length;
    while (len > 1 && res[len - 1] == "0") {
      --len;
    }
    if (len > 1 && res[len - 1] == ".") {
      ++len; // leave one zero
    }
    return res.substring(0, len);
  }
}
