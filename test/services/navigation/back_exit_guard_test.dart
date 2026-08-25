import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/navigation/back_exit_guard.dart';

void main() {
  test('两秒内第二次返回才允许退出', () {
    var now = DateTime(2026, 8, 4, 12);
    final guard = BackExitGuard(now: () => now);

    expect(guard.shouldExit(), isFalse);

    now = now.add(const Duration(milliseconds: 1999));
    expect(guard.shouldExit(), isTrue);
  });

  test('超时后重新开始计数', () {
    var now = DateTime(2026, 8, 4, 12);
    final guard = BackExitGuard(now: () => now);

    expect(guard.shouldExit(), isFalse);

    now = now.add(const Duration(seconds: 2));
    expect(guard.shouldExit(), isFalse);

    now = now.add(const Duration(seconds: 1));
    expect(guard.shouldExit(), isTrue);
  });
}
