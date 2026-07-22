import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/utils/blocked_content_info_visibility.dart';

void main() {
  group('BlockedContentInfoVisibility', () {
    test('开关开启且存在隐藏话题时显示顶部提示', () {
      expect(
        BlockedContentInfoVisibility.shouldShowTopicHint(
          enabled: true,
          hiddenCount: 1,
        ),
        isTrue,
      );
      expect(
        BlockedContentInfoVisibility.shouldShowTopicHint(
          enabled: true,
          hiddenCount: 0,
        ),
        isFalse,
      );
    });

    test('开关关闭后隐藏话题提示和论坛原生回复 Gap', () {
      const gaps = PostStreamGaps(
        before: {
          10: [7, 8, 9],
        },
      );

      expect(
        BlockedContentInfoVisibility.shouldShowTopicHint(
          enabled: false,
          hiddenCount: 3,
        ),
        isFalse,
      );
      expect(
        BlockedContentInfoVisibility.visiblePostGaps(
          enabled: false,
          gaps: gaps,
        ),
        isNull,
      );
      expect(
        BlockedContentInfoVisibility.visiblePostGaps(enabled: true, gaps: gaps),
        same(gaps),
      );
    });
  });
}
