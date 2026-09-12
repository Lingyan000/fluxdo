import 'dart:convert';
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
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_view_mode_switcher.dart';
import 'package:fluxdo/widgets/markdown_editor/content_actions_button.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_editor.dart';
import 'package:fluxdo/widgets/post/reply_sheet.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/rich_composer_editor.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpReply(WidgetTester tester, {bool rich = false}) async {
  PlatformUtils.debugDesktopOverride = false;
  addTearDown(() => PlatformUtils.debugDesktopOverride = null);
  SharedPreferences.setMockInitialValues({'pref_use_rich_composer': rich});
  final prefs = await SharedPreferences.getInstance();
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
          home: const Scaffold(body: ReplySheet()),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
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
