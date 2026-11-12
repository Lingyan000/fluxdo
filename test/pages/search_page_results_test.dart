import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/search_result.dart';
import 'package:fluxdo/pages/search_page.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/selected_topic_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/widgets/search/search_list_skeleton.dart';
import 'package:fluxdo/widgets/search/search_post_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 每次搜索挂一个 Completer，由测试决定何时、以什么结果返回
class _SearchService extends Fake implements DiscourseService {
  final pending = <Completer<SearchResult>>[];
  final queries = <String>[];
  final aiPending = <Completer<SearchResult>>[];

  @override
  Future<SearchResult> search({
    required String query,
    int page = 1,
    String? typeFilter,
  }) {
    queries.add(query);
    final completer = Completer<SearchResult>();
    pending.add(completer);
    return completer.future;
  }

  @override
  Future<SearchResult> semanticSearch({required String query}) {
    final completer = Completer<SearchResult>();
    aiPending.add(completer);
    return completer.future;
  }

  @override
  Future<List<String>> getRecentSearches() async => [];
}

SearchResult _result({
  List<String> usernames = const [],
  List<String> blurbs = const [],
}) => SearchResult.fromJson({
  'posts': [
    for (var i = 0; i < blurbs.length; i++)
      {'id': i + 1, 'username': 'author', 'blurb': blurbs[i]},
  ],
  'users': [
    for (var i = 0; i < usernames.length; i++)
      {'id': i + 1, 'username': usernames[i]},
  ],
});

Future<ProviderContainer> _pumpSearch(
  WidgetTester tester,
  _SearchService service, {
  String? initialQuery,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      discourseServiceProvider.overrideWithValue(service),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
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
          home: SearchPage(initialQuery: initialQuery),
        ),
      ),
    ),
  );
  // 首帧后的回调里才发首页搜索；站点 AI 开关也在这之后读到
  await tester.pump();
  return container;
}

Future<void> _submit(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
}

void _seedSite({bool aiSearch = false}) {
  PreloadedDataService().debugSeed(
    siteSettings: {'ai_embeddings_semantic_search_enabled': aiSearch},
    loaded: true,
  );
}

void main() {
  tearDown(() {
    PreloadedDataService().debugSeed(
      currentUser: null,
      siteSettings: null,
      loaded: false,
    );
  });

  testWidgets('搜完是零结果显示空态，而不是一直骨架屏', (tester) async {
    _seedSite();
    final service = _SearchService();
    await _pumpSearch(tester, service, initialQuery: '逆向geminiapp');

    expect(service.queries, hasLength(1));
    expect(find.byType(SearchListSkeleton), findsOneWidget);
    expect(find.text('没有找到相关结果'), findsNothing);

    service.pending.single.complete(_result());
    await tester.pump();

    expect(find.byType(SearchListSkeleton), findsNothing);
    expect(find.text('没有找到相关结果'), findsOneWidget);
    expect(find.text('请尝试其他关键词'), findsOneWidget);
  });

  testWidgets('慢的旧请求回来不盖掉新关键词的结果', (tester) async {
    _seedSite();
    final service = _SearchService();
    await _pumpSearch(tester, service, initialQuery: 'old');

    await _submit(tester, 'new');
    expect(service.queries, hasLength(2));

    service.pending[1].complete(_result(usernames: ['fresh_user']));
    await tester.pump();
    expect(find.text('fresh_user'), findsOneWidget);

    // 旧关键词的请求这时才回来：不该落到页面上
    service.pending[0].complete(_result(usernames: ['stale_user']));
    await tester.pump();
    expect(find.text('fresh_user'), findsOneWidget);
    expect(find.text('stale_user'), findsNothing);
  });

  testWidgets('首页搜索失败后重试，在途期间回到骨架屏', (tester) async {
    _seedSite();
    final service = _SearchService();
    await _pumpSearch(tester, service, initialQuery: 'boom');

    service.pending.single.completeError(StateError('network down'));
    await tester.pump();
    expect(find.byType(SearchListSkeleton), findsNothing);

    await _submit(tester, 'boom');
    expect(service.queries, hasLength(2));
    expect(find.byType(SearchListSkeleton), findsOneWidget);

    service.pending[1].complete(_result());
    await tester.pump();
    expect(find.text('没有找到相关结果'), findsOneWidget);
  });

  testWidgets('关键词零结果而 AI 语义搜索还在途：先给空态并标出 AI 在搜', (tester) async {
    _seedSite(aiSearch: true);
    final service = _SearchService();
    await _pumpSearch(tester, service);

    await _submit(tester, 'q');
    expect(service.aiPending, hasLength(1));

    service.pending.single.complete(_result());
    await tester.pump();
    expect(find.byType(SearchListSkeleton), findsNothing);
    expect(find.text('没有找到相关结果'), findsOneWidget);
    expect(find.text('AI 语义搜索中…'), findsOneWidget);

    service.aiPending.single.complete(_result());
    await tester.pump();
    expect(find.text('AI 语义搜索中…'), findsNothing);
    expect(find.text('请尝试其他关键词'), findsOneWidget);
  });

  testWidgets('上一个关键词的 AI 结果晚到不混进新关键词', (tester) async {
    _seedSite(aiSearch: true);
    final service = _SearchService();
    await _pumpSearch(tester, service);

    await _submit(tester, 'first');
    await _submit(tester, 'second');
    expect(service.aiPending, hasLength(2));

    service.pending[1].complete(_result());
    await tester.pump();
    service.aiPending[0].complete(_result(blurbs: ['stale ai post']));
    await tester.pump();

    expect(find.byType(SearchPostCard), findsNothing);
    expect(find.text('没有找到相关结果'), findsOneWidget);
    // 新关键词自己的 AI 搜索还没回来
    expect(find.text('AI 语义搜索中…'), findsOneWidget);
  });

  testWidgets('退出独立搜索页不抛异常，并清掉它自己的平行视界栈', (tester) async {
    _seedSite();
    final service = _SearchService();
    final container = await _pumpSearch(tester, service);
    container.read(selectedSearchProvider.notifier).select(topicId: 42);
    expect(container.read(selectedSearchProvider).hasSelection, isTrue);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );
    expect(tester.takeException(), isNull);
    // 清栈推迟到卸载完成之后
    await tester.pump();
    expect(container.read(selectedSearchProvider).hasSelection, isFalse);
  });
}
