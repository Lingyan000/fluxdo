import 'package:fluxdo/models/topic_post_excerpt.dart';
import 'package:fluxdo/models/topic_timeline_lookup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TopicTimelineLookup', () {
    final base = DateTime(2026, 11, 17, 15, 30);
    // 与线上实测格式一致：[[位置, 距今天数], ...]，只在天数变化处记录
    final lookup = TopicTimelineLookup.fromJson([
      [1, 127],
      [6, 121],
      [8, 120],
      [52, 0],
    ], base);

    test('命中样本位置取样本天数', () {
      expect(lookup.daysAgoAt(1), 127);
      expect(lookup.daysAgoAt(6), 121);
      expect(lookup.daysAgoAt(52), 0);
    });

    test('两个样本之间取前一个样本', () {
      expect(lookup.daysAgoAt(3), 127);
      expect(lookup.daysAgoAt(7), 121);
      expect(lookup.daysAgoAt(30), 120);
    });

    test('越界取端点样本', () {
      expect(lookup.daysAgoAt(0), 127);
      expect(lookup.daysAgoAt(999), 0);
    });

    test('天数按接收时刻换算成本地日期（只到天）', () {
      expect(lookup.dateAt(52), DateTime(2026, 11, 17));
      expect(lookup.dateAt(1), DateTime(2026, 7, 13));
    });

    test('缺失或格式不符时为空', () {
      expect(TopicTimelineLookup.fromJson(null, base).isEmpty, isTrue);
      expect(TopicTimelineLookup.fromJson([
        ['x', 1],
      ], base).isEmpty, isTrue);
      expect(TopicTimelineLookup.empty.dateAt(1), isNull);
    });
  });

  group('TopicPostExcerpt.plainTextFromHtml', () {
    test('剥离标签、解码实体、表情取 alt、去掉灯箱说明', () {
      const html =
          'Hi &amp; <b>bye</b> <img class="emoji" alt=":smile:"> '
          '<a class="lightbox"><img src="x.png"><div class="meta">'
          '<span class="filename">x.png</span> 800×600</div></a>end';
      expect(TopicPostExcerpt.plainTextFromHtml(html), 'Hi & bye :smile: end');
    });

    test('超长截断并加省略号', () {
      expect(
        TopicPostExcerpt.plainTextFromHtml('abcdefgh', maxLength: 3),
        'abc…',
      );
    });
  });
}
