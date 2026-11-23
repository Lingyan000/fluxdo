import 'package:flutter/foundation.dart';

import '../../../models/nested_reading_position.dart';

/// 跳转前的阅读锚点。分段内偏移不依赖窗口中前面加载了多少楼。
class TopicReadingPosition {
  const TopicReadingPosition({
    required this.postNumber,
    this.postId,
    this.segmentIndex = 0,
    this.offset = 0,
    this.nestedPosition,
    this.contextTarget,
    this.browsePosition,
  });

  final int postNumber;
  final int? postId;
  final int segmentIndex;
  final double offset;
  final NestedReadingPosition? nestedPosition;
  final int? contextTarget;
  final NestedReadingPosition? browsePosition;

  bool sameLocation(TopicReadingPosition other) =>
      postNumber == other.postNumber &&
      segmentIndex == other.segmentIndex &&
      (offset - other.offset).abs() < 1 &&
      (nestedPosition == null) == (other.nestedPosition == null) &&
      contextTarget == other.contextTarget;
}

class TopicJumpAttempt {
  TopicJumpAttempt(this.origin, this.returnTarget);

  final TopicReadingPosition? origin;
  final TopicReadingPosition? returnTarget;
}

/// 仅记录成功的主动跳转，快速改选共用尚未离开的阅读起点。
class TopicJumpHistory extends ChangeNotifier {
  final List<TopicReadingPosition> _positions = [];
  TopicJumpAttempt? _pending;
  bool _disposed = false;

  TopicReadingPosition? get target => _positions.lastOrNull;
  bool get returning => _pending?.returnTarget != null;

  TopicJumpAttempt begin(
    TopicReadingPosition? origin, {
    bool returning = false,
  }) {
    final attempt = TopicJumpAttempt(
      _pending?.origin ?? origin,
      returning ? target : null,
    );
    _pending = attempt;
    notifyListeners();
    return attempt;
  }

  bool isCurrent(TopicJumpAttempt attempt) =>
      !_disposed && identical(_pending, attempt);

  void finish(
    TopicJumpAttempt attempt, {
    required bool succeeded,
    TopicReadingPosition? destination,
  }) {
    if (!isCurrent(attempt)) return;
    _pending = null;
    if (succeeded) {
      if (attempt.returnTarget != null) {
        if (identical(target, attempt.returnTarget)) _positions.removeLast();
      } else {
        final origin = attempt.origin;
        if (origin != null &&
            destination != null &&
            !origin.sameLocation(destination) &&
            !(target?.sameLocation(origin) ?? false)) {
          _positions.add(origin);
        }
      }
    }
    notifyListeners();
  }

  void clear() {
    _positions.clear();
    _pending = null;
    notifyListeners();
  }

  void cancelPending() {
    if (_pending == null) return;
    _pending = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pending = null;
    super.dispose();
  }
}
