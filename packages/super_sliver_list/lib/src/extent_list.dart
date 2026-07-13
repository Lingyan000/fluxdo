import "package:collection/collection.dart";
import "package:flutter/foundation.dart";

import "fenwick_tree.dart";

class ResizableFloat64List {
  static const _minCapacity = 16;

  @pragma("vm:prefer-inline")
  double operator [](int index) {
    assert(index >= 0 && index < _length);
    return _list[index];
  }

  @pragma("vm:prefer-inline")
  void operator []=(int index, double value) {
    assert(index >= 0 && index < _length);
    _list[index] = value;
  }

  void resize(int newSize, double Function(int index) defaultElement) {
    assert(newSize >= 0);
    if (newSize == _length) {
      return;
    }
    _ensureCapacity(newSize);
    for (var i = _length; i < newSize; ++i) {
      _list[i] = defaultElement(i);
    }
    _length = newSize;
    _maybeTrim();
  }

  void resizeWithDefault(int newSize, double defaultValue) {
    assert(newSize >= 0);
    if (newSize == _length) {
      return;
    }
    _ensureCapacity(newSize);
    final list = _list;
    for (var i = _length; i < newSize; ++i) {
      list[i] = defaultValue;
    }
    _length = newSize;
    _maybeTrim();
  }

  void insert(int index, double element) {
    _ensureCapacity(_length + 1);
    if (index < _length) {
      _list.setRange(index + 1, _length + 1, _list, index);
    }
    _list[index] = element;
    ++_length;
  }

  void removeAt(int index) {
    assert(index >= 0 && index < _length);
    _list.setRange(index, _length - 1, _list, index + 1);
    --_length;
    _maybeTrim();
  }

  void _maybeTrim() {
    var newCapacity = _capacity;
    while (newCapacity > _minCapacity && newCapacity ~/ 2 >= _length) {
      newCapacity ~/= 2;
    }
    _reallocate(newCapacity);
  }

  void _ensureCapacity(int newCapacity) {
    var capacity = _capacity;
    while (capacity < newCapacity) {
      capacity *= 2;
    }
    _reallocate(capacity);
  }

  void _reallocate(int newCapacity) {
    assert(_length <= newCapacity);
    if (_capacity == newCapacity) {
      return;
    }

    final previous = _list;
    _list = Float64List(newCapacity);
    _list.setRange(0, _length, previous);
  }

  bool get isEmpty => _length == 0;

  int get length => _length;

  int get _capacity => _list.length;
  int _length = 0;

  var _list = Float64List(_minCapacity);
}

/// Maintains a list of extents for multi-box adapter widget.
class ExtentList {
  final _extents = ResizableFloat64List();
  final _dirty = BoolList.empty(growable: true);
  int _dirtyCount = 0;

  double get _totalExtent => __totalExtent;
  set _totalExtent(double value) {
    __totalExtent = value;
    // Floating point is not associative, we need to make sure that we don't
    // end up with a negative total extent.
    if (__totalExtent.abs() < precisionErrorTolerance) {
      __totalExtent = 0.0;
    }
  }

  double __totalExtent = 0.0;

  int? _cleanRangeStart;
  int? _cleanRangeEnd;

  // Cached FenwickTree for fast offsetForIndex and indexForOffset. This is
  // created on demand and invalidated when the extent list length changes. The
  // assumption is that modifications to individual extents (which can be
  // reflected in the FenwickTree) are more frequent than changes to the length
  // of the list (which require rebuilding the FenwickTree next time
  // offsetForIndex or indexForOffset is called).
  FenwickTree? _fenwickTree;

  void setExtent(int index, double extent, {bool isEstimation = false}) {
    assert(_extents.length == _dirty.length);
    assert(index >= 0 && index < _extents.length && index < _dirty.length);

    if (!isEstimation) {
      if (_dirty[index]) {
        --_dirtyCount;
      }
      _dirty[index] = false;

      _cleanRangeStart = index;
      _cleanRangeEnd = index;
    }

    final delta = extent - _extents[index];
    _extents[index] = extent;
    _totalExtent += delta;
    _fenwickTree?.update(index, delta);
  }

  /// Returns index of first item in range of items with valid extents.
  int? get cleanRangeStart {
    while (_cleanRangeStart != null &&
        _cleanRangeStart! > 0 &&
        !_dirty[_cleanRangeStart! - 1]) {
      _cleanRangeStart = _cleanRangeStart! - 1;
    }
    assert(_cleanRangeStart == null || _dirty[_cleanRangeStart!] == false);
    return _cleanRangeStart;
  }

  /// Returns index of last item in range of items with valid extents.
  int? get cleanRangeEnd {
    while (_cleanRangeEnd != null &&
        _cleanRangeEnd! < _dirty.length - 1 &&
        !_dirty[_cleanRangeEnd! + 1]) {
      _cleanRangeEnd = _cleanRangeEnd! + 1;
    }
    assert(_cleanRangeEnd == null || _dirty[_cleanRangeEnd!] == false);
    return _cleanRangeEnd;
  }

  int get length => _extents.length;

  @pragma("vm:prefer-inline")
  double operator [](int index) {
    assert(_extents.length == _dirty.length);
    assert(index >= 0 && index < _extents.length);
    return _extents[index];
  }

  @pragma("vm:prefer-inline")
  bool isDirty(int index) {
    assert(_extents.length == _dirty.length);
    assert(index >= 0 && index < _extents.length);
    return _dirty[index];
  }

  double get totalExtent => _totalExtent;

  bool get hasDirtyItems => _dirtyCount > 0;

  void markAllDirty() {
    assert(_extents.length == _dirty.length);
    if (_extents.isEmpty) {
      return;
    }
    _dirty.fillRange(0, _dirty.length, true);
    _dirtyCount = _dirty.length;
    _cleanRangeStart = null;
    _cleanRangeEnd = null;
  }

  void markDirty(int index) {
    assert(_extents.length == _dirty.length);
    assert(index >= 0 && index < _extents.length);
    // This could be optimized to preserve part of clean range.
    if (!_dirty[index]) {
      _dirty[index] = true;
      ++_dirtyCount;
      _cleanRangeStart = null;
      _cleanRangeEnd = null;
    }
  }

  void removeAt(int index) {
    assert(index >= 0 && index < _extents.length);
    _totalExtent -= _extents[index];
    _extents.removeAt(index);
    if (_dirty[index]) {
      --_dirtyCount;
    }
    _dirty.removeAt(index);
    _cleanRangeStart = null;
    _cleanRangeEnd = null;
    _fenwickTree = null;
  }

  void insertAt(int index, double Function(int index) defaultExtent) {
    assert(index >= 0 && index <= _extents.length);
    final extent = defaultExtent(index);
    _extents.insert(index, extent);
    _totalExtent += extent;
    _dirty.insert(index, true);
    ++_dirtyCount;
    _cleanRangeStart = null;
    _cleanRangeEnd = null;
    _fenwickTree = null;
  }

  void resize(int newSize, double Function(int? index) defaultExtent) {
    assert(_extents.length == _dirty.length);
    final prevSize = _extents.length;
    final prevExtents = _extents;

    if (newSize < prevSize) {
      if (prevSize - newSize < newSize) {
        for (var i = newSize; i < prevSize; ++i) {
          _totalExtent -= prevExtents[i];
          _dirtyCount -= _dirty[i] ? 1 : 0;
        }
      } else {
        // In this case it's less work to count the extent and dirty items
        // from scratch.
        _totalExtent = 0;
        _dirtyCount = 0;
        for (var i = 0; i < newSize; ++i) {
          _totalExtent += _extents[i];
          _dirtyCount += _dirty[i] ? 1 : 0;
        }
      }
    }

    double addedDefaultExtent = 0.0;
    final sameExtent = defaultExtent(null);
    if (sameExtent > 0) {
      _extents.resizeWithDefault(newSize, sameExtent);
      if (newSize > prevSize) {
        addedDefaultExtent = (newSize - prevSize) * sameExtent;
      }
    } else {
      _extents.resize(newSize, (index) {
        final extent = defaultExtent(index);
        addedDefaultExtent += extent;
        return extent;
      });
    }

    _dirty.length = newSize;

    if (newSize > prevSize) {
      _dirty.fillRange(prevSize, newSize, true);
      _dirtyCount += newSize - prevSize;
      _totalExtent += addedDefaultExtent;
    }

    if (_cleanRangeStart != null && _cleanRangeStart! >= newSize) {
      _cleanRangeStart = null;
      _cleanRangeEnd = null;
    }
    if (_cleanRangeEnd != null && _cleanRangeEnd! >= newSize) {
      _cleanRangeEnd = newSize - 1;
    }
    _fenwickTree = null;
  }

  FenwickTree _getOrBuildFenwickTree() {
    _fenwickTree ??= FenwickTree.fromList(list: _extents._list);
    return _fenwickTree!;
  }

  double offsetForIndex(int index) {
    final tree = _getOrBuildFenwickTree();
    return tree.query(index);
  }

  int? indexForOffset(double offset) {
    if (offset >= _totalExtent) {
      return null;
    }
    final tree = _getOrBuildFenwickTree();
    return tree.inverseQuery(offset);
  }

  /// Returns number of estimated extents.
  int get dirtyItemCount => _dirtyCount;
}
