import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/navigation/nav_action_bus.dart';
import 'package:fluxdo/pages/bookmarks_page.dart';
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

Finder _findBookmarkInList(String title) {
  return find.descendant(
    of: find.byType(BookmarksListContent),
    matching: find.text(title),
  );
}

Finder _findWorkspaceTab(String title) {
  return find.descendant(
    of: find.byType(BookmarksWorkspaceTabBar),
    matching: find.text(title),
  );
}

void main() {
  testWidgets('工作区会复用同一话题标签并在关闭后回到书签页', (tester) async {
    PlatformUtils.debugDesktopOverride = true;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);

    final suggestionRequests = <String>[];
    final container = await _createContainer(
      suggestionRequests: suggestionRequests,
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _BookmarksPageTestApp(),
      ),
    );
    await tester.pumpAndSettle();

    final loaded = await container
        .read(bookmarkNameSuggestionsProvider.notifier)
        .ensureLoaded();
    expect(loaded, ['beta', 'image']);
    expect(suggestionRequests, isEmpty);

    await tester.tap(_findBookmarkInList('Alpha'));
    await tester.pumpAndSettle();

    expect(find.text('detail:1 active:true'), findsOneWidget);
    expect(_findWorkspaceTab('Alpha'), findsOneWidget);

    await tester.tap(_findWorkspaceTab('我的书签'));
    await tester.pumpAndSettle();

    expect(find.text('detail:1 active:true'), findsNothing);
    expect(find.text('Alpha'), findsNWidgets(2));

    await tester.tap(_findBookmarkInList('Alpha'));
    await tester.pumpAndSettle();

    expect(find.text('detail:1 active:true'), findsOneWidget);
    expect(_findWorkspaceTab('Alpha'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    expect(find.text('detail:1 active:true'), findsNothing);
    expect(_findWorkspaceTab('Alpha'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('离开书签页时会清空工作区标签', (tester) async {
    PlatformUtils.debugDesktopOverride = true;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);

    final container = await _createContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _BookmarksPageLifecycleHost(),
      ),
    );
    await tester.pumpAndSettle();

    final hostState = tester.state<_BookmarksPageLifecycleHostState>(
      find.byType(_BookmarksPageLifecycleHost),
    );

    await tester.tap(_findBookmarkInList('Alpha'));
    await tester.pumpAndSettle();

    expect(_findWorkspaceTab('Alpha'), findsOneWidget);
    expect(find.text('detail:1 active:true'), findsOneWidget);

    hostState.setActive(false);
    await tester.pumpAndSettle();

    hostState.setActive(true);
    await tester.pumpAndSettle();

    expect(_findWorkspaceTab('Alpha'), findsNothing);
    expect(find.text('detail:1 active:true'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);

    await tester.tap(_findBookmarkInList('Alpha'));
    await tester.pumpAndSettle();

    expect(_findWorkspaceTab('Alpha'), findsOneWidget);

    hostState.setVisible(false);
    await tester.pumpAndSettle();

    hostState.setVisible(true);
    await tester.pumpAndSettle();

    expect(_findWorkspaceTab('Alpha'), findsNothing);
    expect(find.text('detail:1 active:true'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('打开书签话题时会把书签上下文传给工作区详情页', (tester) async {
    PlatformUtils.debugDesktopOverride = true;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);

    final container = await _createContainer();
    addTearDown(container.dispose);

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
    await tester.pumpAndSettle();

    await tester.tap(_findBookmarkInList('Alpha'));
    await tester.pumpAndSettle();

    expect(find.text('detail:1 bookmark:101 type:Post'), findsOneWidget);
  });

  testWidgets('手机端标签页模式会显示数字方框并可打开切换器', (tester) async {
    PlatformUtils.debugDesktopOverride = false;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));

    final container = await _createContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _BookmarksPageTestApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(BookmarksWorkspaceTabBar), findsNothing);

    await tester.tap(_findBookmarkInList('Alpha'));
    await tester.pumpAndSettle();

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
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('bookmark-workspace-switcher-sheet')),
      findsOneWidget,
    );
    expect(find.text('Alpha'), findsAtLeastNWidgets(1));

    Navigator.of(
      tester.element(
        find.byKey(const ValueKey('bookmark-workspace-switcher-sheet')),
      ),
    ).pop();
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('bookmark-workspace-mobile-back')),
    );
    await tester.pumpAndSettle();

    expect(container.read(barVisibilityProvider), 1);
    expect(
      find.byKey(const ValueKey('bookmark-workspace-mobile-count-button')),
      findsOneWidget,
    );
    expect(find.text('已打开 1 个'), findsNothing);
  });

  testWidgets('手机端工作区返回按钮会回到书签列表并保留已打开话题', (tester) async {
    PlatformUtils.debugDesktopOverride = false;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));

    final container = await _createContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _BookmarksPageTestApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_findBookmarkInList('Alpha'));
    await tester.pumpAndSettle();

    expect(find.text('detail:1 active:true'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('bookmark-workspace-mobile-back')),
    );
    await tester.pumpAndSettle();

    expect(container.read(barVisibilityProvider), 1);
    expect(find.text('detail:1 active:true'), findsNothing);
    expect(_findBookmarkInList('Alpha'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bookmark-workspace-mobile-title-bar')),
      findsNothing,
    );
  });

  testWidgets('手机端工作区关闭按钮会关闭当前标签页', (tester) async {
    PlatformUtils.debugDesktopOverride = false;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));

    final container = await _createContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _BookmarksPageTestApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_findBookmarkInList('Alpha'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('bookmark-workspace-mobile-close')),
    );
    await tester.pumpAndSettle();

    expect(container.read(barVisibilityProvider), 1);
    expect(find.text('detail:1 active:true'), findsNothing);
    expect(_findBookmarkInList('Alpha'), findsOneWidget);
  });

  testWidgets('手机端重选底栏书签会回到书签列表', (tester) async {
    PlatformUtils.debugDesktopOverride = false;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));

    final container = await _createContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _BookmarksPageTestApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_findBookmarkInList('Alpha'));
    await tester.pumpAndSettle();

    container.read(navActionBusProvider.notifier).state = const NavActionEvent(
      targetId: NavEntryIds.bookmarks,
      action: NavAction.scrollToTop,
      nonce: 1,
    );
    await tester.pumpAndSettle();

    expect(find.text('detail:1 active:true'), findsNothing);
    expect(_findBookmarkInList('Alpha'), findsOneWidget);
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
