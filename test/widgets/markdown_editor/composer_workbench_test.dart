import 'dart:convert';

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
import 'package:fluxdo/widgets/markdown_editor/emoji_sticker_panel.dart';
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
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
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
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
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
        final items = find.byType(PopupMenuItem<int>);
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
      var previousHeight = initial.height;
      for (final height in [20.0, 40.0, 60.0, 100.0, 160.0, 240.0, 300.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: height);
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getSize(space).height, height);
        expect(
          tester.getRect(surface).bottom,
          closeTo(760 - height - kComposerIslandBottomGap, .1),
        );
        expect(
          tester.getSize(surface).height,
          greaterThanOrEqualTo(previousHeight - .1),
        );
        previousHeight = tester.getSize(surface).height;
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
        expect(
          tester.getSize(surface).height,
          lessThanOrEqualTo(previousHeight + .1),
        );
        previousHeight = tester.getSize(surface).height;
      }
      expect(tester.getRect(surface), initial);
      expect(find.byKey(const ValueKey('composer-format-row')), findsNothing);
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.getRect(surface), initial);
      expect(focus.hasFocus, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    });

    testWidgets('表情与键盘往返保留工具栏，关闭输入区后隐藏 rich=$rich', (tester) async {
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
      expect(formats, findsNothing, reason: '焦点本身不显示格式行');
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
      expect(formats, findsNothing, reason: '键盘真正关闭后不残留过渡状态');

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
      expect(formats, findsNothing, reason: '直接关闭表情面板也要收起格式行');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    });

    testWidgets('工具接替键盘后保留展开，结束输入才隐藏工具行 rich=$rich', (tester) async {
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
      Future<void> openTools() => rich
          ? richKey.currentState!.showTools()
          : sourceKey.currentState!.showTools();
      final island = find.byKey(const ValueKey('composer-workbench'));
      final grid = find.byKey(const ValueKey('composer-tools-panel'));
      final handle = find.byKey(const ValueKey('composer-tools-handle'));
      final formats = find.byKey(const ValueKey('composer-format-row'));
      final closedHeight = tester.getSize(island).height;
      expect(handle, findsNothing);
      await openTools();
      await tester.pump();
      expect(grid, findsNothing);
      focus.requestFocus();
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 26);
      ChatBottomContainerListenerManager().flutterApi.keyboardHeight(260);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final midwayHeight = tester.getSize(island).height;
      expect(midwayHeight, greaterThan(closedHeight));
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 140));
      expect(tester.getSize(island).height, greaterThan(midwayHeight));
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
      expect(grid, findsOneWidget, reason: '工具态不再依赖键盘可见');
      if (rich) {
        richKey.currentState!.closeEmojiPanel();
      } else {
        sourceKey.currentState!.closeEmojiPanel();
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      expect(grid, findsNothing);
      await tester.pump(const Duration(milliseconds: 70));
      expect(tester.getSize(island).height, greaterThanOrEqualTo(closedHeight));
      await tester.pump(const Duration(milliseconds: 100));
      expect(formats, findsNothing);
      expect(handle, findsNothing);
      await tester.dragFrom(
        tester.getCenter(find.byKey(const ValueKey('composer-context-row'))),
        const Offset(0, -90),
      );
      await openTools();
      await tester.pump();
      expect(grid, findsNothing);
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      ChatBottomContainerListenerManager().flutterApi.keyboardHeight(260);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(formats, findsOneWidget);
      expect(grid, findsNothing, reason: '再次弹出键盘从折叠态开始');
      tester.view.viewInsets = const FakeViewPadding();
      ChatBottomContainerListenerManager().flutterApi.keyboardHeight(0);
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      ChatBottomContainerListenerManager().flutterApi.keyboardHeight(260);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(formats, findsOneWidget, reason: '快速重新打开输入区应打断隐藏动画');
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

  testWidgets('格式行只跟随键盘，不跟随光标或焦点', (tester) async {
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
    expect(
      find.byKey(const ValueKey('composer-format-row')),
      findsNothing,
      reason: '有光标而键盘关闭时，不显示格式行',
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('composer-format-row')), findsOneWidget);
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 170));
    expect(focus.hasFocus, isTrue);
    expect(find.byKey(const ValueKey('composer-format-row')), findsNothing);
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
