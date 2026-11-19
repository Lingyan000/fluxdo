import 'package:fluxdo/pages/topic_detail_page/widgets/topic_scrub_mapping.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TopicScrubTracker tracker({
    int start = 6686,
    int total = 10000,
    bool fromHandle = true,
  }) => TopicScrubTracker(
    startIndex: start,
    totalCount: total,
    surfaceWidth: 320,
    startX: 210,
    fromHandle: fromHandle,
  );

  test('全帖按位置定位，两端直达，落点与采样次数无关', () {
    for (final samples in [1, 8, 120]) {
      final t = tracker(fromHandle: false);
      for (var i = 1; i <= samples; i++) {
        t.update(210 - 130 * i / samples, 0);
      }
      expect(t.index, 2501);
      t.update(321, 0);
      expect(t.index, 10000);
      t.update(-4, 0);
      expect(t.index, 1);
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
