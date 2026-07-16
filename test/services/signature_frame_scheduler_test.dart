import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/signature_frame_scheduler.dart';

void main() {
  final scheduler = SignatureFrameScheduler.instance;

  tearDown(scheduler.debugReset);

  test('连续高负载快速从 24 FPS 降到 12/6 FPS', () {
    expect(scheduler.targetFps, 24);
    for (var i = 0; i < 2; i++) {
      scheduler.debugRecordLoad(workMicros: 16000);
    }
    expect(scheduler.targetFps, 12);
    for (var i = 0; i < 2; i++) {
      scheduler.debugRecordLoad(workMicros: 16000);
    }
    expect(scheduler.targetFps, 6);
  });

  test('健康帧持续一段时间后缓慢恢复帧率', () {
    for (var i = 0; i < 4; i++) {
      scheduler.debugRecordLoad(workMicros: 16000);
    }
    expect(scheduler.targetFps, 6);

    for (var i = 0; i < 119; i++) {
      scheduler.debugRecordLoad(workMicros: 3000);
    }
    expect(scheduler.targetFps, 6);
    scheduler.debugRecordLoad(workMicros: 3000);
    expect(scheduler.targetFps, 12);
  });

  testWidgets('取消订阅后停止共享调度', (tester) async {
    final owner = Object();
    var calls = 0;
    scheduler.subscribe(owner: owner, onFrame: (_) => calls++);
    await tester.pump(const Duration(milliseconds: 100));
    expect(calls, greaterThan(0));

    scheduler.unsubscribe(owner);
    final stoppedAt = calls;
    await tester.pump(const Duration(milliseconds: 200));
    expect(calls, stoppedAt);
    expect(scheduler.debugSubscriberCount, 0);
  });
}
