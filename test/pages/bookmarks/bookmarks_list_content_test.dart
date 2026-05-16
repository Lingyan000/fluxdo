import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/bookmark/bookmarks_list_content.dart';

Topic _topic({required int id, required String title, String? bookmarkName}) {
  return Topic(
    id: id,
    title: title,
    slug: 'topic-$id',
    postsCount: 1,
    replyCount: 0,
    views: 0,
    likeCount: 0,
    categoryId: '1',
    bookmarkName: bookmarkName,
  );
}

void main() {
  testWidgets('汇总条只统计非空名称并按数量降序展示', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoryMapProvider.overrideWith(
            (ref) => const AsyncValue.data(<int, Category>{}),
          ),
        ],
        child: _BookmarksListTestHost(
          topics: [
            _BookmarkSeed(id: 1, title: 'Alpha', bookmarkName: 'codex'),
            _BookmarkSeed(id: 2, title: 'Beta', bookmarkName: 'beta'),
            _BookmarkSeed(id: 3, title: 'Gamma', bookmarkName: 'codex'),
            _BookmarkSeed(id: 4, title: 'No Name', bookmarkName: '   '),
          ],
        ),
      ),
    );

    expect(find.text('全部'), findsOneWidget);
    expect(find.text('codex (2)'), findsOneWidget);
    expect(find.text('beta (1)'), findsOneWidget);
    expect(find.text('未设置 (1)'), findsOneWidget);
  });

  testWidgets('切换汇总项后只显示对应名称书签，切回全部恢复完整列表', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoryMapProvider.overrideWith(
            (ref) => const AsyncValue.data(<int, Category>{}),
          ),
        ],
        child: _BookmarksListTestHost(
          topics: [
            _BookmarkSeed(id: 1, title: 'Alpha', bookmarkName: 'codex'),
            _BookmarkSeed(id: 2, title: 'Beta', bookmarkName: 'beta'),
            _BookmarkSeed(id: 3, title: 'Gamma', bookmarkName: 'codex'),
          ],
        ),
      ),
    );

    await tester.tap(find.text('codex (2)'));
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);

    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);
  });

  testWidgets('点击未设置后只显示未命名书签', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoryMapProvider.overrideWith(
            (ref) => const AsyncValue.data(<int, Category>{}),
          ),
        ],
        child: _BookmarksListTestHost(
          topics: const [
            _BookmarkSeed(id: 1, title: 'Alpha', bookmarkName: 'codex'),
            _BookmarkSeed(id: 2, title: 'No Name 1', bookmarkName: '   '),
            _BookmarkSeed(id: 3, title: 'No Name 2'),
          ],
        ),
      ),
    );

    await tester.tap(find.text('未设置 (2)'));
    await tester.pumpAndSettle();

    expect(find.text('No Name 1'), findsOneWidget);
    expect(find.text('No Name 2'), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);
  });

  testWidgets('隐藏汇总条再恢复后保留之前的筛选状态', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoryMapProvider.overrideWith(
            (ref) => const AsyncValue.data(<int, Category>{}),
          ),
        ],
        child: _BookmarksListTestHost(
          topics: [
            _BookmarkSeed(id: 1, title: 'Alpha', bookmarkName: 'codex'),
            _BookmarkSeed(id: 2, title: 'Beta', bookmarkName: 'beta'),
            _BookmarkSeed(id: 3, title: 'Gamma', bookmarkName: 'codex'),
          ],
        ),
      ),
    );

    await tester.tap(find.text('codex (2)'));
    await tester.pumpAndSettle();

    final state = tester.state<_BookmarksListTestHostState>(
      find.byType(_BookmarksListTestHost),
    );
    state.hideSummaryBar();
    await tester.pumpAndSettle();

    expect(find.text('codex (2)'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);

    state.showSummaryBar();
    await tester.pumpAndSettle();

    expect(find.text('codex (2)'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);
  });

  testWidgets('桌面端可以通过导航按钮横向滚动顶部书签标签', (tester) async {
    PlatformUtils.debugDesktopOverride = true;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoryMapProvider.overrideWith(
            (ref) => const AsyncValue.data(<int, Category>{}),
          ),
        ],
        child: _BookmarksListTestHost(
          topics: List.generate(
            14,
            (index) => _BookmarkSeed(
              id: index + 1,
              title: 'Topic $index',
              bookmarkName: 'tag-$index',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final summaryScrollable = tester.state<ScrollableState>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.right,
      ),
    );

    expect(summaryScrollable.position.pixels, 0);

    await tester.tap(
      find.byKey(const ValueKey('bookmark-summary-scroll-right')),
    );
    await tester.pumpAndSettle();

    expect(summaryScrollable.position.pixels, greaterThan(0));
  });

  testWidgets('桌面端滚轮会横向滚动顶部书签标签且不改选中项', (tester) async {
    PlatformUtils.debugDesktopOverride = true;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoryMapProvider.overrideWith(
            (ref) => const AsyncValue.data(<int, Category>{}),
          ),
        ],
        child: _BookmarksListTestHost(
          topics: List.generate(
            14,
            (index) => _BookmarkSeed(
              id: index + 1,
              title: 'Topic $index',
              bookmarkName: 'tag-$index',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final state = tester.state<_BookmarksListTestHostState>(
      find.byType(_BookmarksListTestHost),
    );
    final summaryScrollable = tester.state<ScrollableState>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.right,
      ),
    );
    expect(summaryScrollable.position.pixels, 0);
    expect(state._selectedBookmarkName, isNull);
    expect(state._scrollController.offset, 0);

    final region = find.byKey(const ValueKey('bookmark-summary-wheel-region'));
    final center = tester.getCenter(region);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: center);
    await tester.pump();

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: center,
        scrollDelta: const Offset(0, 20),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pumpAndSettle();

    expect(summaryScrollable.position.pixels, greaterThan(0));
    expect(state._selectedBookmarkName, isNull);
    expect(state._scrollController.offset, 0);
  });

  testWidgets('手机端左右滑动标签下方内容会切换当前筛选项', (tester) async {
    PlatformUtils.debugDesktopOverride = false;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoryMapProvider.overrideWith(
            (ref) => const AsyncValue.data(<int, Category>{}),
          ),
        ],
        child: _BookmarksListTestHost(
          topics: const [
            _BookmarkSeed(id: 1, title: 'Alpha', bookmarkName: 'codex'),
            _BookmarkSeed(id: 2, title: 'Beta', bookmarkName: 'beta'),
            _BookmarkSeed(id: 3, title: 'Gamma', bookmarkName: 'codex'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final state = tester.state<_BookmarksListTestHostState>(
      find.byType(_BookmarksListTestHost),
    );
    final swipeRegion = find.byKey(
      const ValueKey('bookmark-content-swipe-region'),
    );

    expect(state._selectedBookmarkName, isNull);

    await tester.drag(swipeRegion, const Offset(-320, 0));
    await tester.pumpAndSettle();

    expect(state._selectedBookmarkName, 'codex');
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);

    await tester.drag(swipeRegion, const Offset(-320, 0));
    await tester.pumpAndSettle();

    expect(state._selectedBookmarkName, 'beta');
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);

    await tester.drag(swipeRegion, const Offset(320, 0));
    await tester.pumpAndSettle();

    expect(state._selectedBookmarkName, 'codex');
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);

    await tester.drag(swipeRegion, const Offset(320, 0));
    await tester.pumpAndSettle();

    expect(state._selectedBookmarkName, isNull);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);
  });

  testWidgets('手机端左右拖动顶部名称标签只滚动标签条不切换筛选项', (tester) async {
    PlatformUtils.debugDesktopOverride = false;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(320, 640));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoryMapProvider.overrideWith(
            (ref) => const AsyncValue.data(<int, Category>{}),
          ),
        ],
        child: _BookmarksListTestHost(
          topics: List.generate(
            14,
            (index) => _BookmarkSeed(
              id: index + 1,
              title: 'Topic $index',
              bookmarkName: 'tag-$index',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final state = tester.state<_BookmarksListTestHostState>(
      find.byType(_BookmarksListTestHost),
    );
    final summaryScrollable = tester.state<ScrollableState>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.right,
      ),
    );

    expect(summaryScrollable.position.pixels, 0);
    expect(state._selectedBookmarkName, isNull);

    await tester.drag(
      find.byKey(const ValueKey('bookmark-summary-wheel-region')),
      const Offset(-240, 0),
    );
    await tester.pumpAndSettle();

    expect(summaryScrollable.position.pixels, greaterThan(0));
    expect(state._selectedBookmarkName, isNull);
  });
}

class _BookmarkSeed {
  const _BookmarkSeed({
    required this.id,
    required this.title,
    this.bookmarkName,
  });

  final int id;
  final String title;
  final String? bookmarkName;
}

class _BookmarksListTestHost extends StatefulWidget {
  const _BookmarksListTestHost({required this.topics});

  final List<_BookmarkSeed> topics;

  @override
  State<_BookmarksListTestHost> createState() => _BookmarksListTestHostState();
}

class _BookmarksListTestHostState extends State<_BookmarksListTestHost> {
  final ScrollController _scrollController = ScrollController();
  String? _selectedBookmarkName;
  bool _showSummaryBar = true;

  void hideSummaryBar() {
    setState(() => _showSummaryBar = false);
  }

  void showSummaryBar() {
    setState(() => _showSummaryBar = true);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topics = widget.topics
        .map(
          (item) => _topic(
            id: item.id,
            title: item.title,
            bookmarkName: item.bookmarkName,
          ),
        )
        .toList();

    return TranslationProvider(
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocaleUtils.supportedLocales,
        home: Scaffold(
          body: BookmarksListContent(
            bookmarksAsync: AsyncValue.data(topics),
            bookmarkNameSuggestions: const <String>[],
            bookmarkNameSuggestionsLoader: _emptySuggestionsLoader,
            scrollController: _scrollController,
            onRefresh: () async {},
            onTap: (_) {},
            onMiddleClick: (_) {},
            enableLongPress: false,
            showSummaryBar: _showSummaryBar,
            selectedBookmarkName: _selectedBookmarkName,
            onSelectedBookmarkName: (value) {
              setState(() => _selectedBookmarkName = value);
            },
            hasMore: false,
            isLoadMoreFailed: false,
            isLoadingMore: false,
            onRetryLoadMore: () {},
            onEditBookmark: (_) async {},
            onQuickRenameBookmark: (_, _) async => true,
            onClearReminder: (_) async {},
            onDeleteBookmark: (_) async {},
          ),
        ),
      ),
    );
  }
}

Future<List<String>> _emptySuggestionsLoader() async => const <String>[];
