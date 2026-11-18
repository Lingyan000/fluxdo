import 'package:fluxdo/pages/topic_detail_page/widgets/topic_scrub_mapping.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TopicScrubTracker tracker({int start = 100, int total = 1000}) =>
      TopicScrubTracker(
        startIndex: start,
        totalCount: total,
        surfaceWidth: 320,
      );

  /// 以恒定速度移动 [distance]，每 8ms 一个事件（120Hz 左右）
  int move(TopicScrubTracker t, double distance, {required double speed}) {
    const dt = 0.008;
    final step = speed * dt * distance.sign;
    var moved = 0.0;
    var index = t.index;
    while (moved < distance.abs() - 1e-9) {
      final dx = (distance.abs() - moved) < step.abs()
          ? (distance.abs() - moved) * distance.sign
          : step;
      index = t.update(dx, dt);
      moved += dx.abs();
    }
    return index;
  }

  group('慢速：逐楼精确定位', () {
    test('每 24px 一楼，向右往后、向左往前', () {
      final t = tracker();
      expect(move(t, 24, speed: 80), 101);
      expect(move(t, 48, speed: 80), 103);
      expect(move(t, -72, speed: 80), 100);
    });

    test('长话题慢速时同样逐楼，不会飞出去', () {
      final t = tracker(total: 5000);
      expect(move(t, 96, speed: 100), 104);
    });
  });

  group('快速：增益平滑放大', () {
    test('同样距离，快划比慢挪走得远', () {
      final slow = move(tracker(), 120, speed: 100);
      final fast = move(tracker(), 120, speed: 2000);
      expect(fast, greaterThan(slow + 50));
    });

    test('全宽快划一次约覆盖整个话题', () {
      final t = tracker(start: 1, total: 1000);
      expect(move(t, 320, speed: 3000), greaterThan(900));
    });

    test('增益随速度单调不减，且起止平滑', () {
      final t = tracker();
      var last = 0.0;
      for (var v = 0.0; v <= 2000; v += 50) {
        final gain = t.gainFor(v);
        expect(gain, greaterThanOrEqualTo(last));
        last = gain;
      }
      expect(t.gainFor(0), 1);
      expect(t.gainFor(TopicScrubTracker.fastSpeed), t.maxGain);
    });
  });

  group('边界', () {
    test('楼数少时增益上限为 1（不需要加速）', () {
      expect(tracker(start: 1, total: 8).maxGain, 1);
    });

    test('不越过首末楼', () {
      final t = tracker(start: 2, total: 3);
      expect(move(t, 400, speed: 3000), 3);
      expect(move(t, -800, speed: 3000), 1);
    });

    test('单楼话题恒为 1', () {
      expect(move(tracker(start: 1, total: 1), 200, speed: 100), 1);
    });
  });
}
