import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/nested_topic.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/topic_reader_page/reader_preferences.dart';
import 'package:fluxdo/pages/topic_reader_page/topic_reader_page.dart';
import 'package:fluxdo/providers/nested_topic_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/nested/nested_post_card.dart';
import 'package:fluxdo/widgets/post/post_item/render_parse_cache.dart';
import 'package:fluxdo/widgets/post/small_action_item.dart' show PostTypes;
import 'package:fluxdo/widgets/topic/topic_card_layout.dart';
import 'package:fluxdo/widgets/user/activity_card_layout.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

Post _makePost({
  required int id,
  required int postNumber,
  required String cooked,
}) {
  final ts = DateTime.utc(2026, 5, 1, 9, 0);
  return Post(
    id: id,
    username: 'tester',
    name: '测试用户',
    avatarTemplate: '',
    cooked: cooked,
    postNumber: postNumber,
    postType: PostTypes.regular,
    createdAt: ts,
    updatedAt: ts,
    likeCount: 0,
    replyCount: 0,
  );
}

TopicDetail _makeDetail(List<Post> posts) {
  return TopicDetail(
    id: 9001,
    title: '性能回归测试话题',
    slug: 'perf-regression-topic',
    postsCount: posts.length,
    postStream: PostStream(
      posts: posts,
      stream: posts.map((p) => p.id).toList(),
    ),
    categoryId: 1,
    closed: false,
    archived: false,
    createdAt: DateTime.utc(2026, 5, 1, 9, 0),
    createdBy: TopicUser(
      id: 1,
      username: 'tester',
      name: '测试用户',
      avatarTemplate: '',
    ),
  );
}

Topic _makeTopic({
  required int id,
  required String title,
  required DateTime lastPostedAt,
}) {
  return Topic(
    id: id,
    title: title,
    slug: 'topic-$id',
    postsCount: 5,
    replyCount: 4,
    views: 100,
    likeCount: 3,
    lastPostedAt: lastPostedAt,
    categoryId: '1',
    pinned: false,
    visible: true,
    closed: false,
    archived: false,
    posters: const [],
  );
}

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    LocaleSettings.setLocale(AppLocale.zh);
    FlattenCache.evictAll();
    ParagraphLayoutCache.evictAll();
    ParagraphWarmupProbe.reset();
    RenderParseCache.clear();
    TopicCardLayout.evictAll();
  });

  testWidgets('创建 8 张紧凑活动卡后，原正文 24 段文字与话题卡缓存均不失效', (tester) async {
    final nodes = <BlockNode>[
      for (var i = 0; i < 24; i++)
        ParagraphNode(
          id: 'act_p_$i',
          inlines: [TextRun('活动卡对照组正文第 $i 段内容，检验主题对象稳定性。')],
        ),
    ];
    final topic = _makeTopic(
      id: 101,
      title: '测试话题卡缓存稳定性',
      lastPostedAt: DateTime.now().toUtc().subtract(const Duration(days: 3)),
    );

    var showActivities = false;
    var tick = 0;
    var seed = Colors.blue;
    late StateSetter setHostState;
    late BuildContext capturedContext;

    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          setHostState = setState;
          return TranslationProvider(
            child: MaterialApp(
              navigatorKey: navigatorKey,
              locale: const Locale('zh'),
              supportedLocales: AppLocaleUtils.supportedLocales,
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed)),
              themeAnimationDuration: Duration.zero,
              home: Scaffold(
                body: Builder(
                  builder: (ctx) {
                    capturedContext = ctx;
                    return SingleChildScrollView(
                      child: Column(
                        children: [
                          Text('tick=$tick'),
                          FluxdoRender(cookedHtml: '', parsedNodes: nodes),
                          if (showActivities)
                            SizedBox(
                              width: 360,
                              child: Column(
                                children: [
                                  for (var i = 0; i < 8; i++)
                                    ActivityCardFrame(
                                      position: (index: i, count: 8),
                                      child: Text('活动项 $i'),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );

    TopicCardLayout.obtain(
      identity: 'topic-${topic.id}',
      topic: topic,
      width: 360,
      theme: Theme.of(capturedContext),
      category: null,
      emojiUrlOf: (_) => '',
    );

    final layoutMissesBefore = ParagraphLayoutCache.misses;
    final topicCardBuildsBefore = TopicCardLayout.layoutBuildCount;

    setHostState(() {
      showActivities = true;
      tick++;
    });
    await tester.pump();

    setHostState(() {
      tick++;
    });
    await tester.pump();

    TopicCardLayout.obtain(
      identity: 'topic-${topic.id}',
      topic: topic,
      width: 360,
      theme: Theme.of(capturedContext),
      category: null,
      emojiUrlOf: (_) => '',
    );

    expect(
      ParagraphLayoutCache.misses,
      layoutMissesBefore,
      reason: '紧凑活动卡不应破坏正文文字布局缓存',
    );
    expect(
      TopicCardLayout.layoutBuildCount,
      topicCardBuildsBefore,
      reason: '紧凑活动卡不应导致话题卡重新排版',
    );

    // 真实改变主题颜色时，话题卡应按新主题重新排版
    setHostState(() {
      seed = Colors.green;
      tick++;
    });
    await tester.pump();

    TopicCardLayout.obtain(
      identity: 'topic-${topic.id}',
      topic: topic,
      width: 360,
      theme: Theme.of(capturedContext),
      category: null,
      emojiUrlOf: (_) => '',
    );
    expect(
      TopicCardLayout.layoutBuildCount,
      greaterThan(topicCardBuildsBefore),
      reason: '真实切换主题颜色后话题卡必须重排以使用新颜色',
    );
  });

  testWidgets('楼中楼 NestedPostCard 卸载重挂复用解析与文字布局缓存，编辑后及时更新', (tester) async {
    final cooked24 = [
      for (var i = 0; i < 24; i++) '<p>楼中楼正文第 $i 段，用于验证滑出回收再滑回的缓存命中。</p>',
    ].join();
    final post = _makePost(id: 501, postNumber: 2, cooked: cooked24);
    final detail = _makeDetail([post]);
    final nestedParams = NestedTopicParams(topicId: detail.id);

    Widget buildCard(Post targetPost, {required bool visible}) {
      return ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          nestedTopicProvider(nestedParams).overrideWith(
            () => _FakeNestedTopicNotifier(nestedParams),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            locale: const Locale('zh'),
            supportedLocales: AppLocaleUtils.supportedLocales,
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Scaffold(
              body: visible
                  ? SingleChildScrollView(
                      child: NestedPostCard(
                        node: NestedNode(post: targetPost),
                        topicId: detail.id,
                        detail: detail,
                        params: nestedParams,
                        depth: 0,
                        isLastChild: true,
                        isLoggedIn: false,
                        blockedUsernames: const {},
                        onReply: (_, {initialContent}) {},
                        onEdit: (_) {},
                        onRefreshPost: (_) {},
                        onJumpToPost: (_) {},
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildCard(post, visible: true));
    await tester.pump();
    final layoutMissesAfterFirstMount = ParagraphLayoutCache.misses;
    expect(layoutMissesAfterFirstMount, greaterThanOrEqualTo(24));

    // 卸载模拟滑出 cacheExtent
    await tester.pumpWidget(buildCard(post, visible: false));
    await tester.pump();

    // 重新挂载模拟滑回视口
    await tester.pumpWidget(buildCard(post, visible: true));
    await tester.pump();
    expect(
      ParagraphLayoutCache.misses,
      layoutMissesAfterFirstMount,
      reason: '楼中楼滑回重挂应命中 RenderParseCache 与 ParagraphLayoutCache，不再重排',
    );

    // 编辑正文后必须失效并重新排版
    final editedPost = _makePost(
      id: 501,
      postNumber: 2,
      cooked: '<p>已编辑的新楼中楼正文内容</p>',
    );
    await tester.pumpWidget(buildCard(editedPost, visible: true));
    await tester.pump();
    expect(
      ParagraphLayoutCache.misses,
      greaterThan(layoutMissesAfterFirstMount),
      reason: '编辑楼中楼正文后必须更新解析与排版',
    );
  });

  testWidgets('话题卡分钟刷新在时间文案不变时跳过重排', (tester) async {
    late BuildContext capturedContext;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          locale: const Locale('zh'),
          supportedLocales: AppLocaleUtils.supportedLocales,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Builder(
            builder: (ctx) {
              capturedContext = ctx;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    final oldTopic = _makeTopic(
      id: 202,
      title: '三天前的老话题',
      lastPostedAt: DateTime.now().toUtc().subtract(const Duration(days: 3)),
    );

    final layout = TopicCardLayout.obtain(
      identity: 'old-topic',
      topic: oldTopic,
      width: 360,
      theme: Theme.of(capturedContext),
      category: null,
      emojiUrlOf: (_) => '',
    );

    final buildsBefore = TopicCardLayout.layoutBuildCount;
    final revBefore = layout.revision;

    final updated = layout.refreshTime();
    expect(updated, isFalse, reason: '相对时间文案未变时应跳过重排');
    expect(TopicCardLayout.layoutBuildCount, buildsBefore);
    expect(layout.revision, revBefore);
  });

  testWidgets('阅读页开启纸张配色与独立字体后，滚动触发 80ms 进度更新不重排已有正文', (tester) async {
    tester.view.physicalSize = const Size(420, 840);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final cooked = [
      '<h2>第一节 阅读性能验证</h2>',
      for (var i = 0; i < 40; i++)
        '<p>阅读页正文第 $i 段，确保内容足够长以便触发滚动进度变化与 80ms 节流刷新。</p>',
    ].join();
    final detail = _makeDetail([
      _makePost(id: 701, postNumber: 1, cooked: cooked),
    ]);

    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: Consumer(
          builder: (context, ref, child) {
            container = ProviderScope.containerOf(context);
            return child!;
          },
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: navigatorKey,
              locale: const Locale('zh'),
              theme: ThemeData(brightness: Brightness.light),
              supportedLocales: AppLocaleUtils.supportedLocales,
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: TopicReaderPage(initialDetail: detail),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 启用护眼绿纸张配色与独立系统阅读字体
    final notifier = container.read(readerPreferencesProvider.notifier);
    notifier.setPaperTheme(ReaderPaperTheme.green);
    notifier.setFontChoice(FontChoice.system);
    await tester.pumpAndSettle();

    final flattenMissesBefore = FlattenCache.misses;
    final layoutMissesBefore = ParagraphLayoutCache.misses;

    // 滚动触发 80ms 进度与标题追踪刷新
    final scrollable = find.byType(Scrollable).first;
    await tester.drag(scrollable, const Offset(0, -180));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      FlattenCache.misses,
      flattenMissesBefore,
      reason: '阅读页仅更新滚动进度时不应重建主题导致 FlattenCache 失效',
    );
    expect(
      ParagraphLayoutCache.misses,
      layoutMissesBefore,
      reason: '阅读页仅更新滚动进度时不应重排已有正文段落',
    );
  });

  testWidgets('阅读页长文分块滚动停稳后按设备 DPR 预热前方 chunk 的排版与字形', (tester) async {
    tester.view.physicalSize = const Size(1260, 2520);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      GlyphPrebaker.resetStatsForTesting();
    });
    GlyphPrebaker.resetStatsForTesting();
    GlyphPrebaker.debugImageRunner = (_, _, _) async {};

    // 生成超过分块阈值的长文（多个 chunk）
    final cooked = [
      for (var i = 0; i < 90; i++)
        '<p>长文分块预热测试第 $i 段，这是一段长度充足的中文测试正文，用于触发长文分块并验证滚动停稳后前方 chunk 的空闲排版与按 DPR 缩放的字形预烤。</p>',
    ].join();
    final detail = _makeDetail([
      _makePost(id: 702, postNumber: 1, cooked: cooked),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            locale: const Locale('zh'),
            theme: ThemeData(brightness: Brightness.light),
            supportedLocales: AppLocaleUtils.supportedLocales,
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: TopicReaderPage(initialDetail: detail),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final bakedBefore = GlyphPrebaker.bakedParagraphs;

    // 拖动并停稳，触发 ScrollEndNotification 后的空闲分块预热
    final scrollable = find.byType(Scrollable).first;
    await tester.drag(scrollable, const Offset(0, -160));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      GlyphPrebaker.bakedParagraphs,
      greaterThan(bakedBefore),
      reason: '阅读页长文滚动停稳后应预热前方未缓存分块并触发字形预烤',
    );
    expect(
      GlyphPrebaker.lastBakedDpr,
      3.0,
      reason: '阅读页字形预烤应使用当前 3.0x 设备像素比',
    );
  });
}

class _FakeNestedTopicNotifier extends NestedTopicNotifier {
  _FakeNestedTopicNotifier(super.params);

  @override
  Future<NestedTopicState> build() async => const NestedTopicState();
}
