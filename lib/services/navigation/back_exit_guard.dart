class BackExitGuard {
  BackExitGuard({
    this.timeout = const Duration(seconds: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration timeout;
  final DateTime Function() _now;
  DateTime? _lastBackPress;

  /// 记录一次首页返回。只有在超时前再次调用时才允许退出。
  bool shouldExit() {
    final now = _now();
    final previous = _lastBackPress;
    _lastBackPress = now;
    if (previous == null || now.difference(previous) >= timeout) {
      return false;
    }
    _lastBackPress = null;
    return true;
  }
}
