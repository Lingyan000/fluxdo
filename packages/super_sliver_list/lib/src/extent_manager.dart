import "dart:ui";

import "package:flutter/foundation.dart";

import "extent_list.dart";

abstract class ExtentManagerDelegate {
  const ExtentManagerDelegate();

  void onMarkNeedsLayout();
  double estimateExtentForItem(int? index);
  double getOffsetToReveal(
    int index,
    double alignment, {
    required bool estimationOnly,
    Rect? rect,
  });
}

class ExtentManager with ChangeNotifier {
  ExtentManager({required this.delegate});

  double _beforeCorrection = 0.0;
  double _afterCorrection = 0.0;

  final ExtentManagerDelegate delegate;

  double get correctionPercentage => _afterCorrection / _beforeCorrection;

  void setExtent(int index, double extent, {bool isEstimation = false}) {
    if (!isEstimation) {
      _beforeCorrection += _extentList[index];
      _afterCorrection += extent;
    }
    _extentList.setExtent(index, extent, isEstimation: isEstimation);
    _isModified = true;
  }

  void markAllDirty() {
    _afterCorrection = 0.0;
    _beforeCorrection = 0.0;
    _isModified = true;
    _extentList.markAllDirty();
  }

  bool get hasDirtyItems => _extentList.hasDirtyItems;

  double get totalExtent => _extentList.totalExtent;

  int? get cleanRangeStart => _extentList.cleanRangeStart;
  int? get cleanRangeEnd => _extentList.cleanRangeEnd;

  @pragma("vm:prefer-inline")
  double getExtent(int index) => _extentList[index];

  void resize(
    int newSize,
  ) {
    if (newSize == _extentList.length) {
      return;
    }
    _isModified = true;
    _extentList.resize(newSize, delegate.estimateExtentForItem);
  }

  final _extentList = ExtentList();

  int? indexForOffset(double offset) {
    return _extentList.indexForOffset(offset);
  }

  double offsetForIndex(int index) {
    assert(index >= 0 && index < _extentList.length);
    return _extentList.offsetForIndex(index);
  }

  (double, bool) extentForIndex(int index) {
    return (_extentList[index], _extentList.isDirty(index));
  }

  bool _layoutInProgress = false;
  bool _isModified = false;

  bool _didReportVisibleChildren = false;
  bool _didReportUnobstructedVisibleChildren = false;

  void performLayout(VoidCallback layout) {
    assert(!_layoutInProgress);
    _layoutInProgress = true;
    _isModified = false;
    _didReportVisibleChildren = false;
    _didReportUnobstructedVisibleChildren = false;
    _beforeCorrection = 0.0;
    _afterCorrection = 0.0;

    try {
      layout();
    } finally {
      assert(_layoutInProgress);
      // Not reporting children means there are no visible children - set the
      // visible range to null.
      if (!_didReportVisibleChildren) {
        reportVisibleChildren(null);
      }
      if (!_didReportUnobstructedVisibleChildren) {
        reportUnobstructedVisibleChildren(null);
      }
      _layoutInProgress = false;
      if (_isModified) {
        notifyListeners();
      }
    }
  }

  void reportVisibleChildren((int, int)? range) {
    assert(_layoutInProgress);
    if (_visibleRange != range) {
      _visibleRange = range;
      _isModified = true;
    }
    _didReportVisibleChildren = true;
  }

  void reportUnobstructedVisibleChildren((int, int)? range) {
    assert(_layoutInProgress);
    if (_unobstructedVisibleRange != range) {
      _unobstructedVisibleRange = range;
      _isModified = true;
    }
    _didReportUnobstructedVisibleChildren = true;
  }

  (int, int)? get visibleRange => _visibleRange;
  (int, int)? _visibleRange;

  (int, int)? get unobstructedVisibleRange => _unobstructedVisibleRange;
  (int, int)? _unobstructedVisibleRange;

  int get numberOfItems => _extentList.length;

  int get numberOfItemsWithEstimatedExtent => _extentList.dirtyItemCount;

  void addItem(int index) {
    _extentList.insertAt(index, delegate.estimateExtentForItem);
    delegate.onMarkNeedsLayout();
  }

  void removeItem(int index) {
    _extentList.removeAt(index);
    delegate.onMarkNeedsLayout();
  }

  void invalidateExtent(int index) {
    _extentList.markDirty(index);
    delegate.onMarkNeedsLayout();
  }

  void invalidateAllExtents() {
    _extentList.markAllDirty();
    delegate.onMarkNeedsLayout();
  }

  bool get isLocked => _layoutInProgress;

  double getOffsetToReveal(
    int index,
    double alignment, {
    Rect? rect,
    required bool estimationOnly,
  }) {
    return delegate.getOffsetToReveal(
      index,
      alignment,
      rect: rect,
      estimationOnly: estimationOnly,
    );
  }

  @override
  String toString() {
    return "ExtentManager ${identityHashCode(this).toRadixString(16)}";
  }
}
