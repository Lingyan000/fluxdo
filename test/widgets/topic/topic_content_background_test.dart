import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_detail_header.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/widgets/post/post_item/widgets/post_segment_frame.dart';
import 'package:fluxdo/widgets/post/post_item_skeleton.dart';
import 'package:fluxdo/widgets/topic/painted_topic_card.dart';
import 'package:fluxdo/widgets/topic/pinned_topics_header.dart';
import 'package:fluxdo/widgets/topic/topic_card.dart';
import 'package:fluxdo/widgets/topic/topic_card_layout.dart';
import 'package:fluxdo/widgets/topic/topic_item_builder.dart';
import 'package:fluxdo/widgets/topic/topic_list_skeleton.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _wallpaper = Color(0xff287856);

final _topic = Topic(
  id: 42,
  title: 'Topic background',
  slug: 'background',
  postsCount: 2,
  replyCount: 1,
  views: 10,
  likeCount: 0,
  categoryId: '1',
);

Post _post({bool hidden = false, bool deleted = false}) => Post.fromJson({
  'id': 1,
  'post_number': 1,
  'username': 'tester',
  'avatar_template': '',
  'created_at': '2026-11-11T00:00:00Z',
  'cooked': '<p>Content</p>',
  'hidden': hidden,
  'deleted_at': deleted ? '2026-11-11T01:00:00Z' : null,
});

Future<Color> _pixel(WidgetTester tester, GlobalKey key, Offset point) async =>
    (await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final offset = (point.dy.toInt() * image.width + point.dx.toInt()) * 4;
        return Color.fromARGB(
          bytes.getUint8(offset + 3),
          bytes.getUint8(offset),
          bytes.getUint8(offset + 1),
          bytes.getUint8(offset + 2),
        );
      } finally {
        image.dispose();
      }
    }))!;

void main() {
  late SharedPreferences prefs;
  late ValueNotifier<bool> background;
  late GlobalKey pixels;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    background = ValueNotifier(false);
    pixels = GlobalKey();
    TopicCardLayout.evictAll();
    LocaleSettings.setLocale(AppLocale.zh);
  });

  tearDown(() {
    background.dispose();
    TopicCardLayout.evictAll();
  });

  Future<void> mount(
    WidgetTester tester,
    ThemeData theme,
    WidgetBuilder builder,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          categoryMapProvider.overrideWith(
            (ref) => const AsyncValue.data(<int, Category>{}),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            theme: theme,
            locale: const Locale('zh'),
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (_, child) => ValueListenableBuilder(
              valueListenable: background,
              builder: (_, enabled, _) => PageBackgroundScope(
                backgroundBuilder: enabled
                    ? (_) => const ColoredBox(color: _wallpaper)
                    : null,
                child: child!,
              ),
            ),
            home: RepaintBoundary(
              key: pixels,
              child: RoutePageBackground(
                child: Scaffold(
                  backgroundColor: Colors.transparent,
                  body: Align(
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      width: 360,
                      child: Builder(builder: builder),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  for (final brightness in Brightness.values) {
    final theme = ThemeData(
      brightness: brightness,
      cardTheme: CardThemeData(
        color: brightness == Brightness.light ? Colors.white : Colors.black,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
    );

    for (final style in TopicItemStyle.values) {
      testWidgets('话题卡随背景开关更新且复用自绘排版 $style $brightness', (tester) async {
        await mount(
          tester,
          theme,
          (context) => buildTopicItem(
            context: context,
            topic: _topic,
            style: style,
            isSelected: false,
            enableLongPress: false,
            onTap: () {},
            categoryMap: const {},
          ),
        );
        final plainPixel = await _pixel(tester, pixels, const Offset(200, 4));
        final painted = find.byType(PaintedTopicCard);
        final layout = painted.evaluate().isEmpty
            ? null
            : tester.widget<PaintedTopicCard>(painted).layout;

        background.value = true;
        await tester.pump();
        expect(await _pixel(tester, pixels, const Offset(200, 4)), _wallpaper);
        if (layout != null) {
          expect(tester.widget<PaintedTopicCard>(painted).layout, same(layout));
        }
        background.value = false;
        await tester.pump();
        expect(await _pixel(tester, pixels, const Offset(200, 4)), plainPixel);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('组件话题卡、置顶入口和详情头部透出背景 $brightness', (tester) async {
      background.value = true;
      await mount(
        tester,
        theme,
        (context) => Column(
          children: [
            buildTopicItem(
              context: context,
              topic: _topic,
              isSelected: false,
              enableLongPress: false,
              onTap: () {},
              middleWidget: const SizedBox(height: 1),
              categoryMap: const {},
            ),
            PinnedTopicsHeader(
              count: 2,
              unreadCount: 0,
              expanded: true,
              markingRead: false,
              onToggle: () {},
            ),
            TopicDetailHeader(
              detail: TopicDetail.fromJson({
                'id': 42,
                'title': 'Details',
                'posts_count': 2,
                'post_stream': {
                  'posts': [],
                  'stream': [1, 2],
                },
              }),
            ),
            const TopicDetailHeaderSkeleton(),
          ],
        ),
      );
      for (final type in [
        TopicCard,
        PinnedTopicsHeader,
        TopicDetailHeader,
        TopicDetailHeaderSkeleton,
      ]) {
        final top = tester.getTopLeft(find.byType(type));
        expect(
          await _pixel(tester, pixels, Offset(200, top.dy + 4)),
          _wallpaper,
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('帖子背景与高亮叠层各自生效 $brightness', (tester) async {
      background.value = true;
      await mount(
        tester,
        theme,
        (_) => Column(
          children: [
            for (final highlight in [false, true])
              PostSegmentFrame(
                post: _post(),
                selected: true,
                highlight: highlight,
                showTopDateSeparator: true,
                topDateSeparatorLabel: '11/11',
                child: const SizedBox(width: double.infinity, height: 100),
              ),
          ],
        ),
      );
      expect(await _pixel(tester, pixels, const Offset(200, 50)), _wallpaper);
      final highlighted = await _pixel(tester, pixels, const Offset(200, 150));
      final expected = Color.alphaBlend(
        theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
        _wallpaper,
      );
      expect(highlighted.r, closeTo(expected.r, 1 / 255));
      expect(highlighted.g, closeTo(expected.g, 1 / 255));
      expect(highlighted.b, closeTo(expected.b, 1 / 255));
      expect(
        await _pixel(tester, pixels, const Offset(21, 50)),
        theme.colorScheme.primary,
      );
      background.value = false;
      await tester.pump();
      expect(
        await _pixel(tester, pixels, const Offset(200, 50)),
        theme.colorScheme.surface,
      );
      expect(tester.takeException(), isNull);
    });

    for (final messageStyle in [false, true]) {
      testWidgets('话题骨架卡透出背景 $messageStyle $brightness', (tester) async {
        background.value = true;
        await mount(
          tester,
          theme,
          (_) => SizedBox(
            height: 400,
            child: TopicListSkeleton(messageStyle: messageStyle),
          ),
        );
        final top = tester.getTopLeft(find.byType(Card).first);
        expect(
          await _pixel(tester, pixels, Offset(200, top.dy + 4)),
          _wallpaper,
        );
        expect(tester.takeException(), isNull);
      });
    }

    test('删除和隐藏帖保留语义底色 $brightness', () {
      expect(
        buildPostTargetColor(
          theme,
          _post(deleted: true),
          false,
          backgroundColor: Colors.transparent,
        ),
        theme.colorScheme.errorContainer.withValues(alpha: 0.15),
      );
      expect(
        buildPostTargetColor(
          theme,
          _post(hidden: true),
          false,
          backgroundColor: Colors.transparent,
        ),
        theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      );
    });
  }
}
