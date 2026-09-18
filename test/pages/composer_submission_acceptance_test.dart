import 'dart:async';

import 'package:fluxdo/plugins/site_plugin.dart';
import 'package:fluxdo/plugins/plugin_context.dart';
import 'package:fluxdo/plugins/plugin_registry.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_submission_snapshot.dart';

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/create_topic_page.dart';
import 'package:fluxdo/pages/edit_topic_page.dart';
import 'package:fluxdo/providers/discourse_providers.dart';
import 'package:fluxdo/providers/draft_store_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/discourse_cook_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_view_mode_switcher.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_workbench.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/rich_composer_editor.dart';
import 'package:fluxdo/widgets/post/reply_sheet.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/memory_draft_store.dart';

const _raw = '这是符合最小长度要求的原始正文，用来验证实际发布请求。';
const _title = '这是符合最小长度要求的真实话题标题';
final _postJson = <String, dynamic>{
  'id': 21,
  'username': 'tester',
  'avatar_template': '',
  'cooked': '<p>正文</p>',
  'raw': _raw,
  'post_number': 1,
  'post_type': 1,
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
  'can_edit': true,
};

Widget _editPage() => EditTopicPage(
  topicDetail: TopicDetail(
    id: 11,
    title: _title,
    slug: 'test',
    postsCount: 1,
    postStream: PostStream(posts: [], stream: [21]),
    categoryId: 1,
    closed: false,
    archived: false,
    canEdit: true,
  ),
  firstPost: Post.fromJson(_postJson),
);

Future<void> _pumpPage(
  WidgetTester tester,
  Widget page,
  List<RequestOptions> requests,
) async {
  PlatformUtils.debugDesktopOverride = false;
  addTearDown(() => PlatformUtils.debugDesktopOverride = null);
  SharedPreferences.setMockInitialValues({'pref_use_rich_composer': true});
  FlutterSecureStorage.setMockInitialValues({'linux_do_username': 'tester'});
  final prefs = await SharedPreferences.getInstance();
  final dio = DiscourseService().dio;
  final mock = InterceptorsWrapper(
    onRequest: (request, handler) {
      requests.add(request);
      // 所有请求均在 Dio 边界终止，保存返回真实 API 的 post 包装结构。
      handler.resolve(
        Response(
          requestOptions: request,
          data: request.method == 'PUT' && request.path == '/posts/21.json'
              ? {'post': _postJson}
              : request.path == '/posts/21.json'
              ? _postJson
              : {'success': 'OK', 'draft': null, 'draft_sequence': 0},
        ),
      );
    },
  );
  dio.interceptors.insert(0, mock);
  addTearDown(() => dio.interceptors.remove(mock));
  await tester.runAsync(() async {
    await PreloadedDataService().hydrateFromHtml(
      '<meta id="data-discourse-setup"><script id="data-preloaded" type="application/json">${jsonEncode({
        'currentUser': {'id': 1, 'username': 'tester'},
        'siteSettings': {'min_topic_title_length': 6, 'min_first_post_length': 20, 'max_post_length': 10000},
        'site': {'categories': [], 'top_tags': []},
      })}</script>',
    );
    await DiscourseCookService().ensureInitialized();
  });
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      localDraftStoreProvider.overrideWithValue(MemoryDraftStore()),
      categoriesProvider.overrideWith(
        (_) async => [
          Category.fromJson({
            'id': 1,
            'name': '测试分类',
            'color': '4b73e6',
            'permission': 1,
          }),
        ],
      ),
      tagsProvider.overrideWith((_) async => []),
      canTagTopicsProvider.overrideWith((_) async => false),
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
          home: page,
        ),
      ),
    ),
  );
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    final editors = find.byType(FluxdoEditor).evaluate();
    if (editors.length == 1 &&
        docToMarkdown((editors.single.widget as FluxdoEditor).state.blocks)
                .trim() ==
            _raw)
      return;
  }
  fail('真实页面未加载预期富文本文档');
}

void _append(WidgetTester tester, String text) {
  final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
  editor.updateSelection(
    EditorSelection.collapsed(
      EditorPosition(blockId: editor.blocks.first.id, offset: _raw.length),
    ),
  );
  editor.insertText(text);
}

class _DelayedSubmitPlugin extends SitePlugin {
  final confirmation = Completer<bool>();
  int calls = 0;

  @override
  String get id => 'delayed-submit-test';

  @override
  Future<bool> beforeReplySubmit(ReplySubmitContext context) {
    calls++;
    return confirmation.future;
  }
}

void main() {
  testWidgets('真实回复等待插件确认时输入，保留最新正文并要求重试，不发送旧 raw', (tester) async {
    final plugin = _DelayedSubmitPlugin();
    PluginRegistry.overridePlugins([plugin]);
    addTearDown(PluginRegistry.resetOverride);
    final requests = <RequestOptions>[];
    await _pumpPage(
      tester,
      Scaffold(
        body: ReplySheet(
          topicId: 11,
          initialContent: _raw,
          preloadedDraftFuture: Future.value(null),
        ),
      ),
      requests,
    );
    await tester.tap(find.byType(FluxdoEditor));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('composer-header-submit')));
    await tester.pump();
    expect(plugin.calls, 1);
    // 从真实平台输入通道修改，而不是直接修改 controller 镜像。
    await tester.tap(find.byType(FluxdoEditor));
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isTrue);
    tester.testTextInput.enterText(' $_raw确认期间的新输入');
    plugin.confirmation.complete(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      requests.where(
        (r) =>
            r.method == 'PUT' ||
            (r.method == 'POST' && r.path.startsWith('/posts')),
      ),
      isEmpty,
    );
    expect(find.text(ComposerSubmissionSnapshot.retryMessage), findsOneWidget);
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    expect(docToMarkdown(editor.blocks), contains('确认期间的新输入'));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('编辑话题最后字符后立即保存，真实 PUT raw 包含 debounce 窗口内容', (tester) async {
    final requests = <RequestOptions>[];
    await _pumpPage(tester, _editPage(), requests);
    await tester.pump(const Duration(milliseconds: 600));
    _append(tester, '末');
    // 不 pump、不显式 flush，让真正的页面提交入口负责同步。
    await tester.tap(find.byKey(const ValueKey('composer-header-submit')));
    await tester.pump();
    for (var i = 0; i < 100 && !requests.any((r) => r.method == 'PUT'); i++) {
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    final writes = requests
        .where((r) => r.method == 'PUT' && r.path == '/posts/21.json')
        .toList();
    expect(
      writes,
      hasLength(1),
      reason:
          '请求=${requests.map((r) => '${r.method} ${r.path}')}；界面=${tester.widgetList<Text>(find.byType(Text)).map((w) => w.data).join('|')}',
    );
    expect((writes.single.data as Map)['post[raw]'], '$_raw末');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  for (final privateMessage in [false, true]) {
    testWidgets('回复弹框${privateMessage ? '私信' : '编辑'}分支导出失败不发送写请求', (
      tester,
    ) async {
      final requests = <RequestOptions>[];
      await _pumpPage(
        tester,
        Scaffold(
          body: ReplySheet(
            topicId: privateMessage ? null : 11,
            editPost: privateMessage ? null : Post.fromJson(_postJson),
            targetUsername: privateMessage ? 'recipient' : null,
            composePrivateMessage: privateMessage,
            initialContent: privateMessage ? _raw : null,
            initialTitle: privateMessage ? _title : null,
            preloadedDraftFuture: Future.value(null),
          ),
        ),
        requests,
      );
      _append(tester, '未同步末字符');
      var attempts = 0;
      RichComposerEditorState.debugBeforeExport = () {
        attempts++;
        throw StateError('验收测试注入导出失败');
      };
      try {
        requests.clear();
        await tester.tap(find.byKey(const ValueKey('composer-header-submit')));
        await tester.pump();
        expect(attempts, greaterThan(0));
        expect(
          requests.where(
            (r) =>
                r.method == 'PUT' ||
                (r.method == 'POST' && r.path.startsWith('/posts')),
          ),
          isEmpty,
        );
        expect(find.byType(RichComposerEditor), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        RichComposerEditorState.debugBeforeExport = null;
        await tester.pump(const Duration(seconds: 5));
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 6));
      }
    });
  }

  for (final create in [false, true]) {
    testWidgets('${create ? '创建' : '编辑'}话题导出失败阻断真实写请求及预览', (tester) async {
      final requests = <RequestOptions>[];
      await _pumpPage(
        tester,
        create
            ? const CreateTopicPage(
                initialTitle: _title,
                initialContent: _raw,
                initialCategoryId: 1,
              )
            : _editPage(),
        requests,
      );
      _append(tester, '未同步末字符');
      var attempts = 0;
      RichComposerEditorState.debugBeforeExport = () {
        attempts++;
        throw StateError('验收测试注入导出失败');
      };
      try {
        requests.clear();
        await tester.tap(find.byKey(const ValueKey('composer-header-submit')));
        await tester.pump();
        expect(attempts, greaterThan(0), reason: '必须确实到达导出门禁，不能因表单无效假通过');
        final afterSubmit = attempts;
        await tester.tap(find.byType(ComposerPreviewButton));
        await tester.pump();
        expect(attempts, greaterThan(afterSubmit));
        expect(
          tester
              .widget<ComposerPreviewPane>(find.byType(ComposerPreviewPane))
              .previewing,
          isFalse,
        );
        expect(find.byType(RichComposerEditor), findsOneWidget);
        expect(
          requests.where(
            (r) =>
                r.method == 'PUT' ||
                (r.method == 'POST' && r.path.startsWith('/posts')),
          ),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      } finally {
        RichComposerEditorState.debugBeforeExport = null;
        await tester.pump(const Duration(seconds: 5));
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 6));
      }
    });
  }
}
