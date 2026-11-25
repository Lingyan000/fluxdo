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

  bool get isNested => nestedPosition != null;

  bool sameViewMode(TopicReadingPosition other) =>
      isNested == other.isNested && contextTarget == other.contextTarget;
}

class TopicJumpAttempt {
  TopicJumpAttempt(
    this.origin,
    this.returnTarget, {
    this.recordHistory = true,
    this.coalesceExplore = false,
    Set<int> originVisiblePosts = const {},
  }) : originVisiblePosts = Set.unmodifiable(originVisiblePosts);

  final TopicReadingPosition? origin;
  final TopicReadingPosition? returnTarget;
  final bool recordHistory;
  final bool coalesceExplore;
  final Set<int> originVisiblePosts;
}

class _JumpHistoryEntry {
  _JumpHistoryEntry({
    required this.origin,
    required this.destination,
    required this.createdAt,
  });

  final TopicReadingPosition origin;
  TopicReadingPosition destination;
  DateTime createdAt;
  bool settledAtDestination = false;
  final Set<int> browsedPosts = {};
}

/// 仅记录成功的主动跳转，快速改选共用尚未离开的阅读起点，
/// 并根据用户的后续阅读行为自动合并探索过路站、滚回原位消退或新位置续读失效。
class TopicJumpHistory extends ChangeNotifier {
  TopicJumpHistory({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// 返回栈最大深度，避免连续跳离后无限堆叠。
  static const int maxHistoryDepth = 8;

  /// 连续定位探索（如进度条/时间线/目录选点）在该窗口内未滚动阅读时合并过路站。
  static const Duration exploreMergeWindow = Duration(seconds: 8);

  /// 离开目标楼层及紧邻上下文后，手动连续浏览达到该楼层数时视为已接续主线阅读。
  static const int maxBrowsedPostsBeforeExpire = 4;

  /// 同楼层内跳转的最小有效位移，过滤微小抖动。
  static const double minSamePostJumpDelta = 120.0;

  /// 同楼层内手动滚回原锚点的接近阈值。
  static const double returnProximityThreshold = 140.0;

  final DateTime Function() _clock;
  final List<_JumpHistoryEntry> _entries = [];
  TopicJumpAttempt? _pending;
  bool _disposed = false;

  TopicReadingPosition? get target => _entries.lastOrNull?.origin;
  bool get returning => _pending?.returnTarget != null;
  bool get hasPending => _pending != null;

  TopicJumpAttempt begin(
    TopicReadingPosition? origin, {
    bool returning = false,
    bool recordHistory = true,
    bool coalesceExplore = false,
    Set<int> originVisiblePosts = const {},
  }) {
    final reusePendingOrigin = _pending != null && _pending!.recordHistory;
    final attempt = TopicJumpAttempt(
      reusePendingOrigin ? (_pending!.origin ?? origin) : origin,
      returning ? target : null,
      recordHistory: recordHistory,
      coalesceExplore: coalesceExplore,
      originVisiblePosts: reusePendingOrigin
          ? _pending!.originVisiblePosts
          : originVisiblePosts,
    );
    _pending = attempt;
    notifyListeners();
    return attempt;
  }

  bool isCurrent(TopicJumpAttempt attempt) =>
      !_disposed && identical(_pending, attempt);

  /// 完成跳转尝试；返回 true 表示本次跳转新增或更新了返回锚点。
  bool finish(
    TopicJumpAttempt attempt, {
    required bool succeeded,
    TopicReadingPosition? destination,
  }) {
    if (!isCurrent(attempt)) return false;
    _pending = null;
    var recorded = false;
    if (succeeded) {
      if (attempt.returnTarget != null) {
        if (identical(target, attempt.returnTarget)) _entries.removeLast();
      } else if (attempt.recordHistory) {
        final origin = attempt.origin;
        if (origin != null &&
            destination != null &&
            _isMeaningfulJump(
              origin,
              destination,
              attempt.originVisiblePosts,
            )) {
          recorded = _recordJump(
            origin,
            destination,
            coalesceExplore: attempt.coalesceExplore,
          );
        }
      }
    }
    notifyListeners();
    return recorded;
  }

  bool _isMeaningfulJump(
    TopicReadingPosition origin,
    TopicReadingPosition destination,
    Set<int> originVisiblePosts,
  ) {
    if (origin.sameLocation(destination)) return false;
    if (!origin.sameViewMode(destination)) return true;
    if (origin.postNumber == destination.postNumber) {
      if (origin.segmentIndex != destination.segmentIndex) return true;
      return (origin.offset - destination.offset).abs() >= minSamePostJumpDelta;
    }
    // 相邻楼层且跳转前已在视口内可见时，无需弹出返回入口。
    if ((origin.postNumber - destination.postNumber).abs() <= 1 &&
        originVisiblePosts.contains(destination.postNumber)) {
      return false;
    }
    return true;
  }

  bool _recordJump(
    TopicReadingPosition origin,
    TopicReadingPosition destination, {
    required bool coalesceExplore,
  }) {
    final now = _clock();
    if (coalesceExplore && _entries.isNotEmpty) {
      final top = _entries.last;
      final canCoalesce =
          !top.settledAtDestination &&
          now.difference(top.createdAt) <= exploreMergeWindow &&
          top.destination.sameViewMode(origin) &&
          top.destination.postNumber == origin.postNumber;
      if (canCoalesce) {
        if (_isBackAtOrigin(top.origin, destination)) {
          _entries.removeLast();
          return false;
        }
        top.destination = destination;
        top.createdAt = now;
        top.browsedPosts.clear();
        return true;
      }
    }
    if (target?.sameLocation(origin) ?? false) return false;
    _entries.add(
      _JumpHistoryEntry(
        origin: origin,
        destination: destination,
        createdAt: now,
      ),
    );
    if (_entries.length > maxHistoryDepth) {
      _entries.removeAt(0);
    }
    return true;
  }

  bool _isBackAtOrigin(
    TopicReadingPosition origin,
    TopicReadingPosition current,
  ) {
    if (!origin.sameViewMode(current)) return false;
    if (origin.postNumber != current.postNumber) return false;
    if (origin.segmentIndex != current.segmentIndex) return false;
    return (origin.offset - current.offset).abs() <= returnProximityThreshold;
  }

  /// 记录用户在落点处发生过主动滚动，用于区分过路探索与真实停留阅读。
  void markUserScrolled() {
    if (_disposed || _pending != null || _entries.isEmpty) return;
    _entries.last.settledAtDestination = true;
  }

  /// 根据用户主动滚动后的阅读位置，自动消退已滚回原位或已在新位置续读的锚点。
  void observeReading({
    required int currentPostNumber,
    required Set<int> visiblePostNumbers,
    TopicReadingPosition? currentPosition,
    required bool isNestedView,
    int? nestedContextTarget,
  }) {
    if (_disposed || _pending != null || _entries.isEmpty) return;
    final top = _entries.last;
    if (!top.settledAtDestination) return;
    if (top.destination.isNested != isNestedView ||
        top.destination.contextTarget != nestedContextTarget) {
      return;
    }

    // 1. 滚回原位：弹出当前栈顶。
    if (top.origin.sameViewMode(top.destination)) {
      if (top.origin.postNumber == top.destination.postNumber) {
        if (currentPosition != null &&
            _isBackAtOrigin(top.origin, currentPosition)) {
          _entries.removeLast();
          notifyListeners();
          return;
        }
      } else {
        final returnedToOrigin =
            currentPostNumber == top.origin.postNumber ||
            (visiblePostNumbers.contains(top.origin.postNumber) &&
                (currentPostNumber - top.origin.postNumber).abs() <= 1);
        if (returnedToOrigin) {
          _entries.removeLast();
          notifyListeners();
          return;
        }
      }
    }

    // 2. 停留在目标楼层（含长帖内持续阅读）及紧邻 1 楼时永远保留；
    //    离开目标后继续跨越多楼阅读时，视为已在新位置接续主线阅读。
    if (nestedContextTarget != null) return;
    if ((currentPostNumber - top.destination.postNumber).abs() <= 1) return;
    top.browsedPosts.add(currentPostNumber);
    if (top.browsedPosts.length >= maxBrowsedPostsBeforeExpire) {
      _entries.clear();
      notifyListeners();
    }
  }

  void clear() {
    final hadState = _entries.isNotEmpty || _pending != null;
    _entries.clear();
    _pending = null;
    if (hadState) notifyListeners();
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
