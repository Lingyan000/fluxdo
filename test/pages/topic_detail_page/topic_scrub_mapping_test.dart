import 'package:fluxdo/pages/topic_detail_page/widgets/topic_scrub_mapping.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  int target({
    int start = 100,
    int total = 1000,
    double startX = 180,
    required double currentX,
    double left = 16,
    double right = 344,
  }) => topicScrubTargetIndex(
    startIndex: start,
    totalCount: total,
    startX: startX,
    currentX: currentX,
    surfaceLeft: left,
    surfaceRight: right,
  );

  group('步进段', () {
    test('未越过一个步宽不移动', () {
      expect(target(currentX: 180 + 23), 100);
      expect(target(currentX: 180 - 23), 100);
    });

    test('每个步宽移动一楼，向右往后、向左往前', () {
      expect(target(currentX: 180 + 24), 101);
      expect(target(currentX: 180 + 48), 102);
      expect(target(currentX: 180 - 24), 99);
      expect(target(currentX: 180 - 72), 97);
    });
  });

  group('加速段', () {
    test('拖到手势面右边缘恰好到末楼', () {
      expect(target(currentX: 344), 1000);
      expect(target(currentX: 400), 1000);
    });

    test('拖到手势面左边缘恰好到首楼', () {
      expect(target(currentX: 16), 1);
      expect(target(currentX: -20), 1);
    });

    test('加速段内随距离单调推进', () {
      var last = target(currentX: 180 + 72);
      for (var x = 180.0 + 73; x <= 344; x += 4) {
        final t = target(currentX: x);
        expect(t, greaterThanOrEqualTo(last));
        last = t;
      }
    });

    test('起手贴近边缘时，越过步进段直接到端点', () {
      expect(target(startX: 330, currentX: 330 + 80), 1000);
    });
  });

  group('边界', () {
    test('短话题不越界', () {
      expect(target(start: 2, total: 3, currentX: 344), 3);
      expect(target(start: 2, total: 3, currentX: 16), 1);
      expect(target(start: 1, total: 3, currentX: 180 + 72), 3);
    });

    test('单楼话题恒为 1', () {
      expect(target(start: 1, total: 1, currentX: 344), 1);
    });

    test('剩余楼数不足步进段时只做步进', () {
      expect(target(start: 998, total: 1000, currentX: 180 + 200), 1000);
      expect(target(start: 3, total: 1000, currentX: 180 - 200), 1);
    });
  });
}
