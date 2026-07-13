import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/post_segment_frame.dart';

void main() {
  group('eyeCareBubblePalette', () {
    test('light owner uses green card', () {
      final theme = ThemeData(brightness: Brightness.light);
      final palette = eyeCareBubblePalette(theme, isTopicOwner: true);
      expect(palette.card, const Color(0xFFEAF6DF));
      expect(palette.border, const Color(0xFF9FCA88));
      expect(palette.gradient, isNotNull);
    });

    test('light reply uses warm yellow card', () {
      final theme = ThemeData(brightness: Brightness.light);
      final palette = eyeCareBubblePalette(theme, isTopicOwner: false);
      expect(palette.card, const Color(0xFFFFF8DF));
      expect(palette.border, const Color(0xFFEAD9A6));
    });

    test('segment border connects long posts', () {
      final side = eyeCareBubbleBorder(
        const Color(0xFFEAD9A6),
        EyeCareBubblePart.middle,
      );
      expect(side.top, BorderSide.none);
      expect(side.bottom, BorderSide.none);
      expect(side.left.color, const Color(0xFFEAD9A6));
      expect(side.right.color, const Color(0xFFEAD9A6));
    });

    test('segmented long posts use solid card color (no gradient bands)', () {
      final theme = ThemeData(brightness: Brightness.light);
      final palette = eyeCareBubblePalette(theme, isTopicOwner: true);
      // 短帖可有渐变；长帖分段必须用纯色，避免每段重画渐变造成绿色断层
      expect(palette.gradient, isNotNull);
      expect(palette.card, const Color(0xFFEAF6DF));
      for (final part in [
        EyeCareBubblePart.start,
        EyeCareBubblePart.middle,
        EyeCareBubblePart.end,
      ]) {
        // 分段 margin 水平对齐，垂直无间隙
        final margin = eyeCareBubbleMargin(part);
        expect(margin.left, 8);
        expect(margin.right, 8);
        if (part != EyeCareBubblePart.end) {
          expect(margin.bottom, 0);
        }
      }
    });
  });

  group('isEyeCareTopicOwner', () {
    test('uses createdBy when present', () {
      expect(
        isEyeCareTopicOwner(
          postUsername: 'alice',
          postNumber: 1,
          createdByUsername: 'alice',
        ),
        isTrue,
      );
      expect(
        isEyeCareTopicOwner(
          postUsername: 'bob',
          postNumber: 2,
          createdByUsername: 'alice',
        ),
        isFalse,
      );
    });

    test('falls back to postNumber == 1 when createdBy missing', () {
      expect(
        isEyeCareTopicOwner(
          postUsername: 'anyone',
          postNumber: 1,
          createdByUsername: null,
        ),
        isTrue,
      );
      expect(
        isEyeCareTopicOwner(
          postUsername: 'anyone',
          postNumber: 2,
          createdByUsername: null,
        ),
        isFalse,
      );
    });
  });

  group('buildPostTargetColor eye-care highlight', () {
    Post post({int postNumber = 1}) => Post(
      id: 1,
      postNumber: postNumber,
      username: 'op',
      avatarTemplate: '',
      cooked: '<p>hi</p>',
      createdAt: DateTime.utc(2024, 1, 1),
      updatedAt: DateTime.utc(2024, 1, 1),
      replyCount: 0,
      likeCount: 0,
      postType: 1,
    );

    test('highlight does not tint owner green with primaryContainer', () {
      final theme = ThemeData(
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      );
      final normal = buildPostTargetColor(
        theme,
        post(),
        false,
        eyeCareBubbles: true,
        isTopicOwner: true,
      );
      final highlighted = buildPostTargetColor(
        theme,
        post(),
        true,
        eyeCareBubbles: true,
        isTopicOwner: true,
      );
      // 护眼气泡高亮改用边框加深，底色保持纯绿，避免肤色+绿脏色
      expect(highlighted, normal);
      expect(highlighted, const Color(0xFFEAF6DF));
      // 非护眼模式会混 primaryContainer，结果绝不是纯绿卡色
      final dirty = buildPostTargetColor(theme, post(), true);
      expect(dirty, isNot(equals(const Color(0xFFEAF6DF))));
    });

    test('highlight still blends without eye-care bubbles', () {
      final theme = ThemeData(
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      );
      final normal = buildPostTargetColor(theme, post(), false);
      final highlighted = buildPostTargetColor(theme, post(), true);
      expect(highlighted, isNot(equals(normal)));
    });
  });
}
