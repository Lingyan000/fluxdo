import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_interaction.dart';
import 'package:fluxdo/pages/topics_page.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/message_bus/topic_tracking_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/topic_list/tab_state_provider.dart';
import 'package:fluxdo/providers/topic_list/topic_list_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CurrentUser extends CurrentUserNotifier {
  @override
  User? build() => null;
}

class _LoggedInUser extends CurrentUserNotifier {
  @override
  User? build() => User(id: 1, username: 'tester', trustLevel: 1);
}

class _Tracking extends TopicTrackingStateNotifier {
  @override
  Map<int, TrackedTopicState> build() => {};
}

class _MessageBusInit extends MessageBusInitNotifier {
  @override
  void build() {}
}

class _TopicsService extends Fake implements DiscourseService {
  int requests = 0;
  List<Topic>? seedTopics;
  Completer<void>? pendingRead;
  final readIds = <int>[];

  @override
  Future<List<int>> dismissTopicIds(
    List<int> topicIds, {
    required bool dismissPosts,
  }) async {
    readIds.addAll(topicIds);
    if (pendingRead != null) await pendingRead!.future;
    return topicIds;
  }

  TopicListResponse _response() {
    requests++;
    return TopicListResponse(
      topics:
          seedTopics ??
          [
            Topic(
              id: 10,
              title: '启动话题',
              slug: 'startup',
              postsCount: 1,
              replyCount: 0,
              views: 0,
              likeCount: 0,
              categoryId: '2',
            ),
          ],
    );
  }

  @override
  Future<TopicListResponse> getLatestTopics({
    int page = 0,
    String? order,
    bool? ascending,
  }) async => _response();

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
  }) async => _response();
}

void main() {
  testWidgets('首页一键已读有加载反馈，成功后自动折叠且普通话题不受影响', (tester) async {
    PlatformUtils.debugDesktopOverride = false;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    Topic topic(int id, {bool pinned = false}) => Topic(
      id: id,
      title: '测试话题 $id',
      slug: '$id',
      postsCount: 3,
      replyCount: 2,
      views: 0,
      likeCount: 0,
      categoryId: '2',
      highestPostNumber: 3,
      pinned: pinned,
      unseen: true,
    );
    final service = _TopicsService()
      ..seedTopics = [
        topic(11),
        topic(10, pinned: true),
        topic(
          12,
          pinned: true,
        ).copyWith(unseen: false, unread: 2, lastReadPostNumber: 1),
      ]
      ..pendingRead = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        discourseServiceProvider.overrideWithValue(service),
        currentUserProvider.overrideWith(_LoggedInUser.new),
        topicTrackingStateProvider.overrideWith(_Tracking.new),
        messageBusInitProvider.overrideWith(_MessageBusInit.new),
        categoryMapProvider.overrideWith(
          (ref) => const AsyncData(<int, Category>{}),
        ),
        visibleCategoryIdsProvider.overrideWith((ref) => <int>{}),
        miniAppPullEnabledProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: const Scaffold(body: TopicsPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('topic-10')), findsOneWidget);
    final action = find.byKey(const ValueKey('pinned-topics-mark-read'));
    await tester.tap(action);
    await tester.pump();
    expect(tester.widget<IconButton>(action).onPressed, isNull);
    expect(service.readIds, [10]);
    service.pendingRead!.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('topic-10')), findsNothing);
    expect(find.byKey(const ValueKey('topic-11')), findsOneWidget);
    final topics = container.read(topicListProvider(null)).requireValue;
    expect(topics.firstWhere((t) => t.id == 10).unseen, isFalse);
    expect(topics.firstWhere((t) => t.id == 11).unseen, isTrue);
    expect(topics.firstWhere((t) => t.id == 12).unread, 2);
    expect(topics.firstWhere((t) => t.id == 12).lastReadPostNumber, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页启动只加载一次，同值标签不刷新，实际改标签才刷新', (tester) async {
    PlatformUtils.debugDesktopOverride = false;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = _TopicsService();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        discourseServiceProvider.overrideWithValue(service),
        currentUserProvider.overrideWith(_CurrentUser.new),
        topicTrackingStateProvider.overrideWith(_Tracking.new),
        messageBusInitProvider.overrideWith(_MessageBusInit.new),
        categoryMapProvider.overrideWith(
          (ref) => const AsyncData(<int, Category>{}),
        ),
        visibleCategoryIdsProvider.overrideWith((ref) => <int>{}),
        miniAppPullEnabledProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: const Scaffold(body: TopicsPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(service.requests, 1, reason: '首帧同步空标签不能触发第二次请求');
    expect(find.byKey(const ValueKey('topic-10')), findsOneWidget);

    container.read(tabTagsProvider(null).notifier).state = <String>[];
    await tester.pumpAndSettle();
    expect(service.requests, 1, reason: '新建的同值列表不能触发刷新');

    container.read(tabTagsProvider(null).notifier).state = ['dart'];
    await tester.pumpAndSettle();
    expect(service.requests, 2);

    container.read(tabTagsProvider(null).notifier).state = ['dart'];
    await tester.pumpAndSettle();
    expect(service.requests, 2);

    container.read(tabTagsProvider(null).notifier).state = [];
    await tester.pumpAndSettle();
    expect(service.requests, 3, reason: '清空已有标签仍然需要刷新');
    expect(tester.takeException(), isNull);
  });
}
