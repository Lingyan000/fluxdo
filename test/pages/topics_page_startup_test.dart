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
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

class _TopicsService extends Fake implements DiscourseService {
  int requests = 0;

  TopicListResponse _response() {
    requests++;
    return TopicListResponse(
      topics: [
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
