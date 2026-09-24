import 'dart:convert';
import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:chat_bottom_container/listener_manager.dart';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/widgets/common/tag_selection_sheet.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/emoji.dart';
import 'package:fluxdo/providers/emoji_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_workbench.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_desktop_workbench.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_chrome.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_island.dart';
import 'package:fluxdo/widgets/markdown_editor/content_actions_button.dart';
import 'package:fluxdo/widgets/markdown_editor/cursor_swipe_control.dart';
import 'package:common_ui/common_ui.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/services/discourse_cook_service.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_editor.dart';
import 'package:fluxdo/widgets/markdown_editor/emoji_sticker_panel.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/rich_composer_editor.dart';
import 'package:fluxdo/widgets/topic/topic_editor_helpers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/semantic_editor.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_composer_codec.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/composer_import_pipeline.dart';
import 'package:fluxdo_render/src/editor/widget/editor_caret.dart';
import 'package:fluxdo_render/src/editor/widget/editor_table_grid.dart';
import 'package:fluxdo_render/fluxdo_render.dart'
    show ImageRun, LinkRun, TextRun;

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 390,
  double height = 760,
  double scale = 1,
  bool dark = false,
  bool desktop = false,
  bool disableAnimations = false,
}) async {
  PlatformUtils.debugDesktopOverride = desktop;
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  // 本文件手动回报 IME 帧；原生拖拽通道在专门的交接测试中覆盖。
  const keyboardChannel = MethodChannel('com.fluxdo/interactive_keyboard');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    keyboardChannel,
    (call) async => call.method == 'begin' ? {'supported': false} : null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      keyboardChannel,
      null,
    ),
  );
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.runAsync(() async {
    if (!PreloadedDataService().isLoaded) {
      await PreloadedDataService().hydrateFromHtml(
        '<meta id="data-discourse-setup"><script id="data-preloaded" type="application/json">${jsonEncode({
          'currentUser': {'id': 1, 'username': 'tester'},
          'siteSettings': {'min_post_length': 1, 'max_post_length': 10000},
          'site': {'categories': [], 'top_tags': []},
        })}</script>',
      );
      await DiscourseCookService().ensureInitialized();
    }
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        emojiGroupsProvider.overrideWith(
          (ref) => Stream.value(<String, List<Emoji>>{}),
        ),
      ],
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
          theme: ThemeData(
            platform: desktop ? TargetPlatform.macOS : TargetPlatform.android,
            brightness: dark ? Brightness.dark : Brightness.light,
            colorSchemeSeed: const Color(0xff315fe7),
          ),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                size: Size(width, height),
                textScaler: TextScaler.linear(scale),
                disableAnimations: disableAnimations,
              ),
              child: RepaintBoundary(
                key: const ValueKey('capture-workbench'),
                child: Scaffold(
                  resizeToAvoidBottomInset: false,
                  appBar: AppBar(title: const Text('新话题')),
                  body: child,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

class _TableFixtureCodec extends SemanticComposerCodec {
  @override
  Future<ComposerImportResult<SemanticNode>> import(
    String raw, {
    Duration timeout = const Duration(seconds: 10),
    bool guarded = true,
  }) async {
    if (raw != '表格测试草稿') {
      return super.import(raw, timeout: timeout, guarded: guarded);
    }
    SemanticNode cell(String text) => SemanticNode(
      'table_cell',
      attrs: {
        'header': true,
        'style': 'text-align:center',
        'unknownCell': '保留',
      },
      content: [SemanticNode('text', text: text)],
    );
    return ComposerImportResult.success(
      SemanticNode(
        'doc',
        content: [
          SemanticNode(
            'table',
            attrs: {'unknownTable': '保留'},
            content: [
              SemanticNode(
                'table_row',
                attrs: {'unknownRow': '保留'},
                content: [cell('原单元格'), cell('旁列')],
              ),
              SemanticNode(
                'table_row',
                content: [
                  cell('正文').copy(attrs: {'header': false}),
                  cell('内容').copy(attrs: {'header': false}),
                ],
              ),
            ],
          ),
          SemanticNode('paragraph'),
        ],
      ),
    );
  }
}

void main() {
  setUp(() => PlatformUtils.debugDesktopOverride = false);
  tearDown(() => PlatformUtils.debugDesktopOverride = null);

  testWidgets('语义表格真实单元格编辑保留未知属性和来源对齐', (tester) async {
    final codec = _TableFixtureCodec();
    final controller = TextEditingController(text: '表格测试草稿');
    final key = GlobalKey<RichComposerEditorState>();
    await _pump(
      tester,
      RichComposerEditor(
        key: key,
        controller: controller,
        semanticCodec: codec,
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(find.text('原单元格').first);
    await tester.pump();
    await tester.enterText(
      find
          .descendant(
            of: find.byType(EditorTableGrid),
            matching: find.byType(EditableText),
          )
          .first,
      '新单元格',
    );
    await tester.runAsync(() async {
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    key.currentState!.flushToController();
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    final tree =
        (editor.documentBindingState as SemanticEditorProjection).source;
    final table = tree.content.first;
    expect(table.attrs['unknownTable'], '保留');
    expect(table.content.first.attrs['unknownRow'], '保留');
    final cell = table.content.first.content.first;
    expect(cell.attrs['unknownCell'], '保留');
    expect(cell.attrs['style'], 'text-align:center');
    expect(controller.text, contains('新单元格'));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('手机表格保留格式行且列菜单不混入行操作', (tester) async {
    final controller = TextEditingController(text: '表格测试草稿');
    await _pump(
      tester,
      RichComposerEditor(
        controller: controller,
        semanticCodec: _TableFixtureCodec(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(find.text('原单元格').first);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    final format = find.byKey(const ValueKey('table-format-tools'));
    expect(format, findsOneWidget);
    expect(
      find.ancestor(of: format, matching: find.byType(AbsorbPointer)),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('composer-format-row')),
        matching: find.byKey(const ValueKey('table-row-operations')),
      ),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('table-column-operations')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('table-action-columnBefore')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('table-action-rowBefore')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('table-action-columnAfter')));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester
          .widget<EditorTableGrid>(find.byType(EditorTableGrid))
          .node
          .columnCount,
      3,
    );
    expect(find.byKey(const ValueKey('table-format-tools')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('手机表格插入前提交中文组合文本，撤销结构保留输入', (tester) async {
    final controller = TextEditingController(text: '表格测试草稿');
    await _pump(
      tester,
      RichComposerEditor(
        controller: controller,
        semanticCodec: _TableFixtureCodec(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(find.text('原单元格').first);
    await tester.pump();
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文输入',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 0, end: 4),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('table-row-operations')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('table-action-rowBefore')));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
    }
    final grid = tester.widget<EditorTableGrid>(find.byType(EditorTableGrid));
    expect(grid.node.rows.length, 3);
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    editor.undo();
    await tester.pump();
    expect(
      tester
          .widget<EditorTableGrid>(find.byType(EditorTableGrid))
          .node
          .rows
          .length,
      2,
    );
    expect(find.text('中文输入'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    controller.dispose();
  });

  testWidgets('手机表格删除有内容行需确认，取消不修改', (tester) async {
    final controller = TextEditingController(text: '表格测试草稿');
    await _pump(
      tester,
      RichComposerEditor(
        controller: controller,
        semanticCodec: _TableFixtureCodec(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(find.text('原单元格').first);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('table-row-operations')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    final action = find.byKey(const ValueKey('table-action-deleteRow'));
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pump();
    expect(find.byKey(const ValueKey('table-confirm-delete')), findsOneWidget);
    expect(
      tester
          .widget<EditorTableGrid>(find.byType(EditorTableGrid))
          .node
          .rows
          .length,
      2,
    );
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(find.byKey(const ValueKey('table-confirm-delete')), findsNothing);
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('table-confirm-delete')));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester
          .widget<EditorTableGrid>(find.byType(EditorTableGrid))
          .node
          .rows
          .length,
      1,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('手机表格工具岛保留键盘并插入行，支持撤销', (tester) async {
    final controller = TextEditingController(text: '表格测试草稿');
    await _pump(
      tester,
      RichComposerEditor(
        controller: controller,
        semanticCodec: _TableFixtureCodec(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(find.text('原单元格').first);
    await tester.pump();
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    final grid = find.byType(EditorTableGrid);
    final before = tester.widget<EditorTableGrid>(grid).node.rows.length;
    await tester.tap(find.byKey(const ValueKey('table-row-operations')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    final field = find.descendant(
      of: grid,
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);
    expect(tester.view.viewInsets.bottom, 300);
    await tester.tap(find.byKey(const ValueKey('table-action-rowBefore')));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(tester.widget<EditorTableGrid>(grid).node.rows.length, before + 1);
    expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);
    tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state.undo();
    await tester.pump();
    expect(tester.widget<EditorTableGrid>(grid).node.rows.length, before);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('真实宿主键盘下内容末尾表格完整避开工具岛', (tester) async {
    final controller = TextEditingController(text: '表格测试草稿');
    final focus = FocusNode();
    await _pump(
      tester,
      RichComposerEditor(
        controller: controller,
        focusNode: focus,
        semanticCodec: _TableFixtureCodec(),
        header: const SizedBox(height: 220),
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    final cellText = find.text('原单元格').first;
    await tester.tap(cellText);
    await tester.pump();
    await tester.pump();
    final field = find.descendant(
      of: find.byType(EditorTableGrid),
      matching: find.byType(EditableText),
    );
    expect(field, findsOneWidget);
    for (final inset in [40.0, 100.0, 180.0, 260.0, 300.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    final surface = find.byKey(const ValueKey('composer-island-surface'));
    expect(surface, findsOneWidget);
    final fieldRect = tester.getRect(field);
    final surfaceRect = tester.getRect(surface);
    final scrollable = tester.state<ScrollableState>(
      find
          .ancestor(
            of: find.byType(FluxdoEditor),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      scrollable.position.pixels,
      greaterThan(0),
      reason: '应发生实际滚动而非仅改变布局',
    );
    expect(
      fieldRect.bottom,
      lessThanOrEqualTo(surfaceRect.top),
      reason: '编辑格必须完整位于真实工具岛上方',
    );

    // 用户主动往上翻文档后必须取消表格自动跟随。后续键盘/工具岛布局
    // 重建只能保持用户位置，不能把页面重新拉回聚焦 cell。
    final automaticPixels = scrollable.position.pixels;
    final gesture = await tester.startGesture(const Offset(200, 160));
    await gesture.moveBy(const Offset(0, 48));
    await tester.pump(const Duration(milliseconds: 80));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 200));
    final manualPixels = scrollable.position.pixels;
    expect(manualPixels, lessThan(automaticPixels));
    expect(
      tester.widget<EditableText>(field).focusNode.hasFocus,
      isTrue,
      reason: '滚动不应退出 cell 编辑态',
    );
    for (final inset in [260.0, 300.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      scrollable.position.pixels,
      closeTo(manualPixels, 1),
      reason: '用户滚离后布局变化不能把页面拉回聚焦 cell',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    focus.dispose();
  });

  testWidgets('语义宿主粘贴回调在原选区插入并保留两侧正文', (tester) async {
    final controller = TextEditingController();
    final key = GlobalKey<RichComposerEditorState>();
    await _pump(tester, RichComposerEditor(key: key, controller: controller));
    await tester.pump(const Duration(milliseconds: 800));
    final widget = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
    final editor = widget.state;
    final id = editor.blocks.first.id;
    editor.updateSelection(
      EditorSelection.collapsed(EditorPosition(blockId: id, offset: 0)),
    );
    editor.insertText('前后');
    final selection = EditorSelection.collapsed(
      EditorPosition(blockId: id, offset: 1),
    );
    bool? handled;
    await tester.runAsync(() async {
      handled = await widget.semanticMarkdownInserter!('**粘贴**', selection);
    });
    await tester.pump();
    expect(handled, true);
    key.currentState!.flushToController();
    expect(controller.text, '前**粘贴**后');
    editor.undo();
    key.currentState!.flushToController();
    expect(controller.text, '前后');
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('语义上传取消清理redo不复活占位且保留后来输入', (tester) async {
    final controller = TextEditingController();
    final key = GlobalKey<RichComposerEditorState>();
    await _pump(tester, RichComposerEditor(key: key, controller: controller));
    await tester.pump(const Duration(milliseconds: 800));
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    editor.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: editor.blocks.first.id, offset: 0),
      ),
    );
    editor.insertText('保留');
    final completion = Completer<UploadResult>();
    key.currentState!.queueUpload(
      '/模拟/取消.png',
      '取消图片',
      image: true,
      execute: (_, _) => completion.future,
    );
    await tester.pump();
    editor.insertText('后来输入');
    await tester.pump();
    await tester.tap(find.byTooltip(S.current.common_cancel).first);
    await tester.pump();
    await tester.pump();
    key.currentState!.flushToController();
    expect(controller.text, contains('保留'));
    expect(controller.text, contains('后来输入'));
    expect(key.currentState!.hasPendingUploads, false);
    editor.undo();
    editor.redo();
    key.currentState!.flushToController();
    expect(controller.text, isNot(contains('pending_upload')));
    expect(controller.text, contains('后来输入'));
    completion.complete(
      UploadResult(
        shortUrl: 'upload://cancelled.png',
        originalFilename: '取消.png',
      ),
    );
    await tester.pump();
    key.currentState!.flushToController();
    expect(controller.text, isNot(contains('cancelled.png')));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('语义上传mock完成替换保留占位两侧输入且导出无临时节点', (tester) async {
    final controller = TextEditingController();
    final key = GlobalKey<RichComposerEditorState>();
    await _pump(tester, RichComposerEditor(key: key, controller: controller));
    await tester.pump(const Duration(milliseconds: 800));
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    final first = editor.blocks.first;
    editor.updateSelection(
      EditorSelection.collapsed(EditorPosition(blockId: first.id, offset: 0)),
    );
    editor.insertText('前后');
    editor.updateSelection(
      EditorSelection.collapsed(EditorPosition(blockId: first.id, offset: 1)),
    );
    final completion = Completer<UploadResult>();
    key.currentState!.queueUpload(
      '/模拟/图片.png',
      '模拟图片',
      image: true,
      execute: (_, _) => completion.future,
    );
    await tester.pump();
    key.currentState!.flushToController();
    expect(controller.text, isNot(contains('pending_upload')));
    expect(controller.text, contains('前'));
    expect(controller.text, contains('后'));
    editor.insertText('新增');
    completion.complete(
      UploadResult(
        shortUrl: 'upload://semantic-mock.png',
        originalFilename: '模拟图片.png',
        url: 'https://mock.example.test/semantic-mock.png',
      ),
    );
    await tester.pump();
    await tester.pump();
    key.currentState!.flushToController();
    expect(controller.text, contains('upload://semantic-mock.png'));
    expect(controller.text, contains('新增'));
    expect(key.currentState!.hasPendingUploads, false);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('语义宿主真实输入立即切源码与卸载均导出最新正文', (tester) async {
    final controller = TextEditingController();
    final key = GlobalKey<RichComposerEditorState>();
    String? switched;
    await _pump(
      tester,
      RichComposerEditor(
        key: key,
        controller: controller,
        onSwitchToSource: () => switched = controller.text,
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(find.byType(FluxdoEditor));
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: ' 真实输入',
        selection: TextSelection.collapsed(offset: 5),
      ),
    );
    await tester.pump();
    key.currentState!.flushToController();
    expect(controller.text, '真实输入');
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    editor.insertText('未等防抖');
    // 源码模式回调沿用生产 flush 契约。
    await tester.pump();
    await tester.tap(
      find.byTooltip(
        '${S.current.composerView_switch}: ${S.current.composerView_source}',
      ),
    );
    await tester.pump();
    expect(switched, '真实输入未等防抖');
    editor.insertText('卸载');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(controller.text, '真实输入未等防抖卸载');
    controller.dispose();
  });

  testWidgets('原子链接真实点击打开宿主编辑对话框并保留标题附件来源', (tester) async {
    final controller = TextEditingController();
    final key = GlobalKey<RichComposerEditorState>();
    await _pump(tester, RichComposerEditor(key: key, controller: controller));
    await tester.pump(const Duration(milliseconds: 800));
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    editor.insertAtom(
      const LinkRun(
        href: 'https://mock.example.test/file',
        children: [TextRun('模拟附件')],
        isAttachment: true,
        filename: '模拟附件',
        editorLinkTitle: '保留标题',
      ),
    );
    await tester.pump();
    final rendered = find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText().contains('模拟附件'),
    );
    await tester.tapAt(
      tester.getTopLeft(rendered.first) + const Offset(10, 10),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byTooltip('编辑链接'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '模拟附件'), '修改名称');
    await tester.enterText(
      find.widgetWithText(TextField, 'https://mock.example.test/file'),
      'https://mock.example.test/new',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    key.currentState!.flushToController();
    expect(controller.text, contains('修改名称|attachment'));
    expect(controller.text, contains('https://mock.example.test/new'));
    expect(controller.text, contains('保留标题'));
    editor.undo();
    await tester.pumpAndSettle();
    key.currentState!.flushToController();
    expect(controller.text, contains('模拟附件|attachment'));
    expect(controller.text, contains('https://mock.example.test/file'));
    expect(controller.text, contains('保留标题'));
    expect(controller.text, isNot(contains('修改名称')));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('链接展开期间自动镜像与卸载回写不能增加转义包装', (tester) async {
    final controller = TextEditingController();
    final key = GlobalKey<RichComposerEditorState>();
    await _pump(tester, RichComposerEditor(key: key, controller: controller));
    await tester.pump(const Duration(milliseconds: 800));
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    editor.mode = EditorMode.ir;
    const url = 'https://github.com';
    const raw = '[$url]($url)';
    final id = editor.blocks.first.id;
    editor.updateSelection(
      EditorSelection.collapsed(EditorPosition(blockId: id, offset: 0)),
    );
    editor.pastePlainText(raw);
    editor.updateSelection(
      EditorSelection.collapsed(EditorPosition(blockId: id, offset: 4)),
    );
    expect((editor.blocks.first as TextBlock).content.text, raw);
    final selection = editor.selection;
    await tester.pump(const Duration(milliseconds: 1100));
    expect(controller.text, raw, reason: '光标仍驻留时定时镜像必须保留链接');
    expect(editor.selection, selection);
    expect((editor.blocks.first as TextBlock).content.text, raw);
    key.currentState!.flushToController();
    expect(controller.text, raw);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(controller.text, raw, reason: '卸载时最终回写同样不能毁掉链接');
    controller.dispose();
  });

  testWidgets('高图下方向上拖虚拟光标，宿主不能把视口拉回图片底部', (tester) async {
    final controller = TextEditingController();
    await _pump(tester, RichComposerEditor(controller: controller));
    await tester.pump(const Duration(milliseconds: 800));
    final widget = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
    final state = widget.state;
    state.pastePlainText('above image');
    final above = state.selection!.extent.blockId;
    state.splitBlock();
    state.insertAtom(
      const ImageRun(
        src: 'https://example.com/tall.png',
        width: 240,
        height: 900,
      ),
    );
    state.splitBlock();
    state.insertText('below image');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(CustomScrollView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final position = scrollable.position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    final pointer = widget.virtualPointer!;
    expect(pointer.start(), isTrue);
    pointer.moveBy(const Offset(0, -5000));
    var previous = position.pixels;
    for (var i = 0; i < 180; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        position.pixels,
        lessThanOrEqualTo(previous + 0.01),
        reason: '向上拖动时不能被光标避让反向拉回图片底部',
      );
      previous = position.pixels;
    }
    expect(position.pixels, closeTo(position.minScrollExtent, 0.01));
    expect(state.selection!.extent.blockId, above);
    pointer.end();
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  for (final rich in [false, true]) {
    testWidgets('PC 宽屏分列工具，缩窄保留正文、选区、撤销和已打开面板 rich=$rich', (tester) async {
      final controller = TextEditingController(text: rich ? '' : 'desktop');
      final focus = FocusNode();
      await _pump(
        tester,
        rich
            ? RichComposerEditor(
                controller: controller,
                focusNode: focus,
                onSwitchToSource: () {},
              )
            : MarkdownEditor(
                controller: controller,
                focusNode: focus,
                showPreviewButton: false,
                onSwitchToRich: () {},
              ),
        desktop: true,
        width: 1200,
      );
      // 原生 UndoHistory 以 500ms 合并编辑，先让初始文本快照落入历史。
      await tester.pump(const Duration(milliseconds: 800));
      final editor = rich
          ? tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state
          : null;
      if (rich) {
        editor!.pastePlainText('desktop');
        editor.selectAll();
      } else {
        controller.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 7,
        );
      }
      focus.requestFocus();
      await tester.pump();
      // 初始 controller 的选区无效；有效选区也需要先形成撤销基线。
      await tester.pump(const Duration(milliseconds: 600));
      final rail = find.byKey(const ValueKey('composer-desktop-rail'));
      final history = find.byKey(const ValueKey('composer-desktop-history'));
      final document = find.byType(CustomScrollView).first;
      expect(rail, findsOneWidget);
      expect(history, findsOneWidget);
      expect(
        tester.getRect(document).left,
        greaterThan(tester.getRect(history).right),
      );
      expect(
        tester.getRect(document).right,
        lessThan(tester.getRect(rail).left),
      );
      expect(find.byType(CursorSwipeControl), findsNothing);
      await tester.tap(
        find.byTooltip(RegExp('^${RegExp.escape(S.current.toolPanel_bold)}')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        rich ? docToMarkdown(editor!.blocks) : controller.text,
        contains('**desktop**'),
      );
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) =>
                    w is IconButton &&
                    (w.tooltip ?? '').startsWith(S.current.toolbar_undo),
              ),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(
        find.byTooltip(RegExp('^${RegExp.escape(S.current.toolbar_undo)}')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        (rich ? docToMarkdown(editor!.blocks) : controller.text).trim(),
        'desktop',
      );
      expect(focus.hasFocus, isTrue);
      final selection = rich ? editor!.selection : controller.selection;

      await tester.tap(find.byTooltip(S.current.composer_expandToolbar));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final panel = find.byKey(const ValueKey('composer-tools-panel'));
      expect(panel, findsOneWidget);
      expect(tester.getRect(panel).right, lessThan(tester.getRect(rail).left));
      expect(tester.getRect(panel).top, greaterThanOrEqualTo(kToolbarHeight));
      tester.view.physicalSize = const Size(700, 760);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(rail, findsNothing);
      expect(panel, findsOneWidget);
      expect(tester.getRect(panel).right, lessThanOrEqualTo(700));
      expect(rich ? editor!.selection : controller.selection, selection);
      if (rich) {
        expect(
          tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state,
          same(editor),
        );
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(panel, findsNothing);
      expect(focus.hasFocus, isTrue);

      tester.view.physicalSize = const Size(390, 760);
      await tester.pump();
      expect(find.byType(ContentActionsButton), findsOneWidget);
      expect(
        find.byTooltip(RegExp('^${RegExp.escape(S.current.toolbar_undo)}')),
        findsNothing,
      );
      expect(
        find.byTooltip(S.current.composer_expandToolbar).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byType(ContentActionsButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byKey(const ValueKey('composer-content-actions-grid')),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(2, 80));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      tester.view.physicalSize = const Size(1200, 760);
      await tester.pump();
      expect(rail, findsOneWidget);
      expect(
        (rich ? docToMarkdown(editor!.blocks) : controller.text).trim(),
        'desktop',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    });

    testWidgets('PC 采用实际编辑区宽高，侧栏表情弹层随缩放避让 rich=$rich', (tester) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      Widget editor() => rich
          ? RichComposerEditor(controller: controller, focusNode: focus)
          : MarkdownEditor(
              controller: controller,
              focusNode: focus,
              showPreviewButton: false,
            );
      await _pump(
        tester,
        SizedBox(width: 600, child: editor()),
        desktop: true,
        width: 1300,
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('composer-desktop-rail')), findsNothing);
      expect(
        tester.getRect(find.byKey(const ValueKey('composer-format-row'))).right,
        lessThanOrEqualTo(600),
      );
      await _pump(tester, editor(), desktop: true, width: 1200, height: 400);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('composer-desktop-rail')), findsNothing);
      await _pump(tester, editor(), desktop: true, width: 1200);
      await tester.pump(const Duration(milliseconds: 400));
      focus.requestFocus();
      await tester.pump();
      final rail = find.byKey(const ValueKey('composer-desktop-rail'));
      expect(rail, findsOneWidget);
      await tester.tap(find.byTooltip(S.current.emoji_tab));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final popover = find.byKey(const ValueKey('composer-emoji-popover'));
      expect(popover, findsOneWidget);
      expect(
        tester.getRect(popover).right,
        lessThan(tester.getRect(rail).left),
      );
      tester.view.physicalSize = const Size(390, 760);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(popover, findsOneWidget);
      expect(tester.getRect(popover).left, greaterThanOrEqualTo(0));
      expect(tester.getRect(popover).right, lessThanOrEqualTo(390));
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    });
  }

  testWidgets('富文本持续输入也会定期生成最新草稿快照', (tester) async {
    final controller = TextEditingController();
    await _pump(tester, RichComposerEditor(controller: controller));
    await tester.pump(const Duration(milliseconds: 300));
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    for (var i = 0; i < 8; i++) {
      editor.pastePlainText('字');
      await tester.pump(const Duration(milliseconds: 300));
      if (i >= 3) expect(controller.text, isNotEmpty);
    }
    await tester.pump(const Duration(milliseconds: 850));
    expect(controller.text, contains('字字字字字字字字'));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  for (final rich in [false, true]) {
    testWidgets('键盘开合保持工具栏高度、分类宽度和光标入口状态 rich=$rich', (tester) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      const metadata = SizedBox.expand(key: ValueKey('transition-metadata'));
      await _pump(
        tester,
        rich
            ? RichComposerEditor(
                controller: controller,
                focusNode: focus,
                metaBar: metadata,
                onSwitchToSource: () {},
              )
            : MarkdownEditor(
                controller: controller,
                focusNode: focus,
                metaBar: metadata,
                showPreviewButton: false,
                onSwitchToRich: () {},
              ),
      );
      focus.requestFocus();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final info = find.byKey(const ValueKey('transition-metadata'));
      final cursor = find.byType(CursorSwipeControl);
      final originalState = tester.state(cursor);
      final expandedWidth = tester.getSize(info).width;
      final workbench = find.byType(ComposerWorkbench);
      final toolbarHeight = tester.getSize(workbench).height;

      tester.view.viewInsets = const FakeViewPadding(bottom: 32);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getSize(info).width, expandedWidth);
      expect(tester.getSize(workbench).height, toolbarHeight);
      expect(cursor.hitTestable(), findsOneWidget);
      expect(tester.state(cursor), same(originalState));

      // 键盘动画中途反向也只改变位置。
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getSize(info).width, expandedWidth);
      expect(cursor.hitTestable(), findsOneWidget);
      expect(tester.state(cursor), same(originalState));

      tester.view.viewInsets = const FakeViewPadding(bottom: 0);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getSize(info).width, expandedWidth);
      expect(tester.getSize(workbench).height, toolbarHeight);
      expect(cursor.hitTestable(), findsOneWidget);
      expect(focus.hasFocus, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    });

    testWidgets('键盘直接切到零占位后立即展开工具，不复用旧键盘高度 rich=$rich', (tester) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      await _pump(
        tester,
        rich
            ? RichComposerEditor(controller: controller, focusNode: focus)
            : MarkdownEditor(controller: controller, focusNode: focus),
      );
      await tester.pump(const Duration(milliseconds: 300));
      focus.requestFocus();
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pump();
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pump();
      tester.testTextInput.log.clear();
      await tester.tap(find.byTooltip(S.current.composer_expandToolbar));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      final grid = find.byKey(const ValueKey('composer-tools-panel'));
      expect(grid, findsOneWidget);
      expect(tester.getSize(grid).height, greaterThan(200));
      await tester.tap(find.byTooltip(S.current.composer_collapseToolbar));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(grid, findsNothing);
      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.show',
        ),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    });

    testWidgets('自定义工具固定持久化并在底栏可用 rich=$rich', (tester) async {
      final controller = TextEditingController();
      await _pump(
        tester,
        rich
            ? RichComposerEditor(controller: controller)
            : MarkdownEditor(controller: controller),
        desktop: true,
        width: 1000,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip(S.current.composer_expandToolbar));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text(S.current.toolPanel_customize));
      await tester.pump();
      final cell = find.byKey(const ValueKey('composer-tool-strikethrough'));
      await tester.ensureVisible(cell);
      await tester.pump();
      await tester.tap(cell);
      await tester.pump();
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getStringList(
          rich ? 'pref_rich_toolbar_tools' : 'pref_editor_toolbar_tools',
        ),
        contains('strikethrough'),
      );
      expect(controller.text, isEmpty, reason: '自定义只改工具栏，不执行格式操作');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final button = find.byWidgetPredicate(
        (w) =>
            w is Tooltip &&
            (w.message ?? '').startsWith(S.current.toolPanel_strikethrough),
      );
      expect(button, findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ComposerDesktopWorkbench)),
      );
      expect(
        rich
            ? container.read(preferencesProvider).richToolbarTools
            : container.read(preferencesProvider).editorToolbarTools,
        contains('strikethrough'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });

    testWidgets('正文下拉不再唤起工具，滚动后工具入口仍可用 rich=$rich', (tester) async {
      final raw = List.generate(40, (i) => '正文第 $i 段').join('\n\n');
      final controller = TextEditingController(text: rich ? '' : raw);
      final chrome = ComposerChromeController();
      await _pump(
        tester,
        ComposerChromeScope(
          controller: chrome,
          child: rich
              ? RichComposerEditor(controller: controller)
              : MarkdownEditor(controller: controller),
        ),
      );
      await tester.pump();
      if (rich) {
        tester
            .widget<FluxdoEditor>(find.byType(FluxdoEditor))
            .state
            .pastePlainText(raw);
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView).first)
          .controller!;
      scroll.jumpTo(0);
      await tester.pump();
      final drag = await tester.startGesture(const Offset(10, 200));
      await drag.moveBy(const Offset(0, 180));
      await drag.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('composer-tools-panel')), findsNothing);
      scroll.jumpTo(scroll.position.maxScrollExtent / 2);
      await tester.pump();
      await tester.dragFrom(const Offset(10, 300), const Offset(0, -120));
      await tester.pump(const Duration(milliseconds: 300));
      expect(chrome.hidden, isTrue);
      expect(
        find.byTooltip(S.current.toolPanel_bold).hitTestable(),
        findsNothing,
      );
      await tester.dragFrom(const Offset(10, 250), const Offset(0, 100));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(chrome.hidden, isFalse);
      await tester.tap(find.byTooltip(S.current.composer_expandToolbar));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.byKey(const ValueKey('composer-tools-panel')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip(S.current.composer_collapseToolbar));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      chrome.dispose();
    });
  }

  for (final rich in [false, true]) {
    testWidgets('滚到文末后向上阅读不被光标拉回，继续输入仍跟随 rich=$rich', (tester) async {
      final raw = List.generate(80, (i) => '正文第 $i 段，保持光标在文末。').join('\n\n');
      final controller = TextEditingController(text: rich ? '' : raw);
      final focus = FocusNode();
      await _pump(
        tester,
        rich
            ? RichComposerEditor(controller: controller)
            : MarkdownEditor(controller: controller, focusNode: focus),
        desktop: true,
        width: 1000,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      if (rich) {
        tester
            .widget<FluxdoEditor>(find.byType(FluxdoEditor))
            .state
            .pastePlainText(raw);
      } else {
        focus.requestFocus();
        controller.selection = TextSelection.collapsed(offset: raw.length);
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      final scrollFinder = find.byType(CustomScrollView).first;
      final scroll = tester.widget<CustomScrollView>(scrollFinder).controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      final bottom = scroll.offset;
      expect(bottom, greaterThan(500));
      for (var i = 0; i < 2; i++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(scrollFinder),
            scrollDelta: const Offset(0, -240),
          ),
        );
        final readingOffset = scroll.offset;
        expect(readingOffset, lessThan(bottom - 100));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));
        await tester.pump();
        expect(
          scroll.offset,
          closeTo(readingOffset, 1),
          reason: '停止滚动后也不能拉回文末',
        );
      }
      final readingOffset = scroll.offset;
      if (rich) {
        tester
            .widget<FluxdoEditor>(find.byType(FluxdoEditor))
            .state
            .insertText('继续输入');
      } else {
        controller.value = TextEditingValue(
          text: '$raw继续输入',
          selection: TextSelection.collapsed(offset: raw.length + 4),
        );
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(scroll.offset, greaterThan(readingOffset + 100));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      controller.dispose();
      focus.dispose();
    });
  }

  for (final rich in [false, true]) {
    testWidgets('页头隐藏时编辑工具仍可见，继续输入恢复页头 rich=$rich', (tester) async {
      final chrome = ComposerChromeController();
      final controller = TextEditingController();
      await _pump(
        tester,
        ComposerChromeScope(
          controller: chrome,
          child: rich
              ? RichComposerEditor(controller: controller)
              : MarkdownEditor(controller: controller),
        ),
        desktop: true,
        width: 1000,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester
            .widget<CustomScrollView>(find.byType(CustomScrollView).first)
            .controller!
            .position
            .maxScrollExtent,
        closeTo(0, .01),
      );
      chrome.hide();
      await tester.pump();
      expect(chrome.hidden, isTrue);
      expect(
        find
            .byTooltip(RegExp('^${RegExp.escape(S.current.toolPanel_bold)}'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byTooltip(S.current.composer_expandToolbar).hitTestable(),
        findsOneWidget,
      );
      if (rich) {
        tester
            .widget<FluxdoEditor>(find.byType(FluxdoEditor))
            .state
            .insertText('typed');
      } else {
        controller.value = const TextEditingValue(
          text: 'typed',
          selection: TextSelection.collapsed(offset: 5),
        );
      }
      await tester.pump();
      expect(chrome.hidden, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      chrome.dispose();
    });
  }

  for (final width in [320.0, 390.0, 1000.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('$width 宽、${scale}x 字体：实际编辑台无溢出、按钮保留触控空间', (tester) async {
        final controller = TextEditingController(
          text: '最近重新整理了自己的写作环境。\n\n常用的工具留在手边，需要的时候，它们都在。',
        );
        final focus = FocusNode();
        final category = Category.fromJson({
          'id': 1,
          'name': '软件与应用开发讨论',
          'color': '315fe7',
        });
        await _pump(
          tester,
          MarkdownEditor(
            controller: controller,
            focusNode: focus,
            expands: true,
            showPreviewButton: false,
            onSwitchToRich: () {},
            metaBar: ComposerMetaBar(
              category: category,
              categories: [category],
              onCategorySelected: (_) {},
              selectedTags: const ['flutter', 'design', 'experience'],
              allTags: const ['flutter', 'design', 'experience'],
              onTagsChanged: (_) {},
            ),
          ),
          width: width,
          scale: scale,
          dark: scale == 2,
        );
        focus.requestFocus();
        tester.view.viewInsets = const FakeViewPadding(bottom: 240);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        expect(find.byType(ComposerWorkbench), findsOneWidget);
        final info = tester.getRect(
          find.byKey(const ValueKey('composer-context-row')),
        );
        final formats = tester.getRect(
          find.byKey(const ValueKey('composer-format-row')),
        );
        // 宽手机/平板仍是触控布局，不能因变宽而把分类与工具合为一行。
        expect(formats.top, greaterThanOrEqualTo(info.bottom));
        final island = tester.getRect(
          find.byKey(const ValueKey('composer-island-surface')),
        );
        final canvas = tester.getRect(
          find.byKey(const ValueKey('composer-writing-canvas')),
        );
        final viewport = tester.getRect(find.byType(CustomScrollView).first);
        expect(viewport.bottom, canvas.bottom);
        expect(viewport.bottom, greaterThan(island.top + 48));
        expect(island.left, greaterThan(canvas.left));
        expect(island.right, lessThan(canvas.right));
        expect(island.bottom, lessThan(canvas.bottom));
        expect(find.byType(GlassSurface), findsOneWidget);
        final bold = find.byTooltip(S.current.toolPanel_bold);
        expect(tester.getSize(bold).width, greaterThanOrEqualTo(48));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        controller.dispose();
        focus.dispose();
      });
    }
  }

  for (final rich in [false, true]) {
    testWidgets('光标与内容菜单保留键盘和选区 rich=$rich', (tester) async {
      final controller = TextEditingController(text: rich ? '' : 'hello world');
      final focus = FocusNode();
      await _pump(
        tester,
        rich
            ? RichComposerEditor(controller: controller, focusNode: focus)
            : MarkdownEditor(controller: controller, focusNode: focus),
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      focus.requestFocus();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final editor = rich
          ? tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state
          : null;
      if (rich) {
        editor!.pastePlainText('hello world');
        editor.selectAll();
      } else {
        controller.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 5,
        );
      }
      await tester.pump();
      final selection = rich ? editor!.selection : controller.selection;
      expect(focus.hasFocus, isTrue);
      for (final control in [
        find.byType(ContentActionsButton),
        find.byType(CursorSwipeControl),
      ]) {
        tester.testTextInput.log.clear();
        await tester.tap(control);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(focus.hasFocus, isTrue, reason: '菜单路由不能抢正文焦点');
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.hide',
          ),
          isEmpty,
        );
        expect(rich ? editor!.selection : controller.selection, selection);
        final items = tester.widget(control) is ContentActionsButton
            ? find.byKey(const ValueKey('composer-content-actions-grid'))
            : find.byType(PopupMenuItem<int>);
        expect(items, findsWidgets);
        expect(tester.getRect(items.first).top, greaterThanOrEqualTo(0));
        expect(
          tester.getRect(items.last).bottom,
          lessThanOrEqualTo(500),
          reason: '操作菜单避开键盘',
        );
        await tester.tapAt(const Offset(2, 80));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(focus.hasFocus, isTrue);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    });
  }

  for (final rich in [false, true]) {
    testWidgets('键盘终态通知不抢跑位置，普通开合逐帧同步浮岛 rich=$rich', (tester) async {
      tester.view.viewPadding = const FakeViewPadding(bottom: 20);
      addTearDown(tester.view.resetViewPadding);
      final controller = TextEditingController(text: rich ? '' : '保留当前段落');
      final focus = FocusNode();
      await _pump(
        tester,
        rich
            ? RichComposerEditor(controller: controller, focusNode: focus)
            : MarkdownEditor(controller: controller, focusNode: focus),
      );
      await tester.pump(const Duration(milliseconds: 300));
      if (rich) {
        tester
            .widget<FluxdoEditor>(find.byType(FluxdoEditor))
            .state
            .insertText('保留当前段落');
        await tester.pump();
      }
      focus.requestFocus();
      await tester.pump();
      final space = find.byKey(const ValueKey('composer-keyboard-space'));
      final surface = find.byKey(const ValueKey('composer-island-surface'));
      final initial = tester.getRect(surface);
      expect(tester.getSize(space).height, 20);

      // Android 的终态通知可以早于原生动画第一帧，不能拿它直接占位。
      ChatBottomContainerListenerManager().flutterApi.keyboardHeight(300);
      await tester.pump();
      expect(tester.getRect(surface), initial);
      for (final height in [20.0, 40.0, 60.0, 100.0, 160.0, 240.0, 300.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: height);
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getSize(space).height, height);
        expect(
          tester.getRect(surface).bottom,
          closeTo(760 - height - kComposerIslandBottomGap, .1),
        );
        expect(tester.getSize(surface).height, initial.height);
      }
      final open = tester.getRect(surface);
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.getRect(surface), open, reason: '键盘到位后不能再补播另一段收放');

      ChatBottomContainerListenerManager().flutterApi.keyboardHeight(0);
      await tester.pump();
      expect(tester.getRect(surface), open, reason: '关闭通知不能提前清空仍在移动的键盘占位');
      for (final height in [240.0, 160.0, 100.0, 60.0, 40.0, 20.0, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: height);
        await tester.pump(const Duration(milliseconds: 16));
        final reserved = height < 20 ? 20.0 : height;
        expect(tester.getSize(space).height, reserved);
        expect(
          tester.getRect(surface).bottom,
          closeTo(760 - reserved - kComposerIslandBottomGap, .1),
        );
        expect(tester.getSize(surface).height, initial.height);
      }
      expect(tester.getRect(surface), initial);
      expect(find.byKey(const ValueKey('composer-format-row')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.getRect(surface), initial);
      expect(focus.hasFocus, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    });

    testWidgets('表情与键盘往返及关闭后工具栏始终可用 rich=$rich', (tester) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      final sourceKey = GlobalKey<MarkdownEditorState>();
      final richKey = GlobalKey<RichComposerEditorState>();
      await _pump(
        tester,
        rich
            ? RichComposerEditor(
                key: richKey,
                controller: controller,
                focusNode: focus,
              )
            : MarkdownEditor(
                key: sourceKey,
                controller: controller,
                focusNode: focus,
              ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      focus.requestFocus();
      await tester.pump();

      Future<void> keyboardHeight(double height) async {
        tester.view.viewInsets = FakeViewPadding(bottom: height);
        ChatBottomContainerListenerManager().flutterApi.keyboardHeight(height);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
      }

      final formats = find.byKey(const ValueKey('composer-format-row'));
      final emojiToggle = find.descendant(
        of: formats,
        matching: find.byTooltip(S.current.emoji_tab),
      );
      expect(formats, findsOneWidget, reason: '没有软键盘也能使用格式工具');
      await keyboardHeight(260);
      final toolbarBottom = tester.getRect(formats).bottom;
      await tester.tap(emojiToggle);
      await tester.pump();
      expect(formats, findsOneWidget);
      await keyboardHeight(0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(EmojiStickerPanel), findsOneWidget);
      expect(formats, findsOneWidget);
      expect(find.byIcon(Symbols.keyboard_rounded), findsOneWidget);
      expect(tester.getRect(formats).bottom, closeTo(toolbarBottom, .1));

      await tester.tap(emojiToggle);
      await tester.pump();
      expect(formats, findsOneWidget, reason: '原生键盘高度回报前不能闪退');
      await tester.pump(const Duration(milliseconds: 160));
      expect(formats, findsOneWidget);
      for (final height in [25.0, 110.0, 220.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: height);
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.getRect(formats).bottom,
          closeTo(toolbarBottom, .1),
          reason: '表情切回键盘时不追随尚未到位的键盘跳到底部',
        );
      }
      await keyboardHeight(260);
      expect(find.byType(EmojiStickerPanel), findsNothing);
      expect(formats, findsOneWidget);
      expect(focus.hasFocus, isTrue);

      // 新键盘变矮且终态高度回报较晚，等高交接结束后仍须继续跟随真实帧。
      await tester.tap(emojiToggle);
      await tester.pump();
      await keyboardHeight(0);
      await tester.tap(emojiToggle);
      await tester.pump();
      final keyboardSpace = find.byKey(
        const ValueKey('composer-keyboard-space'),
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      await tester.pump();
      expect(tester.getSize(keyboardSpace).height, 260);
      ChatBottomContainerListenerManager().flutterApi.keyboardHeight(220);
      await tester.pump();
      await tester.pump();
      expect(tester.getSize(keyboardSpace).height, 220);
      tester.view.viewInsets = const FakeViewPadding(bottom: 110);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getSize(keyboardSpace).height, 110);
      await keyboardHeight(0);
      expect(formats, findsOneWidget, reason: '关闭键盘不隐藏编辑工具');

      await keyboardHeight(260);
      await tester.tap(emojiToggle);
      await tester.pump();
      await keyboardHeight(0);
      await tester.tap(find.byTooltip(S.current.composer_expandToolbar));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      expect(
        find.byKey(const ValueKey('composer-tools-panel')),
        findsOneWidget,
      );
      if (rich) {
        richKey.currentState!.closeEmojiPanel();
      } else {
        sourceKey.currentState!.closeEmojiPanel();
      }
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      await tester.pump(const Duration(milliseconds: 170));
      expect(find.byType(EmojiStickerPanel), findsNothing);
      expect(formats, findsOneWidget, reason: '关闭表情面板后保留编辑工具');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    });

    testWidgets('工具接替键盘后保留展开，关闭输入后仍能再次展开 rich=$rich', (tester) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      final sourceKey = GlobalKey<MarkdownEditorState>();
      final richKey = GlobalKey<RichComposerEditorState>();
      await _pump(
        tester,
        rich
            ? RichComposerEditor(
                key: richKey,
                controller: controller,
                focusNode: focus,
              )
            : MarkdownEditor(
                key: sourceKey,
                controller: controller,
                focusNode: focus,
              ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final island = find.byKey(const ValueKey('composer-workbench'));
      final grid = find.byKey(const ValueKey('composer-tools-panel'));
      final handle = find.byKey(const ValueKey('composer-tools-handle'));
      final formats = find.byKey(const ValueKey('composer-format-row'));
      final closedHeight = tester.getSize(island).height;
      expect(handle, findsOneWidget);
      expect(formats, findsOneWidget);
      focus.requestFocus();
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 26);
      ChatBottomContainerListenerManager().flutterApi.keyboardHeight(260);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.getSize(island).height, closedHeight);
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 140));
      expect(tester.getSize(island).height, closedHeight);
      await tester.tap(find.byTooltip(S.current.composer_expandToolbar));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      expect(grid, findsOneWidget);
      final expandedTop = tester.getTopLeft(island).dy;
      tester.view.viewInsets = const FakeViewPadding();
      ChatBottomContainerListenerManager().flutterApi.keyboardHeight(0);
      await tester.pump();
      expect(
        tester.getTopLeft(island).dy,
        closeTo(expandedTop, .1),
        reason: '键盘让出的空间由面板向下接住，上沿不跳变',
      );
      expect(grid, findsOneWidget);
      if (rich) {
        richKey.currentState!.closeEmojiPanel();
      } else {
        sourceKey.currentState!.closeEmojiPanel();
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(grid, findsNothing);
      expect(formats, findsOneWidget);
      expect(handle, findsOneWidget);
      expect(tester.getSize(island).height, closedHeight);

      tester.testTextInput.log.clear();
      await tester.tap(find.byTooltip(S.current.composer_expandToolbar));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      expect(grid, findsOneWidget, reason: '关闭输入后仍能打开更多工具');
      expect(tester.getSize(grid).height, greaterThan(200));
      await tester.tap(find.byTooltip(S.current.composer_collapseToolbar));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(grid, findsNothing);
      expect(tester.getSize(island).height, closedHeight);
      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.show',
        ),
        isEmpty,
        reason: '没有底部键盘时，展开和收起工具不主动唤起键盘',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    });
  }

  for (final rich in [false, true]) {
    testWidgets('工具态点击正文重新接回键盘 rich=$rich', (tester) async {
      final controller = TextEditingController(text: rich ? '' : '继续编辑');
      final focus = FocusNode();
      await _pump(
        tester,
        rich
            ? RichComposerEditor(controller: controller, focusNode: focus)
            : MarkdownEditor(controller: controller, focusNode: focus),
      );
      await tester.pump(const Duration(milliseconds: 300));
      if (rich) {
        tester
            .widget<FluxdoEditor>(find.byType(FluxdoEditor))
            .state
            .pastePlainText('继续编辑');
      }
      focus.requestFocus();
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pump();
      await tester.tap(find.byTooltip(S.current.composer_expandToolbar));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('composer-tools-panel')),
        findsOneWidget,
      );
      tester.testTextInput.log.clear();
      await tester.tapAt(const Offset(70, 100));
      await tester.pump();
      expect(
        tester.testTextInput.log.any((call) => call.method == 'TextInput.show'),
        isTrue,
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('composer-tools-panel')), findsNothing);
      expect(focus.hasFocus, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    });
  }

  for (final rich in [false, true]) {
    for (final size in [
      const Size(390, 760),
      const Size(375, 500),
      const Size(600, 320),
    ]) {
      testWidgets('无软键盘占位时可编辑和展开工具 rich=$rich size=$size', (tester) async {
        tester.view.viewPadding = const FakeViewPadding(bottom: 20);
        addTearDown(tester.view.resetViewPadding);
        final compact = size.height < 760;
        final controller = TextEditingController();
        final focus = FocusNode();
        await _pump(
          tester,
          rich
              ? RichComposerEditor(controller: controller, focusNode: focus)
              : MarkdownEditor(
                  controller: controller,
                  focusNode: focus,
                  showPreviewButton: false,
                ),
          width: size.width,
          height: size.height,
          scale: size.width == 375 ? 2 : 1,
          dark: compact,
          disableAnimations: compact,
        );
        await tester.pump(const Duration(milliseconds: 300));
        final formats = find.byKey(const ValueKey('composer-format-row'));
        final cursor = find.byType(CursorSwipeControl);
        final island = find.byKey(const ValueKey('composer-island-surface'));
        final initial = tester.getRect(island);
        expect(formats, findsOneWidget);
        expect(cursor.hitTestable(), findsOneWidget);
        expect(initial.bottom, lessThanOrEqualTo(size.height - 20));

        // 首次输入前就能展开，不依赖一次软键盘高度回报。
        tester.testTextInput.log.clear();
        await tester.tap(find.byTooltip(S.current.composer_expandToolbar));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 450));
        final grid = find.byKey(const ValueKey('composer-tools-panel'));
        expect(grid, findsOneWidget);
        final boldCell = find.byKey(const ValueKey('composer-tool-bold'));
        await tester.ensureVisible(boldCell);
        await tester.pump();
        expect(boldCell.hitTestable(), findsOneWidget);
        expect(
          tester.getRect(boldCell).bottom,
          lessThanOrEqualTo(tester.getRect(grid).bottom),
        );
        expect(
          tester.getRect(island).top,
          greaterThanOrEqualTo(kToolbarHeight),
        );
        await tester.tap(find.byTooltip(S.current.composer_collapseToolbar));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(grid, findsNothing);
        expect(tester.getRect(island), initial);
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.show',
          ),
          isEmpty,
        );

        focus.requestFocus();
        await tester.pump();
        if (rich) {
          final editor = tester
              .widget<FluxdoEditor>(find.byType(FluxdoEditor))
              .state;
          editor.pastePlainText('外接键盘输入');
          editor.selectAll();
        } else {
          await tester.enterText(find.byType(EditableText), '浮动键盘输入');
          controller.selection = TextSelection(
            baseOffset: 0,
            extentOffset: controller.text.length,
          );
        }
        await tester.pump();
        expect(tester.view.viewInsets.bottom, 0);
        await tester.tap(find.byTooltip(S.current.toolPanel_bold));
        await tester.pump();
        final text = rich
            ? docToMarkdown(
                tester
                    .widget<FluxdoEditor>(find.byType(FluxdoEditor))
                    .state
                    .blocks,
              )
            : controller.text;
        expect(text, contains(rich ? '**外接键盘输入**' : '**浮动键盘输入**'));
        if (rich) {
          final bold = tester.widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == S.current.toolPanel_bold,
            ),
          );
          expect(bold.isSelected, isTrue, reason: '选中态来自实际编辑器格式状态');
        }
        expect(focus.hasFocus, isTrue);
        expect(formats, findsOneWidget);
        expect(cursor.hitTestable(), findsOneWidget);
        expect(tester.getRect(island), initial);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        focus.dispose();
      });
    }
  }

  testWidgets('富文本扩展动作直接列出插入块，不再叠加菜单', (tester) async {
    final controller = TextEditingController();
    await _pump(
      tester,
      RichComposerEditor(controller: controller, onSwitchToSource: () {}),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    final before = docToMarkdown(editor.blocks);
    await tester.runAsync(() => DiscourseCookService().ensureInitialized());
    await tester.tap(find.byTooltip(S.current.composer_expandToolbar));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pump();
    expect(find.text(S.current.toolbar_moreTools), findsNothing);
    expect(find.byKey(const ValueKey('composer-tools-search')), findsNothing);
    final table = find.byKey(const ValueKey('composer-tool-insert:table'));
    await tester.scrollUntilVisible(
      table,
      180,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('composer-tools-panel')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(table);
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pump(const Duration(milliseconds: 400));
    for (
      var i = 0;
      i < 30 && !docToMarkdown(editor.blocks).contains('|');
      i++
    ) {
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(find.byKey(const ValueKey('composer-tools-panel')), findsNothing);
    expect(docToMarkdown(editor.blocks), contains('|'));
    editor.undo();
    await tester.pump();
    expect(docToMarkdown(editor.blocks), before);
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView).first)
        .controller!;
    expect(scroll.position.maxScrollExtent, closeTo(0, .01));
    editor.pastePlainText(List.generate(80, (i) => '长正文第 $i 段').join('\n\n'));
    await tester.pump();
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    editor.undo();
    await tester.pump();
    expect(scroll.position.maxScrollExtent, closeTo(0, .01));

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets('光标点按入口按字素移动，不拆开 emoji', (tester) async {
    final controller = TextEditingController(text: 'a😀b');
    final focus = FocusNode();
    await _pump(
      tester,
      MarkdownEditor(
        controller: controller,
        focusNode: focus,
        showPreviewButton: false,
      ),
    );
    focus.requestFocus();
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    controller.selection = const TextSelection.collapsed(offset: 3);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('cursor-swipe-knob')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text(S.current.composer_cursorLeft));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.selection.extentOffset, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    focus.dispose();
  });

  testWidgets('分类和标签恢复独立弹框，并保持正文选区', (tester) async {
    final controller = TextEditingController(text: 'abcdef');
    final focus = FocusNode();
    final categories = [
      Category.fromJson({
        'id': 1,
        'name': '开发',
        'color': '315fe7',
        'permission': 1,
      }),
      Category.fromJson({
        'id': 2,
        'name': '日常',
        'color': '315fe7',
        'permission': 1,
      }),
    ];
    Category? selected;
    await _pump(
      tester,
      MarkdownEditor(
        controller: controller,
        focusNode: focus,
        showPreviewButton: false,
        metaBar: ComposerMetaBar(
          category: categories.first,
          categories: categories,
          onCategorySelected: (value) => selected = value,
          selectedTags: const [],
          allTags: const [],
          onTagsChanged: (_) {},
        ),
      ),
    );
    focus.requestFocus();
    controller.selection = const TextSelection.collapsed(offset: 3);
    await tester.pump();
    await tester.tap(find.text('开发'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ComposerWorkbench), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.tap(find.text('日常'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(selected?.id, 2);
    expect(controller.selection.extentOffset, 3);
    final service = DiscourseService();
    final mock = InterceptorsWrapper(
      onRequest: (options, handler) => handler.resolve(
        Response(requestOptions: options, data: {'results': <Object>[]}),
      ),
    );
    service.dio.interceptors.insert(0, mock);
    addTearDown(() => service.dio.interceptors.remove(mock));
    await tester.tap(find.text(S.current.topic_addTags));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(TagSelectionSheet), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ComposerWorkbench),
        matching: find.byType(TagSelectionSheet),
      ),
      findsNothing,
    );
    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.selection.extentOffset, 3);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    focus.dispose();
  });
  for (final width in [390.0, 1000.0]) {
    for (final rich in [false, true]) {
      testWidgets(
        '真实 PC ${width.toInt()} 宽 ${rich ? "富文本" : "源码"}：属性在文档头部，光标手势不占桌面栏',
        (tester) async {
          final controller = TextEditingController();
          final category = Category.fromJson({
            'id': 1,
            'name': '开发',
            'color': '315fe7',
            'permission': 1,
          });
          final meta = ComposerMetaBar(
            category: category,
            categories: [category],
            onCategorySelected: (_) {},
            selectedTags: const ['flutter', 'design'],
            allTags: const ['flutter', 'design'],
            onTagsChanged: (_) {},
          );
          final header = Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text('分享最近的开发体验', style: const TextStyle(fontSize: 24)),
          );
          await _pump(
            tester,
            rich
                ? RichComposerEditor(
                    controller: controller,
                    header: header,
                    metaBar: meta,
                    onSwitchToSource: () {},
                  )
                : MarkdownEditor(
                    controller: controller,
                    header: header,
                    metaBar: meta,
                    onSwitchToRich: () {},
                    showPreviewButton: false,
                  ),
            width: width,
            desktop: true,
            dark: true,
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(PlatformUtils.isDesktop, isTrue);
          expect(find.byType(ContentActionsButton), findsOneWidget);
          expect(find.byType(CursorSwipeControl), findsNothing);
          expect(
            find.byKey(const ValueKey('composer-context-row')),
            findsNothing,
          );
          final attributes = find.byKey(
            const ValueKey('composer-document-metadata'),
          );
          expect(attributes, findsOneWidget);
          expect(
            find.descendant(
              of: find.byType(ComposerIsland),
              matching: find.byType(ComposerMetaBar),
            ),
            findsNothing,
          );
          expect(
            tester.getRect(attributes).bottom,
            lessThan(tester.getRect(find.byType(ComposerIsland)).top),
          );
          expect(
            find.descendant(
              of: find.byType(ComposerIsland),
              matching: find.byType(GlassSurface),
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 1));
          controller.dispose();
        },
      );
    }
  }

  for (final rich in [false, true]) {
    for (final size in [const Size(390, 844), const Size(360, 520)]) {
      testWidgets('手机顶底栏同步阅读显隐，输入与零占位键盘保持显示 rich=$rich size=$size', (
        tester,
      ) async {
        final text = TextEditingController();
        final focus = FocusNode();
        final chrome = ComposerChromeController();
        await _pump(
          tester,
          ComposerChromeScope(
            controller: chrome,
            child: Column(
              children: [
                const ComposerChromeVisibility(
                  top: true,
                  child: SizedBox(height: 36, child: Text('TOP BAR')),
                ),
                Expanded(
                  child: rich
                      ? RichComposerEditor(controller: text, focusNode: focus)
                      : MarkdownEditor(controller: text, focusNode: focus),
                ),
              ],
            ),
          ),
          width: size.width,
          height: size.height,
        );
        await tester.pump(const Duration(milliseconds: 800));
        final raw = List.generate(50, (i) => '正文段落 $i').join('\n\n');
        final core = rich
            ? tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state
            : null;
        if (rich) {
          core!.pastePlainText(raw);
        } else {
          text.text = raw;
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final scroll = tester
            .widget<CustomScrollView>(find.byType(CustomScrollView).first)
            .controller!;
        Future<void> readDown() async {
          scroll.jumpTo(scroll.position.maxScrollExtent / 2);
          await tester.pump();
          final rect = tester.getRect(find.byType(CustomScrollView).first);
          await tester.dragFrom(
            rect.topLeft + const Offset(10, 90),
            const Offset(0, -75),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
        }

        await readDown();
        expect(chrome.hidden, isTrue);
        expect(find.text('TOP BAR').hitTestable(), findsNothing);
        expect(
          find.byTooltip(S.current.toolPanel_bold).hitTestable(),
          findsNothing,
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 180);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 220));
        await readDown();
        expect(chrome.hidden, isFalse);
        expect(find.text('TOP BAR').hitTestable(), findsOneWidget);
        expect(
          find.byTooltip(S.current.toolPanel_bold).hitTestable(),
          findsOneWidget,
        );
        tester.view.viewInsets = const FakeViewPadding();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        focus.requestFocus();
        await tester.pump();
        if (rich) {
          final block = core!.textBlockById(core.selection!.extent.blockId)!;
          tester.testTextInput.updateEditingValue(
            TextEditingValue(
              text: ' ${block.content.text}x',
              selection: TextSelection.collapsed(
                offset: block.content.length + 2,
              ),
            ),
          );
        } else {
          tester.testTextInput.updateEditingValue(
            TextEditingValue(
              text: '${text.text}x',
              selection: TextSelection.collapsed(offset: text.text.length + 1),
            ),
          );
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await readDown();
        expect(chrome.hidden, isFalse, reason: '浮动/外接键盘输入无底部占位也不能隐藏');
        ChatBottomContainerListenerManager().flutterApi.keyboardHeight(0);
        await tester.pump();
        await readDown();
        expect(chrome.hidden, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
        text.dispose();
        focus.dispose();
        chrome.dispose();
      });
    }
  }

  for (final rich in [false, true]) {
    testWidgets('手机表情与展开工具面板锁定顶底栏，关闭后恢复阅读隐藏 rich=$rich', (tester) async {
      final text = TextEditingController();
      final chrome = ComposerChromeController();
      final source = GlobalKey<MarkdownEditorState>();
      final rendered = GlobalKey<RichComposerEditorState>();
      await _pump(
        tester,
        ComposerChromeScope(
          controller: chrome,
          child: rich
              ? RichComposerEditor(key: rendered, controller: text)
              : MarkdownEditor(key: source, controller: text),
        ),
      );
      await tester.pump(const Duration(milliseconds: 800));
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('composer-format-row')),
          matching: find.byTooltip(S.current.emoji_tab),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      chrome.hide();
      expect(chrome.hidden, isFalse);
      if (rich) {
        rendered.currentState!.closeEmojiPanel();
      } else {
        source.currentState!.closeEmojiPanel();
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      chrome.hide();
      expect(chrome.hidden, isTrue);
      chrome.reveal();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      await tester.tap(find.byTooltip(S.current.composer_expandToolbar));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      chrome.hide();
      expect(chrome.hidden, isFalse);
      await tester.tap(find.byTooltip(S.current.composer_collapseToolbar));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      chrome.hide();
      expect(chrome.hidden, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      text.dispose();
      chrome.dispose();
    });
  }

  for (final change in ['keyboard-open', 'keyboard-close', 'resize']) {
    testWidgets('富文本阅读上文时布局变化不追到文末 $change', (tester) async {
      final controller = TextEditingController();
      await _pump(
        tester,
        RichComposerEditor(controller: controller),
        desktop: change == 'resize',
        width: 600,
      );
      await tester.pump(const Duration(milliseconds: 800));
      final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
      editor.state.pastePlainText(
        List.generate(60, (i) => '上文阅读段落 $i').join('\n\n'),
      );
      if (change == 'keyboard-close') {
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView).first)
          .controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(scroll.offset, greaterThan(500));
      scroll.jumpTo(0);
      await tester.pump();
      await tester.pump();
      final selection = editor.state.selection;
      if (change == 'resize') {
        tester.view.physicalSize = const Size(600, 540);
      } else {
        tester.view.viewInsets = FakeViewPadding(
          bottom: change == 'keyboard-open' ? 300 : 0,
        );
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(editor.state.selection, selection);
      expect(scroll.offset, closeTo(0, 1), reason: '只变布局不能回到屏幕外的旧光标');
      editor.state.insertText('继续');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(scroll.offset, greaterThan(500));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }

  testWidgets('富文本正在编辑时键盘连续升起，光标仍保持在浮岛上方', (tester) async {
    final controller = TextEditingController();
    await _pump(tester, RichComposerEditor(controller: controller));
    await tester.pump(const Duration(milliseconds: 800));
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
    editor.state.pastePlainText(List.filled(50, '正文测试，检查浮岛避让。').join('\n\n'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    for (final inset in [50.0, 140.0, 240.0, 300.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final caret = tester
        .widget<EditorCaret>(find.byType(EditorCaret))
        .caretRect!;
    final bottom =
        tester.getTopLeft(find.byType(FluxdoEditor)).dy + caret.bottom;
    final toolbar = tester.getRect(
      find.byKey(const ValueKey('composer-island-surface')),
    );
    expect(bottom, lessThan(toolbar.top));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('源码最后一行与光标可以滚到浮岛上方', (tester) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    await _pump(
      tester,
      MarkdownEditor(
        controller: controller,
        focusNode: focus,
        expands: true,
        showPreviewButton: false,
      ),
    );
    focus.requestFocus();
    await tester.pump();
    controller.value = TextEditingValue(
      text: List.filled(50, '正文测试，检查浮岛避让。').join('\n'),
      selection: TextSelection.collapsed(
        offset: List.filled(50, '正文测试，检查浮岛避让。').join('\n').length,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final rect = editable.getLocalRectForCaret(controller.selection.extent);
    final bottom = editable.localToGlobal(rect.bottomLeft).dy;
    final islandTop = tester
        .getRect(find.byKey(const ValueKey('composer-island-surface')))
        .top;
    expect(bottom, lessThan(islandTop));
    // 改变可用高度（窗口收窄、键盘出现）后仍需避让同一个浮岛。
    tester.view.physicalSize = const Size(390, 540);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    final resizedCaret = editable.getLocalRectForCaret(
      controller.selection.extent,
    );
    expect(
      editable.localToGlobal(resizedCaret.bottomLeft).dy,
      lessThan(
        tester
            .getRect(find.byKey(const ValueKey('composer-island-surface')))
            .top,
      ),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    focus.dispose();
  });
}
