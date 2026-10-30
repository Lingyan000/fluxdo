import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/draft.dart';
import 'package:fluxdo/pages/create_topic_page.dart';
import 'package:fluxdo/providers/discourse_providers.dart';
import 'package:fluxdo/providers/draft_store_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/memory_draft_store.dart';

void main() {
  testWidgets('创建页完整恢复后才接受编辑，回到前台同步标题正文分类及清空后的标签', (tester) async {
    PlatformUtils.debugDesktopOverride = false;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);
    SharedPreferences.setMockInitialValues({'pref_use_rich_composer': false});
    FlutterSecureStorage.setMockInitialValues({'linux_do_username': 'tester'});
    final prefs = await SharedPreferences.getInstance();
    final categories = Completer<List<Category>>();
    final store = MemoryDraftStore();
    var remote = const Draft(
      draftKey: 'new_topic_sync',
      sequence: 1,
      data: DraftData(
        title: '云端原始标题',
        reply: '云端原始正文',
        categoryId: 1,
        tags: ['旧标签'],
        action: 'createTopic',
      ),
    );
    final writes = <Map>[];
    final interceptor = InterceptorsWrapper(
      onRequest: (request, handler) {
        if (request.method == 'POST' && request.path == '/drafts.json') {
          writes.add(Map.of(request.data as Map));
        }
        handler.resolve(
          Response(
            requestOptions: request,
            data: {
              'success': 'OK',
              // 模拟网页端 serializeTags 的真实草稿格式，而非客户端自己的序列化。
              'draft': jsonEncode({
                ...remote.data.toJson(),
                'tags': [
                  for (final name in remote.data.tags ?? <String>[])
                    {'name': name},
                ],
              }),
              'draft_sequence': remote.sequence,
            },
          ),
        );
      },
    );
    final service = DiscourseService();
    service.dio.interceptors.insert(0, interceptor);
    addTearDown(() => service.dio.interceptors.remove(interceptor));
    await tester.runAsync(() async {
      await PreloadedDataService().hydrateFromHtml(
        '<meta id="data-discourse-setup"><script id="data-preloaded" type="application/json">${jsonEncode({
          'currentUser': {'id': 1, 'username': 'tester', 'can_tag_topics': true},
          'siteSettings': {'min_topic_title_length': 6, 'min_first_post_length': 20, 'max_post_length': 10000, 'tagging_enabled': true},
          'site': {'categories': [], 'top_tags': []},
        })}</script>',
      );
    });
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        localDraftStoreProvider.overrideWithValue(store),
        categoriesProvider.overrideWith((_) => categories.future),
        tagsProvider.overrideWith((_) async => ['旧标签']),
        canTagTopicsProvider.overrideWith((_) async => true),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            locale: const Locale('zh'),
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: const CreateTopicPage(draftKey: 'new_topic_sync'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(S.current.common_restore));
    await tester.pump(const Duration(milliseconds: 300));
    categories.complete([
      for (final id in [1, 2])
        Category.fromJson({
          'id': id,
          'name': '分类 $id',
          'color': '4b73e6',
          'permission': 1,
        }),
    ]);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    final editor = tester.widget<MarkdownEditor>(find.byType(MarkdownEditor));
    expect(editor.controller.text, remote.data.reply);
    expect(find.text(remote.data.title!), findsOneWidget);
    expect(find.text('旧标签'), findsOneWidget);
    expect(find.text('{name: 旧标签}'), findsNothing);
    expect(writes, isEmpty, reason: '标题、正文、分类恢复过程不能上传半份草稿');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    remote = const Draft(
      draftKey: 'new_topic_sync',
      sequence: 2,
      data: DraftData(
        title: '云端更新标签',
        reply: '云端更新正文',
        categoryId: 2,
        tags: ['纯水', '快问快答'],
        action: 'createTopic',
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('纯水'), findsOneWidget);
    expect(
      find.byTooltip('${S.current.tag_tabTags}: #纯水 #快问快答'),
      findsOneWidget,
    );
    expect(find.text('{name: 纯水}'), findsNothing);
    expect(find.text('旧标签'), findsNothing);
    expect(store.entry?.data.tags, ['纯水', '快问快答']);
    expect(store.entry?.synced, isTrue);
    expect(writes, isEmpty, reason: '采用云端标签后不能触发多余回写');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    remote = const Draft(
      draftKey: 'new_topic_sync',
      sequence: 3,
      data: DraftData(
        title: '云端最新标题',
        reply: '云端最新正文',
        categoryId: 2,
        tags: [],
        action: 'createTopic',
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(editor.controller.text, remote.data.reply);
    expect(find.text(remote.data.title!), findsOneWidget);
    expect(find.text('云端原始标题'), findsNothing);
    expect(find.text('旧标签'), findsNothing);
    expect(store.entry?.data.categoryId, 2);
    expect(store.entry?.data.tags, isEmpty);
    expect(find.text('纯水'), findsNothing);
    expect(find.text('快问快答'), findsNothing);
    expect(store.entry?.sequence, 3);
    expect(writes, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
