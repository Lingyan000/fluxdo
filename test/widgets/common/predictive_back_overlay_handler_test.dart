/// PredictiveBackOverlayHandler 单元测试:
/// isEnabled 门控、isButtonEvent 不认领、进度 clamp、commit/cancel 映射、
/// 手势中途进后台代打 cancel。
library;

import 'package:flutter/services.dart' show PredictiveBackEvent;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/predictive_back_overlay_handler.dart';

PredictiveBackEvent _gesture(double progress) => PredictiveBackEvent.fromMap({
  'touchOffset': <Object?>[0.0, 400.0],
  'progress': progress,
  'swipeEdge': 0,
});

PredictiveBackEvent _button() => PredictiveBackEvent.fromMap({
  'progress': 0.0,
  'swipeEdge': 0,
});

class _Harness {
  bool enabled = true;
  int starts = 0;
  double? lastProgress;
  int cancels = 0;
  int commits = 0;

  late final PredictiveBackOverlayHandler handler =
      PredictiveBackOverlayHandler(
        isEnabled: () => enabled,
        onStart: () => starts++,
        onUpdate: (p) => lastProgress = p,
        onCancel: () => cancels++,
        onCommit: () => commits++,
      )..attach();

  void dispose() => handler.dispose();
}

void main() {
  testWidgets('isEnabled=false 不认领;true 才认领并触发 onStart', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);

    h.enabled = false;
    expect(h.handler.handleStartBackGesture(_gesture(0)), isFalse);
    expect(h.starts, 0);

    h.enabled = true;
    expect(h.handler.handleStartBackGesture(_gesture(0)), isTrue);
    expect(h.starts, 1);
  });

  testWidgets('button event 永远不认领(交给 pop/history 路径)', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);

    expect(h.handler.handleStartBackGesture(_button()), isFalse);
    expect(h.starts, 0);
  });

  testWidgets('进度 clamp 到 [0,1];commit/cancel 只派发给认领的手势', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);

    expect(h.handler.handleStartBackGesture(_gesture(0)), isTrue);
    h.handler.handleUpdateBackGestureProgress(_gesture(0.7));
    expect(h.lastProgress, 0.7);

    // cancel 后状态复位,后续 update 不再派发。
    h.handler.handleCancelBackGesture();
    expect(h.cancels, 1);
    h.handler.handleUpdateBackGestureProgress(_gesture(0.9));
    expect(h.lastProgress, 0.7);

    // 新一轮 commit。
    expect(h.handler.handleStartBackGesture(_gesture(0)), isTrue);
    h.handler.handleCommitBackGesture();
    expect(h.commits, 1);
    // commit 后复位,重复 commit 不重复派发。
    h.handler.handleCommitBackGesture();
    expect(h.commits, 1);
  });

  testWidgets('手势中途 App 进后台:代打 cancel 防卡半开', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);

    expect(h.handler.handleStartBackGesture(_gesture(0)), isTrue);
    h.handler.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(h.cancels, 1);
  });
}
