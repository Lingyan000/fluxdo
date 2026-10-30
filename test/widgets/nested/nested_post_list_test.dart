import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/nested_topic.dart';
import 'package:fluxdo/models/nested_reading_position.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/nested_post_list.dart';
import 'package:fluxdo/providers/nested_reading_provider.dart';
import 'package:fluxdo/providers/nested_topic_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/widgets/nested/nested_post_card.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/services/local_notification_service.dart';

Post _post(int number, {bool long = false}) => Post(
  id: number,
  username: 'tester',
  avatarTemplate: '',
  cooked:
      '<p>Reply $number</p>${long ? List.filled(30, '<p>A paragraph for testing reading position.</p>').join() : ''}',
  postNumber: number,
  postType: 1,
  updatedAt: DateTime(2026),
  createdAt: DateTime(2026),
  likeCount: 0,
  replyCount: 0,
);
final _detail = TopicDetail.fromJson({
  'id': 1,
  'title': 'Reading test',
  'posts_count': 30,
  'category_id': 1,
  'post_stream': {'posts': [], 'stream': []},
});

class _Nested extends NestedTopicNotifier {
  _Nested(this.preset) : super(const NestedTopicParams(topicId: 1));
  final NestedTopicState preset;
  void deliver(NestedChildCreatedEvent event) {
    state = AsyncData(state.requireValue.copyWith(lastChildCreated: event));
  }

  @override
  Future<NestedTopicState> build() async => preset;
}

Future<void> _pump(
  WidgetTester tester, {
  required NestedTopicState state,
  Size size = const Size(375, 812),
  double scale = 1,
  bool dark = false,
  VoidCallback? onResume,
  ValueChanged<Set<int>>? onVisible,
  NestedReadingSession? session,
  NestedReadingPosition? restore,
  AutoScrollController? controller,
  _Nested? notifier,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final store = NestedReadingStore(prefs, 'test');
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final scroll = controller ?? AutoScrollController();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      categoryMapProvider.overrideWith(
        (_) => const AsyncData(<int, Category>{}),
      ),
      categoriesProvider.overrideWith((_) async => <Category>[]),
      nestedReadingStoreProvider.overrideWithValue(store),
      nestedTopicProvider(const NestedTopicParams(topicId: 1))
          .overrideWith(() => notifier ?? _Nested(state)),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    store.dispose();
    scroll.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
          locale: const Locale('zh'),
          supportedLocales: AppLocaleUtils.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(
              body: NestedPostList(
                nestedState: state,
                params: const NestedTopicParams(topicId: 1),
                detail: _detail,
                blockedUsernames: const {},
                topicId: 1,
                scrollController: scroll,
                headerKey: GlobalKey(),
                isLoggedIn: false,
                session: session,
                restorePosition: restore,
                resumePosition: const NestedReadingPosition(
                  postNumber: 20,
                  rootPostNumber: 2,
                ),
                onResume: onResume,
                onVisiblePostsChanged: onVisible,
                onReply: (_, {initialContent}) {},
                onEdit: (_) {},
                onRefreshPost: (_) {},
                onJumpToPost: (_) {},
                onVoteChanged: (_, _) {},
                onScrollNotification: (_) => false,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('新回复等待主动加载，页面重建保留提示和折叠状态', (tester) async {
    final session = NestedReadingSession()..expanded[2] = false;
    final state = NestedTopicState(
      roots: [
        NestedNode(
          post: _post(2),
          children: [NestedNode(post: _post(3))],
        ),
      ],
    );
    final notifier = _Nested(state);
    await _pump(tester, state: state, session: session, notifier: notifier);
    notifier.deliver(
      NestedChildCreatedEvent(parentPostNumber: 2, post: _post(8)),
    );
    await tester.pumpAndSettle();
    expect(session.expanded[2], false);
    expect(find.text('1 条新回复'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is NestedPostCard && w.node.post.postNumber == 8,
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester, state: state, session: session);
    expect(find.text('1 条新回复'), findsOneWidget);
    await tester.tap(find.text('1 条新回复'));
    await tester.pumpAndSettle();
    expect(session.expanded[2], true);
    expect(
      find.byWidgetPredicate(
        (w) => w is NestedPostCard && w.node.post.postNumber == 8,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final settings in [
    (const Size(375, 812), 1.0, false),
    (const Size(375, 812), 2.0, false),
    (const Size(812, 375), 1.0, true),
  ]) {
    testWidgets('续读入口不自动跳转，小屏/大字/横屏 ${settings.$1} ${settings.$2}', (
      tester,
    ) async {
      var resumed = 0;
      await _pump(
        tester,
        state: NestedTopicState(roots: [NestedNode(post: _post(2))]),
        size: settings.$1,
        scale: settings.$2,
        dark: settings.$3,
        onResume: () => resumed++,
      );
      expect(resumed, 0);
      await tester.tap(find.byKey(const ValueKey('nested-resume-reading')));
      expect(resumed, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('屏外的已加载回复不提前上报，长分支可跳到下一条主回复', (tester) async {
    final scroll = AutoScrollController();
    Set<int> visible = {};
    await _pump(
      tester,
      controller: scroll,
      onVisible: (posts) => visible = posts,
      state: NestedTopicState(
        roots: [
          NestedNode(
            post: _post(2, long: true),
            children: [NestedNode(post: _post(20))],
          ),
          NestedNode(post: _post(3)),
        ],
      ),
    );
    expect(visible, {2});
    await tester.tap(find.byTooltip('下一条主回复'));
    await tester.pumpAndSettle();
    expect(visible.contains(3), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('续读展开目标祖先，恢复长回复中段而非跳到帖首', (tester) async {
    final session = NestedReadingSession()..expanded[2] = false;
    final scroll = AutoScrollController();
    await _pump(
      tester,
      controller: scroll,
      session: session,
      restore: const NestedReadingPosition(
        postNumber: 20,
        rootPostNumber: 2,
        offset: -240,
        expanded: {2: false},
      ),
      state: NestedTopicState(
        contextMode: true,
        targetPostNumber: 20,
        contextChain: NestedNode(
          post: _post(2),
          children: [NestedNode(post: _post(20, long: true))],
        ),
      ),
    );
    expect(session.expanded[2], isTrue);
    expect(session.position?.postNumber, 20);
    expect(session.position?.offset, closeTo(-240, 1));
    expect(tester.takeException(), isNull);
  });
  testWidgets('长分支先展示少量回复，主动展开后显示其余回复', (tester) async {
    final state = NestedTopicState(
      roots: [
        NestedNode(
          post: _post(2),
          children: [
            for (var number = 3; number <= 8; number++)
              NestedNode(post: _post(number)),
          ],
        ),
      ],
    );
    await _pump(tester, state: state);
    expect(find.text('展开其余 3 条回复'), findsOneWidget);
    final button = find.text('展开其余 3 条回复');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('展开其余 3 条回复'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is NestedPostCard && widget.node.post.postNumber == 8,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('临时离开后按同一实例恢复阅读现场', (tester) async {
    final session = NestedReadingSession();
    final scroll = AutoScrollController();
    final state = NestedTopicState(
      roots: [
        NestedNode(
          post: _post(2, long: true),
          children: [NestedNode(post: _post(20, long: true))],
        ),
      ],
    );
    await _pump(tester, state: state, session: session, controller: scroll);
    scroll.jumpTo(450);
    await tester.pumpAndSettle();
    final original = session.position!;
    expect(original.offset, lessThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester, state: state, session: session);
    expect(session.position?.postNumber, original.postNumber);
    expect(session.position?.offset, closeTo(original.offset, 1));
    expect(tester.takeException(), isNull);
  });
}
