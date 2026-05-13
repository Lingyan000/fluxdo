import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/app_localizations.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/bookmarks/bookmarks_models.dart';
import 'package:fluxdo/pages/bookmarks_page.dart';
import 'package:fluxdo/providers/bookmark_name_suggestions_provider.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/user_content_providers.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/bookmark/bookmarks_list_content.dart';
import 'package:fluxdo/widgets/bookmark/bookmarks_workspace_tab_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

Topic _bookmarkTopic({
  required int topicId,
  required int bookmarkId,
  required String title,
  String? bookmarkName,
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
  );
}

Future<ProviderContainer> _createContainer({
  List<String>? suggestionRequests,
}) async {
  SharedPreferences.setMockInitialValues({
    'pref_bookmarks_open_mode': 'tabbedWorkspace',
  });
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      categoryMapProvider.overrideWith(
        (ref) => const AsyncValue.data(<int, Category>{}),
      ),
      bookmarksPageLoaderProvider.overrideWithValue((page, limit) async {
        switch (page) {
          case 0:
            return TopicListResponse(
              topics: [
                _bookmarkTopic(
                  topicId: 1,
                  bookmarkId: 101,
                  title: 'Alpha',
                  bookmarkName: 'image',
                ),
                _bookmarkTopic(
                  topicId: 2,
                  bookmarkId: 102,
                  title: 'Beta',
                  bookmarkName: 'beta',
                ),
              ],
              moreTopicsUrl: '/u/test/bookmarks.json?page=1',
            );
          default:
            return TopicListResponse(topics: const []);
        }
      }),
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
