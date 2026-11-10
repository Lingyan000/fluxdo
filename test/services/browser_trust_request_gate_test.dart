import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/browser_trust_coordinator.dart';

void main() {
  testWidgets('同一轮闸门超时后，后续请求立即复用失败结果', (tester) async {
    var timeouts = 0;
    final gate = BrowserTrustRequestGate(
      timeout: const Duration(seconds: 6),
      onTimeout: () {
        timeouts++;
        return false;
      },
    );
    final first = gate.future;
    await tester.pump(const Duration(seconds: 6));
    expect(await first, isFalse);
    bool? secondResult;
    gate.future.then((value) {
      secondResult = value;
    });
    await tester.pump();
    expect(secondResult, isFalse);
    expect(timeouts, 1);
    gate.complete(true);
    expect(await gate.future, isFalse);
  });

  testWidgets('同步提前完成会取消超时计时', (tester) async {
    var timedOut = false;
    final gate = BrowserTrustRequestGate(
      timeout: const Duration(seconds: 6),
      onTimeout: () {
        timedOut = true;
        return false;
      },
    );
    gate.complete(true);
    await tester.pump();
    expect(await gate.future, isTrue);
    await tester.pump(const Duration(seconds: 7));
    expect(timedOut, isFalse);
  });
}
