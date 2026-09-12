import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_workbench.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_chrome.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_island.dart';
import 'package:fluxdo/widgets/markdown_editor/content_actions_button.dart';
import 'package:fluxdo/widgets/markdown_editor/cursor_swipe_control.dart';
import 'package:common_ui/common_ui.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/services/discourse_cook_service.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_editor.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/rich_composer_editor.dart';
import 'package:fluxdo/widgets/topic/topic_editor_helpers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo_render/editor.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 390,
  double scale = 1,
  bool dark = false,
  bool desktop = false,
}) async {
  PlatformUtils.debugDesktopOverride = desktop;
  tester.view.physicalSize = Size(width, 760);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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
            platform: desktop ? TargetPlatform.macOS : TargetPlatform.android,
            brightness: dark ? Brightness.dark : Brightness.light,
            colorSchemeSeed: const Color(0xff315fe7),
          ),
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 760),
              textScaler: TextScaler.linear(scale),
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
  );
  await tester.pump();
}

void main() {
  setUp(() => PlatformUtils.debugDesktopOverride = false);
  tearDown(() => PlatformUtils.debugDesktopOverride = null);

  for (final rich in [false, true]) {
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
        tester.element(find.byType(ComposerWorkbench)),
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
      await _pump(
        tester,
        rich
            ? RichComposerEditor(controller: controller)
            : MarkdownEditor(controller: controller),
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
    testWidgets('继续输入恢复隐藏工具栏 rich=$rich', (tester) async {
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

  testWidgets('普通态隐藏格式行，输入后原位置出现', (tester) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    await _pump(
      tester,
      MarkdownEditor(
        controller: controller,
        focusNode: focus,
        showPreviewButton: false,
      ),
    );
    expect(find.byKey(const ValueKey('composer-format-row')), findsNothing);
    focus.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('composer-format-row')), findsOneWidget);
    focus.unfocus();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    focus.dispose();
  });

  testWidgets('富文本扩展动作直接列出插入块，不再叠加菜单', (tester) async {
    final controller = TextEditingController();
    await _pump(
      tester,
      RichComposerEditor(controller: controller, onSwitchToSource: () {}),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    final before = docToMarkdown(editor.blocks);
    await tester.runAsync(() => DiscourseCookService().ensureInitialized());
    await tester.tap(find.byTooltip(S.current.composer_expandToolbar));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
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
    await tester.pumpAndSettle();
    await tester.tap(table);
    await tester.pump();
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

  testWidgets('分类选择复用面板区域，并保持正文选区', (tester) async {
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
    await tester.tap(find.text('日常'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(selected?.id, 2);
    expect(controller.selection.extentOffset, 3);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    focus.dispose();
  });
  for (final width in [390.0, 1000.0]) {
    for (final rich in [false, true]) {
      testWidgets(
        '真实 PC ${width.toInt()} 宽 ${rich ? "富文本" : "源码"}：属性不在工具岛，移动端控件不出现',
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
          expect(find.byType(ContentActionsButton), findsNothing);
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
          expect(find.byType(GlassSurface), findsOneWidget);
          expect(tester.takeException(), isNull);

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 1));
          controller.dispose();
        },
      );
    }
  }

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
