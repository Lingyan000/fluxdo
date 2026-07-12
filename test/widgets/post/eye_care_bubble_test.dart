import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
