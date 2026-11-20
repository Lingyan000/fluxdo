import 'dart:async';
import 'dart:io';

import 'package:fluxdo/plugins/site_plugin.dart';
import 'package:fluxdo/plugins/plugin_context.dart';
import 'package:fluxdo/plugins/plugin_registry.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_submission_snapshot.dart';

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:fluxdo/widgets/markdown_editor/image_upload_dialog.dart';
import 'package:fluxdo/widgets/markdown_editor/uploads/upload_task_panel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/draft.dart';
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
import 'package:fluxdo/utils/dialog_utils.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_editor.dart';
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

Widget _editPage({bool canEditContent = true}) => EditTopicPage(
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
  firstPost: Post.fromJson({..._postJson, 'can_edit': canEditContent}),
);

Future<void> _pumpPage(
  WidgetTester tester,
  Widget page,
  List<RequestOptions> requests, {
  String expectedRaw = _raw,
  bool openRoute = false,
  bool waitForEditor = true,
  bool rich = true,
  MemoryDraftStore? draftStore,
  Future<void>? postLoad,
  Future<void>? draftLoad,
}) async {
  PlatformUtils.debugDesktopOverride = false;
  addTearDown(() => PlatformUtils.debugDesktopOverride = null);
  SharedPreferences.setMockInitialValues({'pref_use_rich_composer': rich});
  FlutterSecureStorage.setMockInitialValues({'linux_do_username': 'tester'});
  final prefs = await SharedPreferences.getInstance();
  final dio = DiscourseService().dio;
  final mock = InterceptorsWrapper(
    onRequest: (request, handler) async {
      requests.add(request);
      if (request.method == 'GET' && request.path == '/posts/21.json') {
        await postLoad;
      }
      if (request.method == 'GET' && request.path.startsWith('/drafts/')) {
        await draftLoad;
      }
      // 所有请求均在 Dio 边界终止，保存返回真实 API 的 post 包装结构。
      handler.resolve(
        Response(
          requestOptions: request,
          data: request.method == 'PUT' && request.path == '/posts/21.json'
              ? {'post': _postJson}
              : request.path == '/posts/21.json'
              ? _postJson
              : request.path == '/uploads.json'
              ? {
                  'short_url': 'upload://empty-title.png',
                  'url': 'https://mock.example.test/empty-title.png',
                  'original_filename': '空标题.png',
                }
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
      localDraftStoreProvider.overrideWithValue(
        draftStore ?? MemoryDraftStore(),
      ),
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
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: openRoute
              ? Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      onPressed: () {
                        if (page is ReplySheet) {
                          showAppBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            respectPopScopeOnDrag: true,
                            useSafeArea: false,
                            builder: (_) => page,
                          );
                        } else {
                          Navigator.of(context).push(
                            InteractionPageRoute<void>(builder: (_) => page),
                          );
                        }
                      },
                      child: const Text('打开编辑器'),
                    ),
                  ),
                )
              : page,
        ),
      ),
    ),
  );
  if (openRoute) {
    await tester.tap(find.text('打开编辑器'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }
  if (!waitForEditor) return;
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (!rich) {
      final editors = find.byType(MarkdownEditor).evaluate();
      if (editors.length == 1 &&
          (editors.single.widget as MarkdownEditor).controller.text ==
              expectedRaw) {
        return;
      }
      continue;
    }
    final editors = find.byType(FluxdoEditor).evaluate();
    if (editors.length == 1 &&
        docToMarkdown((editors.single.widget as FluxdoEditor).state.blocks)
                .trim() ==
            expectedRaw) {
      return;
    }
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
  for (final editTopic in [false, true]) {
    Widget page() => editTopic
        ? _editPage()
        : ReplySheet(topicId: 11, editPost: Post.fromJson(_postJson));

    testWidgets('${editTopic ? '编辑话题' : '编辑帖子'}加载原文期间可以返回', (tester) async {
      final loading = Completer<void>();
      final requests = <RequestOptions>[];
      await _pumpPage(
        tester,
        page(),
        requests,
        openRoute: true,
        waitForEditor: false,
        postLoad: loading.future,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('打开编辑器'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(ReplySheet), findsNothing);
      expect(find.byType(EditTopicPage), findsNothing);
      loading.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    for (final rich in [false, true]) {
      testWidgets('${editTopic ? '编辑话题' : '编辑帖子'}未修改直接关闭 rich=$rich', (
        tester,
      ) async {
        await _pumpPage(tester, page(), [], openRoute: true, rich: rich);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('打开编辑器'), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(ReplySheet), findsNothing);
        expect(find.byType(EditTopicPage), findsNothing);
      });

      testWidgets('${editTopic ? '编辑话题' : '编辑帖子'}修改后关闭可继续编辑或放弃 rich=$rich', (
        tester,
      ) async {
        final requests = <RequestOptions>[];
        await _pumpPage(tester, page(), requests, openRoute: true, rich: rich);
        if (rich) {
          _append(tester, '未保存修改');
        } else {
          tester
                  .widget<MarkdownEditor>(find.byType(MarkdownEditor))
                  .controller
                  .text +=
              '未保存修改';
        }
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(
          find.text(S.current.composer_discardChangesBody),
          findsOneWidget,
        );
        await tester.tap(find.text(S.current.createTopic_continueEditing));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        final content = rich
            ? tester
                  .widget<RichComposerEditor>(find.byType(RichComposerEditor))
                  .controller
                  .text
            : tester
                  .widget<MarkdownEditor>(find.byType(MarkdownEditor))
                  .controller
                  .text;
        expect(content, contains('未保存修改'));
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.tap(find.text(S.current.composer_discardAndClose));
        await tester.pumpAndSettle();
        expect(find.text('打开编辑器'), findsOneWidget);
        expect(find.byType(ReplySheet), findsNothing);
        expect(find.byType(EditTopicPage), findsNothing);
        expect(requests.where((r) => r.method == 'PUT'), isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final (name, page) in [
    ('编辑帖子', ReplySheet(topicId: 11, editPost: Post.fromJson(_postJson))),
    ('编辑话题', _editPage()),
    ('新建话题', const CreateTopicPage(initialTitle: _title, initialContent: _raw)),
    (
      '回复',
      const ReplySheet(
        topicId: 11,
        initialContent: _raw,
        initialContentIsComplete: true,
      ),
    ),
  ]) {
    testWidgets('$name导出失败可以继续编辑或确认关闭，保留已有草稿', (tester) async {
      final requests = <RequestOptions>[];
      final store = MemoryDraftStore();
      await _pumpPage(
        tester,
        page,
        requests,
        openRoute: true,
        draftStore: store,
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      final saved = store.entry?.data.reply;
      final writes = store.writes;
      _append(tester, '尚未同步的最后一段');
      RichComposerEditorState.debugBeforeExport = () =>
          throw StateError('关闭测试注入导出失败');
      addTearDown(() => RichComposerEditorState.debugBeforeExport = null);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text(S.current.composer_closeSyncFailed), findsOneWidget);
      await tester.tap(find.text(S.current.createTopic_continueEditing));
      await tester.pumpAndSettle();
      expect(find.byType(RichComposerEditor), findsOneWidget);
      final editor = tester
          .widget<FluxdoEditor>(find.byType(FluxdoEditor))
          .state;
      expect(docToMarkdown(editor.blocks), contains('尚未同步的最后一段'));
      expect(store.entry?.data.reply, saved);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.current.composer_discardAndClose));
      await tester.pumpAndSettle();
      expect(find.byType(RichComposerEditor), findsNothing);
      expect(find.text('打开编辑器'), findsOneWidget);
      expect(store.entry?.data.reply, saved);
      expect(store.writes, writes);
      expect(requests.where((r) => r.method == 'PUT'), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final changed in [false, true]) {
    testWidgets('仅可编辑话题属性时正常关闭 changed=$changed', (tester) async {
      await _pumpPage(
        tester,
        _editPage(canEditContent: false),
        [],
        openRoute: true,
        waitForEditor: false,
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.byType(RichComposerEditor), findsNothing);
      if (changed) {
        await tester.enterText(find.byType(TextFormField), '修改后的话题标题');
      }
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      if (changed) {
        expect(
          find.text(S.current.composer_discardChangesBody),
          findsOneWidget,
        );
        await tester.tap(find.text(S.current.composer_discardAndClose));
        await tester.pumpAndSettle();
      }
      expect(find.byType(EditTopicPage), findsNothing);
      expect(find.text('打开编辑器'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('编辑弹框保存成功直接关闭并返回更新后的帖子', (tester) async {
    await _pumpPage(
      tester,
      ReplySheet(topicId: 11, editPost: Post.fromJson(_postJson)),
      [],
      openRoute: true,
    );
    final route = ModalRoute.of(tester.element(find.byType(ReplySheet)))!;
    _append(tester, '保存修改');
    await tester.tap(find.byKey(const ValueKey('composer-header-submit')));
    await tester.pumpAndSettle();
    expect(find.byType(ReplySheet), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(await route.popped, isA<Post>());
    expect(tester.takeException(), isNull);
  });

  testWidgets('真实回复弹框关闭前保存最后一次输入', (tester) async {
    final store = MemoryDraftStore();
    await _pumpPage(
      tester,
      const ReplySheet(
        topicId: 11,
        initialContent: _raw,
        initialContentIsComplete: true,
      ),
      [],
      openRoute: true,
      draftStore: store,
    );
    _append(tester, '关闭前最后一次输入');
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    expect(find.byType(ReplySheet), findsNothing);
    expect(store.entry?.data.reply, contains('关闭前最后一次输入'));
    expect(tester.takeException(), isNull);
  });

  for (final drag in [false, true]) {
    testWidgets('编辑弹框${drag ? '下拉' : '点击遮罩'}关闭也确认未保存的修改', (tester) async {
      await _pumpPage(
        tester,
        ReplySheet(topicId: 11, editPost: Post.fromJson(_postJson)),
        [],
        openRoute: true,
      );
      _append(tester, '尚未保存的改动');
      if (drag) {
        final header = tester.getRect(
          find.byKey(const ValueKey('reply-composer-header')),
        );
        await tester.flingFrom(header.center, const Offset(0, 500), 1600);
      } else {
        await tester.tapAt(const Offset(10, 10));
      }
      await tester.pumpAndSettle();
      expect(find.text(S.current.composer_discardChangesBody), findsOneWidget);
      await tester.tap(find.text(S.current.createTopic_continueEditing));
      await tester.pumpAndSettle();
      expect(find.byType(CloseButton).hitTestable(), findsOneWidget);
      expect(find.byType(RichComposerEditor), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final page in [const CreateTopicPage(), const ReplySheet(topicId: 11)]) {
    testWidgets('${page.runtimeType}草稿加载中退出不会删除或覆盖已有草稿', (tester) async {
      final loading = Completer<void>();
      final requests = <RequestOptions>[];
      final store = MemoryDraftStore();
      await store.write(
        accountId: 'tester',
        draftKey: page is CreateTopicPage
            ? Draft.newTopicKey
            : Draft.replyKey(11),
        data: const DraftData(reply: _raw),
        sequence: 0,
        synced: true,
      );
      await _pumpPage(
        tester,
        page,
        requests,
        openRoute: true,
        waitForEditor: false,
        draftLoad: loading.future,
        draftStore: store,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('打开编辑器'), findsOneWidget);
      expect(find.byType(ReplySheet), findsNothing);
      expect(find.byType(CreateTopicPage), findsNothing);
      loading.complete();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(
        requests.where(
          (r) => r.path.startsWith('/drafts') && r.method != 'GET',
        ),
        isEmpty,
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(store.entry?.data.reply, _raw);
      expect(store.writes, 1);
      expect(tester.takeException(), isNull);
    });
  }

  for (final body in ['', _raw]) {
    testWidgets('空标题未聚焦正文也能选择并上传图片，上传不挤动标题 body=$body', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('composer-upload-'),
      );
      final image = File('${directory!.path}/空标题.png');
      await tester.runAsync(
        () => image.writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=',
          ),
        ),
      );
      addTearDown(() => directory.delete(recursive: true));
      const picker = MethodChannel('plugins.flutter.io/image_picker');
      var picked = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(picker, (
        _,
      ) async {
        picked++;
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        return [image.path];
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          picker,
          null,
        ),
      );
      final requests = <RequestOptions>[];
      await _pumpPage(
        tester,
        CreateTopicPage(initialContent: body),
        requests,
        expectedRaw: body,
      );
      final title = find.byType(TextFormField).first;
      expect(tester.widget<TextFormField>(title).controller!.text, isEmpty);
      final before = tester.getTopLeft(title).dy;
      await tester.tap(find.byTooltip('上传图片').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(picked, 1);
      expect(find.byType(ImageUploadDialog), findsOneWidget);
      Navigator.of(tester.element(find.byType(ImageUploadDialog)))
          .pop(ImageUploadResult(path: image.path, originalName: '空标题.png'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(UploadTaskCard), findsOneWidget);
      expect(tester.getTopLeft(title).dy, closeTo(before, 1));
      expect(tester.getTopLeft(title).dy, lessThan(220));
      expect(find.textContaining(S.current.editorUploads_title), findsNothing);
      final editor = tester
          .widget<FluxdoEditor>(find.byType(FluxdoEditor))
          .state;
      editor.undo();
      await tester.pump();
      expect(
        find.textContaining(S.current.editorUploads_title),
        findsOneWidget,
      );
      expect(tester.getTopLeft(title).dy, closeTo(before, 1));
      editor.redo();
      await tester.pump();
      expect(find.textContaining(S.current.editorUploads_title), findsNothing);
      expect(tester.getTopLeft(title).dy, closeTo(before, 1));
      for (var i = 0; i < 50; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byType(UploadTaskCard).evaluate().isEmpty) break;
      }
      expect(requests.where((r) => r.path == '/uploads.json'), hasLength(1));
      expect(find.byType(UploadTaskCard), findsNothing);
      final rich = tester.state<RichComposerEditorState>(
        find.byType(RichComposerEditor),
      );
      expect(rich.hasPendingUploads, false);
      expect(rich.flushToController(), true);
      expect(
        tester
            .widget<RichComposerEditor>(find.byType(RichComposerEditor))
            .controller
            .text,
        contains('upload://empty-title.png'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    });
  }

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
