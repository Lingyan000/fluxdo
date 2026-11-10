import 'dart:async';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/pages/topic_detail_page/topic_detail_page.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_post_list.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/message_bus_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/topic_detail_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:shared_preferences/shared_preferences.dart';

TopicDetail _detail(int first, int last) => TopicDetail.fromJson({
  'id': 42,
  'title': 'Navigation regression',
  'posts_count': 120,
  'post_stream': {
    'stream': [for (var i = 1; i <= 120; i++) i],
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
  _DetailNotifier(super.arg);
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
    return _detail(40, 99);
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
  var enablePrevious = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    LocaleSettings.setLocale(AppLocale.zh);
    service = _PagingService();
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
          )..previousEnabled = enablePrevious,
        ),
      ],
    );
  });

  tearDown(() => container.dispose());

  Widget app() => UncontrolledProviderScope(
    container: container,
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: navigatorKey,
        locale: const Locale('zh'),
        supportedLocales: AppLocaleUtils.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const TopicDetailPage(
          topicId: 42,
          scrollToPostNumber: 60,
          embeddedMode: true,
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
    await tester.pump(const Duration(seconds: 1));
  }

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
