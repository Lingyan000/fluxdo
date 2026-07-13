import "package:collection/collection.dart";
import "package:flutter/rendering.dart";

import "render_object.dart";

class SliverLayoutState {
  bool didAddInitialChild = false;
  bool didRemoveChildren = false;
  bool didSetPreviousConstraint = false;
  bool? precalculateExtents;
}

class LayoutPass {
  LayoutPass({
    required this.slivers,
    required this.initialScrollPosition,
    required this.childScrollOffsetEstimation,
    required this.sliverWithOffsetEstimation,
  });

  bool isNew = true;

  final List<RenderSuperSliverList> slivers;
  final double initialScrollPosition;
  final bool childScrollOffsetEstimation;
  final RenderSuperSliverList? sliverWithOffsetEstimation;

  final sliversDuringLayout = <RenderSuperSliverList>[];

  /// Returns whether provided sliver is laid out before a sliver with active
  /// scroll offset estimation. If there is no sliver with active scroll offset
  /// estimation, returns false.
  bool sliverIsBeforeSliverWithOffsetEstimation(RenderSuperSliverList s) {
    assert(sliversDuringLayout.contains(s));
    if (sliverWithOffsetEstimation == null) {
      return false;
    }
    final index = sliversDuringLayout.indexOf(sliverWithOffsetEstimation!);
    return index == -1 // not reached yet
        ||
        index > sliversDuringLayout.indexOf(s);
  }

  SliverLayoutState getLayoutState(RenderSuperSliverList sliver) {
    return _sliverLayoutState.putIfAbsent(sliver, () => SliverLayoutState());
  }

  final _sliverLayoutState = <RenderSuperSliverList, SliverLayoutState>{};

  int correctionCount = 0;
}

final _viewportToLayoutPass = Expando<LayoutPass>();

extension RenderSliverLayoutPass on RenderSliver {
  RenderViewportBase? getViewport() {
    RenderObject? parent = this.parent;
    while (parent != null) {
      if (parent is RenderViewportBase) {
        return parent;
      }
      parent = parent.parent;
    }
    return null;
  }

  static void _gatherSliverList(
    List<RenderSuperSliverList> slivers,
    RenderObject sliver,
  ) {
    if (sliver is RenderSuperSliverList) {
      slivers.add(sliver);
    } else {
      sliver.visitChildren((child) {
        if (child is RenderSliver) {
          _gatherSliverList(slivers, child);
        }
      });
    }
  }

  List<RenderSuperSliverList> getSuperSliverLists() {
    final slivers = <RenderSuperSliverList>[];
    final viewport = getViewport();
    if (viewport != null) {
      _gatherSliverList(slivers, viewport);
    }
    return slivers;
  }

  LayoutPass? getLayoutPass(RenderSuperSliverList self) {
    final viewport = getViewport();
    if (viewport == null) {
      return null;
    }
    var pass = _viewportToLayoutPass[viewport];
    if (pass == null) {
      final slivers = getSuperSliverLists();
      var sliverWithOffsetEstimation = slivers.firstWhereOrNull(
          (element) => element.hasChildScrollOffsetEstimation);
      if (sliverWithOffsetEstimation != null) {
        sliverWithOffsetEstimation
            .sanitizeChildScrollOffsetEstimation(viewport);
        if (!sliverWithOffsetEstimation.hasChildScrollOffsetEstimation) {
          sliverWithOffsetEstimation = null;
        }
      }
      pass = LayoutPass(
        slivers: slivers,
        // Note: This only works if there are no other sliver being laid out
        // first that do scroll offset correction. Unfortunately there isn't any
        // way in Flutter to get the original (uncorrected) scroll position.
        initialScrollPosition: viewport.offset.pixels,
        childScrollOffsetEstimation: sliverWithOffsetEstimation != null,
        sliverWithOffsetEstimation: sliverWithOffsetEstimation,
      );
      _viewportToLayoutPass[viewport] = pass;
      Future.microtask(() {
        _viewportToLayoutPass[viewport] = null;
      });
    }
    if (!pass.sliversDuringLayout.contains(self)) {
      pass.sliversDuringLayout.add(self);
    }
    return pass;
  }
}
