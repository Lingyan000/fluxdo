import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/shortcut_binding.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_interaction.dart';
import 'package:fluxdo/pages/topics_page.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/message_bus/topic_list_events.dart';
import 'package:fluxdo/providers/message_bus/topic_tracking_providers.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/providers/pinned_categories_provider.dart';
import 'package:fluxdo/providers/selected_topic_provider.dart';
import 'package:fluxdo/providers/shortcut_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/topic_list/topic_list_provider.dart';
import 'package:fluxdo/providers/topic_list/tab_state_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/utils/paged_async_notifier.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/common/positioned_stream_list.dart';
import 'package:fluxdo/widgets/topic/topic_list_update_banner.dart';
import 'package:fluxdo/widgets/topic/pinned_topics_header.dart';
import 'package:fluxdo/widgets/topic/topic_card.dart';
import 'package:fluxdo/widgets/layout/adaptive_scaffold.dart';
import 'package:fluxdo/widgets/layout/adaptive_navigation.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

Topic topic(
  int id, {
  String? title,
  bool pinned = false,
  bool unseen = false,
}) => Topic(
  id: id,
  title: title ?? '话题 $id ${'长标题内容 ' * (id % 4 * 8)}',
  slug: 'topic-$id',
  postsCount: 10,
  replyCount: 9,
  views: 120,
  likeCount: 5,
  categoryId: '2',
  pinned: pinned,
  unseen: unseen,
);

class _Topics extends TopicListNotifier {
  _Topics() : super(null);
  final initial = [for (var id = 40; id < 140; id++) topic(id)];
  int builds = 0;
  int loadMoreCalls = 0;
  Completer<List<Topic>>? page;
  List<Topic> get items => state.value!;

  @override
  Future<List<Topic>> build() async {
    builds++;
    return completePagedRefresh(PagedPage(items: initial, hasMore: false));
  }

  void publish(List<Topic> topics, {bool hasMore = false}) {
    state = AsyncData(
      completePagedRefresh(PagedPage(items: topics, hasMore: hasMore)),
    );
  }

  @override
  Future<List<int>?> loadBefore(List<int> ids) async {
    publish([...ids.map(topic), ...state.value!]);
    return ids;
  }

  @override
  Future<void> loadMore() async {
    loadMoreCalls++;
    await runPagedLoadMore(
      (items, _) async =>
          PagedPage(items: [...items, ...await page!.future], hasMore: false),
    );
  }
}

class _CurrentUser extends CurrentUserNotifier {
  @override
  User? build() => null;
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
  late ProviderContainer container;
  late _Topics topics;

  setUp(() async {
    PlatformUtils.debugDesktopOverride = true;
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    LocaleSettings.setLocale(AppLocale.zh);
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentUserProvider.overrideWith(_CurrentUser.new),
        topicTrackingStateProvider.overrideWith(_Tracking.new),
        messageBusInitProvider.overrideWith(_MessageBusInit.new),
        categoryMapProvider.overrideWith(
          (ref) => AsyncData({
            2: Category(
              id: 2,
              name: '测试分类',
              color: '0088CC',
              textColor: 'FFFFFF',
              slug: 'test',
            ),
          }),
        ),
        visibleCategoryIdsProvider.overrideWith((ref) => <int>{2}),
        miniAppPullEnabledProvider.overrideWithValue(false),
        topicListProvider(null).overrideWith(() => topics = _Topics()),
        topicListProvider(2).overrideWith(_Topics.new),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    PlatformUtils.debugDesktopOverride = null;
  });

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1400, 800),
    bool withBottomNavigation = false,
  }) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
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
            home: withBottomNavigation
                ? MediaQuery(
                    data: MediaQueryData(
                      size: size,
                      padding: const EdgeInsets.only(bottom: 24),
                      viewPadding: const EdgeInsets.only(bottom: 24),
                    ),
                    child: AdaptiveScaffold(
                      selectedIndex: 0,
                      onDestinationSelected: (_) {},
                      destinations: const [
                        AdaptiveDestination(
                          id: 'home',
                          icon: Icon(Icons.home),
                          selectedIcon: Icon(Icons.home),
                          label: '首页',
                        ),
                        AdaptiveDestination(
                          id: 'chat',
                          icon: Icon(Icons.chat),
                          selectedIcon: Icon(Icons.chat),
                          label: '聊天',
                        ),
                      ],
                      body: const TopicsPage(),
                    ),
                  )
                : const Scaffold(body: TopicsPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }

  Finder activeList() => find.byWidgetPredicate(
    (widget) =>
        widget is PositionedStreamList &&
        widget.positionKey ==
            ('topics', container.read(currentTabCategoryIdProvider)),
  );
  Finder row(int id) => find.descendant(
    of: activeList(),
    matching: find.byKey(ValueKey('topic-$id')),
  );
  PositionedStreamList list(WidgetTester tester) =>
      tester.widget<PositionedStreamList>(activeList());

  Future<void> jump(WidgetTester tester, int id) async {
    final widget = list(tester);
    final done = widget.listController.jumpToIndex(
      widget.itemKeys.indexOf('topic-$id'),
      offset: 150,
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    await done;
  }

  void invokeShortcut(WidgetTester tester, ShortcutAction action) {
    final callbacks = resolveShortcutScopeCallbacks(
      registry: container.read(shortcutScopeRegistryProvider),
      scope: ShortcutScope.master,
      route: ModalRoute.of(tester.element(find.byType(TopicsPage))),
    );
    expect(callbacks[action], isNotNull);
    callbacks[action]!();
  }

  void nextTopic(WidgetTester tester) =>
      invokeShortcut(tester, ShortcutAction.nextItem);

  testWidgets('手机滚到列表末端时页尾加载指示器保持可见', (tester) async {
    PlatformUtils.debugDesktopOverride = false;
    await container
        .read(preferencesProvider.notifier)
        .setHideBarOnScroll(false);
    await mount(tester, size: const Size(375, 815), withBottomNavigation: true);
    topics.page = Completer();
    topics.publish(topics.items.take(20).toList(), hasMore: true);
    await tester.pump();
    final scroll = list(tester).scrollController;
    scroll.jumpTo(scroll.position.maxScrollExtent - 100);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(topics.loadMoreCalls, 1);
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    final spinner = find.descendant(
      of: find.byType(TopicsPage),
      matching: find.byType(LoadingSpinner),
    );
    expect(spinner, findsOneWidget);
    final bar = tester.getRect(find.byType(AdaptiveBottomNavigation));
    expect(tester.getRect(spinner).bottom, lessThan(bar.top));
    await tester.pump(const Duration(seconds: 2));
    expect(spinner, findsOneWidget);
    expect(topics.loadMoreCalls, 1);
    topics.page!.complete([for (var n = 60; n < 80; n++) topic(n)]);
    await tester.pump();
    expect(list(tester).itemKeys, contains('topic-60'));
    await tester.pumpAndSettle();
    expect(spinner, findsNothing);
    await dispose(tester);
  });

  testWidgets('新话题提示出现及批量插入后保持当前卡片位置', (tester) async {
    await mount(tester);
    await jump(tester, 90);
    final before = tester.getTopLeft(row(90)).dy;
    container
        .read(topicListEventsProvider.notifier)
        .publish(
          const TopicListEvent(topicId: 200, type: 'latest', categoryId: 2),
        );
    await tester.pump();
    expect(tester.getTopLeft(row(90)).dy, closeTo(before, 0.5));
    topics.publish([
      for (var id = 200; id < 220; id++) topic(id),
      ...topics.items,
    ]);
    await tester.pump();
    expect(tester.getTopLeft(row(90)).dy, closeTo(before, 0.5));
    await dispose(tester);
  });

  testWidgets('贴顶收到新话题后可立即查看并保持顶部', (tester) async {
    await mount(tester);
    container
        .read(topicListEventsProvider.notifier)
        .publish(
          const TopicListEvent(topicId: 200, type: 'latest', categoryId: 2),
        );
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(find.byType(TopicListUpdateBanner), findsOneWidget);
    await tester.tap(find.byType(TopicListUpdateBanner));
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(find.byType(TopicListUpdateBanner), findsNothing);
    expect(row(200), findsOneWidget);
    expect(list(tester).scrollController.offset, closeTo(0, 0.5));
    expect(tester.getTopLeft(row(200)).dy, lessThan(300));
    await dispose(tester);
  });

  testWidgets('拖动中插入新话题仍能继续拖动', (tester) async {
    await mount(tester);
    await jump(tester, 90);
    final gesture = await tester.startGesture(const Offset(700, 450));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    final before = tester.getTopLeft(row(90)).dy;
    topics.publish([
      for (var id = 200; id < 220; id++) topic(id),
      ...topics.items,
    ]);
    await tester.pump();
    expect(tester.getTopLeft(row(90)).dy, closeTo(before, 0.5));
    expect(
      list(tester).scrollController.position.isScrollingNotifier.value,
      isTrue,
    );
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(tester.getTopLeft(row(90)).dy, closeTo(before - 40, 0.5));
    await tester.pump(const Duration(seconds: 1));
    await gesture.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(
      list(tester).scrollController.position.isScrollingNotifier.value,
      isFalse,
    );
    await dispose(tester);
  });

  testWidgets('筛掉上方卡片并显示提示条时保持当前话题', (tester) async {
    await mount(tester);
    topics.publish([
      for (var id = 40; id < 140; id++)
        topic(id, title: id < 80 ? '屏蔽关键词 $id' : '保留话题 $id'),
    ]);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    await jump(tester, 90);
    final before = tester.getTopLeft(row(90)).dy;
    await container.read(preferencesProvider.notifier).setTopicFilterKeywords([
      '屏蔽关键词',
    ]);
    await tester.pump();
    expect(tester.getTopLeft(row(90)).dy, closeTo(before, 0.5));
    expect(list(tester).itemKeys, isNot(contains('topic-40')));
    await dispose(tester);
  });

  testWidgets('J 导航通过真实索引把远处话题移入视口', (tester) async {
    await mount(tester);
    container.read(selectedTopicProvider.notifier).select(topicId: 100);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    nextTopic(tester);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(container.read(selectedTopicProvider).topicId, 101);
    final target = tester.getRect(row(101));
    expect(target.top, greaterThanOrEqualTo(48));
    expect(target.bottom, lessThanOrEqualTo(800));
    await dispose(tester);
  });

  testWidgets('键盘定位期间插入话题后仍定位选中项', (tester) async {
    await mount(tester);
    container.read(selectedTopicProvider.notifier).select(topicId: 100);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    nextTopic(tester);
    topics.publish([
      for (var id = 200; id < 220; id++) topic(id),
      ...topics.items,
    ]);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(container.read(selectedTopicProvider).topicId, 101);
    expect(tester.getRect(row(101)).top, greaterThanOrEqualTo(48));
    expect(tester.getRect(row(101)).bottom, lessThanOrEqualTo(800));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 160)),
    );
    nextTopic(tester);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(container.read(selectedTopicProvider).topicId, 102);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 160)),
    );
    invokeShortcut(tester, ShortcutAction.previousItem);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(container.read(selectedTopicProvider).topicId, 101);
    await dispose(tester);
  });

  testWidgets('到底翻页结果及时显示且不会重复请求', (tester) async {
    await mount(tester);
    topics.page = Completer();
    topics.publish(topics.items, hasMore: true);
    await tester.pump();
    final sc = list(tester).scrollController;
    sc.jumpTo(sc.position.maxScrollExtent);
    await tester.pump();
    expect(topics.loadMoreCalls, 1);
    await tester.pump();
    expect(topics.loadMoreCalls, 1);
    topics.page!.complete([topic(140), topic(141)]);
    await tester.pump();
    expect(list(tester).itemKeys, contains('topic-140'));
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(topics.loadMoreCalls, 1);
    await dispose(tester);
  });

  testWidgets('回顶及刷新信号继续工作', (tester) async {
    await mount(tester);
    await jump(tester, 90);
    container.read(scrollToTopProvider.notifier).trigger();
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(list(tester).scrollController.offset, closeTo(0, 0.5));
    final before = topics.builds;
    container.read(fabRefreshSignalProvider.notifier).trigger();
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(topics.builds, before + 1);
    expect(row(40), findsOneWidget);
    await dispose(tester);
  });

  testWidgets('分类切换后各自恢复阅读位置', (tester) async {
    container.read(pinnedCategoriesProvider.notifier).add(2);
    await mount(tester);
    await jump(tester, 90);
    final before = tester.getTopLeft(row(90)).dy;
    invokeShortcut(tester, ShortcutAction.nextTab);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(container.read(currentTabCategoryIdProvider), 2);
    await jump(tester, 110);
    invokeShortcut(tester, ShortcutAction.previousTab);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(container.read(currentTabCategoryIdProvider), isNull);
    expect(tester.getTopLeft(row(90)).dy, closeTo(before, 0.5));
    await dispose(tester);
  });

  testWidgets('手机宽度变化后保持首个阅读话题', (tester) async {
    PlatformUtils.debugDesktopOverride = false;
    await mount(tester, size: const Size(390, 844));
    final widget = list(tester);
    final done = widget.listController.jumpToIndex(
      widget.itemKeys.indexOf('topic-90'),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    await done;
    final before = tester.getTopLeft(row(90)).dy;
    tester.view.physicalSize = const Size(600, 844);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(tester.getTopLeft(row(90)).dy, closeTo(before, 0.5));
    await dispose(tester);
  });

  testWidgets('低帧率下拖动结束后头部弹簧能够收敛', (tester) async {
    await mount(tester);
    await jump(tester, 90);
    final gesture = await tester.startGesture(const Offset(700, 450));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
    await gesture.up();
    final frames = await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    expect(frames, lessThan(50));
    expect(tester.binding.hasScheduledFrame, isFalse);
    await dispose(tester);
  });
  testWidgets('置顶折叠分组保持在新增普通话题前，已读后自动收起', (tester) async {
    await mount(tester);
    topics.publish([
      topic(41),
      topic(40, pinned: true, unseen: true),
      topic(42),
    ]);
    await tester.pumpAndSettle();
    expect(
      list(tester).itemKeys.indexOf('topic-40'),
      lessThan(list(tester).itemKeys.indexOf('topic-41')),
    );
    expect(row(40), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pinned-topics-toggle')));
    await tester.pumpAndSettle();
    expect(list(tester).itemKeys, isNot(contains('topic-40')));
    topics.publish([
      topic(43),
      topic(41),
      topic(40, pinned: true, unseen: true),
      topic(42),
    ]);
    await tester.pumpAndSettle();
    expect(
      list(tester).itemKeys,
      isNot(contains('topic-40')),
      reason: '普通新话题不应重置手动折叠',
    );
    await tester.tap(find.byKey(const ValueKey('pinned-topics-toggle')));
    await tester.pumpAndSettle();
    expect(
      list(tester).itemKeys.indexOf('topic-40'),
      lessThan(list(tester).itemKeys.indexOf('topic-43')),
    );
    topics.publish([topic(40, pinned: true), topic(43), topic(41), topic(42)]);
    await tester.pumpAndSettle();
    expect(list(tester).itemKeys, isNot(contains('topic-40')));
    expect(find.byKey(const ValueKey('pinned-topics-toggle')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏已读置顶默认折叠，可手动查看，再有未读自动展开', (tester) async {
    await mount(tester, size: const Size(375, 812));
    topics.publish([topic(40, pinned: true), topic(41)]);
    await tester.pumpAndSettle();
    expect(list(tester).itemKeys, isNot(contains('topic-40')));
    await tester.tap(find.byKey(const ValueKey('pinned-topics-toggle')));
    await tester.pumpAndSettle();
    expect(row(40), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pinned-topics-toggle')));
    await tester.pumpAndSettle();
    topics.publish([topic(41), topic(40, pinned: true, unseen: true)]);
    await tester.pumpAndSettle();
    expect(row(40), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('读过置顶主帖即自动折叠，未读回复不会重新展开', (tester) async {
    await mount(tester);
    final pin = topic(40, title: '置顶话题', pinned: true, unseen: true);
    topics.publish([pin, topic(41)]);
    await tester.pumpAndSettle();
    expect(row(40), findsOneWidget);
    topics.publish([
      pin.copyWith(
        unseen: false,
        unread: 9,
        lastReadPostNumber: 1,
        highestPostNumber: 10,
      ),
      topic(41),
    ]);
    await tester.pumpAndSettle();
    expect(list(tester).itemKeys, isNot(contains('topic-40')));
    topics.publish([
      pin.copyWith(
        unseen: false,
        unread: 10,
        lastReadPostNumber: 1,
        highestPostNumber: 11,
      ),
      topic(41),
    ]);
    await tester.pumpAndSettle();
    expect(list(tester).itemKeys, isNot(contains('topic-40')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('分组折叠判定不影响卡片原有的未读回复数和标题样式', (tester) async {
    await mount(tester);
    topics.publish([
      topic(
        40,
        title: '已读置顶',
        pinned: true,
      ).copyWith(unread: 2, lastReadPostNumber: 3, highestPostNumber: 10),
      topic(41),
    ]);
    await tester.pumpAndSettle();
    expect(list(tester).itemKeys, isNot(contains('topic-40')));
    await tester.tap(find.byKey(const ValueKey('pinned-topics-toggle')));
    await tester.pumpAndSettle();
    expect(row(40), findsOneWidget);
    final title = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.textSpan?.toPlainText().contains('已读置顶') == true,
      ),
    );
    expect(title.textSpan!.style!.fontWeight, FontWeight.w500);
    expect(
      find.descendant(of: row(40), matching: find.text('2')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('展开的置顶标题与条目连续衔接，末行与普通话题保持间距', (tester) async {
    await mount(tester, size: const Size(375, 812));
    topics.publish([
      topic(40, title: '置顶一', pinned: true, unseen: true),
      topic(41, title: '置顶二', pinned: true),
      topic(42, title: '普通话题'),
    ]);
    await tester.pumpAndSettle();
    final header = find.byType(PinnedTopicsHeader);
    expect(
      tester.getRect(header).bottom,
      closeTo(tester.getRect(row(40)).top, 0.1),
    );
    expect(
      tester.getRect(row(40)).bottom,
      closeTo(tester.getRect(row(41)).top, 0.1),
    );
    final cards = tester
        .widgetList<CompactTopicCard>(find.byType(CompactTopicCard))
        .toList();
    // 标题行是分组第 0 项，置顶话题依次接在后面
    expect(cards.map((card) => card.group), [
      (index: 1, count: 3),
      (index: 2, count: 3),
    ]);
    // 再新增一条置顶时，旧末行缓存必须切换为中间行。
    topics.publish([
      topic(40, title: '置顶一', pinned: true, unseen: true),
      topic(41, title: '置顶二', pinned: true),
      topic(43, title: '置顶三', pinned: true),
      topic(42, title: '普通话题'),
    ]);
    await tester.pumpAndSettle();
    final second = tester.widget<CompactTopicCard>(
      find.descendant(of: row(41), matching: find.byType(CompactTopicCard)),
    );
    expect(second.group, (index: 2, count: 4));
    expect(tester.takeException(), isNull);
  });
}
