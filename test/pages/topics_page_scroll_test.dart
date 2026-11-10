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
import 'package:shared_preferences/shared_preferences.dart';

Topic topic(int id, {String? title}) => Topic(
  id: id,
  title: title ?? '话题 $id ${'长标题内容 ' * (id % 4 * 8)}',
  slug: 'topic-$id',
  postsCount: 10,
  replyCount: 9,
  views: 120,
  likeCount: 5,
  categoryId: '2',
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
            home: const Scaffold(body: TopicsPage()),
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
}
