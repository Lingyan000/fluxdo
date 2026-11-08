import 'dart:io';
import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/message_bus/topic_tracking_providers.dart';
import 'package:fluxdo/providers/topic_list/filter_provider.dart';
import 'package:fluxdo/providers/topic_list/sort_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/widgets/topic/topic_filter_menu.dart';

class _Tracking extends TopicTrackingStateNotifier {
  @override
  Map<int, TrackedTopicState> build() => {};
}

void main() {
  testWidgets('首页标题式排序菜单展开、级联选择和取消后，bar 入口与箭头保持可见', (tester) async {
    const preview = String.fromEnvironment('MENU_ANCHOR_PREVIEW_DIR');
    final originalShadows = debugDisableShadows;
    if (preview.isNotEmpty) {
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = originalShadows);
      await (FontLoader(
        'MiSans',
      )..addFont(rootBundle.load('assets/fonts/MiSansVF.ttf'))).load();
      await (FontLoader(
            'packages/material_symbols_icons/${Symbols.sort_rounded.fontFamily}',
          )..addFont(
            rootBundle.load(
              'packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf',
            ),
          ))
          .load();
    }
    final screenKey = GlobalKey();
    var order = TopicSortOrder.defaultOrder;
    var calls = 0;
    await tester.pumpWidget(
      RepaintBoundary(
        key: screenKey,
        child: ProviderScope(
          overrides: [topicTrackingStateProvider.overrideWith(_Tracking.new)],
          child: TranslationProvider(
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(fontFamily: preview.isEmpty ? null : 'MiSans'),
              navigatorKey: navigatorKey,
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.only(top: 60, left: 16),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: StatefulBuilder(
                      builder: (context, update) => TopicFilterMenuButton(
                        titleStyle: true,
                        currentFilter: TopicListFilter.latest,
                        isLoggedIn: false,
                        onFilterChanged: (_) {},
                        currentSubset: NewSubset.all,
                        onSubsetChanged: (_) {},
                        currentOrder: order,
                        ascending: false,
                        onOrderChanged: (value) => update(() {
                          order = value;
                          calls++;
                        }),
                        onToggleAscending: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final entry = find.byType(TopicFilterMenuButton);
    final title = find.descendant(of: entry, matching: find.byType(Text)).first;
    final arrow = find.descendant(
      of: entry,
      matching: find.byType(AnimatedRotation),
    );

    Future<int> titlePixels([String? name]) async =>
        (await tester.runAsync(() async {
          final boundary =
              screenKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          try {
            if (preview.isNotEmpty && name != null) {
              final data = (await image.toByteData(
                format: ui.ImageByteFormat.png,
              ))!;
              await Directory(preview).create(recursive: true);
              await File('$preview/$name.png')
                  .writeAsBytes(data.buffer.asUint8List());
            }
            final pixels = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final rect = tester.getRect(title);
            var darkPixels = 0;
            for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
              for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
                final index = (y * image.width + x) * 4;
                if (pixels.getUint8(index) < 128 &&
                    pixels.getUint8(index + 1) < 128 &&
                    pixels.getUint8(index + 2) < 128) {
                  darkPixels++;
                }
              }
            }
            return darkPixels;
          } finally {
            image.dispose();
          }
        }))!;

    final restingPixels = await titlePixels('rest');
    expect(restingPixels, greaterThan(0));
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(await titlePixels('open'), greaterThanOrEqualTo(restingPixels));
    expect(tester.widget<AnimatedRotation>(arrow).turns, .5);
    await tester.tap(find.byType(ExpandablePopupMenuEntry<Object>));
    await tester.pumpAndSettle();
    expect(await titlePixels('submenu'), greaterThanOrEqualTo(restingPixels));
    await tester.tap(find.text(TopicSortOrder.likes.label));
    await tester.pump();
    expect(order, TopicSortOrder.likes);
    expect(calls, 1);
    expect(tester.widget<AnimatedRotation>(arrow).turns, 0);
    for (var elapsed = 0; elapsed <= 272; elapsed += 16) {
      expect(
        await titlePixels('close-${elapsed.toString().padLeft(3, '0')}'),
        greaterThan(0),
        reason: '收回 $elapsed ms 标题仍可见',
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(await titlePixels('selected'), restingPixels);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(700, 500));
    await tester.pump();
    for (var elapsed = 0; elapsed <= 240; elapsed += 16) {
      expect(
        await titlePixels('single-close-${elapsed.toString().padLeft(3, '0')}'),
        greaterThan(0),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(await titlePixels(), restingPixels);
    expect(tester.widget<AnimatedRotation>(arrow).turns, 0);
    expect(calls, 1);
    expect(tester.takeException(), isNull);
    debugDisableShadows = originalShadows;
  });
}
