import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_menu_placement.dart';

void main() {
  test(
    'desktop menus stay at the trigger even if a distant column is empty',
    () {
      const trigger = Rect.fromLTWH(40, 480, 40, 40);
      final menu = placeComposerMenu(
        viewport: const Rect.fromLTWH(8, 64, 1184, 720),
        preferred: const Rect.fromLTWH(40, 120, 280, 352),
        trigger: trigger,
        avoidRects: [const Rect.fromLTWH(0, 64, 800, 700)],
        stayNearTrigger: true,
      );
      expect(menu.inflate(32).contains(trigger.center), isTrue);
      expect(menu.left, lessThan(400));
      expect(
        menu.height,
        352,
        reason: 'desktop actions should not require unnecessary scrolling',
      );
    },
  );

  test(
    'a nearby free area can scroll but must show at least four action rows',
    () {
      final menu = placeComposerMenu(
        viewport: const Rect.fromLTWH(8, 64, 784, 600),
        preferred: const Rect.fromLTWH(500, 100, 280, 448),
        trigger: const Rect.fromLTWH(740, 560, 40, 40),
        avoidRects: [const Rect.fromLTWH(8, 64, 784, 230)],
        keepVisibleRect: const Rect.fromLTWH(8, 620, 784, 44),
      );
      expect(menu.height, greaterThanOrEqualTo(208));
      expect(menu.height, lessThan(448));
      expect(menu.bottom, lessThanOrEqualTo(612));
    },
  );

  test(
    'a blank column beside an image remains usable below its full-width header',
    () {
      const image = Rect.fromLTWH(40, 110, 440, 380);
      const details = Rect.fromLTWH(40, 530, 840, 60);
      const viewport = Rect.fromLTWH(8, 64, 984, 728);
      final menu = placeComposerMenu(
        viewport: viewport,
        preferred: const Rect.fromLTWH(40, 170, 280, 352),
        trigger: const Rect.fromLTWH(320, 730, 48, 48),
        avoidRects: [const Rect.fromLTWH(40, 70, 840, 32), image, details],
      );
      expect(menu.size, const Size(280, 352));
      expect(menu.overlaps(image), isFalse);
      expect(menu.overlaps(details), isFalse);
      expect(menu.left, greaterThanOrEqualTo(image.right + 8));
      expect(viewport.intersect(menu), menu);
    },
  );

  test(
    'crowded keyboard viewport preserves menu height and keeps it on screen',
    () {
      const viewport = Rect.fromLTWH(8, 32, 359, 310);
      final menu = placeComposerMenu(
        viewport: viewport,
        preferred: const Rect.fromLTWH(280, -100, 280, 448),
        trigger: const Rect.fromLTWH(310, 290, 48, 48),
        avoidRects: [viewport],
      );
      expect(menu.size, const Size(280, 310));
      expect(viewport.intersect(menu), menu);
    },
  );

  test('prefer the nearest free space when multiple columns are available', () {
    final menu = placeComposerMenu(
      viewport: const Rect.fromLTWH(8, 64, 1184, 720),
      preferred: const Rect.fromLTWH(840, 280, 280, 352),
      trigger: const Rect.fromLTWH(1120, 640, 48, 48),
      avoidRects: [const Rect.fromLTWH(350, 100, 400, 500)],
    );
    expect(menu, const Rect.fromLTWH(840, 280, 280, 352));
  });
}
