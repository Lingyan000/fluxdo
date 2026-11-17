import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/bookmarks/bookmarks_models.dart';
import 'package:fluxdo/providers/bookmark_name_suggestions_provider.dart';
import 'package:fluxdo/providers/bookmarks_reconciler.dart';
import 'package:fluxdo/providers/bookmarks_repository.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/user_content_providers.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/storage/bookmark_cache_dao.dart';
import 'package:fluxdo/widgets/bookmark/bookmark_edit_sheet.dart';
import 'package:fluxdo/widgets/bookmark/bookmark_edit_sheet_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../storage/bookmark_hive_test_support.dart';

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
  required WidgetTester tester,
  required BookmarkPageLoader suggestionsLoader,
}) async {
  final setup = await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues({
      'bookmark_last_full_sync_test_user': DateTime.now()
          .toUtc()
          .toIso8601String(),
    });
    final prefs = await SharedPreferences.getInstance();
    final storage = await BookmarkHiveTestSupport.create();
    addTearDown(storage.dispose);

    final repo = BookmarksRepository(
      BookmarkCacheDao(boxFactory: storage.openBox),
    );
    addTearDown(repo.dispose);

    Map<String, dynamic> payloadOf(Topic topic) {
      return {
        'id': topic.id,
        'title': topic.title,
        'slug': topic.slug,
        'posts_count': topic.postsCount,
        'reply_count': topic.replyCount,
        'views': topic.views,
        'like_count': topic.likeCount,
        'category_id': int.parse(topic.categoryId),
        '_bookmark_id': topic.bookmarkId,
        if (topic.bookmarkName != null) '_bookmark_name': topic.bookmarkName,
        '_bookmark_updated_at': DateTime.utc(2026, 5, 1).toIso8601String(),
      };
    }

    final topics = [
      _bookmarkTopic(topicId: 1, bookmarkId: 101, bookmarkName: 'image'),
      _bookmarkTopic(topicId: 2, bookmarkId: 102, bookmarkName: 'beta'),
    ];
    await repo.upsertEntries('test_user', [
      for (final topic in topics)
        BookmarkCacheEntry(
          bookmarkId: topic.bookmarkId!,
          topicId: topic.id,
          nameNormalized: topic.bookmarkName,
          updatedAt: DateTime.utc(2026, 5, 1),
          cachedAt: DateTime.utc(2026, 5, 1),
          payload: payloadOf(topic),
        ),
    ]);

    return (prefs: prefs, repo: repo);
  });

  final prefs = setup!.prefs;
  final repo = setup.repo;
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      currentUsernameProvider.overrideWith((ref) async => 'test_user'),
      bookmarksRepositoryProvider.overrideWithValue(repo),
      bookmarkRawPageLoaderProvider.overrideWithValue(
        (_) async => BookmarkPageParseResult(
          topics: const [],
          entries: const [],
          moreUrl: null,
        ),
      ),
      bookmarkNameSuggestionPageLoaderProvider.overrideWithValue(
        suggestionsLoader,
      ),
    ],
  );
  ProviderSubscription<AsyncValue<List<Topic>>>? sub;
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
  addTearDown(() => sub?.close());
  return container;
}

void main() {
  testWidgets('书签已全量补水后打开编辑面板不会再次全量加载候选', (tester) async {
    final suggestionRequests = <String>[];
    final container = await _createContainer(
      tester: tester,
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

    await tester.pump();

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
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
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
