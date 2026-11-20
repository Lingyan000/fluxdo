import 'package:fluxdo/pages/topic_detail_page/widgets/topic_scrub_mapping.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TopicScrubTracker tracker({
    int start = 6686,
    int total = 10000,
    double startX = 210,
  }) => TopicScrubTracker(
    startIndex: start,
    totalCount: total,
    surfaceWidth: 320,
    startX: startX,
  );

  test('从不同位置起手，同样的短拖相对当前楼层移动相同距离', () {
    for (final x in [64.0, 256.0]) {
      final t = tracker(start: 5001, total: 10001, startX: x);
      expect(t.index, 5001);
      expect(t.thumbX, 160);
      t.update(x + 16, 0);
      expect(t.index, 5501);
      expect(t.thumbX, 176);
      t.update(x - 16, 0);
      expect(t.index, 4501);
      t.update(x - 16, 76);
      expect(t.index, 4501);
      t.update(x - 2, 76);
      expect(t.index, 4502);
      expect(t.rulerOrigin + t.thumbX * t.floorsPerPixel, closeTo(4502, .001));
    }
    final edge = tracker(start: 5001, total: 10001, startX: 4)..update(0, 0);
    expect(edge.index, 4876);
  });

  test('全帖长扫直达首末楼，落点与采样次数无关，到边可立刻反向', () {
    int? expected;
    for (final samples in [1, 8, 120]) {
      final t = tracker(start: 8001, total: 10001, startX: 110);
      for (var i = 1; i <= samples; i++) {
        t.update(110 - 86 * i / samples, 0);
      }
      expected ??= t.index;
      expect(t.index, expected);
      expect(t.index, inExclusiveRange(1, 5314));
      t.update(0, 0);
      expect(t.index, 1);
      t.update(3, 0);
      expect(t.index, greaterThan(1));
      t.update(320, 0);
      expect(t.index, 10001);
    }
  });

  test('斜着换档保留楼号，同一笔内逐楼、反向并回到全帖', () {
    final t = tracker();
    t.update(213, 38);
    expect(t.scale, TopicScrubScale.nearby);
    expect(t.index, 6686);
    t.update(216, 76);
    expect(t.scale, TopicScrubScale.single);
    expect(t.index, 6686);
    t.update(202, 76);
    expect(t.index, 6685);
    t.update(230, 76);
    expect(t.index, 6687);
    t.update(235, 0);
    expect(t.scale, TopicScrubScale.whole);
    expect(t.index, 6687);
    t.update(0, 0);
    expect(t.index, 1);
    t.update(3, 76);
    t.update(17, 76);
    expect(t.index, 2);
  });

  test('档位交界处有余量，局部刻度比全帖移动得慢', () {
    final t = tracker();
    t.update(211, 38);
    t.update(211, 20);
    expect(t.scale, TopicScrubScale.nearby);
    t.update(225, 20);
    expect(t.index - 6686, inExclusiveRange(1, 100));
    t.update(225, 76);
    t.update(225, 57);
    expect(t.scale, TopicScrubScale.single);
  });

  test('按可用行程和话题长度提供必要档位', () {
    expect(tracker(total: 1).scales, [TopicScrubScale.whole]);
    expect(tracker(total: 8).scales, [TopicScrubScale.whole]);
    expect(tracker(total: 80).scales, [
      TopicScrubScale.whole,
      TopicScrubScale.single,
    ]);
    final single = tracker(total: 1)..update(1000, 80);
    expect(single.index, 1);
  });
}
