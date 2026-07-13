import "dart:typed_data";

/// Zero indexed Fenwick Tree
class FenwickTree {
  FenwickTree({
    required this.size,
  }) : _tree = Float64List(size + 1);

  FenwickTree.fromList({
    required Float64List list,
  })  : size = list.length,
        _tree = Float64List(list.length + 1) {
    for (int i = 1; i <= size; ++i) {
      _tree[i] += list[i - 1];
      if (i + (i & -i) <= size) {
        _tree[i + (i & -i)] += _tree[i];
      }
    }
  }

  final int size;
  final Float64List _tree;

  /// Update the value at index with delta. Index is 0 based.
  void update(int index, double delta) {
    ++index;
    while (index <= size) {
      _tree[index] += delta;
      index += index & -index;
    }
  }

  /// Returns the prefix sum of the elements from 0 to index-1. Index is 0 based.
  double query(int index) {
    double result = 0.0;
    while (index > 0) {
      result += _tree[index];
      index -= index & -index;
    }
    return result;
  }

  // Returns the index of last element whose prefix sum is less than or equal to prefixSum.
  int inverseQuery(double prefixSum) {
    var index = 0;
    var bitmask = 1 << size.bitLength - 1;
    while (bitmask != 0 && index < size) {
      final nextIndex = index + bitmask;
      if (nextIndex <= size && _tree[nextIndex] <= prefixSum) {
        index = nextIndex;
        prefixSum -= _tree[index];
      }
      bitmask >>= 1;
    }
    return index;
  }
}
