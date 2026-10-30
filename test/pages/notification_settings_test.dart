import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/tag_notification_level.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/pages/tag_topics_page.dart';
import 'package:fluxdo/pages/category_topics_page.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/message_bus/topic_tracking_providers.dart';
import 'package:fluxdo/providers/message_bus/topic_list_events.dart';
import 'package:fluxdo/providers/topic_list/filter_provider.dart';
import 'package:fluxdo/widgets/topic/topic_list_update_banner.dart';
import 'package:fluxdo/widgets/topic/topic_card_prewarmer.dart';
import 'package:fluxdo/providers/tag_notification_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/topic/tag_notification_button.dart';
import 'package:fluxdo/widgets/topic/topic_notification_button.dart';
import 'package:fluxdo/widgets/common/notification_level_button.dart';
import 'package:fluxdo/widgets/topic/sort_and_tags_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NotificationService extends Fake implements DiscourseService {
  TagNotificationLevel level = TagNotificationLevel.regular;
  Future<TagNotificationLevel> Function()? load;
  Future<void> Function()? save;
  Future<TopicListResponse> Function(List<int>)? loadUpdates;
  final reads = <String>[];
  final writes = <(String, TagNotificationLevel)>[];
  final categoryWrites = <(int, int)>[];

  @override
  Future<void> setCategoryNotificationLevel(int categoryId, int level) async {
    categoryWrites.add((categoryId, level));
    await save?.call();
  }

  @override
  Future<TagNotificationLevel> getTagNotificationLevel(String tagName) async {
    reads.add(tagName);
    return load != null ? load!() : level;
  }

  @override
  Future<void> setTagNotificationLevel(
    String tagName,
    TagNotificationLevel level,
  ) async {
    writes.add((tagName, level));
    await save?.call();
    this.level = level;
  }

  @override
  Future<TopicListResponse> getFilteredTopics({
    required String filter,
    int? categoryId,
    String? categorySlug,
    String? parentCategorySlug,
    List<String>? tags,
    String? period,
    int page = 0,
    String? order,
    bool? ascending,
    String? subset,
    List<int>? topicIds,
  }) async {
    if (topicIds != null && loadUpdates != null) return loadUpdates!(topicIds);
    return TopicListResponse(
      topics: [],
      tags: [const Tag(id: 42, name: '开发')],
    );
  }
}

class _CurrentUser extends CurrentUserNotifier {
  _CurrentUser(this.user);

  final User? user;

  @override
  User? build() => user;

  void setUser(User? user) => state = AsyncData(user);
}

class _NoMessageBus extends MessageBusInitNotifier {
  @override
  void build() {}
}

class _EmptyTopicTracking extends TopicTrackingStateNotifier {
  @override
  Map<int, TrackedTopicState> build() => {};
}

Future<ProviderContainer> _pumpPage(
  WidgetTester tester,
  _NotificationService service, {
  _CurrentUser? currentUser,
  Widget? page,
  Size size = const Size(390, 844),
  TopicListFilter initialFilter = TopicListFilter.latest,
}) async {
  SharedPreferences.setMockInitialValues({
    'topic_sort_filter': initialFilter.name,
  });
  final prefs = await SharedPreferences.getInstance();
  PlatformUtils.debugDesktopOverride = size.width >= 900;
  addTearDown(() => PlatformUtils.debugDesktopOverride = null);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      discourseServiceProvider.overrideWithValue(service),
      categoriesProvider.overrideWith((_) async => [_category]),
      topicTrackingStateProvider.overrideWith(_EmptyTopicTracking.new),
      messageBusInitProvider.overrideWith(_NoMessageBus.new),
      currentUserProvider.overrideWith(
        () =>
            currentUser ??
            _CurrentUser(User(id: 1, username: 'tester', trustLevel: 1)),
      ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
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
          home: page ?? const TagTopicsPage(tagName: '开发'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

final _category = Category(
  id: 7,
  name: '开发',
  slug: 'development',
  color: '0088CC',
  textColor: 'FFFFFF',
  notificationLevel: CategoryNotificationLevel.tracking.value,
);

Finder _subscriptionButton() => find.descendant(
  of: find.byType(NotificationLevelButton),
  matching: find.byType(IconButton),
);

Future<void> _selectLevel(WidgetTester tester, String label) async {
  await tester.tap(_subscriptionButton());
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(ListTile, label));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  for (final isCategory in [true, false]) {
    testWidgets('${isCategory ? "分类" : "标签"} 空的新话题列表能显示横幅，失败后可重试', (
      tester,
    ) async {
      final pending = Completer<TopicListResponse>();
      final service = _NotificationService()
        ..loadUpdates = (_) => pending.future;
      final container = await _pumpPage(
        tester,
        service,
        initialFilter: TopicListFilter.newTopics,
        page: isCategory
            ? CategoryTopicsPage(category: _category)
            : const TagTopicsPage(tagName: '开发'),
      );
      expect(find.byType(TopicListUpdateBanner), findsNothing);
      container
          .read(topicListEventsProvider.notifier)
          .publish(
            const TopicListEvent(
              topicId: 101,
              type: 'new_topic',
              categoryId: 7,
              tags: [
                {'id': 42},
              ],
            ),
          );
      await tester.pumpAndSettle();
      expect(find.byType(TopicListUpdateBanner), findsOneWidget);
      await tester.tap(find.byType(TopicListUpdateBanner));
      await tester.pump();
      expect(
        tester
            .widget<TopicListUpdateBanner>(find.byType(TopicListUpdateBanner))
            .loading,
        isTrue,
      );
      pending.completeError(
        DioException(requestOptions: RequestOptions(path: '/new.json')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TopicListUpdateBanner>(find.byType(TopicListUpdateBanner))
            .loading,
        isFalse,
      );
      expect(
        tester
            .widget<TopicListUpdateBanner>(find.byType(TopicListUpdateBanner))
            .count,
        1,
      );
      service.loadUpdates = (_) async => TopicListResponse(topics: []);
      await tester.tap(find.byType(TopicListUpdateBanner));
      await tester.pumpAndSettle();
      expect(find.byType(TopicListUpdateBanner), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final isCategory in [true, false]) {
    testWidgets('${isCategory ? "分类" : "标签"} 横幅加载中切换筛选不插入旧响应', (tester) async {
      final pending = Completer<TopicListResponse>();
      final service = _NotificationService()
        ..loadUpdates = (_) => pending.future;
      final container = await _pumpPage(
        tester,
        service,
        initialFilter: TopicListFilter.newTopics,
        page: isCategory
            ? CategoryTopicsPage(category: _category)
            : const TagTopicsPage(tagName: '开发'),
      );
      container
          .read(topicListEventsProvider.notifier)
          .publish(
            const TopicListEvent(
              topicId: 101,
              type: 'new_topic',
              categoryId: 7,
              tags: [
                {'id': 42},
              ],
            ),
          );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TopicListUpdateBanner));
      await tester.pump();
      tester
          .widget<SortAndTagsBar>(find.byType(SortAndTagsBar))
          .onFilterChanged(TopicListFilter.latest);
      await tester.pumpAndSettle();
      pending.complete(
        TopicListResponse(
          topics: [
            Topic(
              id: 101,
              title: 'outdated',
              slug: 'outdated',
              postsCount: 1,
              replyCount: 0,
              views: 0,
              likeCount: 0,
              categoryId: '7',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TopicCardPrewarmScope>(find.byType(TopicCardPrewarmScope))
            .topics,
        isEmpty,
      );
      expect(find.byType(TopicListUpdateBanner), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [320.0, 1200.0]) {
    for (final isCategory in [true, false]) {
      testWidgets('${isCategory ? "分类" : "标签"} $width：订阅与搜索对齐并能保存', (
        tester,
      ) async {
        final service = _NotificationService()
          ..level = TagNotificationLevel.tracking;
        await _pumpPage(
          tester,
          service,
          size: Size(width, 844),
          page: isCategory
              ? CategoryTopicsPage(category: _category)
              : const TagTopicsPage(tagName: '开发'),
        );

        expect(_subscriptionButton(), findsOneWidget);
        final subscription = tester.getRect(_subscriptionButton());
        final search = tester.getRect(
          find.ancestor(
            of: find.byTooltip(S.current.common_search),
            matching: find.byType(IconButton),
          ),
        );
        expect(subscription.size, search.size);
        expect(subscription.top, search.top);
        expect(subscription.right, lessThanOrEqualTo(search.left));
        expect(
          subscription.bottom,
          lessThanOrEqualTo(tester.getTopLeft(find.byType(SortAndTagsBar)).dy),
        );

        await _selectLevel(tester, '关注新话题');
        await tester.pumpAndSettle();
        if (isCategory) {
          expect(service.categoryWrites, [(7, 4)]);
        } else {
          expect(service.writes, [
            ('开发', TagNotificationLevel.watchingFirstPost),
          ]);
        }
        expect(
          find.byTooltip('${S.current.topic_notificationSettings}: 关注新话题'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('分类顶部订阅保存失败后恢复原级别及侧栏共享状态', (tester) async {
    final saving = Completer<void>();
    final service = _NotificationService()..save = () => saving.future;
    final container = await _pumpPage(
      tester,
      service,
      page: CategoryTopicsPage(category: _category),
    );
    await _selectLevel(tester, '关注');
    expect(tester.widget<IconButton>(_subscriptionButton()).onPressed, isNull);
    expect(container.read(categoryNotificationOverridesProvider)[7], 3);

    saving.completeError(
      DioException(
        requestOptions: RequestOptions(path: '/category/7/notifications'),
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(categoryNotificationOverridesProvider)[7], 2);
    expect(
      find.byTooltip('${S.current.topic_notificationSettings}: 跟踪'),
      findsOneWidget,
    );
  });

  testWidgets('话题顶部订阅使用相同面板并保留四档选项', (tester) async {
    TopicNotificationLevel? selected;
    await _pumpPage(
      tester,
      _NotificationService(),
      size: const Size(320, 640),
      page: Scaffold(
        appBar: AppBar(
          title: const Text('话题'),
          actions: [
            TopicNotificationButton(
              level: TopicNotificationLevel.tracking,
              onChanged: (level) => selected = level,
            ),
          ],
        ),
      ),
    );
    await tester.tap(_subscriptionButton());
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(4));
    expect(find.text('关注新话题'), findsNothing);
    await tester.tap(
      find.widgetWithText(ListTile, TopicNotificationLevel.watching.label),
    );
    await tester.pumpAndSettle();
    expect(selected, TopicNotificationLevel.watching);
    expect(tester.takeException(), isNull);
  });

  testWidgets('话题详情订阅入口保持摘要卡片内的胶囊样式', (tester) async {
    TopicNotificationLevel? selected;
    await _pumpPage(
      tester,
      _NotificationService(),
      size: const Size(390, 844),
      page: Scaffold(
        body: Center(
          child: TopicNotificationButton(
            level: TopicNotificationLevel.tracking,
            onChanged: (level) => selected = level,
            style: TopicNotificationButtonStyle.chip,
          ),
        ),
      ),
    );
    // 胶囊样式不占用 AppBar 图标按钮，直接内联展示当前级别文案
    expect(find.byType(NotificationLevelButton), findsNothing);
    final chip = find.text(TopicNotificationLevel.tracking.label);
    expect(chip, findsOneWidget);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(4));
    await tester.tap(
      find.widgetWithText(ListTile, TopicNotificationLevel.watching.label),
    );
    await tester.pumpAndSettle();
    expect(selected, TopicNotificationLevel.watching);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未登录不请求订阅设置，登录后显示服务端当前状态', (tester) async {
    final service = _NotificationService()
      ..level = TagNotificationLevel.tracking;
    final currentUser = _CurrentUser(null);
    await _pumpPage(tester, service, currentUser: currentUser);

    expect(find.byType(TagNotificationButton), findsNothing);
    expect(service.reads, isEmpty);
    expect(find.text('该标签下暂无话题'), findsOneWidget);

    currentUser.setUser(User(id: 1, username: 'tester', trustLevel: 1));
    await tester.pumpAndSettle();
    expect(service.reads, ['开发']);
    expect(
      find.byTooltip('${S.current.topic_notificationSettings}: 跟踪'),
      findsOneWidget,
    );
  });

  testWidgets('标签页提供五档订阅，重复选择不提交，保存后可重新读取', (tester) async {
    final service = _NotificationService()
      ..level = TagNotificationLevel.watchingFirstPost;
    final container = await _pumpPage(tester, service);

    await tester.tap(_subscriptionButton());
    await tester.pumpAndSettle();
    for (final label in ['静音', '常规', '跟踪', '关注', '关注新话题']) {
      expect(find.widgetWithText(ListTile, label), findsOneWidget);
    }
    expect(find.text('此标签有新话题时通知'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final selected = tester.widget<ListTile>(
      find.widgetWithText(ListTile, '关注新话题'),
    );
    expect(selected.trailing, isNotNull);
    await tester.tap(find.widgetWithText(ListTile, '关注新话题'));
    await tester.pumpAndSettle();
    expect(service.writes, isEmpty);

    for (final (label, level) in [
      ('静音', TagNotificationLevel.muted),
      ('常规', TagNotificationLevel.regular),
      ('跟踪', TagNotificationLevel.tracking),
      ('关注', TagNotificationLevel.watching),
      ('关注新话题', TagNotificationLevel.watchingFirstPost),
    ]) {
      await _selectLevel(tester, label);
      await tester.pumpAndSettle();
      expect(service.writes.last, ('开发', level));
      expect(
        find.byTooltip('${S.current.topic_notificationSettings}: $label'),
        findsOneWidget,
      );
    }

    container.invalidate(tagNotificationLevelProvider('开发'));
    await tester.pumpAndSettle();
    expect(service.reads, ['开发', '开发']);
    expect(
      find.byTooltip('${S.current.topic_notificationSettings}: 关注新话题'),
      findsOneWidget,
    );
  });

  testWidgets('订阅读取失败可重试，加载完成前不允许操作', (tester) async {
    final service = _NotificationService()
      ..load = () async => throw DioException(
        requestOptions: RequestOptions(path: '/tag/开发/notifications.json'),
      );
    await _pumpPage(tester, service);
    expect(find.byTooltip('加载标签订阅设置失败，点击重试'), findsOneWidget);

    final loading = Completer<TagNotificationLevel>();
    service.load = () => loading.future;
    await tester.tap(_subscriptionButton());
    await tester.pump();
    expect(tester.widget<IconButton>(_subscriptionButton()).onPressed, isNull);
    expect(service.writes, isEmpty);

    loading.complete(TagNotificationLevel.muted);
    await tester.pumpAndSettle();
    expect(service.reads, ['开发', '开发']);
    expect(
      find.byTooltip('${S.current.topic_notificationSettings}: 静音'),
      findsOneWidget,
    );
  });

  testWidgets('保存中阻止重复提交，失败保留原设置并允许重试', (tester) async {
    final saving = Completer<void>();
    final service = _NotificationService()..save = () => saving.future;
    final container = await _pumpPage(tester, service);

    await _selectLevel(tester, '关注');
    expect(tester.widget<IconButton>(_subscriptionButton()).onPressed, isNull);
    await container
        .read(tagNotificationLevelProvider('开发').notifier)
        .setLevel(TagNotificationLevel.muted);
    expect(service.writes, [('开发', TagNotificationLevel.watching)]);

    saving.completeError(
      DioException(
        requestOptions: RequestOptions(path: '/tag/开发/notifications.json'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byTooltip('${S.current.topic_notificationSettings}: 常规'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    service.save = null;
    await _selectLevel(tester, '关注');
    await tester.pumpAndSettle();
    expect(service.writes, hasLength(2));
    expect(
      find.byTooltip('${S.current.topic_notificationSettings}: 关注'),
      findsOneWidget,
    );
  });

  testWidgets('切换账号重新加载，旧账号迟到的保存结果不覆盖新账号', (tester) async {
    final saving = Completer<void>();
    final service = _NotificationService()..save = () => saving.future;
    final currentUser = _CurrentUser(
      User(id: 1, username: 'first', trustLevel: 1),
    );
    await _pumpPage(tester, service, currentUser: currentUser);

    await _selectLevel(tester, '关注');
    service.level = TagNotificationLevel.muted;
    currentUser.setUser(User(id: 2, username: 'second', trustLevel: 1));
    await tester.pumpAndSettle();
    expect(service.reads, ['开发', '开发']);

    saving.complete();
    await tester.pumpAndSettle();
    expect(
      find.byTooltip('${S.current.topic_notificationSettings}: 静音'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
