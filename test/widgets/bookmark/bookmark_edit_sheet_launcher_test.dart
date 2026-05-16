import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/bookmarks/bookmarks_models.dart';
import 'package:fluxdo/providers/bookmark_name_suggestions_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/user_content_providers.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/bookmark/bookmark_edit_sheet.dart';
import 'package:fluxdo/widgets/bookmark/bookmark_edit_sheet_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

Topic _bookmarkTopic({
  required int topicId,
  required int bookmarkId,
  String? bookmarkName,
}) {
  return Topic(
    id: topicId,
    title: 'Topic $topicId',
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
  required BookmarkPageLoader bookmarksLoader,
  required BookmarkPageLoader suggestionsLoader,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      bookmarksPageLoaderProvider.overrideWithValue(bookmarksLoader),
      bookmarkNameSuggestionPageLoaderProvider.overrideWithValue(
        suggestionsLoader,
      ),
    ],
  );
}

Future<void> _waitForHydration(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await container.read(bookmarksProvider.future);
  for (var i = 0; i < 10; i++) {
    await tester.pump();
    if (!container.read(bookmarksProvider.notifier).isHydratingAll) {
      return;
    }
  }
  fail('书签补水未在预期时间内完成');
}

void main() {
  testWidgets('书签已全量补水后打开编辑面板不会再次全量加载候选', (tester) async {
    final suggestionRequests = <String>[];
    final container = await _createContainer(
      bookmarksLoader: (page, limit) async {
        switch (page) {
          case 0:
            return TopicListResponse(
              topics: [
                _bookmarkTopic(
                  topicId: 1,
                  bookmarkId: 101,
                  bookmarkName: 'image',
                ),
                _bookmarkTopic(
                  topicId: 2,
                  bookmarkId: 102,
                  bookmarkName: 'beta',
                ),
              ],
              moreTopicsUrl: '/u/test/bookmarks.json?page=1',
            );
          default:
            return TopicListResponse(topics: const []);
        }
      },
      suggestionsLoader: (page, limit) async {
        suggestionRequests.add('$page:$limit');
        return TopicListResponse(topics: const []);
      },
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _LauncherTestApp(),
      ),
    );

    await _waitForHydration(tester, container);
    container
        .read(bookmarkNameSuggestionsProvider.notifier)
        .seedFromTopics(
          container.read(bookmarksProvider).value ?? const [],
          isCompleteSnapshot: true,
        );

    await tester.tap(find.text('打开编辑'));
    await tester.pumpAndSettle();

    expect(find.byType(BookmarkEditSheet), findsOneWidget);
    expect(suggestionRequests, isEmpty);
    expect(container.read(bookmarkNameSuggestionsProvider), ['beta', 'image']);
  });
}

class _LauncherTestApp extends StatelessWidget {
  const _LauncherTestApp();

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
        home: const Scaffold(body: _LauncherTestButton()),
      ),
    );
  }
}

class _LauncherTestButton extends ConsumerWidget {
  const _LauncherTestButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: FilledButton(
        onPressed: () {
          showBookmarkEditSheetWithCachedNames(
            context,
            ref,
            bookmarkId: 101,
            initialName: 'image',
            seedTopics: ref.read(bookmarksProvider).value ?? const [],
          );
        },
        child: const Text('打开编辑'),
      ),
    );
  }
}
