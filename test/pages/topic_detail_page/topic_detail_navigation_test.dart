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
  bool get hasMoreBefore => false;
  @override
  bool get hasMoreAfter => false;

  void publish(TopicDetail detail) => state = AsyncData(detail);
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    LocaleSettings.setLocale(AppLocale.zh);
    container = ProviderContainer(
      overrides: [
        aiSharedPreferencesProvider.overrideWithValue(prefs),
        sharedPreferencesProvider.overrideWithValue(prefs),
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
          ),
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
