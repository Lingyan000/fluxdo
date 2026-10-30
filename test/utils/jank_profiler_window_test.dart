import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/jank_profiler.dart';

void main() {
  test('帧窗口使用单调时间，不混入墙上时钟', () {
    final timing = FrameTiming(
      vsyncStart: 1000000,
      buildStart: 1000100,
      buildFinish: 1005000,
      rasterStart: 1005100,
      rasterFinish: 1008000,
      rasterFinishWallTime: 1800000000000000,
    );
    expect(JankProfiler.frameWindow(timing), (1000000, 8000));
  });
}
