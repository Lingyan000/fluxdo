import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/navigation/nav_action_bus.dart';
import 'package:fluxdo/pages/bookmarks_page.dart';
import 'package:fluxdo/pages/bookmarks/bookmarks_models.dart';
import 'package:fluxdo/pages/topics_page.dart';
import 'package:fluxdo/providers/bookmark_name_suggestions_provider.dart';
import 'package:fluxdo/providers/bookmarks_reconciler.dart';
import 'package:fluxdo/providers/bookmarks_repository.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/user_content_providers.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/storage/bookmark_cache_dao.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/bookmark/bookmarks_list_content.dart';
import 'package:fluxdo/widgets/bookmark/bookmarks_workspace_tab_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../storage/bookmark_hive_test_support.dart';

Topic _bookmarkTopic({
  required int topicId,
  required int bookmarkId,
  required String title,
  String? bookmarkName,
  String? bookmarkableType,
}) {
  return Topic(
    id: topicId,
    title: title,
    slug: 'topic-$topicId',
    postsCount: 1,
    replyCount: 0,
    views: 0,
    likeCount: 0,
    categoryId: '1',
    bookmarkId: bookmarkId,
    bookmarkName: bookmarkName,
    bookmarkableType: bookmarkableType,
  );
}

Future<ProviderContainer> _createContainer({
  List<String>? suggestionRequests,
}) async {
  SharedPreferences.setMockInitialValues({
    'pref_bookmarks_open_mode': 'tabbedWorkspace',
    'bookmark_last_full_sync_test_user': DateTime.now()
        .toUtc()
        .toIso8601String(),
  });
  final prefs = await SharedPreferences.getInstance();

  // 用临时目录 Hive box 做 BookmarksRepository 的存储——避免 testWidgets 触发
  // 真实 path_provider 调用。
  final storage = await BookmarkHiveTestSupport.create();
  addTearDown(storage.dispose);

  final repo = BookmarksRepository(
    BookmarkCacheDao(boxFactory: storage.openBox),
  );
  addTearDown(repo.dispose);

  // 预填充 2 条书签：用 _bookmarkTopic 的 raw JSON 作 payload。
  Map<String, dynamic> payloadOf(Topic topic, int bookmarkId) {
    return {
      'id': topic.id,
      'title': topic.title,
      'slug': topic.slug,
      'posts_count': topic.postsCount,
      'reply_count': topic.replyCount,
      'views': topic.views,
      'like_count': topic.likeCount,
      'category_id': int.parse(topic.categoryId),
      '_bookmark_id': bookmarkId,
      if (topic.bookmarkName != null) '_bookmark_name': topic.bookmarkName,
      if (topic.bookmarkableType != null)
        '_bookmarkable_type': topic.bookmarkableType,
      '_bookmark_updated_at': DateTime.utc(2026, 5, 1).toIso8601String(),
    };
  }

  final preset = [
    _bookmarkTopic(
      topicId: 1,
      bookmarkId: 101,
      title: 'Alpha',
      bookmarkName: 'image',
      bookmarkableType: 'Post',
    ),
    _bookmarkTopic(
      topicId: 2,
      bookmarkId: 102,
      title: 'Beta',
      bookmarkName: 'beta',
      bookmarkableType: 'Topic',
    ),
  ];
  await repo.upsertEntries('test_user', [
    for (final t in preset)
      BookmarkCacheEntry(
        bookmarkId: t.bookmarkId!,
        topicId: t.id,
        nameNormalized: t.bookmarkName,
        updatedAt: DateTime.utc(2026, 5, 1),
        cachedAt: DateTime.utc(2026, 5, 1),
        payload: payloadOf(t, t.bookmarkId!),
      ),
  ]);

  return ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      categoryMapProvider.overrideWith(
        (ref) => const AsyncValue.data(<int, Category>{}),
      ),
      bookmarksRepositoryProvider.overrideWithValue(repo),
      currentUsernameProvider.overrideWith((ref) async => 'test_user'),
      bookmarkRawPageLoaderProvider.overrideWithValue(
        (_) async => BookmarkPageParseResult(
          topics: const [],
          entries: const [],
          moreUrl: null,
        ),
      ),
      // 旧 provider stub，保留兼容（已不被新代码使用）。
      // ignore: deprecated_member_use_from_same_package
      bookmarkNameSuggestionPageLoaderProvider.overrideWithValue((
        page,
        limit,
      ) async {
        suggestionRequests?.add('$page:$limit');
        return TopicListResponse(topics: const []);
      }),
    ],
  );
}

Future<ProviderContainer> _createContainerForWidgetTest(
  WidgetTester tester, {
  List<String>? suggestionRequests,
}) async {
  final container = (await tester.runAsync(
    () => _createContainer(suggestionRequests: suggestionRequests),
  ))!;
  ProviderSubscription<AsyncValue<List<Topic>>>? sub;
  // 初始化或断言失败也先卸载页面，让延迟清理在容器仍存活时完成。
  // 此回调后注册，先于 repository 和 Hive 存储的清理执行。
  addTearDown(() async {
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero);
      await tester.pumpAndSettle();
    } finally {
      try {
        sub?.close();
      } finally {
        container.dispose();
      }
    }
  });
  await tester.runAsync(() async {
    sub = container.listen<AsyncValue<List<Topic>>>(
      bookmarksProvider,
      (_, _) {},
    );
    await container.read(bookmarksProvider.future);
    await container
        .read(bookmarkNameSuggestionsProvider.notifier)
        .ensureLoaded();
  });
  return container;
}

Future<void> _pumpPage(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder _findBookmarkInList(Topic topic) {
  // 自绘卡片没有标题 Text，使用与生产代码一致的书签身份。
  return find.descendant(
    of: find.byType(BookmarksListContent),
    matching: find.byKey(ValueKey(bookmarkTopicIdentity(topic))),
  );
}

final _alphaBookmark = _bookmarkTopic(
  topicId: 1,
  bookmarkId: 101,
  title: 'Alpha',
  bookmarkName: 'image',
  bookmarkableType: 'Post',
);

Finder _findWorkspaceTab(String title) {
  return find.descendant(
    of: find.byType(BookmarksWorkspaceTabBar),
    matching: find.text(title),
  );
}

// Widget 测试的不变量检查早于 addTearDown，必须在测试体退出前
// 卸载页面并处理 disposeDeferred 的事件队列任务。
void _testPage(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero);
    }
  });
}

void main() {
  _testPage('工作区会复用同一话题标签并在关闭后回到书签页', (tester) async {
    PlatformUtils.debugDesktopOverride = true;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);

    final suggestionRequests = <String>[];
    final container = await _createContainerForWidgetTest(
      tester,
      suggestionRequests: suggestionRequests,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _BookmarksPageTestApp(),
      ),
    );
    await _pumpPage(tester);

    final loaded = await container
        .read(bookmarkNameSuggestionsProvider.notifier)
        .ensureLoaded();
    expect(loaded, ['beta', 'image']);
    expect(suggestionRequests, isEmpty);

    await tester.tap(_findBookmarkInList(_alphaBookmark));
    await _pumpPage(tester);

    expect(find.text('detail:1 active:true'), findsOneWidget);
    expect(_findWorkspaceTab('Alpha'), findsOneWidget);

    await tester.tap(_findWorkspaceTab('我的书签'));
    await _pumpPage(tester);

    expect(find.text('detail:1 active:true'), findsNothing);
    expect(_findWorkspaceTab('Alpha'), findsOneWidget);
    expect(_findBookmarkInList(_alphaBookmark), findsOneWidget);

    await tester.tap(_findBookmarkInList(_alphaBookmark));
    await _pumpPage(tester);

    expect(find.text('detail:1 active:true'), findsOneWidget);
    expect(_findWorkspaceTab('Alpha'), findsOneWidget);
    expect(_findBookmarkInList(_alphaBookmark), findsNothing);

    await tester.tap(find.byIcon(Symbols.close_rounded));
    await _pumpPage(tester);

    expect(find.text('detail:1 active:true'), findsNothing);
    expect(_findWorkspaceTab('Alpha'), findsNothing);
    expect(_findBookmarkInList(_alphaBookmark), findsOneWidget);
  });

  _testPage('离开书签页时会清空工作区标签', (tester) async {
    PlatformUtils.debugDesktopOverride = true;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);

    final container = await _createContainerForWidgetTest(tester);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _BookmarksPageLifecycleHost(),
      ),
    );
    await _pumpPage(tester);

    final hostState = tester.state<_BookmarksPageLifecycleHostState>(
      find.byType(_BookmarksPageLifecycleHost),
    );

    await tester.tap(_findBookmarkInList(_alphaBookmark));
    await _pumpPage(tester);

    expect(_findWorkspaceTab('Alpha'), findsOneWidget);
    expect(find.text('detail:1 active:true'), findsOneWidget);

    hostState.setActive(false);
    await _pumpPage(tester);

    hostState.setActive(true);
    await _pumpPage(tester);

    expect(_findWorkspaceTab('Alpha'), findsNothing);
    expect(find.text('detail:1 active:true'), findsNothing);
    expect(_findBookmarkInList(_alphaBookmark), findsOneWidget);

    await tester.tap(_findBookmarkInList(_alphaBookmark));
    await _pumpPage(tester);

    expect(_findWorkspaceTab('Alpha'), findsOneWidget);

    hostState.setVisible(false);
    await _pumpPage(tester);

    hostState.setVisible(true);
    await _pumpPage(tester);

    expect(_findWorkspaceTab('Alpha'), findsNothing);
    expect(find.text('detail:1 active:true'), findsNothing);
    expect(_findBookmarkInList(_alphaBookmark), findsOneWidget);
  });

  _testPage('打开书签话题时会把书签上下文传给工作区详情页', (tester) async {
    PlatformUtils.debugDesktopOverride = true;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);

    final container = await _createContainerForWidgetTest(tester);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            locale: const Locale('zh'),
            navigatorKey: navigatorKey,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: Scaffold(
              body: BookmarksPage(
                workspaceTopicPageBuilder: (context, tab, parentActive) {
                  return Center(
                    child: Text(
                      'detail:${tab.topicId} bookmark:${tab.bookmarkId} type:${tab.bookmarkableType}',
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await _pumpPage(tester);

    await tester.tap(_findBookmarkInList(_alphaBookmark));
    await _pumpPage(tester);

    expect(find.text('detail:1 bookmark:101 type:Post'), findsOneWidget);
  });

  _testPage('手机端标签页模式会显示数字方框并可打开切换器', (tester) async {
    PlatformUtils.debugDesktopOverride = false;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));

    final container = await _createContainerForWidgetTest(tester);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _BookmarksPageTestApp(),
      ),
    );
    await _pumpPage(tester);

    expect(find.byType(BookmarksWorkspaceTabBar), findsNothing);

    await tester.tap(_findBookmarkInList(_alphaBookmark));
    await _pumpPage(tester);

    expect(find.text('detail:1 active:true'), findsOneWidget);
    expect(container.read(barVisibilityProvider), 0);
    expect(
      find.byKey(const ValueKey('bookmark-workspace-mobile-back')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bookmark-workspace-mobile-close')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bookmark-workspace-mobile-count-button')),
      findsOneWidget,
    );
    expect(find.text('已打开 1 个'), findsNothing);
    expect(find.text('1'), findsOneWidget);

    final titleText = tester.widget<Text>(
      find.byKey(const ValueKey('bookmark-workspace-mobile-title-text')),
    );
    expect(titleText.data, 'Alpha');
    expect(titleText.maxLines, 1);
    expect(titleText.overflow, TextOverflow.ellipsis);

    final backLeft = tester.getTopLeft(
      find.byKey(const ValueKey('bookmark-workspace-mobile-back')),
    );
    final closeLeft = tester.getTopLeft(
      find.byKey(const ValueKey('bookmark-workspace-mobile-close')),
    );
    final titleLeft = tester.getTopLeft(
      find.byKey(const ValueKey('bookmark-workspace-mobile-title-text')),
    );
    final countLeft = tester.getTopLeft(
      find.byKey(const ValueKey('bookmark-workspace-mobile-count-button')),
    );
    expect(backLeft.dx, lessThan(closeLeft.dx));
    expect(closeLeft.dx, lessThan(titleLeft.dx));
    expect(titleLeft.dx, lessThan(countLeft.dx));

    await tester.tap(
      find.byKey(const ValueKey('bookmark-workspace-mobile-count-button')),
    );
    await _pumpPage(tester);

    expect(
      find.byKey(const ValueKey('bookmark-workspace-switcher-sheet')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('bookmark-workspace-switcher-sheet')),
        matching: find.text('Alpha'),
      ),
      findsOneWidget,
    );

    Navigator.of(
      tester.element(
        find.byKey(const ValueKey('bookmark-workspace-switcher-sheet')),
      ),
    ).pop();
    await _pumpPage(tester);

    await tester.tap(
      find.byKey(const ValueKey('bookmark-workspace-mobile-back')),
    );
    await _pumpPage(tester);

    expect(container.read(barVisibilityProvider), 1);
    expect(
      find.byKey(const ValueKey('bookmark-workspace-mobile-count-button')),
      findsOneWidget,
    );
    expect(find.text('已打开 1 个'), findsNothing);
  });

  _testPage('手机端工作区返回按钮会回到书签列表并保留已打开话题', (tester) async {
    PlatformUtils.debugDesktopOverride = false;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));

    final container = await _createContainerForWidgetTest(tester);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _BookmarksPageTestApp(),
      ),
    );
    await _pumpPage(tester);

    await tester.tap(_findBookmarkInList(_alphaBookmark));
    await _pumpPage(tester);

    expect(find.text('detail:1 active:true'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('bookmark-workspace-mobile-back')),
    );
    await _pumpPage(tester);

    expect(container.read(barVisibilityProvider), 1);
    expect(find.text('detail:1 active:true'), findsNothing);
    expect(_findBookmarkInList(_alphaBookmark), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bookmark-workspace-mobile-title-bar')),
      findsNothing,
    );
  });

  _testPage('手机端工作区关闭按钮会关闭当前标签页', (tester) async {
    PlatformUtils.debugDesktopOverride = false;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));

    final container = await _createContainerForWidgetTest(tester);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _BookmarksPageTestApp(),
      ),
    );
    await _pumpPage(tester);

    await tester.tap(_findBookmarkInList(_alphaBookmark));
    await _pumpPage(tester);

    await tester.tap(
      find.byKey(const ValueKey('bookmark-workspace-mobile-close')),
    );
    await _pumpPage(tester);

    expect(container.read(barVisibilityProvider), 1);
    expect(find.text('detail:1 active:true'), findsNothing);
    expect(_findBookmarkInList(_alphaBookmark), findsOneWidget);
  });

  _testPage('手机端重选底栏书签会回到书签列表', (tester) async {
    PlatformUtils.debugDesktopOverride = false;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));

    final container = await _createContainerForWidgetTest(tester);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _BookmarksPageTestApp(),
      ),
    );
    await _pumpPage(tester);

    await tester.tap(_findBookmarkInList(_alphaBookmark));
    await _pumpPage(tester);

    container.read(navActionBusProvider.notifier).state = const NavActionEvent(
      targetId: NavEntryIds.bookmarks,
      action: NavAction.scrollToTop,
      nonce: 1,
    );
    await _pumpPage(tester);

    expect(find.text('detail:1 active:true'), findsNothing);
    expect(_findBookmarkInList(_alphaBookmark), findsOneWidget);
  });
}

class _BookmarksPageTestApp extends StatelessWidget {
  const _BookmarksPageTestApp();

  @override
  Widget build(BuildContext context) {
    return TranslationProvider(
      child: MaterialApp(
        locale: const Locale('zh'),
        navigatorKey: navigatorKey,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocaleUtils.supportedLocales,
        home: Scaffold(
          body: BookmarksPage(
            workspaceTopicPageBuilder: (context, tab, parentActive) {
              return Center(
                child: Text('detail:${tab.topicId} active:$parentActive'),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _BookmarksPageLifecycleHost extends StatefulWidget {
  const _BookmarksPageLifecycleHost();

  @override
  State<_BookmarksPageLifecycleHost> createState() =>
      _BookmarksPageLifecycleHostState();
}

class _BookmarksPageLifecycleHostState
    extends State<_BookmarksPageLifecycleHost> {
  bool _isActive = true;
  bool _isVisible = true;

  void setActive(bool value) {
    setState(() {
      _isActive = value;
    });
  }

  void setVisible(bool value) {
    setState(() {
      _isVisible = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    return TranslationProvider(
      child: MaterialApp(
        locale: const Locale('zh'),
        navigatorKey: navigatorKey,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocaleUtils.supportedLocales,
        home: Scaffold(
          body: _isVisible
              ? BookmarksPage(
                  isActive: _isActive,
                  workspaceTopicPageBuilder: (context, tab, parentActive) {
                    return Center(
                      child: Text('detail:${tab.topicId} active:$parentActive'),
                    );
                  },
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}
