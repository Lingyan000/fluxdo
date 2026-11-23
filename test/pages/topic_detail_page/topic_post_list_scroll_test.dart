import 'package:app_icons/app_icons.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/providers/message_bus_providers.dart';
import 'package:fluxdo/pages/topic_detail_page/controllers/topic_detail_controller.dart';
import 'package:fluxdo/pages/topic_detail_page/controllers/topic_toc_controller.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_detail_header.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_more_topics.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_post_list.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_status_notices.dart';
import 'package:fluxdo/widgets/common/positioned_stream_list.dart';
import 'package:fluxdo/widgets/common/relative_time_text.dart';
import 'package:fluxdo/widgets/common/topic_badges.dart';
import 'package:fluxdo/utils/time_utils.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/screen_track.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MessageBusInit extends MessageBusInitNotifier {
  @override
  void build() {}
}

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
  var visibleReportCount = 0;

  Finder metadataText(String value) => find.byWidgetPredicate((widget) {
    if (widget is! Text) return false;
    final text = widget.textSpan?.toPlainText(includePlaceholders: false);
    return (widget.data ?? text) == value;
  });

  double digitCenterY(WidgetTester tester, Finder text) {
    final paragraph = tester.renderObject<RenderParagraph>(text);
    final index = paragraph.text.toPlainText().indexOf(RegExp(r'\d'));
    final digit = paragraph
        .getBoxesForSelection(
          TextSelection(baseOffset: index, extentOffset: index + 1),
        )
        .single;
    return paragraph.localToGlobal(digit.toRect().center).dy;
  }

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
    visibleReportCount = 0;
  });

  tearDown(() {
    toc.dispose();
    controller.dispose();
    details.dispose();
    loading.dispose();
    failed.dispose();
  });

  Widget app({VoidCallback? onShowMembers, Widget? body}) => ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      categoryMapProvider.overrideWith(
        (ref) => const AsyncValue.data(<int, Category>{}),
      ),
      topicChannelProvider(42).overrideWith(_TestTopicChannel.new),
      messageBusInitProvider.overrideWith(_MessageBusInit.new),
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
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: body ?? ValueListenableBuilder<TopicDetail>(
            valueListenable: details,
            builder: (context, detail, _) => TopicPostList(
              detail: detail,
              onShowMembers: onShowMembers,
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
              onReadingProgress: controller.updateReadingPosition,
              onVisiblePostsChanged: (posts) {
                visiblePosts = posts;
                visibleReportCount++;
              },
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

  testWidgets('同一楼内慢滚和反向立即更新进度，跨楼时连续', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final progress = controller.readingPositionNotifier;
    expect(progress.value, 0, reason: '初始定位只在完成后接入视线位置');
    controller.markPositioned();
    final scroll = controller.scrollController;
    final start = scroll.offset;
    final initial = tester.getRect(floor(60));
    double expected(Rect rect) => 59 + (kToolbarHeight - rect.top) / rect.height;
    expect(progress.value, closeTo(expected(initial), .001));
    final reports = reported.length;
    for (final dy in [4.0, 8.0, 12.0, 8.0, 4.0]) {
      scroll.jumpTo(start + dy);
      await tester.pump();
      expect(progress.value, closeTo(expected(tester.getRect(floor(60))), .001));
      expect(reported.length, reports, reason: '楼内移动不重复上报楼号');
    }
    final boundary = start + initial.bottom - kToolbarHeight;
    scroll.jumpTo(boundary - 1);
    await tester.pump();
    final before = progress.value;
    scroll.jumpTo(boundary + 1);
    await tester.pump();
    expect(reported.last, 61);
    expect(before, inExclusiveRange(59.97, 60.0));
    expect(progress.value, inExclusiveRange(60.0, 60.03));
    await disposeList(tester);
  });

  testWidgets('只有一楼的长正文也能从零连续读到满进度', (tester) async {
    initialFloor = 1;
    hasMoreBefore = hasMoreAfter = false;
    final only = post(
      1,
      cooked: '<p>${List.filled(90, '正文').join('<br>')}</p>',
    );
    details.value = topic([only]).copyWith(
      postStream: PostStream(posts: [only], stream: [only.id]),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    controller.markPositioned();
    final progress = controller.readingPositionNotifier;
    final scroll = controller.scrollController;
    expect(progress.value, 0);
    scroll.jumpTo(200);
    await tester.pump();
    final middle = progress.value;
    expect(middle, inExclusiveRange(0.0, 1.0));
    scroll.jumpTo(204);
    await tester.pump();
    expect(progress.value, inExclusiveRange(middle, 1.0));
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(progress.value, 1);
    scroll.jumpTo(scroll.position.minScrollExtent);
    await tester.pumpAndSettle();
    expect(progress.value, 0);
    await disposeList(tester);
  });

  testWidgets('持续滚动每帧只测量和上报一次可见帖子', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(const Offset(400, 300));
    for (var frame = 0; frame < 12; frame++) {
      visibleReportCount = 0;
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        visibleReportCount,
        lessThanOrEqualTo(1),
        reason: '同一帧重复遍历帖子几何会增加滚动开销',
      );
    }
    await gesture.up();
    await tester.pumpAndSettle();
    await disposeList(tester);
  });

  testWidgets('向上翻到加载边界后前插帖子，保持原楼层和拖动连续性', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 815);
    addTearDown(tester.view.reset);
    initialFloor = 40;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    loading.value = true;
    await tester.pump();
    final gesture = await tester.startGesture(const Offset(180, 300));
    for (var n = 0; n < 8; n++) {
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final indicator = find.byKey(const ValueKey('load-previous'));
    final indicatorRect = tester.getRect(indicator);
    expect(
      indicatorRect.bottom,
      greaterThan(24),
      reason: '到达上边界时页首 loading 应可见',
    );
    final before = tester.getTopLeft(floor(40)).dy;
    details.value = topic([
      for (var n = 20; n < 40; n++) post(n),
      ...details.value.postStream.posts,
    ]);
    loading.value = false;
    await tester.pump();
    expect(
      tester.getTopLeft(floor(40)).dy,
      closeTo(before, 1),
      reason: '加载指示器不能成为前插数据后的阅读锚点',
    );
    expect(
      controller.scrollController.position.isScrollingNotifier.value,
      isTrue,
    );
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(tester.getTopLeft(floor(40)).dy, closeTo(before + 40, 1));
    await gesture.up();
    await tester.pumpAndSettle();
    await disposeList(tester);
  });

  testWidgets('快速上翻回弹期间旧楼层落地保持内容位置和惯性', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 815);
    addTearDown(tester.view.reset);
    initialFloor = 40;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    loading.value = true;
    await tester.pump();
    controller.scrollController.jumpTo(180);
    await tester.pump();
    await tester.fling(
      find.byType(PositionedStreamList),
      const Offset(0, 400),
      2000,
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      controller.scrollController.position.isScrollingNotifier.value,
      isTrue,
    );
    final before = tester.getTopLeft(floor(40)).dy;
    details.value = topic([
      for (var n = 20; n < 40; n++)
        post(n, cooked: '<p>${'Earlier content<br>' * (n % 5 + 1)}</p>'),
      ...details.value.postStream.posts,
    ]);
    loading.value = false;
    await tester.pump();
    expect(tester.getTopLeft(floor(40)).dy, closeTo(before, 1));
    expect(
      controller.scrollController.position.isScrollingNotifier.value,
      isTrue,
    );
    await tester.pumpAndSettle();
    await disposeList(tester);
  });

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
    controller.markPositioned();
    final boundary = controller.scrollController.offset - kToolbarHeight;
    final readings = <double>[];
    for (final dy in [-4.0, -1.0, 1.0, 4.0]) {
      controller.scrollController.jumpTo(boundary + dy);
      await tester.pump();
      readings.add(controller.readingPositionNotifier.value);
    }
    expect(readings, everyElement(inExclusiveRange(59.0, 60.0)));
    for (var i = 1; i < readings.length; i++) {
      expect(readings[i] - readings[i - 1], inExclusiveRange(0.0, .05));
    }
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

  testWidgets('私信标识独占标签行，回复数和时间对齐，成员入口随首帖滚动', (tester) async {
    initialFloor = 1;
    hasMoreBefore = false;
    final pm = TopicDetail.fromJson({
      'id': 42,
      'title': '读书会',
      'archetype': 'private_message',
      'posts_count': 7,
      'created_at': DateTime.now()
          .toUtc()
          .subtract(const Duration(days: 1))
          .toIso8601String(),
      'post_stream': {'posts': [], 'stream': []},
      'details': {'allowed_users': [{'id': 1, 'username': 'reader'}]},
    });
    details.value = pm.copyWith(postStream: topic([post(1), post(2)]).postStream);
    var opened = false;
    await tester.pumpWidget(app(onShowMembers: () => opened = true));
    await tester.pumpAndSettle();

    final entry = find.byTooltip('会话成员');
    final title = tester.getRect(find.byKey(headerKey));
    final badge = tester.getRect(find.widgetWithText(TopicLabelBadge, '私信'));
    final repliesText = metadataText('6回复');
    final replies = tester.getRect(repliesText);
    final creationTime = find.byWidgetPredicate(
      (w) => w is RelativeTimeText && w.dateTime == pm.createdAt,
    );
    final time = tester.getRect(creationTime);
    expect(badge.left, closeTo(title.left, 0.1));
    expect(badge.top, greaterThan(title.bottom));
    expect(replies.left, closeTo(badge.left, 0.1));
    expect(replies.top, greaterThan(badge.bottom));
    expect(time.left, greaterThan(replies.right));
    final replyIcon = find.byIcon(Symbols.chat_bubble_rounded);
    final clockIcon = find.byIcon(Symbols.schedule_rounded);
    expect(
      tester.getCenter(clockIcon).dy,
      closeTo(tester.getCenter(replyIcon).dy, 0.5),
    );
    final timeText = find.descendant(
      of: creationTime,
      matching: find.byType(Text),
    );
    expect(
      digitCenterY(tester, timeText),
      closeTo(digitCenterY(tester, repliesText), 0.5),
    );
    expect(
      find.byTooltip(TimeUtils.formatTooltipTime(pm.createdAt)),
      findsOneWidget,
    );
    expect(tester.getRect(entry).left, closeTo(badge.left, 0.1));
    expect(tester.getRect(entry).top, greaterThanOrEqualTo(time.bottom));
    expect(tester.getRect(entry).bottom, lessThan(tester.getRect(floor(1)).top));
    await tester.tap(entry);
    expect(opened, isTrue);
    final longHtml = List.generate(
      100,
      (i) => '<p>Long message paragraph $i with additional content.</p>',
    ).join();
    details.value = pm.copyWith(postStream: topic([post(1, cooked: longHtml), post(2)]).postStream);
    await tester.pumpAndSettle();
    expect(entry, findsOneWidget);
    await jumpToFloor(tester, 2);
    expect(entry, findsNothing);
    await disposeList(tester);
  });

  testWidgets('窄栏双倍字号下私信统计按整项换行', (tester) async {
    textScale = 2;
    final detail = TopicDetail.fromJson({
      'id': 42,
      'title': '读书会',
      'archetype': 'private_message',
      'posts_count': 1235,
      'created_at': DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 23))
          .toIso8601String(),
      'post_stream': {'posts': [], 'stream': []},
      'details': {'allowed_users': [{'id': 1, 'username': 'reader'}]},
    });
    await tester.pumpWidget(app(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 240,
          child: TopicDetailHeader(detail: detail, onShowMembers: () {}),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final badge = tester.getRect(find.widgetWithText(TopicLabelBadge, '私信'));
    final replies = tester.getRect(metadataText('1234回复'));
    final time = tester.getRect(find.byType(RelativeTimeText));
    final members = tester.getRect(find.byTooltip('会话成员'));
    expect(replies.top, greaterThan(badge.bottom));
    expect(time.top, greaterThan(replies.bottom));
    expect(time.left, closeTo(replies.left, 0.1));
    expect(members.top, greaterThanOrEqualTo(time.bottom));
    expect(tester.takeException(), isNull);
    await disposeList(tester);
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
    controller.markPositioned();
    final progress = controller.readingPositionNotifier;
    // 下一篇可见帖子是 80 楼，这一段覆盖完整帖子流中的五格。
    expect(
      progress.value,
      closeTo(74 + 5 * kToolbarHeight / tester.getSize(floor(75)).height, .001),
    );
    details.value = topic([for (var i = 1; i < 100; i++) post(i)]);
    await tester.pump();
    expect(tester.getTopLeft(floor(75)).dy, closeTo(0, 0.5));
    await jumpToFloor(tester, 45);
    expect(tester.getTopLeft(floor(45)).dy, closeTo(0, 0.5));
    expect(
      progress.value,
      closeTo(44 + kToolbarHeight / tester.getSize(floor(45)).height, .001),
    );
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

  testWidgets('返回锚点跨分页恢复长帖分段及段内偏移', (tester) async {
    final longPost = post(
      60,
      cooked: List.generate(
        100,
        (i) =>
            '<p>Paragraph $i with enough text for segmentation and reading.</p>',
      ).join(),
    );
    details.value = topic([
      for (var i = 40; i < 100; i++) i == 60 ? longPost : post(i),
    ]);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final jump = controller.scrollToPostChunk(
      60,
      1,
      details.value.postStream.posts,
    );
    await tester.pumpAndSettle();
    expect(await jump, isTrue);
    controller.scrollController.jumpTo(controller.scrollController.offset + 47);
    await tester.pumpAndSettle();
    final saved = controller.captureReadingPosition()!;
    expect(saved.postNumber, 60);
    expect(saved.segmentIndex, greaterThan(0));
    await jumpToFloor(tester, 85);
    details.value = topic([
      for (var i = 20; i < 100; i++) i == 60 ? longPost : post(i),
    ]);
    await tester.pumpAndSettle();
    final restore = controller.restoreReadingPosition(saved);
    await tester.pumpAndSettle();
    expect(await restore, isTrue);
    final restored = controller.captureReadingPosition()!;
    expect(restored.postNumber, saved.postNumber);
    expect(restored.segmentIndex, saved.segmentIndex);
    expect(restored.offset, closeTo(saved.offset, .5));
    await disposeList(tester);
  });

  testWidgets('帖子加载到末尾后显示话题提示，元数据改变时更新', (tester) async {
    initialFloor = 1;
    hasMoreBefore = false;
    details.value = topic([post(1)]).copyWith(slowModeSeconds: 3600);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byType(TopicStatusNotices), findsNothing);

    hasMoreAfter = false;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final stream = tester.widget<PositionedStreamList>(
      find.byType(PositionedStreamList),
    );
    final done = controller.postListController.jumpToIndex(
      stream.itemKeys.indexOf('topic-status-notices'),
    );
    await tester.pumpAndSettle();
    await done;
    expect(find.text('请在此话题的两次发帖之间等待 1 小时'), findsOneWidget);

    details.value = details.value.copyWith(slowModeSeconds: 0);
    await tester.pumpAndSettle();
    expect(find.textContaining('两次发帖'), findsNothing);
    await disposeList(tester);
  });

  testWidgets('私信读到底只显示相关消息，空结果或关闭推荐时隐藏', (tester) async {
    initialFloor = 1;
    hasMoreBefore = false;
    final pm = TopicDetail.fromJson({
      'id': 42,
      'title': '读书会',
      'archetype': 'private_message',
      'posts_count': 1,
      'post_stream': {'posts': [], 'stream': [1]},
      'related_messages': [
        {
          'id': 43,
          'title': '下次读什么',
          'posts_count': 6,
          'reply_count': 2,
          'last_posted_at': '2026-11-15T08:00:00Z',
        },
      ],
      'suggested_topics': [
        {'id': 44, 'title': '另一条推荐'},
      ],
    }).copyWith(postStream: PostStream(posts: [post(1)], stream: [1]));
    details.value = pm;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('相关消息'), findsNothing);

    hasMoreAfter = false;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('相关消息'), findsOneWidget);
    final title = tester.getRect(find.text('下次读什么'));
    final stats = tester.getRect(find.textContaining('5 · '));
    expect(stats.left, closeTo(title.left, 0.1));
    expect(stats.top, greaterThanOrEqualTo(title.bottom));
    expect(find.text('另一条推荐'), findsNothing);

    details.value = pm.copyWith(relatedMessages: []);
    await tester.pumpAndSettle();
    expect(find.text('相关消息'), findsNothing);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(TopicPostList)),
    );
    await container
        .read(preferencesProvider.notifier)
        .setShowSuggestedTopics(false);
    details.value = pm;
    await tester.pumpAndSettle();
    expect(find.text('相关消息'), findsNothing);
    await disposeList(tester);
  });

  testWidgets('推荐条目有标签时分列展示，回复图标随字号等比缩放', (tester) async {
    final detail = topic([]).copyWith(
      suggestedTopics: [
        Topic.fromJson({
          'id': 43,
          'title': '读书交流',
          'tags': ['阅读'],
          'posts_count': 2,
        }),
      ],
    );
    final section = MoreTopicsSection(detail: detail);
    await tester.pumpWidget(app(body: section));
    await tester.pumpAndSettle();
    final title = tester.getRect(find.text('读书交流'));
    final row = tester.getRect(find.byType(MoreTopicsSection));
    final stats = tester.getRect(metadataText('1'));
    expect(tester.getRect(find.text('#阅读')).left, closeTo(title.left, 0.1));
    expect(row.right - stats.right, closeTo(title.left - row.left, 0.1));

    final icon = find.byIcon(Symbols.chat_bubble_rounded);
    final iconWidth = tester.getRect(icon).width;
    textScale = 2;
    await tester.pumpWidget(app(body: section));
    await tester.pumpAndSettle();
    expect(tester.getRect(icon).width, closeTo(iconWidth * 2, 0.1));
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
