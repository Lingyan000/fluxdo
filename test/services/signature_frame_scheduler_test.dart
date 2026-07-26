import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/signature_frame_scheduler.dart';

void main() {
  final scheduler = SignatureFrameScheduler.instance;

  tearDown(scheduler.debugReset);

  test('顶档不高于关闭自适应时的固定帧率', () {
    // AnimatedSvgView 关闭自适应时是固定 15 FPS。顶档一旦超过它，
    // 这个默认开启的「降帧减卡顿」开关就会变成加帧开关。
    expect(scheduler.targetFps, lessThanOrEqualTo(15));
  });

  test('连续高负载快速从 15 FPS 降到 8/4 FPS', () {
    expect(scheduler.targetFps, 15);
    for (var i = 0; i < 2; i++) {
      scheduler.debugRecordLoad(workMicros: 16000);
    }
    expect(scheduler.targetFps, 8);
    for (var i = 0; i < 2; i++) {
      scheduler.debugRecordLoad(workMicros: 16000);
    }
    expect(scheduler.targetFps, 4);
  });

  test('唤醒延迟连击不被穿插的健康 UI 帧清零', () {
    // 两个派发样本(15Hz)之间必然夹着大量健康 UI 帧样本(60-120Hz)。
    // 唤醒延迟若与帧耗时共用一条 streak,连击会被清零、信号永远失效。
    scheduler.debugRecordLoad(workMicros: 1000, wakeLagMicros: 10000);
    for (var i = 0; i < 8; i++) {
      scheduler.debugRecordLoad(workMicros: 3000); // 健康 UI 帧
    }
    expect(scheduler.targetFps, 15);
    scheduler.debugRecordLoad(workMicros: 1000, wakeLagMicros: 10000);
    expect(scheduler.targetFps, 8);
  });

  test('健康帧持续一段时间后缓慢恢复帧率', () {
    for (var i = 0; i < 4; i++) {
      scheduler.debugRecordLoad(workMicros: 16000);
    }
    expect(scheduler.targetFps, 4);

    for (var i = 0; i < 119; i++) {
      scheduler.debugRecordLoad(workMicros: 3000);
    }
    expect(scheduler.targetFps, 4);
    scheduler.debugRecordLoad(workMicros: 3000);
    expect(scheduler.targetFps, 8);
  });

  testWidgets('多订阅者每人每 tick 都推进一帧,不被摊薄', (tester) async {
    final a = Object();
    final b = Object();
    var callsA = 0;
    var callsB = 0;
    scheduler.subscribe(owner: a, onFrame: (_) => callsA++);
    scheduler.subscribe(owner: b, onFrame: (_) => callsB++);

    await tester.pump(const Duration(milliseconds: 300));

    expect(callsA, greaterThan(0));
    expect(callsA, callsB);

    scheduler.unsubscribe(a);
    scheduler.unsubscribe(b);
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
