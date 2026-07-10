import 'dart:async';

import 'nav_action_bus.dart';

/// Splits active topic-tab taps into the configured single and double actions.
///
/// The coordinator tracks a logical active index separately from TabController
/// so the first tap on an inactive tab switches immediately without dispatching
/// an action. A rapid second tap is then treated as the first active-tab tap,
/// even while the controller animation is still settling.
class TopicTabTapCoordinator {
  TopicTabTapCoordinator({required int initialActiveIndex})
    : _activeIndex = initialActiveIndex;

  static const _doubleTapWindow = Duration(milliseconds: 300);

  int _activeIndex;
  int? _pendingTapIndex;
  Timer? _pendingTapTimer;
  bool _disposed = false;

  void handleTap({
    required int index,
    required NavTapAction singleAction,
    required NavTapAction doubleAction,
    required void Function(NavAction action) dispatch,
  }) {
    if (_disposed) return;

    if (index != _activeIndex) {
      _cancelPendingTap();
      _activeIndex = index;
      return;
    }

    final hasSingle = singleAction != NavTapAction.none;
    final hasDouble = doubleAction != NavTapAction.none;

    if (!hasSingle && !hasDouble) {
      _cancelPendingTap();
      return;
    }

    final isDoubleTap =
        hasDouble && _pendingTapTimer != null && _pendingTapIndex == index;

    if (isDoubleTap) {
      _cancelPendingTap();
      final navAction = doubleAction.toNavAction();
      if (navAction != null) {
        dispatch(navAction);
      }
      return;
    }

    _cancelPendingTap();

    final singleNavAction = singleAction.toNavAction();
    if (!hasDouble) {
      if (singleNavAction != null) {
        dispatch(singleNavAction);
      }
      return;
    }

    _pendingTapIndex = index;
    _pendingTapTimer = Timer(_doubleTapWindow, () {
      _pendingTapTimer = null;
      _pendingTapIndex = null;
      if (_disposed || singleNavAction == null) return;
      dispatch(singleNavAction);
    });
  }

  /// Synchronizes programmatic/external tab changes.
  ///
  /// Settling the same tab selected by [handleTap] keeps its pending action;
  /// changing to a different tab cancels stale pending work.
  void syncActiveIndex(int index) {
    if (_disposed || index == _activeIndex) return;
    _cancelPendingTap();
    _activeIndex = index;
  }

  /// Clears all pending gestures when the tab set changes.
  void reset({required int activeIndex}) {
    if (_disposed) return;
    _cancelPendingTap();
    _activeIndex = activeIndex;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelPendingTap();
  }

  void _cancelPendingTap() {
    _pendingTapTimer?.cancel();
    _pendingTapTimer = null;
    _pendingTapIndex = null;
  }
}
