import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/services/discourse_cook_service.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/storage/app_database.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_view_mode_switcher.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_header_actions.dart';
import 'package:fluxdo/widgets/markdown_editor/content_actions_button.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_editor.dart';
import 'package:fluxdo/widgets/post/reply_sheet.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/rich_composer_editor.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpReply(
  WidgetTester tester, {
  bool rich = false,
  bool review = false,
  ReplySheet? sheet,
  double? width,
  double scale = 1,
  bool dark = false,
}) async {
  PlatformUtils.debugDesktopOverride = false;
  addTearDown(() => PlatformUtils.debugDesktopOverride = null);
  if (width != null) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 760);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
  }
  addTearDown(tester.view.resetViewInsets);
  SharedPreferences.setMockInitialValues({
    'pref_use_rich_composer': rich,
    'pref_ai_post_review_enabled': review,
  });
  final prefs = await SharedPreferences.getInstance();
  FlutterSecureStorage.setMockInitialValues({'linux_do_username': 'tester'});
  final mock = InterceptorsWrapper(
    onRequest: (options, handler) {
      handler.resolve(
        Response(
          requestOptions: options,
          data: {'success': 'OK', 'draft': null},
        ),
      );
    },
  );
  DiscourseService().dio.interceptors.insert(0, mock);
  addTearDown(() => DiscourseService().dio.interceptors.remove(mock));
  if (sheet?.topicId != null) {
    final directory = await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'fluxdo-reply-header-',
      );
      Hive.init(directory.path);
      await AppDatabase.debugReset();
      AppDatabase.debugMarkInitialized();
      await AppDatabase.namedBox('local_drafts');
      return directory;
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await Hive.close();
        await AppDatabase.debugReset();
        await directory!.delete(recursive: true);
      });
    });
  }
  await tester.runAsync(() async {
    final loaded = await PreloadedDataService().hydrateFromHtml(
      '<meta id="data-discourse-setup">'
      '<script id="data-preloaded" type="application/json">${jsonEncode({
        'currentUser': {'id': 1, 'username': 'tester'},
        'siteSettings': {'min_post_length': 1, 'max_post_length': 10000},
        'site': {'categories': [], 'top_tags': []},
      })}</script>',
    );
    expect(loaded, isTrue);
    await DiscourseCookService().ensureInitialized();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
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
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(body: sheet ?? const ReplySheet()),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  // 草稿的本地存储读取需要让平台异步回调完成，再操作被遮罩覆盖的页头。
  for (
    var i = 0;
    i < 20 && find.byType(CloseButton).hitTestable().evaluate().isEmpty;
    i++
  ) {
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(find.byType(CloseButton).hitTestable(), findsOneWidget);
}

void main() {
  for (final (width, scale, dark) in [
    (320.0, 1.0, false),
    (390.0, 1.0, false),
    (700.0, 1.0, true),
    (390.0, 2.0, false),
  ]) {
    testWidgets('回复页头统一尺寸、次级操作收纳且不收键盘 $width/$scale', (tester) async {
      await _pumpReply(
        tester,
        width: width,
        scale: scale,
        dark: dark,
        review: true,
        sheet: ReplySheet(topicId: 1, preloadedDraftFuture: Future.value(null)),
      );
      expect(tester.takeException(), isNull);
      final header = find.byKey(const ValueKey('reply-composer-header'));
      expect(tester.getSize(header).height, kToolbarHeight);
      expect(find.byType(ComposerHeaderActions), findsOneWidget);
      expect(find.byType(CloseButton), findsOneWidget);
      final send = find.byKey(const ValueKey('composer-header-submit'));
      final more = find.byKey(const ValueKey('composer-header-more'));
      expect(tester.getSize(send).height, 44);
      if (width < 480) expect(tester.getSize(more), const Size(44, 44));
      expect(width - tester.getRect(send).right, 16);
      final lastAction = width < 480
          ? more
          : find.byKey(const ValueKey('composer-header-discard-inline'));
      expect(tester.getRect(send).left - tester.getRect(lastAction).right, 8);
      expect(
        find.byType(ComposerPreviewButton),
        width >= 480 ? findsOneWidget : findsNothing,
      );

      final field = find.descendant(
        of: find.byType(MarkdownEditor),
        matching: find.byType(TextField),
      );
      if (width < 480) {
        await tester.showKeyboard(field);
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.pump();
        tester.testTextInput.log.clear();
        await tester.tap(more);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          find.byKey(const ValueKey('composer-header-discard')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('composer-header-review')),
          findsOneWidget,
        );
        expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.hide',
          ),
          isEmpty,
        );
        await tester.tap(find.byKey(const ValueKey('composer-header-preview')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byKey(const ValueKey('reply-preview')), findsOneWidget);
      } else {
        expect(more, findsNothing);
        expect(
          find.byKey(const ValueKey('composer-header-review-inline')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('composer-header-discard-inline')),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  }

  testWidgets('实际回复弹框：预览往返保留编辑器、选区和撤销历史', (tester) async {
    await _pumpReply(tester);
    final source = tester.state<MarkdownEditorState>(
      find.byType(MarkdownEditor),
    );
    final textField = find.descendant(
      of: find.byType(MarkdownEditor),
      matching: find.byType(TextField),
    );
    await tester.showKeyboard(textField);
    await tester.pump(const Duration(milliseconds: 600));
    tester.testTextInput.enterText('hello');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    tester.testTextInput.enterText('hello world');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final controller = tester.widget<TextField>(textField).controller!;
    controller.selection = const TextSelection.collapsed(offset: 5);
    await tester.pump();
    await tester.tap(find.byType(ComposerPreviewButton));
    await tester.pump();
    expect(find.byType(MarkdownEditor), findsNothing);
    expect(find.byKey(const ValueKey('reply-preview')), findsOneWidget);
    await tester.tap(find.byType(ComposerPreviewButton));
    await tester.pump();
    expect(
      tester.state<MarkdownEditorState>(find.byType(MarkdownEditor)),
      same(source),
    );
    expect(controller.text, 'hello world');
    expect(controller.selection.extentOffset, 5);
    await tester.tap(find.byType(ContentActionsButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.current.toolbar_undo));
    await tester.pumpAndSettle();
    expect(controller.text, 'hello');
    await tester.tap(find.byType(ContentActionsButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.current.toolbar_redo));
    await tester.pumpAndSettle();
    expect(controller.text, 'hello world');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
  testWidgets('富文本实际回复：预览使用最新内容并保留内核历史', (tester) async {
    await _pumpReply(tester, rich: true);
    final host = tester.state<RichComposerEditorState>(
      find.byType(RichComposerEditor),
    );
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    editor.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: editor.blocks.first.id, offset: 0),
      ),
    );
    editor.insertText('first');
    editor.sealHistory();
    editor.insertText(' second');
    editor.sealHistory();
    await tester.pump();
    await tester.tap(find.byType(ComposerPreviewButton));
    await tester.pump();
    expect(find.byType(RichComposerEditor), findsNothing);
    expect(find.byKey(const ValueKey('reply-preview')), findsOneWidget);
    await tester.tap(find.byType(ComposerPreviewButton));
    await tester.pump();
    expect(
      tester.state<RichComposerEditorState>(find.byType(RichComposerEditor)),
      same(host),
    );
    expect(
      tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state,
      same(editor),
    );
    expect(docToMarkdown(editor.blocks), contains('first second'));
    await tester.tap(find.byType(ContentActionsButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text(S.current.toolbar_undo));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(docToMarkdown(editor.blocks).trim(), 'first');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
  testWidgets('快捷面板搜索并执行格式，保持原正文选区', (tester) async {
    await _pumpReply(tester);
    final field = find.descendant(
      of: find.byType(MarkdownEditor),
      matching: find.byType(TextField),
    );
    final controller = tester.widget<TextField>(field).controller!;
    await tester.showKeyboard(field);
    tester.testTextInput.enterText('hello');
    await tester.pump();
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text(S.current.composer_quickPanel), findsOneWidget);
    final search = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == S.current.composer_searchTools,
    );
    await tester.enterText(search, S.current.toolPanel_bold);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, S.current.toolPanel_bold));
    await tester.pumpAndSettle();
    expect(controller.text, '**hello**');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
