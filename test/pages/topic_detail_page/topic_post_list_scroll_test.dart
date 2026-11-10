import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/message_bus_providers.dart';
import 'package:fluxdo/pages/topic_detail_page/controllers/topic_detail_controller.dart';
import 'package:fluxdo/pages/topic_detail_page/controllers/topic_toc_controller.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_post_list.dart';
import 'package:fluxdo/widgets/common/positioned_stream_list.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/screen_track.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestTopicChannel extends TopicChannelNotifier {
  _TestTopicChannel() : super(42);

  @override
  TopicChannelState build() => const TopicChannelState();

  void setTyping(bool typing) {
    state = state.copyWith(
      typingUsers: typing
          ? const [TypingUser(id: 1, username: 'tester', avatarTemplate: '')]
          : const [],
    );
  }
}

Post post(int number, {String? cooked}) => Post.fromJson({
  'id': number,
  'post_number': number,
  'username': 'tester',
  'avatar_template': '',
  'created_at': '2026-11-01T00:00:00Z',
  'updated_at': '2026-11-01T00:00:00Z',
  'cooked': cooked ?? '<p>Content for floor $number.</p>',
});

TopicDetail topic(List<Post> posts, {PostStreamGaps? gaps}) =>
    TopicDetail.fromJson({
      'id': 42,
      'title': 'Scroll regression',
      'posts_count': 120,
      'post_stream': {
        'posts': [],
        'stream': [for (var i = 1; i <= 120; i++) i],
      },
    }).copyWith(
      postStream: PostStream(
        posts: posts,
        stream: [for (var i = 1; i <= 120; i++) i],
        gaps: gaps,
      ),
    );

void main() {
  late TopicDetailController controller;
  late TopicTocController toc;
  late ValueNotifier<TopicDetail> details;
  late ValueNotifier<bool> loading;
  late ValueNotifier<bool> failed;
  late SharedPreferences prefs;
  final headerKey = GlobalKey();
  final reported = <int>[];
  var layoutChanges = 0;
  var initialFloor = 60;
  var hasMoreBefore = true;
  var hasMoreAfter = true;
  var retryCount = 0;
  var textScale = 1.0;
  Set<int> visiblePosts = {};

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    LocaleSettings.setLocale(AppLocale.zh);
    details = ValueNotifier(topic([for (var i = 40; i < 100; i++) post(i)]));
    loading = ValueNotifier(false);
    failed = ValueNotifier(false);
    controller = TopicDetailController(
      scrollController: AutoScrollController(),
      screenTrack: ScreenTrack(DiscourseService()),
      trackEnabled: false,
    );
    toc = TopicTocController(detailController: controller);
    reported.clear();
    layoutChanges = 0;
    initialFloor = 60;
    hasMoreBefore = true;
    hasMoreAfter = true;
    retryCount = 0;
    textScale = 1;
    visiblePosts = {};
  });

  tearDown(() {
    toc.dispose();
    controller.dispose();
    details.dispose();
    loading.dispose();
    failed.dispose();
  });

  Widget app() => ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      categoryMapProvider.overrideWith(
        (ref) => const AsyncValue.data(<int, Category>{}),
      ),
      topicChannelProvider(42).overrideWith(_TestTopicChannel.new),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: navigatorKey,
        locale: const Locale('zh'),
        supportedLocales: AppLocaleUtils.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: ValueListenableBuilder<TopicDetail>(
            valueListenable: details,
            builder: (context, detail, _) => TopicPostList(
              detail: detail,
              scrollController: controller.scrollController,
              listController: controller.postListController,
              positionRevision: controller.positionRevision,
              headingAnchorRegistry: toc.registry,
              headerKey: headerKey,
              selectedPostNumber: null,
              highlightPostNumber: null,
              isLoggedIn: false,
              hasMoreBefore: hasMoreBefore,
              hasMoreAfter: hasMoreAfter,
              loadingPreviousListenable: loading,
              loadingMoreListenable: loading,
              loadMoreFailedListenable: failed,
              loadPreviousFailedListenable: failed,
              onRetryLoadMore: () => retryCount++,
              onRetryLoadPrevious: () => retryCount++,
              initialPostIndex: detail.postStream.posts.indexWhere(
                (p) => p.postNumber == initialFloor,
              ),
              dividerPostIndex: null,
              onFirstVisiblePostChanged: reported.add,
              onVisiblePostsChanged: (posts) => visiblePosts = posts,
              onScrollIndexMappingChanged: (mapping) => controller
                  .updateScrollIndexMapping(mapping, detail.postStream.posts),
              onScrollIndexToPostNumberChanged:
                  controller.updateScrollIndexToPostNumber,
              onPostSegmentRangesChanged: controller.updatePostSegmentRanges,
              onJumpToPost: (_) {},
              onReply: (_, {initialContent}) {},
              onEdit: (_) {},
              onRefreshPost: (_) {},
              onVoteChanged: (_, _) {},
              onScrollNotification: (_) => false,
              onLayoutChanged: () => layoutChanges++,
            ),
          ),
        ),
      ),
    ),
  );

  Finder floor(int number) => find.byWidgetPredicate(
    (widget) =>
        widget is AutoScrollTag && widget.key == ValueKey('post-$number'),
  );

  Future<void> disposeList(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  }

  Future<void> jumpToFloor(WidgetTester tester, int number) async {
    final done = controller.scrollToPost(
      number,
      details.value.postStream.posts,
    );
    await tester.pumpAndSettle();
    expect(await done, isTrue);
  }

  testWidgets('真实帖子从中间定位并分页，首帧保位且继续按楼层号跳转', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(floor(60)).dy, closeTo(0, 0.5));
    final before = tester.getTopLeft(floor(60)).dy;
    details.value = topic([
      for (var i = 20; i < 40; i++) post(i),
      ...details.value.postStream.posts,
    ]);
    await tester.pump();
    expect(tester.getTopLeft(floor(60)).dy, closeTo(before, 0.5));
    final changesBeforeJump = layoutChanges;
    final jump = controller.scrollToPost(85, details.value.postStream.posts);
    await tester.pumpAndSettle();
    expect(await jump, isTrue);
    expect(tester.getTopLeft(floor(85)).dy, closeTo(0, 0.5));
    expect(reported, isNotEmpty);
    expect(layoutChanges, greaterThan(changesBeforeJump));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  });

  testWidgets('拖动中分页下一帧显示，并保持位置和后续拖动', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(const Offset(400, 300));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(
      controller.scrollController.position.isScrollingNotifier.value,
      isTrue,
    );
    final before = tester.getTopLeft(floor(60)).dy;
    details.value = topic([
      for (var i = 20; i < 40; i++) post(i),
      ...details.value.postStream.posts,
    ]);
    await tester.pump();
    expect(
      tester
          .widget<PositionedStreamList>(find.byType(PositionedStreamList))
          .itemKeys,
      contains('post-20'),
    );
    expect(tester.getTopLeft(floor(60)).dy, closeTo(before, 0.5));
    expect(
      controller.scrollController.position.isScrollingNotifier.value,
      isTrue,
    );
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(tester.getTopLeft(floor(60)).dy, closeTo(before - 40, 0.5));
    await tester.pump(const Duration(seconds: 1));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PositionedStreamList>(find.byType(PositionedStreamList))
          .itemKeys,
      contains('post-20'),
    );
    expect(tester.getTopLeft(floor(60)).dy, closeTo(before - 40, 0.5));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  });

  testWidgets('上方短帖更新成长帖分块后仍保留阅读楼层', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(floor(60)).dy;
    final longHtml = List.generate(
      100,
      (i) =>
          '<p>Expanded paragraph $i with additional content for height changes.</p>',
    ).join();
    details.value = topic([
      for (final item in details.value.postStream.posts)
        item.postNumber == 59 ? post(59, cooked: longHtml) : item,
    ]);
    await tester.pump();
    expect(tester.getTopLeft(floor(60)).dy, closeTo(before, 0.5));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(floor(60)).dy, closeTo(before, 0.5));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  });

  testWidgets('拖动到底部时分页结果下一帧进入视口', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final jump = controller.scrollToPost(99, details.value.postStream.posts);
    await tester.pumpAndSettle();
    await jump;
    final gesture = await tester.startGesture(const Offset(400, 300));
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    details.value = topic([...details.value.postStream.posts, post(100)]);
    await tester.pump();
    expect(floor(100), findsOneWidget);
    expect(tester.getTopLeft(floor(100)).dy, lessThan(600));
    expect(tester.getBottomLeft(floor(100)).dy, greaterThan(0));
    expect(
      controller.scrollController.position.isScrollingNotifier.value,
      isTrue,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  });

  testWidgets('长帖内按分块索引精确定位', (tester) async {
    final longHtml = List.generate(
      100,
      (i) =>
          '<p>Paragraph $i with enough content to split this post into multiple chunks.</p>',
    ).join();
    details.value = topic([
      for (final item in details.value.postStream.posts)
        item.postNumber == 60 ? post(60, cooked: longHtml) : item,
    ]);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final done = controller.scrollToPostChunk(
      60,
      1,
      details.value.postStream.posts,
    );
    await tester.pumpAndSettle();
    expect(await done, isTrue);
    final chunk = find.byWidgetPredicate(
      (widget) =>
          widget is AutoScrollTag &&
          widget.key == const ValueKey('long-chunk-60-1'),
    );
    expect(tester.getTopLeft(chunk).dy, closeTo(0, 0.5));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  });

  testWidgets('空窗口收到首批帖子后按目标楼层定位', (tester) async {
    details.value = topic([]);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    details.value = topic([for (var i = 40; i < 100; i++) post(i)]);
    await tester.pump();
    expect(tester.getTopLeft(floor(60)).dy, closeTo(0, 0.5));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  });

  testWidgets('目录跨远距离跳转到长帖内部标题', (tester) async {
    final html = List.generate(
      5,
      (section) =>
          '<h2><a name="section-$section" class="anchor" href="#section-$section"></a>Section $section</h2>'
          '${List.generate(40, (i) => '<p>Paragraph $i for section $section with enough text to form a long post.</p>').join()}',
    ).join();
    details.value = topic([
      post(1, cooked: html),
      for (var i = 2; i < 100; i++) post(i),
    ]);
    toc.updateTopic(details.value);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final entry = toc.tocData!.flat[3];
    final done = toc.scrollToHeading(entry, details.value.postStream.posts);
    await tester.pumpAndSettle();
    await done;
    final target = toc.registry.contextOf(entry.anchorKey)!;
    final box = target.findRenderObject()! as RenderBox;
    expect(box.localToGlobal(Offset.zero).dy, closeTo(12, 0.5));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  });

  testWidgets('从首楼进入显示话题标题，回到顶部恢复标题', (tester) async {
    initialFloor = 1;
    hasMoreBefore = false;
    details.value = topic([for (var i = 1; i < 100; i++) post(i)]);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(headerKey.currentContext, isNotNull);
    expect(controller.scrollController.offset, closeTo(0, 0.5));
    expect(tester.getTopLeft(floor(1)).dy, greaterThan(0));
    await jumpToFloor(tester, 85);
    final done = controller.scrollToTop();
    await tester.pumpAndSettle();
    await done;
    expect(controller.scrollController.offset, closeTo(0, 0.5));
    expect(headerKey.currentContext, isNotNull);
    await disposeList(tester);
  });

  testWidgets('从尾部进入且到底后新回复可见', (tester) async {
    initialFloor = 99;
    hasMoreAfter = false;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(floor(99)).dy, lessThanOrEqualTo(600));
    expect(reported.last, 99);
    details.value = topic([...details.value.postStream.posts, post(100)]);
    await tester.pump();
    await jumpToFloor(tester, 100);
    expect(tester.getTopLeft(floor(100)).dy, lessThan(600));
    expect(reported.last, 100);
    expect(visiblePosts, contains(100));
    await disposeList(tester);
  });

  testWidgets('单帖短话题和空话题能布局并恢复数据', (tester) async {
    initialFloor = 1;
    hasMoreBefore = false;
    hasMoreAfter = false;
    details.value = topic([post(1)]);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(floor(1), findsOneWidget);
    expect(
      await controller.scrollToPost(99, details.value.postStream.posts),
      isFalse,
    );
    details.value = topic([]);
    await tester.pumpAndSettle();
    expect(floor(1), findsNothing);
    details.value = topic([post(1)]);
    await tester.pumpAndSettle();
    expect(floor(1), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposeList(tester);
  });

  testWidgets('筛选后的不连续楼层定位，取消筛选后映射更新', (tester) async {
    details.value = topic([for (var i = 10; i < 100; i += 5) post(i)]);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await jumpToFloor(tester, 75);
    expect(tester.getTopLeft(floor(75)).dy, closeTo(0, 0.5));
    expect(reported.last, 75);
    details.value = topic([for (var i = 1; i < 100; i++) post(i)]);
    await tester.pump();
    expect(tester.getTopLeft(floor(75)).dy, closeTo(0, 0.5));
    await jumpToFloor(tester, 45);
    expect(tester.getTopLeft(floor(45)).dy, closeTo(0, 0.5));
    await disposeList(tester);
  });

  testWidgets('补齐隐藏楼层后保位并按正确索引跳转', (tester) async {
    details.value = topic(
      [
        post(40),
        ...[for (var i = 60; i < 100; i++) post(i)],
      ],
      gaps: const PostStreamGaps(
        before: {
          60: [41, 42, 43],
        },
      ),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(floor(60)).dy, closeTo(0, 0.5));
    details.value = topic([for (var i = 40; i < 100; i++) post(i)]);
    await tester.pump();
    expect(tester.getTopLeft(floor(60)).dy, closeTo(0, 0.5));
    await jumpToFloor(tester, 55);
    expect(tester.getTopLeft(floor(55)).dy, closeTo(0, 0.5));
    await disposeList(tester);
  });

  testWidgets('加载失败提示与重试不会推走当前阅读楼层', (tester) async {
    initialFloor = 40;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final positioned = controller.postListController.jumpToIndex(
      2,
      offset: -30,
    );
    await tester.pumpAndSettle();
    await positioned;
    final before = tester.getTopLeft(floor(40)).dy;
    loading.value = true;
    await tester.pump();
    expect(tester.getTopLeft(floor(40)).dy, closeTo(before, 0.5));
    loading.value = false;
    failed.value = true;
    await tester.pump();
    expect(tester.getTopLeft(floor(40)).dy, closeTo(before, 0.5));
    controller.scrollController.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.current.topicDetail_loadFailedTapRetry).first);
    expect(retryCount, 1);
    failed.value = false;
    details.value = topic([for (var i = 20; i < 100; i++) post(i)]);
    await tester.pumpAndSettle();
    await jumpToFloor(tester, 60);
    expect(reported.last, 60);
    await disposeList(tester);
  });

  testWidgets('刷新及未加载目标换窗后首帧准确定位', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    controller.prepareJumpToPost(110);
    controller.markInitialScrolled(110);
    initialFloor = controller.initialPostNumber!;
    details.value = topic([for (var i = 100; i <= 120; i++) post(i)]);
    await tester.pump();
    expect(tester.getTopLeft(floor(110)).dy, closeTo(0, 0.5));
    controller.prepareRefresh(105);
    controller.markInitialScrolled(105);
    initialFloor = controller.initialPostNumber!;
    details.value = topic([for (var i = 95; i <= 120; i++) post(i)]);
    await tester.pump();
    expect(tester.getTopLeft(floor(105)).dy, closeTo(0, 0.5));
    await disposeList(tester);
  });

  testWidgets('真实折叠块展开和收起的每帧标题保持原位', (tester) async {
    details.value = topic([
      for (final item in details.value.postStream.posts)
        item.postNumber == 60
            ? post(
                60,
                cooked:
                    '<details><summary>展开测试内容</summary>'
                    '<p>${'折叠内容。' * 100}</p></details>',
              )
            : item,
    ]);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final summary = find.text('展开测试内容');
    expect(summary, findsOneWidget);
    final before = tester.getTopLeft(summary).dy;
    for (var toggle = 0; toggle < 2; toggle++) {
      await tester.tap(summary);
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getTopLeft(summary).dy, closeTo(before, 0.5));
      }
    }
    await disposeList(tester);
  });

  testWidgets('字号变化后阅读楼层保持，桌面滚轮继续滚动', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    textScale = 1.4;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(floor(60)).dy, closeTo(0, 0.5));
    final before = controller.scrollController.offset;
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(400, 300),
        scrollDelta: Offset(0, 120),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.scrollController.offset, greaterThan(before));
    expect(visiblePosts, isNotEmpty);
    await disposeList(tester);
  });

  testWidgets('跳楼与向上分页同帧发生时跳楼目标优先', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final done = controller.scrollToPost(85, details.value.postStream.posts);
    details.value = topic([for (var i = 20; i < 100; i++) post(i)]);
    await tester.pumpAndSettle();
    expect(await done, isTrue);
    expect(tester.getTopLeft(floor(85)).dy, closeTo(0, 0.5));
    await disposeList(tester);
  });

  testWidgets('覆盖页面期间新增帖子，返回后阅读位置保持', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await jumpToFloor(tester, 75);
    final before = tester.getTopLeft(floor(75)).dy;
    final route = navigatorKey.currentState!.push<void>(
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('覆盖页面'))),
    );
    await tester.pumpAndSettle();
    details.value = topic([for (var i = 20; i <= 100; i++) post(i)]);
    await tester.pump();
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    await route;
    expect(tester.getTopLeft(floor(75)).dy, closeTo(before, 0.5));
    await disposeList(tester);
  });

  testWidgets('阅读中的短帖编辑成长帖后仍停在同一楼层', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    details.value = topic([
      for (final item in details.value.postStream.posts)
        item.postNumber == 60
            ? post(
                60,
                cooked: List.generate(
                  100,
                  (i) =>
                      '<p>Expanded paragraph $i with enough text for segmentation.</p>',
                ).join(),
              )
            : item,
    ]);
    await tester.pump();
    final tag = find.byWidgetPredicate(
      (widget) =>
          widget is AutoScrollTag &&
          controller.postNumberForScrollIndex(widget.index) == 60,
    );
    expect(tag, findsWidgets);
    expect(tester.getTopLeft(tag.first).dy, closeTo(0, 0.5));
    await disposeList(tester);
  });

  testWidgets('快速连续跳楼及取消目标能完成各自的请求', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final first = controller.scrollToPost(45, details.value.postStream.posts);
    final second = controller.scrollToPost(85, details.value.postStream.posts);
    await tester.pumpAndSettle();
    expect(await first, isFalse);
    expect(await second, isTrue);
    expect(tester.getTopLeft(floor(85)).dy, closeTo(0, 0.5));
    final removed = controller.scrollToPost(60, details.value.postStream.posts);
    details.value = topic([
      for (var i = 40; i < 100; i++)
        if (i != 60) post(i),
    ]);
    await tester.pumpAndSettle();
    expect(await removed, isFalse);
    await disposeList(tester);
  });

  testWidgets('手机宽度下拖动分页及键盘收放保持阅读位置', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(const Offset(195, 420));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    final before = tester.getTopLeft(floor(60)).dy;
    details.value = topic([for (var i = 20; i < 100; i++) post(i)]);
    await tester.pump();
    expect(tester.getTopLeft(floor(60)).dy, closeTo(before, 0.5));
    await tester.pump(const Duration(seconds: 1));
    await gesture.up();
    await tester.pumpAndSettle();
    for (final inset in [300.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(floor(60)).dy, closeTo(before, 0.5));
    }
    await disposeList(tester);
  });

  testWidgets('正在阅读的长帖分块被编辑移除后回到该帖首段', (tester) async {
    final originalPosts = details.value.postStream.posts;
    details.value = topic([
      for (final item in originalPosts)
        item.postNumber == 60
            ? post(
                60,
                cooked: List.generate(
                  100,
                  (i) =>
                      '<p>Expanded paragraph $i with enough text for segmentation.</p>',
                ).join(),
              )
            : item,
    ]);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final done = controller.scrollToPostChunk(
      60,
      1,
      details.value.postStream.posts,
    );
    await tester.pumpAndSettle();
    expect(await done, isTrue);
    details.value = topic(originalPosts);
    await tester.pump();
    expect(tester.getTopLeft(floor(60)).dy, closeTo(0, 0.5));
    await disposeList(tester);
  });

  testWidgets('阅读推荐区时输入提示出现消失与新回复插入保持位置', (tester) async {
    hasMoreAfter = false;
    details.value = details.value.copyWith(
      suggestedTopics: [
        for (var i = 0; i < 15; i++)
          Topic(
            id: 1000 + i,
            title: '推荐话题 $i',
            slug: 'recommendation-$i',
            postsCount: 10,
            replyCount: 9,
            views: 120,
            likeCount: 5,
            categoryId: '1',
          ),
      ],
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final stream = tester.widget<PositionedStreamList>(
      find.byType(PositionedStreamList),
    );
    final done = controller.postListController.jumpToIndex(
      stream.itemKeys.indexOf('suggested-topics'),
    );
    await tester.pumpAndSettle();
    await done;
    final target = find.text('推荐话题 0');
    final before = tester.getTopLeft(target).dy;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(TopicPostList)),
    );
    final channel =
        container.read(topicChannelProvider(42).notifier) as _TestTopicChannel;
    for (final typing in [true, false]) {
      channel.setTyping(typing);
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getTopLeft(target).dy, closeTo(before, 0.5));
      }
    }
    details.value = details.value.copyWith(
      postStream: PostStream(
        posts: [...details.value.postStream.posts, post(100)],
        stream: details.value.postStream.stream,
      ),
    );
    await tester.pump();
    expect(tester.getTopLeft(target).dy, closeTo(before, 0.5));
    await disposeList(tester);
  });

  testWidgets('跳转长帖分块与分页同帧时仍定位正确分块', (tester) async {
    details.value = topic([
      for (final item in details.value.postStream.posts)
        item.postNumber == 85
            ? post(
                85,
                cooked: List.generate(
                  100,
                  (i) =>
                      '<p>Expanded paragraph $i with enough text for segmentation.</p>',
                ).join(),
              )
            : item,
    ]);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final done = controller.scrollToPostChunk(
      85,
      1,
      details.value.postStream.posts,
    );
    details.value = topic([
      for (var i = 20; i < 40; i++) post(i),
      ...details.value.postStream.posts,
    ]);
    await tester.pump();
    final target = find.byWidgetPredicate(
      (widget) =>
          widget is AutoScrollTag &&
          widget.key == const ValueKey('long-chunk-85-1'),
    );
    expect(tester.getTopLeft(target).dy, closeTo(0, 0.5));
    await tester.pumpAndSettle();
    expect(await done, isTrue);
    await disposeList(tester);
  });

  testWidgets('目录快速切换并重复点击同一标题时保留最后一次定位', (tester) async {
    final html = List.generate(
      5,
      (section) =>
          '<h2><a name="rapid-$section" class="anchor" href="#rapid-$section"></a>Section $section</h2>'
          '${List.generate(40, (i) => '<p>Paragraph $i for section $section with enough text to form a long post.</p>').join()}',
    ).join();
    details.value = topic([
      post(1, cooked: html),
      for (var i = 2; i < 100; i++) post(i),
    ]);
    toc.updateTopic(details.value);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final first = toc.tocData!.flat[1];
    final second = toc.tocData!.flat[4];
    final requests = [
      toc.scrollToHeading(first, details.value.postStream.posts),
      toc.scrollToHeading(second, details.value.postStream.posts),
      toc.scrollToHeading(first, details.value.postStream.posts),
    ];
    await tester.pumpAndSettle();
    await Future.wait(requests);
    final target = toc.registry.contextOf(first.anchorKey)!;
    final box = target.findRenderObject()! as RenderBox;
    expect(box.localToGlobal(Offset.zero).dy, closeTo(12, 0.5));
    expect(toc.isJumping, isFalse);
    await disposeList(tester);
  });
}
