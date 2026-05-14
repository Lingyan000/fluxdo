import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/app_localizations.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/bookmark_name_suggestions_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
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
  required Future<List<String>> Function() suggestionsLoader,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      bookmarkNameSuggestionPageLoaderProvider.overrideWithValue(
        (_, __) async {
          final names = await suggestionsLoader();
          return TopicListResponse(
            topics: [
              for (final name in names)
                _bookmarkTopic(
                  topicId: 100 + name.length,
                  bookmarkId: 200 + name.length,
                  bookmarkName: name,
                ),
            ],
          );
        },
      ),
    ],
  );
}

void main() {
  testWidgets('书签已全量补水后打开编辑面板不会再次全量加载候选', (tester) async {
    var suggestionLoadCount = 0;
    final seedTopics = [
      _bookmarkTopic(topicId: 1, bookmarkId: 101, bookmarkName: 'image'),
      _bookmarkTopic(topicId: 2, bookmarkId: 102, bookmarkName: 'beta'),
    ];
    final container = await _createContainer(
      suggestionsLoader: () async {
        suggestionLoadCount++;
        return const [];
      },
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _LauncherTestApp(),
      ),
    );

    container
        .read(bookmarkNameSuggestionsProvider.notifier)
        .seedFromTopics(seedTopics, isCompleteSnapshot: true);

    await tester.tap(find.text('打开编辑'));
    await tester.pumpAndSettle();

    expect(find.byType(BookmarkEditSheet), findsOneWidget);
    expect(suggestionLoadCount, 0);
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
            seedTopics: [
              Topic(
                id: 1,
                title: 'Topic 1',
                slug: 'topic-1',
                postsCount: 1,
                replyCount: 0,
                views: 0,
                likeCount: 0,
                categoryId: '1',
                bookmarkId: 101,
                bookmarkName: 'image',
              ),
              Topic(
                id: 2,
                title: 'Topic 2',
                slug: 'topic-2',
                postsCount: 1,
                replyCount: 0,
                views: 0,
                likeCount: 0,
                categoryId: '1',
                bookmarkId: 102,
                bookmarkName: 'beta',
              ),
            ],
          );
        },
        child: const Text('打开编辑'),
      ),
    );
  }
}
