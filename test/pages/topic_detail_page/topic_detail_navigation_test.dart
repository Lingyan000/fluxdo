import 'dart:async';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/pages/topic_detail_page/topic_detail_page.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_bar_gestures.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_post_list.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_reading_rail.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_scrub_indicator.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_toc_panel.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/message_bus_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/topic_detail_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/widgets/post/post_item_skeleton.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:shared_preferences/shared_preferences.dart';

TopicDetail _detail(int first, int last, {int total = 120}) =>
    TopicDetail.fromJson({
      'id': 42,
      'title': 'Navigation regression',
      'posts_count': total,
      'post_stream': {
        'stream': [for (var i = 1; i <= total; i++) i],
        'posts': [
          for (var i = first; i <= last; i++)
            {
              'id': i,
              'post_number': i,
              'username': 'tester',
              'avatar_template': '',
              'created_at': '2026-11-01T00:00:00Z',
              'cooked': '<p>Content for floor $i.</p>',
            },
        ],
      },
    });

class _DetailNotifier extends TopicDetailNotifier {
  _DetailNotifier(super.arg, this.initialDetail);
  final TopicDetail initialDetail;
  bool previousEnabled = false;
  int get firstLoadedPost =>
      state.requireValue.postStream.posts.first.postNumber;

  @override
  Future<TopicDetail> build() async {
    ref.onDispose(() {
      loadingPreviousListenable.dispose();
      loadingMoreListenable.dispose();
      loadPreviousFailedListenable.dispose();
      loadMoreFailedListenable.dispose();
    });
    return initialDetail;
  }

  @override
  bool get hasMoreBefore => previousEnabled && super.hasMoreBefore;
  @override
  bool get hasMoreAfter => false;

  void publish(TopicDetail detail) => state = AsyncData(detail);
}

class _PagingService extends Fake implements DiscourseService {
  late Completer<PostStream> previous;
  int previousCalls = 0;
  final windows = <({List<int> ids, Completer<PostStream> result})>[];
  late Completer<TopicDetail> refresh;
  int detailCalls = 0;

  @override
  Future<TopicDetail> getTopicDetail(
    int id, {
    int? postNumber,
    bool trackVisit = false,
    String? filter,
    String? usernameFilters,
    bool filterTopLevelReplies = false,
  }) {
    detailCalls++;
    refresh = Completer<TopicDetail>();
    return refresh.future;
  }

  @override
  Future<PostStream> getPosts(
    int topicId,
    List<int> postIds, {
    bool includeSuggested = false,
  }) {
    final result = Completer<PostStream>();
    windows.add((ids: postIds, result: result));
    return result.future;
  }

  @override
  Future<PostStream> getPostsByNumber(
    int topicId, {
    required int postNumber,
    required bool asc,
    bool includeSuggested = false,
  }) {
    expect(asc, isFalse);
    previousCalls++;
    previous = Completer<PostStream>();
    return previous.future;
  }
}

class _CurrentUser extends CurrentUserNotifier {
  @override
  User? build() => null;
}

class _TopicChannel extends TopicChannelNotifier {
  _TopicChannel(super.topicId);
  @override
  TopicChannelState build() => const TopicChannelState();
}

class _Tracking extends TopicTrackingStateNotifier {
  @override
  Map<int, TrackedTopicState> build() => {};
}

class _MessageBusInit extends MessageBusInitNotifier {
  @override
  void build() {}
}

void main() {
  late _DetailNotifier notifier;
  late SharedPreferences prefs;
  late ProviderContainer container;
  late _PagingService service;
  late TopicDetail initialDetail;
  var enablePrevious = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    LocaleSettings.setLocale(AppLocale.zh);
    service = _PagingService();
    initialDetail = _detail(40, 99);
    enablePrevious = false;
    container = ProviderContainer(
      overrides: [
        aiSharedPreferencesProvider.overrideWithValue(prefs),
        sharedPreferencesProvider.overrideWithValue(prefs),
        discourseServiceProvider.overrideWithValue(service),
        currentUserProvider.overrideWith(_CurrentUser.new),
        categoryMapProvider.overrideWith(
          (ref) => const AsyncValue.data(<int, Category>{}),
        ),
        topicChannelProvider(42).overrideWith(() => _TopicChannel(42)),
        topicTrackingStateProvider.overrideWith(_Tracking.new),
        messageBusInitProvider.overrideWith(_MessageBusInit.new),
        topicDetailProvider(
          const TopicDetailParams(42, instanceId: 'navigation-test'),
        ).overrideWith(
          () => notifier = _DetailNotifier(
            const TopicDetailParams(42, instanceId: 'navigation-test'),
            initialDetail,
          )..previousEnabled = enablePrevious,
        ),
      ],
    );
  });

  tearDown(() => container.dispose());

  Widget app({int initialFloor = 60, bool embedded = true}) =>
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            locale: const Locale('zh'),
            supportedLocales: AppLocaleUtils.supportedLocales,
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: TopicDetailPage(
              topicId: 42,
              scrollToPostNumber: initialFloor,
              embeddedMode: embedded,
              instanceId: 'navigation-test',
            ),
          ),
        ),
      );

  Finder floor(int number) => find.byWidgetPredicate(
    (widget) =>
        widget is AutoScrollTag && widget.key == ValueKey('post-$number'),
  );

  void expectFloorAtTop(WidgetTester tester, int number) {
    final list = find.byType(TopicPostList);
    expect(
      tester.getTopLeft(floor(number)).dy,
      closeTo(tester.getTopLeft(list).dy, 0.5),
    );
  }

  Future<void> disposePage(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // 详情页销毁后，内联帖子缓存还有 30 秒的保活期。
    await tester.pump(const Duration(seconds: 31));
  }

  testWidgets('松手后的第一帧定位到屏外已加载楼层，与底栏收起动画同时进行', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 720);
    addTearDown(tester.view.reset);
    final original = initialDetail.postStream;
    // 模拟前面有删楼，进度索引和实际楼号不同。
    final stream = original.stream.where((id) => id != 8).toList();
    initialDetail = initialDetail.copyWith(
      postStream: PostStream(stream: stream, posts: original.posts),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final bar = find.byType(TopicBarGestures);
    final finger = await tester.startGesture(tester.getCenter(bar));
    await finger.moveBy(const Offset(58, 0));
    await tester.pumpAndSettle();
    final targetIndex = tester
        .widget<TopicBarGestures>(bar)
        .scrubIndexNotifier
        .value!;
    final target = stream[targetIndex - 1];
    final selectedCounter = find.descendant(
      of: bar,
      matching: find.text('$targetIndex / ${stream.length}'),
    );
    expect(original.posts.any((post) => post.postNumber == target), isTrue);
    expect(floor(target), findsNothing, reason: '目标正文已在内存，列表尚未创建该行');
    expect(selectedCounter, findsOneWidget);

    await finger.up();
    await tester.pump();
    expectFloorAtTop(tester, target);
    expect(find.byType(TopicScrubIndicator), findsOneWidget);
    expect(selectedCounter, findsOneWidget, reason: '底栏收起的第一帧应保留已确认的位置');
    await tester.pump(const Duration(milliseconds: 16));
    expect(selectedCounter, findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(TopicScrubIndicator), findsNothing);
    expect(
      tester.widget<TopicBarGestures>(bar).streamIndexListenable.value,
      targetIndex,
    );
    await disposePage(tester);
  });

  testWidgets('整帖已在一屏内时，连续确认楼层后恢复实际阅读位置', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1600);
    addTearDown(tester.view.reset);
    initialDetail = _detail(1, 3, total: 3);
    await tester.pumpWidget(app(initialFloor: 3));
    await tester.pumpAndSettle();
    final list = tester.widget<TopicPostList>(find.byType(TopicPostList));
    final viewport = list.scrollController.position;
    expect(viewport.maxScrollExtent, viewport.minScrollExtent);
    final bar = tester.widget<TopicBarGestures>(find.byType(TopicBarGestures));
    final index = bar.streamIndexListenable;
    final position = bar.readingPositionListenable!;
    expect(index.value, 3);
    expect(position.value, 3);

    bar.onScrubCommit(1);
    expect(index.value, 1);
    bar.onScrubCommit(2);
    expect(index.value, 2);
    expect(position.value, 1);
    await tester.pumpAndSettle();
    expect(index.value, 3, reason: '视口未移动，也应交还给实际可见楼层');
    expect(position.value, 3);
    await disposePage(tester);
  });

  testWidgets('远端选楼首帧显示目标和骨架，一次取回目标与相邻正文', (tester) async {
    final original = initialDetail.postStream;
    final stream = original.stream.where((id) => id != 8).toList();
    // 模拟按票排序，窗口首尾的楼号不再包住目标。
    final first = stream.indexOf(101);
    stream[first] = 120;
    stream[stream.length - 1] = 101;
    initialDetail = initialDetail.copyWith(
      postStream: PostStream(posts: original.posts, stream: stream),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final bar = tester.widget<TopicBarGestures>(find.byType(TopicBarGestures));
    final targetIndex = stream.indexOf(110) + 1;
    bar.onScrubCommit(targetIndex);
    await tester.pump();
    expect(find.byType(PostListSkeleton), findsOneWidget);
    expect(find.text('$targetIndex / ${stream.length}'), findsOneWidget);
    expect(floor(60), findsNothing);
    final window = service.windows.single;
    expect(window.ids, containsAllInOrder([109, 110, 111]));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(PostListSkeleton), findsOneWidget);
    window.result.complete(
      PostStream(
        posts: _detail(101, 120).postStream.posts.reversed.toList(),
        stream: const [],
      ),
    );
    for (var frame = 0; frame < 3; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byType(PostListSkeleton).evaluate().isEmpty) {
        expectFloorAtTop(tester, 110);
        final opacity = find.ancestor(
          of: floor(110),
          matching: find.byType(Opacity),
        );
        expect(
          tester
              .widgetList<Opacity>(opacity)
              .every((widget) => widget.opacity > 0),
          isTrue,
        );
        break;
      }
    }
    expect(find.byType(PostListSkeleton), findsNothing);
    expectFloorAtTop(tester, 110);
    expect(bar.streamIndexListenable.value, targetIndex);
    final loaded = tester
        .widget<TopicPostList>(find.byType(TopicPostList))
        .detail
        .postStream;
    expect(loaded.posts.map((post) => post.id), window.ids);
    expect(loaded.stream, stream);
    expect(service.windows, hasLength(1));
    expect(service.detailCalls, 0);
    await disposePage(tester);
  });

  testWidgets('跳离页尾后迟到的新回复只更新帖子流，正文留在当前楼层', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final bar = tester.widget<TopicBarGestures>(find.byType(TopicBarGestures));
    bar.onScrubCommit(120);
    service.windows.single.result.complete(_detail(101, 120).postStream);
    await tester.pumpAndSettle();
    notifier.onNewPostCreated(121);
    final incoming = service.windows.last;
    expect(incoming.ids, [121]);
    bar.onScrubCommit(20);
    final window = service.windows.last;
    window.result.complete(
      _detail(window.ids.first, window.ids.last).postStream,
    );
    await tester.pumpAndSettle();
    incoming.result.complete(_detail(121, 121, total: 121).postStream);
    await tester.pumpAndSettle();
    final stream = tester
        .widget<TopicPostList>(find.byType(TopicPostList))
        .detail
        .postStream;
    expect(stream.stream.last, 121);
    expect(stream.posts.last.id, window.ids.last);
    expectFloorAtTop(tester, 20);
    await disposePage(tester);
  });

  testWidgets('旧窗口的分页和刷新在跳楼后才返回，正文仍停在新窗口', (tester) async {
    enablePrevious = true;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final paging = notifier.loadPrevious();
    final previousPage = service.previous;
    expect(service.previousCalls, 1);
    final refreshing = notifier.refreshWithPostNumber(60);
    expect(service.detailCalls, 1);
    final bar = tester.widget<TopicBarGestures>(find.byType(TopicBarGestures));
    bar.onScrubCommit(110);
    await tester.pump();
    final window = service.windows.single;
    window.result.complete(
      _detail(window.ids.first, window.ids.last).postStream,
    );
    await tester.pump();
    await tester.pump();
    previousPage.complete(_detail(20, 39).postStream);
    service.refresh.complete(initialDetail);
    await tester.pump();
    await paging;
    expect(await refreshing, isFalse);
    await tester.pumpAndSettle();
    expectFloorAtTop(tester, 110);
    expect(notifier.firstLoadedPost, window.ids.first);
    expect(notifier.isLoadingPrevious, isFalse);
    await disposePage(tester);
  });

  testWidgets('宽屏等待跳楼时改选，迟到响应不覆盖新目标，相邻楼层复用缓存', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final rail = tester.widget<TopicReadingRail>(find.byType(TopicReadingRail));
    rail.onJumpToIndex(15);
    await tester.pump();
    rail.onJumpToIndex(75);
    await tester.pumpAndSettle();
    expectFloorAtTop(tester, 75);
    expect(find.byType(PostListSkeleton), findsNothing);
    rail.onJumpToIndex(102);
    await tester.pump();
    service.windows.first.result.complete(_detail(10, 29).postStream);
    await tester.pump();
    expect(rail.streamIndexListenable.value, 102);
    expect(find.byType(PostListSkeleton), findsOneWidget);
    final latest = service.windows.last;
    expect(latest.ids.first, 100, reason: '99 楼及之前的正文已在本地');
    latest.result.complete(
      _detail(latest.ids.first, latest.ids.last).postStream,
    );
    await tester.pumpAndSettle();
    expectFloorAtTop(tester, 102);
    expect(notifier.firstLoadedPost, 97);
    expect(service.windows, hasLength(2));
    await disposePage(tester);
  });

  testWidgets('远端跳楼失败或目标已删除时保留原阅读位置，能够重试', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final bar = tester.widget<TopicBarGestures>(find.byType(TopicBarGestures));
    for (final missing in [false, true]) {
      bar.onScrubCommit(20);
      await tester.pump();
      if (missing) {
        service.windows.last.result.complete(_detail(21, 23).postStream);
      } else {
        service.windows.last.result.completeError(StateError('暂时离线'));
      }
      await tester.pumpAndSettle();
      expect(find.byType(PostListSkeleton), findsNothing);
      expect(bar.streamIndexListenable.value, 60);
      expectFloorAtTop(tester, 60);
    }
    expect(service.windows, hasLength(2));
    await disposePage(tester);
  });

  testWidgets('确认后目标被移除，底栏继续显示视口中的楼层', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final bar = tester.widget<TopicBarGestures>(find.byType(TopicBarGestures));
    final previous = bar.streamIndexListenable.value;
    bar.onScrubCommit(80);
    final original = initialDetail.postStream;
    notifier.publish(
      initialDetail.copyWith(
        postStream: PostStream(
          stream: original.stream.where((id) => id != 80).toList(),
          posts: original.posts.where((post) => post.id != 80).toList(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(bar.streamIndexListenable.value, previous);
    expectFloorAtTop(tester, previous);
    await disposePage(tester);
  });

  testWidgets('目录跟随详情窗格宽度切换单一入口，并记住展开选择', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1900, 900);
    addTearDown(tester.view.reset);
    final detail = _detail(1, 60);
    final stream = detail.postStream;
    initialDetail = detail.copyWith(
      postStream: PostStream(
        stream: stream.stream,
        posts: [
          stream.posts.first.copyWith(
            cooked: List.generate(
              12,
              (i) => '<h2>章节 ${i + 1}</h2><p>章节内容</p>',
            ).join(),
          ),
          ...stream.posts.skip(1),
        ],
      ),
    );
    Future<void> resize(double paneWidth) async {
      await tester.pumpWidget(
        Align(
          alignment: Alignment.topRight,
          child: SizedBox(
            width: paneWidth,
            child: app(initialFloor: 1, embedded: false),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    final outline = find.byType(TopicTocSidePanel);
    await resize(1500);
    expect(outline, findsOneWidget);
    expect(find.byType(TopicTocFab), findsNothing);
    final expanded = tester.getRect(outline);
    expect(expanded.right, 400 + (1500 - 800) / 2 - 16);

    final toc = tester.widget<TopicTocSidePanel>(outline).controller;
    final entry = toc.tocData!.flat[2];
    await tester.tap(
      find.descendant(of: outline, matching: find.text(entry.text)),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 160));
    expect(toc.activeHeadingId, entry.id);
    final scroll = toc.detailController.scrollController;
    scroll.jumpTo(scroll.offset + 180);
    await tester.pumpAndSettle();
    expect(toc.activeHeadingId, isNot(entry.id));

    await tester.tap(find.byTooltip('收起目录'));
    await tester.pumpAndSettle();
    final collapsed = tester.getRect(outline);
    expect(collapsed.right, expanded.right);
    expect(collapsed.width, TopicTocSidePanel.collapsedWidth);

    for (final width in [1050.0, 375.0]) {
      await resize(width);
      expect(outline, findsNothing);
      expect(find.byType(TopicTocFab).hitTestable(), findsOneWidget);
    }
    await resize(1500);
    expect(find.byTooltip('展开目录'), findsOneWidget);
    await tester.tap(find.byTooltip('展开目录'));
    await tester.pumpAndSettle();
    expect(tester.getRect(outline), expanded);
    await disposePage(tester);
  });

  testWidgets('私信顶栏随滚动显示会话标题', (tester) async {
    initialDetail = _detail(
      1,
      99,
    ).copyWith(title: '读书会', archetype: 'private_message');
    await tester.pumpWidget(app(initialFloor: 1));
    await tester.pumpAndSettle();
    final bar = find.byType(AppBar);
    expect(tester.widget<AppBar>(bar).centerTitle, isFalse);
    expect(find.descendant(of: bar, matching: find.text('私信')), findsNothing);
    final title = find.descendant(
      of: bar,
      matching: find.textContaining('读书会'),
    );
    final opacity = find
        .ancestor(of: title, matching: find.byType(Opacity))
        .first;
    expect(tester.widget<Opacity>(opacity).opacity, 0);
    tester.widget<TopicPostList>(find.byType(TopicPostList)).onJumpToPost(60);
    await tester.pumpAndSettle();
    expect(tester.widget<Opacity>(opacity).opacity, 1);
    await disposePage(tester);
  });

  testWidgets('详情页中间进入并通过真实跳楼回调定位', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expectFloorAtTop(tester, 60);
    tester.widget<TopicPostList>(find.byType(TopicPostList)).onJumpToPost(85);
    await tester.pumpAndSettle();
    expectFloorAtTop(tester, 85);
    await disposePage(tester);
  });

  testWidgets('连续向上分页每轮 loading 可见，落地保持楼层且不连翻', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 815);
    addTearDown(tester.view.reset);
    enablePrevious = true;
    try {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final list = tester.widget<TopicPostList>(find.byType(TopicPostList));
      list.scrollController.jumpTo(150);
      await tester.pump();
      expect(service.previousCalls, 1);
      final gesture = await tester.startGesture(const Offset(180, 300));
      for (var frame = 0; frame < 20; frame++) {
        await gesture.moveBy(const Offset(0, 20));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final indicator = find.byKey(const ValueKey('load-previous'));
      final spinner = find.descendant(
        of: indicator,
        matching: find.byType(LoadingSpinner),
      );
      expect(
        indicator,
        findsOneWidget,
        reason:
            'pixels=${list.scrollController.offset}, loading=${notifier.isLoadingPrevious}, hasMoreBefore=${tester.widget<TopicPostList>(find.byType(TopicPostList)).hasMoreBefore}',
      );
      final viewport = tester.getRect(find.byType(TopicPostList));
      expect(tester.getRect(indicator).overlaps(viewport), isTrue);
      expect(tester.getSize(indicator).height, greaterThan(0));
      expect(spinner, findsOneWidget);
      expect(viewport.contains(tester.getCenter(spinner)), isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(service.previousCalls, 1);
      final before = tester.getTopLeft(floor(40)).dy;
      service.previous.complete(_detail(20, 39).postStream);
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widget<TopicPostList>(find.byType(TopicPostList))
            .detail
            .postStream
            .posts
            .first
            .postNumber,
        20,
        reason:
            'providerFirst=${notifier.firstLoadedPost}, loading=${notifier.isLoadingPrevious}, failed=${notifier.isLoadPreviousFailed}',
      );
      expect(floor(40), findsOneWidget);
      expect(tester.getTopLeft(floor(40)).dy, closeTo(before, 1));
      expect(
        list.scrollController.position.outOfRange,
        isFalse,
        reason:
            'pixels=${list.scrollController.offset}, max=${list.scrollController.position.maxScrollExtent}',
      );
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      expect(tester.getTopLeft(floor(40)).dy, closeTo(before + 40, 1));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(service.previousCalls, 1);
      for (final (page, first, nextFirst) in [(2, 20, 10), (3, 10, 1)]) {
        final nextGesture = await tester.startGesture(const Offset(180, 300));
        for (
          var frame = 0;
          frame < 150 && list.scrollController.offset > 0;
          frame++
        ) {
          await nextGesture.moveBy(const Offset(0, 80));
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(service.previousCalls, page);
        expect(notifier.isLoadingPrevious, isTrue);
        expect(
          indicator,
          findsOneWidget,
          reason:
              'page=$page pixels=${list.scrollController.offset} anchor=${list.listController.anchor} extent=${list.listController.extentForIndex(0)}',
        );
        expect(tester.getSize(indicator).height, greaterThan(0));
        expect(
          tester.getRect(indicator).overlaps(viewport),
          isTrue,
          reason: '第 $page 次向上加载时指示器应在视口内',
        );
        expect(spinner, findsOneWidget);
        expect(viewport.contains(tester.getCenter(spinner)), isTrue);
        await tester.pump(const Duration(seconds: 1));
        expect(service.previousCalls, page);
        final nextBefore = tester.getTopLeft(floor(first)).dy;
        service.previous.complete(_detail(nextFirst, first - 1).postStream);
        await tester.pump();
        await tester.pump();
        expect(notifier.firstLoadedPost, nextFirst);
        expect(spinner, findsNothing);
        expect(tester.getTopLeft(floor(first)).dy, closeTo(nextBefore, 1));
        await nextGesture.up();
        await tester.pumpAndSettle();
        expect(service.previousCalls, page);
      }
      expect(tester.takeException(), isNull);
    } finally {
      await disposePage(tester);
    }
  });

  testWidgets('向上加载行被回收后失败提示和重试 loading 仍可见', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 815);
    addTearDown(tester.view.reset);
    enablePrevious = true;
    try {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final list = tester.widget<TopicPostList>(find.byType(TopicPostList));
      list.scrollController.jumpTo(150);
      await tester.pump();
      expect(service.previousCalls, 1);
      service.previous.complete(_detail(20, 39).postStream);
      await tester.pumpAndSettle();

      list.scrollController.jumpTo(150);
      await tester.pump();
      expect(service.previousCalls, 2);
      list.scrollController.jumpTo(1500);
      await tester.pump();
      final indicator = find.byKey(const ValueKey('load-previous'));
      expect(indicator, findsNothing);
      service.previous.completeError(StateError('Previous page failed'));
      await tester.pumpAndSettle();
      expect(notifier.isLoadPreviousFailed, isTrue);

      list.scrollController.jumpTo(0);
      await tester.pumpAndSettle();
      final retry = find.text(S.current.topicDetail_loadFailedTapRetry);
      expect(retry.hitTestable(), findsOneWidget);
      expect(service.previousCalls, 2);
      await tester.tap(retry);
      await tester.pump();
      expect(service.previousCalls, 3);
      expect(notifier.isLoadingPrevious, isTrue);
      final spinner = find.descendant(
        of: indicator,
        matching: find.byType(LoadingSpinner),
      );
      expect(spinner, findsOneWidget);
      expect(
        tester
            .getRect(find.byType(TopicPostList))
            .contains(tester.getCenter(spinner)),
        isTrue,
      );
      service.previous.complete(_detail(10, 19).postStream);
      await tester.pumpAndSettle();
      expect(notifier.firstLoadedPost, 10);
      expect(spinner, findsNothing);
      expect(notifier.isLoadPreviousFailed, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await disposePage(tester);
    }
  });

  testWidgets('详情页连续跳楼叠加分页时保留最后一个目标及高亮', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final list = tester.widget<TopicPostList>(find.byType(TopicPostList));
    list.onJumpToPost(45);
    list.onJumpToPost(85);
    notifier.publish(_detail(20, 99));
    await tester.pumpAndSettle();
    expectFloorAtTop(tester, 85);
    expect(
      tester
          .widget<TopicPostList>(find.byType(TopicPostList))
          .highlightPostNumber,
      85,
    );
    await disposePage(tester);
  });
}
