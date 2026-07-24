import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

enum LoadState {
  /// loading
  loading,

  /// completed
  completed,

  /// failed
  failed,
}

///get type from T
Type typeOf<T>() => T;

double clampScale(double scale, double min, double max) {
  return scale.clamp(min, max);
}

extension DoubleExtension on double {
  bool get isZero => abs() < precisionErrorTolerance;
  int compare(double other, {double precision = precisionErrorTolerance}) {
    if (isNaN || other.isNaN) {
      throw UnsupportedError('Compared with Infinity or NaN');
    }
    final double n = this - other;
    if (n.abs() < precision) {
      return 0;
    }
    return n < 0 ? -1 : 1;
  }

  bool greaterThan(double other, {double precision = precisionErrorTolerance}) {
    return compare(other, precision: precision) > 0;
  }

  bool lessThan(double other, {double precision = precisionErrorTolerance}) {
    return compare(other, precision: precision) < 0;
  }

  bool equalTo(double other, {double precision = precisionErrorTolerance}) {
    return compare(other, precision: precision) == 0;
  }

  bool greaterThanOrEqualTo(
    double other, {
    double precision = precisionErrorTolerance,
  }) {
    return compare(other, precision: precision) >= 0;
  }

  bool lessThanOrEqualTo(
    double other, {
    double precision = precisionErrorTolerance,
  }) {
    return compare(other, precision: precision) <= 0;
  }
}

extension DoubleExtensionNullable on double? {
  bool equalTo(double? other, {double precision = precisionErrorTolerance}) {
    if (this == null && other == null) {
      return true;
    }
    if (this == null || other == null) {
      return false;
    }
    return this!.compare(other, precision: precision) == 0;
  }
}

extension RectExtension on Rect {
  bool beyond(Rect other) {
    return left.lessThan(other.left) ||
        right.greaterThan(other.right) ||
        top.lessThan(other.top) ||
        bottom.greaterThan(other.bottom);
  }

  bool topIsSame(Rect other) => top.equalTo(other.top);
  bool leftIsSame(Rect other) => left.equalTo(other.left);
  bool rightIsSame(Rect other) => right.equalTo(other.right);
  bool bottomIsSame(Rect other) => bottom.equalTo(other.bottom);

  bool isSame(Rect other) =>
      topIsSame(other) &&
      leftIsSame(other) &&
      rightIsSame(other) &&
      bottomIsSame(other);

  bool containsOffset(Offset offset) {
    return offset.dx >= left &&
        offset.dx <= right &&
        offset.dy >= top &&
        offset.dy <= bottom;
  }

  bool containsRect(Rect rect) {
    return left.lessThanOrEqualTo(rect.left) &&
        right.greaterThanOrEqualTo(rect.right) &&
        top.lessThanOrEqualTo(rect.top) &&
        bottom.greaterThanOrEqualTo(rect.bottom);
  }
}

extension RectExtensionNullable on Rect? {
  bool isSame(Rect? other) {
    if (this == null && other == null) {
      return true;
    }
    if (this == null || other == null) {
      return false;
    }
    return this!.isSame(other);
  }
}

extension OffsetExtension on Offset {
  bool isSame(Offset other) => dx.equalTo(other.dx) && dy.equalTo(other.dy);
}

extension OffsetExtensionNullable on Offset? {
  bool isSame(Offset? other) {
    if (this == null && other == null) {
      return true;
    }
    if (this == null || other == null) {
      return false;
    }
    return this!.isSame(other);
  }
}

extension DebounceThrottlingE on Function {
  VoidFunction debounce([Duration duration = const Duration(seconds: 1)]) {
    Timer? debounce;
    return () {
      if (debounce?.isActive ?? false) {
        debounce!.cancel();
      }
      debounce = Timer(duration, () {
        this.call();
      });
    };
  }

  VoidFunction throttle([Duration duration = const Duration(seconds: 1)]) {
    Timer? throttle;
    return () {
      if (throttle?.isActive ?? false) {
        return;
      }
      this.call();
      throttle = Timer(duration, () {});
    };
  }
}

typedef VoidFunction = void Function();
