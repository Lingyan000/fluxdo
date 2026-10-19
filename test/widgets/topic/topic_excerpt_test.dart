import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/topic_card_style.dart';
import 'package:fluxdo/pages/topic_card_style_settings_page.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/topic_excerpt_service.dart';
import 'package:fluxdo/utils/relative_time_clock.dart';
import 'package:fluxdo/widgets/topic/painted_topic_card.dart';
import 'package:fluxdo/widgets/common/cached_image.dart';
import 'package:fluxdo/widgets/topic/topic_expandable_excerpt.dart';
import 'package:fluxdo/widgets/topic/topic_item_builder.dart';
import 'package:fluxdo/widgets/topic/topic_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Discourse extends Fake implements DiscourseService {
  final pending = <int, Completer<String?>>{};

  @override
  Future<String?> getTopicFirstPostCooked(int id) {
    return (pending[id] = Completer<String?>()).future;
  }
}

class _CompletedDiscourse extends Fake implements DiscourseService {
  @override
  Future<String?> getTopicFirstPostCooked(int id) async =>
      '<p>缓存正文</p><img src="/uploads/cached.jpg">';
}

Topic _topic(int id, {String? excerpt, String? imageUrl}) => Topic(
  id: id,
  title: '话题 $id',
  slug: 'topic-$id',
  postsCount: 1,
  replyCount: 0,
  views: 0,
  likeCount: 0,
  categoryId: '1',
  excerpt: excerpt,
  imageUrl: imageUrl,
);

void main() {
  late SharedPreferences prefs;
  late _Discourse api;

  // 自绘排版缓存常驻订阅分钟心跳，使用真实时钟避免残留到单个测试的 fake timer。
  void keepClockAlive() {}
  setUpAll(() => RelativeTimeClock.instance.addListener(keepClockAlive));
  tearDownAll(() => RelativeTimeClock.instance.removeListener(keepClockAlive));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    api = _Discourse();
    TopicExcerptService().clear();
    TopicCardStyleScope.current = TopicCardStyle.defaults;
  });
  tearDown(() => TopicCardStyleScope.current = TopicCardStyle.defaults);

  Widget app(Widget child, {double scale = 1}) => ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      discourseServiceProvider.overrideWithValue(api),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: navigatorKey,
        locale: const Locale('zh'),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocaleUtils.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );

  Widget card({bool messageStyle = false}) => Builder(
    builder: (context) => buildTopicItem(
      context: context,
      topic: _topic(1, excerpt: '列表已有摘要'),
      isSelected: false,
      onTap: () {},
      enableLongPress: false,
      messageStyle: messageStyle,
      categoryMap: const {},
    ),
  );

  Future<void> revealSetting(WidgetTester tester, Finder setting) async {
    await tester.scrollUntilVisible(
      setting,
      200,
      scrollable: find
          .descendant(
            of: find.byType(TopicCardStyleSettingsPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('默认使用自绘卡，不展示正文、不请求首楼', (tester) async {
    await tester.pumpWidget(app(card()));
    await tester.pumpAndSettle();
    expect(find.byType(PaintedTopicCard), findsOneWidget);
    expect(find.byType(TopicExpandableExcerpt), findsNothing);
    expect(api.pending, isEmpty);
  });

  testWidgets('内容开关关闭时已有摘要、首图及正文缓存不改变卡片高度和点击', (tester) async {
    var taps = 0;
    Widget item(Topic topic, {Widget? middle}) => Builder(
      builder: (context) => buildTopicItem(
        context: context,
        topic: topic,
        isSelected: false,
        onTap: () => taps++,
        enableLongPress: false,
        categoryMap: const {},
        middleWidget: middle,
      ),
    );
    await tester.pumpWidget(app(item(_topic(1))));
    await tester.pumpAndSettle();
    final originalHeight = tester.getSize(find.byType(PaintedTopicCard)).height;
    await TopicExcerptService().getOrFetchExcerpt(
      1,
      service: _CompletedDiscourse(),
      allowFetch: true,
    );
    await tester.pumpWidget(
      app(
        item(
          _topic(
            1,
            excerpt: List.filled(100, '列表已有长摘要').join(' '),
            imageUrl: '/uploads/cover.jpg',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(PaintedTopicCard)).height,
      originalHeight,
    );
    expect(find.byType(TopicExpandableExcerpt), findsNothing);
    expect(find.byType(CachedImage), findsNothing);
    expect(api.pending, isEmpty);
    await tester.tap(find.byType(PaintedTopicCard));
    await tester.pump();
    expect(taps, 1);

    await tester.pumpWidget(app(item(_topic(1), middle: const Text('原有书签摘要'))));
    await tester.pumpAndSettle();
    expect(find.text('原有书签摘要'), findsOneWidget);
    expect(find.byType(TopicExpandableExcerpt), findsNothing);
    expect(api.pending, isEmpty);
  });

  testWidgets('直接使用卡片时关闭新开关不会自动插入正文', (tester) async {
    await tester.pumpWidget(
      app(
        TopicCard(
          topic: _topic(1, excerpt: '已有摘要', imageUrl: '/uploads/cover.jpg'),
          categoryMap: const {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TopicExpandableExcerpt), findsNothing);
    expect(find.text('已有摘要'), findsNothing);
    expect(api.pending, isEmpty);
  });

  testWidgets('只开启展示时使用列表摘要，不请求首楼', (tester) async {
    const style = TopicCardStyle(showExcerpt: true);
    await prefs.setString('pref_topic_card_style', style.toJsonString());
    TopicCardStyleScope.current = style;
    await tester.pumpWidget(app(card()));
    await tester.pumpAndSettle();
    expect(find.text('列表已有摘要'), findsOneWidget);
    expect(api.pending, isEmpty);
  });

  testWidgets('即使三个开关均开启，私信仍保持原布局且不请求首楼', (tester) async {
    const style = TopicCardStyle(
      showExcerpt: true,
      showImages: true,
      allowExcerptFetch: true,
    );
    await prefs.setString('pref_topic_card_style', style.toJsonString());
    TopicCardStyleScope.current = style;
    await tester.pumpWidget(app(card(messageStyle: true)));
    await tester.pumpAndSettle();
    expect(find.byType(PaintedTopicCard), findsOneWidget);
    expect(find.byType(TopicExpandableExcerpt), findsNothing);
    expect(api.pending, isEmpty);
  });

  testWidgets('系统大字体截断时仍显示展开入口并能展开', (tester) async {
    final text = List.filled(20, 'word').join(' ');
    await tester.pumpWidget(
      app(
        SizedBox(
          width: 260,
          child: TopicExpandableExcerpt(topic: _topic(1, excerpt: text)),
        ),
        scale: 2,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('查看更多'), findsOneWidget);
    await tester.tap(find.text('查看更多'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text(text)).maxLines, isNull);
    expect(find.text('收起'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('复用卡片时旧话题的慢响应不会覆盖新话题正文', (tester) async {
    Widget excerpt(int id) => TopicExpandableExcerpt(
      key: const ValueKey('reused-excerpt'),
      topic: _topic(id),
      allowFetch: true,
    );
    await tester.pumpWidget(app(excerpt(1)));
    await tester.pump();
    await tester.pumpWidget(app(excerpt(2)));
    await tester.pump();
    api.pending[2]!.complete('<p>新话题正文</p>');
    await tester.pumpAndSettle();
    api.pending[1]!.complete('<p>旧话题正文</p>');
    await tester.pumpAndSettle();
    expect(find.text('新话题正文'), findsOneWidget);
    expect(find.text('旧话题正文'), findsNothing);
  });

  testWidgets('摘要与图片开关互不影响，列表图片不请求首楼', (tester) async {
    final topic = _topic(1, excerpt: '列表摘要', imageUrl: '/uploads/cover.jpg');
    await tester.pumpWidget(app(TopicExpandableExcerpt(topic: topic)));
    await tester.pump();
    expect(find.text('列表摘要'), findsOneWidget);
    expect(find.byType(CachedImage), findsNothing);
    await tester.pumpWidget(
      app(
        TopicExpandableExcerpt(topic: topic, showText: false, showImages: true),
      ),
    );
    await tester.pump();
    expect(find.text('列表摘要'), findsNothing);
    expect(
      tester.widget<CachedImage>(find.byType(CachedImage)).url,
      endsWith('/uploads/cover.jpg'),
    );
    expect(api.pending, isEmpty);
  });

  testWidgets('仅显示图片时，额外请求仍把已有单图替换成多图', (tester) async {
    await tester.pumpWidget(
      app(
        TopicExpandableExcerpt(
          topic: _topic(1, excerpt: '不展示的摘要', imageUrl: '/uploads/cover.jpg'),
          showText: false,
          showImages: true,
          allowFetch: true,
        ),
      ),
    );
    await tester.pump();
    expect(api.pending, contains(1));
    api.pending[1]!.complete(
      '<p>仍不展示的正文</p><img src="/uploads/a.jpg"><img src="/uploads/b.jpg">',
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(CachedImage), findsNWidgets(2));
    expect(find.textContaining('不展示'), findsNothing);
  });

  testWidgets('仅允许额外请求而不显示内容时不会发请求', (tester) async {
    const style = TopicCardStyle(allowExcerptFetch: true);
    await prefs.setString('pref_topic_card_style', style.toJsonString());
    TopicCardStyleScope.current = style;
    await tester.pumpWidget(app(card()));
    await tester.pumpAndSettle();
    expect(find.byType(PaintedTopicCard), findsOneWidget);
    expect(api.pending, isEmpty);
  });

  testWidgets('折叠摘要压平段落空白，且无常驻复制栏', (tester) async {
    await tester.pumpWidget(
      app(
        TopicExpandableExcerpt(
          topic: _topic(1, excerpt: '<p>第一段</p><p>第二段</p>'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final text = tester.widget<Text>(find.text('第一段 第二段'));
    expect(text.maxLines, 3);
    expect(find.text('复制摘要'), findsNothing);
  });

  testWidgets('设置页三个开关始终可见且默认关闭', (tester) async {
    await tester.pumpWidget(
      app(const SizedBox(height: 500, child: TopicCardStyleSettingsPage())),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PaintedTopicCard), findsOneWidget);
    expect(find.byType(TopicExpandableExcerpt), findsNothing);
    for (final label in ['显示摘要', '显示图片', '允许额外请求']) {
      final toggle = find.widgetWithText(SwitchListTile, label);
      await revealSetting(tester, toggle);
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    }
    final display = find.widgetWithText(SwitchListTile, '显示摘要');
    await revealSetting(tester, display);
    await tester.pumpAndSettle();
    await tester.tap(display);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(display).value, isTrue);
    expect(
      tester
          .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '显示图片'))
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '允许额外请求'))
          .value,
      isFalse,
    );
    expect(api.pending, isEmpty);
  });

  testWidgets('额外请求经风险确认后才开启，取消或关闭弹窗保持关闭', (tester) async {
    await tester.pumpWidget(
      app(const SizedBox(height: 500, child: TopicCardStyleSettingsPage())),
    );
    await tester.pumpAndSettle();
    final toggle = find.widgetWithText(SwitchListTile, '允许额外请求');
    bool savedValue() =>
        TopicCardStyle.fromJsonString(prefs.getString('pref_topic_card_style'))
            .allowExcerptFetch;

    await revealSetting(tester, toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('开启额外请求？'), findsOneWidget);
    expect(find.textContaining('服务器负载'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(savedValue(), isFalse);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(savedValue(), isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(savedValue(), isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认开启'));
    await tester.pumpAndSettle();
    expect(savedValue(), isTrue);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(api.pending, isEmpty);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(savedValue(), isFalse);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('开启额外请求？'), findsOneWidget);
    expect(savedValue(), isFalse);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
  });
}
