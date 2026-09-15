import 'package:common_ui/common_ui.dart';
import 'dart:convert';
import 'dart:async' show unawaited;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/emoji.dart';
import 'package:fluxdo/providers/emoji_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/services/discourse_cook_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/services/navigation/keyboard_focus_guard.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/rich_composer_editor.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_object_toolbar.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_block_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/widgets/content/discourse_html_content/lazy_image.dart';
import 'package:fluxdo/widgets/content/discourse_html_content/image_utils.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart'
    show ImageRun, ImageGridNode, ImageGridMode, CodeBlockNode;

class _Binding extends AutomatedTestWidgetsFlutterBinding
    with DesktopScrollInteractionBinding {}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 390,
  double height = 760,
  double scale = 1,
  bool dark = false,
  bool desktop = false,
  bool disableAnimations = false,
  bool focusGuard = false,
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
          scrollBehavior: const DesktopScrollInteractionBehavior(),
          locale: const Locale('zh'),
          navigatorKey: navigatorKey,
          navigatorObservers: [if (focusGuard) KeyboardFocusGuard()],
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

Future<({EditorState state, String imageId})> _insertImage(
  WidgetTester tester,
) async {
  await tester.pump(const Duration(milliseconds: 800));
  final state = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
  state.pastePlainText('图片上方的正文');
  state.splitBlock();
  final id = state.selection!.extent.blockId;
  state.insertAtom(
    const ImageRun(
      src: 'https://example.com/test.png',
      alt: 'example.png',
      width: 320,
      height: 900,
    ),
  );
  state.splitBlock();
  state.insertText('图片后继续输入');
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  state.updateSelection(
    EditorSelection(
      base: EditorPosition(blockId: id, offset: 0),
      extent: EditorPosition(blockId: id, offset: 1),
    ),
  );
  await tester.pump();
  await tester.pump();
  return (state: state, imageId: id);
}

void main() {
  _Binding();
  tearDown(() => PlatformUtils.debugDesktopOverride = null);

  testWidgets('手机斜杠菜单利用键盘上方视口而非光标旁的小空隙', (tester) async {
    final controller = TextEditingController();
    await _pump(
      tester,
      RichComposerEditor(controller: controller),
      width: 390,
      height: 844,
    );
    await tester.pump(const Duration(milliseconds: 800));
    tester.view.viewInsets = const FakeViewPadding(bottom: 340);
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
    editor.state.pastePlainText(List.filled(6, '正文').join('\n\n'));
    editor.state.splitBlock();
    editor.state.insertText('/');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    final results = tester.getRect(
      find.byKey(const ValueKey('composer-block-results')),
    );
    expect(results.height, greaterThan(250));
    expect(
      tester.getRect(find.byType(ComposerBlockPicker)).bottom,
      lessThanOrEqualTo(504),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  for (final size in [const Size(360, 520), const Size(640, 390)]) {
    testWidgets('小窗和横屏大字斜杠菜单完整落在键盘上方 size=$size', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final controller = TextEditingController();
      await _pump(
        tester,
        RichComposerEditor(controller: controller),
        width: size.width,
        height: size.height,
        scale: 1.6,
      );
      await tester.pump(const Duration(milliseconds: 800));
      tester.view.viewInsets = const FakeViewPadding(bottom: 160);
      final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
      editor.state.insertText('/');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      final bounds = tester.getRect(find.byType(ComposerBlockPicker));
      expect(bounds.top, greaterThanOrEqualTo(56));
      expect(bounds.bottom, lessThanOrEqualTo(size.height - 160));
      expect(tester.takeException(), isNull);
      final picker = tester
          .widget<ComposerBlockPicker>(find.byType(ComposerBlockPicker))
          .controller;
      picker.search.text = '图片';
      await tester.pump();
      expect(find.text('图片').hitTestable(), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }

  for (final keyboardInset in [0.0, 300.0]) {
    testWidgets('手机图片更多菜单打开和取消都保留输入连接 inset=$keyboardInset', (tester) async {
      final controller = TextEditingController();
      await _pump(
        tester,
        RichComposerEditor(controller: controller),
        focusGuard: true,
      );
      await _insertImage(tester);
      tester.view.viewInsets = FakeViewPadding(bottom: keyboardInset);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.testTextInput.hasAnyClients, isTrue);
      tester.testTextInput.log.clear();
      await tester.tap(find.byKey(const ValueKey('composer-object-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      expect(find.text('图片尺寸').hitTestable(), findsOneWidget);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(
        tester.testTextInput.log.where(
          (call) =>
              call.method == 'TextInput.clearClient' ||
              call.method == 'TextInput.hide',
        ),
        isEmpty,
      );
      Navigator.of(tester.element(find.text('图片尺寸'))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      expect(tester.testTextInput.hasAnyClients, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }

  for (final desktop in [false, true]) {
    for (final delay in [0, 240]) {
      testWidgets('斜杠删除后立即或稍后重输可再次打开 desktop=$desktop delay=$delay', (
        tester,
      ) async {
        final text = TextEditingController();
        await _pump(
          tester,
          RichComposerEditor(controller: text),
          desktop: desktop,
          width: desktop ? 1000 : 390,
        );
        await tester.pump(const Duration(milliseconds: 800));
        final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
        editor.state.insertText('/');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));
        expect(find.byType(ComposerBlockPicker), findsOneWidget);
        editor.state.backspace();
        await tester.pump();
        await tester.pump(Duration(milliseconds: delay));
        editor.state.insertText('/');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));
        expect(find.byType(ComposerBlockPicker), findsOneWidget);
        final picker = tester
            .widget<ComposerBlockPicker>(find.byType(ComposerBlockPicker))
            .controller;
        expect(picker.isClosing, isFalse);
        expect(editor.focusNode!.hasPrimaryFocus, isTrue);
        editor.state.insertText('h2');
        await tester.pump();
        expect(picker.results.map((item) => item.id), ['h2']);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump();
        expect((editor.state.blocks.first as TextBlock).headingLevel, 2);
        expect((editor.state.blocks.first as TextBlock).content.text, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        text.dispose();
      });
    }
  }

  for (final viaSlash in [false, true]) {
    testWidgets('键盘上下移动和首尾循环始终完整显示选中项 slash=$viaSlash', (tester) async {
      final text = TextEditingController();
      await _pump(
        tester,
        RichComposerEditor(controller: text),
        desktop: true,
        width: 1000,
      );
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump();
      final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
      if (viaSlash) {
        editor.state.insertText('/');
      } else {
        await tester.tap(find.byKey(const ValueKey('composer-block-add')));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      final picker = tester
          .widget<ComposerBlockPicker>(find.byType(ComposerBlockPicker))
          .controller;
      Future<void> moveAndCheck(LogicalKeyboardKey key) async {
        await tester.sendKeyEvent(key);
        await tester.pump();
        await tester.pump();
        final viewport = tester.getRect(
          find.byKey(const ValueKey('composer-block-results')),
        );
        final id = picker.results[picker.activeIndex].id;
        final row = tester.getRect(
          find.byKey(ValueKey('composer-block-choice-$id')),
        );
        expect(
          row.top,
          greaterThanOrEqualTo(viewport.top - .1),
          reason: '$key -> $id 顶部可见',
        );
        expect(
          row.bottom,
          lessThanOrEqualTo(viewport.bottom + .1),
          reason: '$key -> $id 底部可见',
        );
      }

      await moveAndCheck(LogicalKeyboardKey.arrowUp);
      for (var i = 0; i < picker.results.length - 1; i++) {
        await moveAndCheck(LogicalKeyboardKey.arrowUp);
      }
      await moveAndCheck(LogicalKeyboardKey.arrowUp);
      await moveAndCheck(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(const SizedBox.shrink());
      text.dispose();
    });
  }

  for (final scale in [1.0, 1.7]) {
    testWidgets('搜索栏图标、提示文字、输入文字和关闭按钮垂直对齐 scale=$scale', (tester) async {
      final text = TextEditingController();
      await _pump(
        tester,
        RichComposerEditor(controller: text),
        desktop: true,
        width: 1000,
        scale: scale,
      );
      await tester.pump(const Duration(milliseconds: 800));
      final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
      editor.state.insertText('/');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      final icon = tester.getCenter(
        find.byKey(const ValueKey('composer-block-search-icon')),
      );
      final close = tester.getCenter(
        find.byKey(const ValueKey('composer-block-search-close')),
      );
      expect(icon.dy, closeTo(close.dy, .5));
      expect(tester.getCenter(find.text('搜索块类型…')).dy, closeTo(icon.dy, .5));
      final search = find.byKey(const ValueKey('composer-block-search'));
      expect(
        tester.getRect(find.text('搜索块类型…')).left,
        closeTo(tester.getRect(find.text('正文')).left, .5),
      );
      await tester.enterText(search, 'h2');
      await tester.pump();
      final editable = tester
          .state<EditableTextState>(
            find.descendant(of: search, matching: find.byType(EditableText)),
          )
          .renderEditable;
      expect(
        editable.localToGlobal(Offset(0, editable.size.height / 2)).dy,
        closeTo(
          tester
              .getCenter(
                find.byKey(const ValueKey('composer-block-search-icon')),
              )
              .dy,
          .5,
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(const SizedBox.shrink());
      text.dispose();
    });
  }

  testWidgets('/ 与加块按钮共用候选、搜索和键盘选择，斜杠输入不转移焦点', (tester) async {
    final text = TextEditingController();
    await _pump(
      tester,
      RichComposerEditor(controller: text),
      desktop: true,
      width: 1000,
    );
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
    final popup = find.byType(ComposerBlockPicker);
    final search = find.byKey(const ValueKey('composer-block-search'));
    await tester.tap(find.byKey(const ValueKey('composer-block-add')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    expect(popup, findsOneWidget);
    final buttonPicker = tester.widget<ComposerBlockPicker>(popup).controller;
    final allIds = buttonPicker.choices.map((choice) => choice.id).toList();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.moveTo(
      tester.getCenter(
        find.byKey(const ValueKey('composer-block-choice-paragraph')),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.pump();
    expect(buttonPicker.results[buttonPicker.activeIndex].id, allIds.last);
    expect(
      find
          .byKey(ValueKey('composer-block-choice-${allIds.last}'))
          .hitTestable(),
      findsOneWidget,
    );
    await mouse.removePointer();
    await tester.enterText(search, '标题');
    await tester.pump();
    final titleIds = buttonPicker.results.map((choice) => choice.id).toList();
    expect(titleIds, ['h1', 'h2', 'h3', 'h4']);
    expect((editor.state.blocks.first as TextBlock).content.text, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(popup, findsNothing);

    editor.state.insertText('/');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    expect(popup, findsOneWidget);
    final slashPicker = tester.widget<ComposerBlockPicker>(popup).controller;
    expect(slashPicker.choices.map((choice) => choice.id), allIds);
    expect(editor.focusNode!.hasPrimaryFocus, isTrue);
    editor.state.insertText('标题');
    await tester.pump();
    expect(slashPicker.results.map((choice) => choice.id), titleIds);
    expect(tester.widget<TextField>(search).controller!.text, '标题');
    expect(editor.focusNode!.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(slashPicker.results[slashPicker.activeIndex].id, 'h3');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    final block = editor.state.blocks.first as TextBlock;
    expect(block.headingLevel, 3);
    expect(block.content.text, isEmpty, reason: '提交命令只移除斜杠查询');
    expect(popup, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    text.dispose();
  });

  testWidgets('统一选择器：按钮搜索可按回车提交，点正文一次退出并保留新光标', (tester) async {
    final text = TextEditingController();
    await _pump(
      tester,
      RichComposerEditor(controller: text),
      desktop: true,
      width: 1000,
    );
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
    await tester.tap(find.byKey(const ValueKey('composer-block-add')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    await tester.enterText(
      find.byKey(const ValueKey('composer-block-search')),
      'h2',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect((editor.state.blocks.first as TextBlock).headingLevel, 2);
    editor.state.insertText('另一段的正文');
    editor.state.splitBlock();
    await tester.pump();
    await tester.pump();
    final first = editor.state.blocks.first;
    await tester.tap(find.byKey(const ValueKey('composer-block-add')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    final bounds = editor.contentActions!.objectBounds(
      EditorBlockTarget(first.id),
    )!;
    await tester.tapAt(
      bounds.topLeft + const Offset(40, 18),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.byType(ComposerBlockPicker), findsNothing);
    expect(editor.state.selection!.extent.blockId, first.id);
    expect(editor.state.selection!.isCollapsed, isTrue);
    expect(editor.focusNode!.hasPrimaryFocus, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    text.dispose();
  });

  testWidgets('统一选择器：手机返回关闭面板，中文组词不会被回车提前提交', (tester) async {
    final text = TextEditingController();
    await _pump(tester, RichComposerEditor(controller: text));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('composer-block-control-surface')),
      findsNothing,
    );
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
    expect(tester.getRect(find.byType(FluxdoEditor)).left, 20);
    editor.state.insertText('/');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    final picker = tester
        .widget<ComposerBlockPicker>(find.byType(ComposerBlockPicker))
        .controller;
    picker.search.value = const TextEditingValue(
      text: 'biao',
      selection: TextSelection.collapsed(offset: 4),
      composing: TextRange(start: 0, end: 4),
    );
    expect(picker.handleLogicalKey(LogicalKeyboardKey.enter), isFalse);
    expect(picker.isClosing, isFalse);
    picker.search.value = const TextEditingValue(
      text: '标题',
      selection: TextSelection.collapsed(offset: 2),
    );
    await tester.pump();
    await navigatorKey.currentState!.maybePop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.byType(ComposerBlockPicker), findsNothing);
    expect(find.byType(RichComposerEditor), findsOneWidget);
    expect(
      tester
          .widget<FluxdoEditor>(find.byType(FluxdoEditor))
          .state
          .blocks
          .length,
      1,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    text.dispose();
  });

  testWidgets('统一选择器：无结果保留查询，Escape 不吞正文，提交保留查询后文字', (tester) async {
    final text = TextEditingController();
    await _pump(
      tester,
      RichComposerEditor(controller: text),
      desktop: true,
      width: 1000,
    );
    await tester.pump(const Duration(milliseconds: 800));
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
    editor.state.insertText('/no_such_block_123');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    expect(
      find.byKey(const ValueKey('composer-block-empty-results')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(
      (editor.state.blocks.first as TextBlock).content.text,
      '/no_such_block_123',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.byType(ComposerBlockPicker), findsNothing);
    expect(
      (editor.state.blocks.first as TextBlock).content.text,
      '/no_such_block_123',
    );
    editor.state.selectAll();
    editor.state.deleteSelection();
    editor.state.insertText('/h2 保留后面的正文');
    editor.state.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: editor.state.blocks.first.id, offset: 3),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    final block = editor.state.blocks.first as TextBlock;
    expect(block.headingLevel, 2);
    expect(block.content.text, ' 保留后面的正文');
    await tester.pumpWidget(const SizedBox.shrink());
    text.dispose();
  });

  testWidgets('手机长图：对象操作复用格式行，不出现常驻替代文本框或改变栏高', (tester) async {
    final controller = TextEditingController();
    await _pump(tester, RichComposerEditor(controller: controller));
    await tester.pump(const Duration(milliseconds: 800));
    final row = find.byKey(const ValueKey('composer-format-row'));
    final before = tester.getRect(row);
    final h = await _insertImage(tester);
    final object = find.byKey(const ValueKey('composer-object-toolbar'));
    expect(object, findsOneWidget);
    expect(tester.getRect(row), before);
    expect(tester.getRect(object).bottom, lessThanOrEqualTo(before.bottom));
    expect(find.text('example.png'), findsNothing);
    expect(
      find.byKey(const ValueKey('composer-image-alt-input')),
      findsNothing,
    );
    await tester.tap(find.byTooltip('在后面输入'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(h.state.selection!.isCollapsed, isTrue);
    expect(
      h.state.textBlockById(h.state.selection!.extent.blockId)!.content.text,
      '图片后继续输入',
    );
    expect(object, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('图片属性按需编辑，保存后仍选中原图片并可撤销', (tester) async {
    final controller = TextEditingController();
    await _pump(tester, RichComposerEditor(controller: controller));
    final h = await _insertImage(tester);
    await tester.tap(find.byKey(const ValueKey('composer-object-more')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('替代文本'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    final input = find.byKey(const ValueKey('composer-image-alt-input'));
    expect(input, findsOneWidget);
    await tester.enterText(input, '这是一张说明图片');
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      (h.state.textBlockById(h.imageId)!.content.atoms[0] as ImageRun).alt,
      '这是一张说明图片',
    );
    expect(h.state.selection!.isCollapsed, isFalse);
    h.state.undo();
    expect(
      (h.state.textBlockById(h.imageId)!.content.atoms[0] as ImageRun).alt,
      'example.png',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('图片控件是一整个点击区，玻璃开关切换不重建按钮或丢失选中', (tester) async {
    final controller = TextEditingController();
    final settings = ValueNotifier(
      const GlassSettings(level: GlassEffectLevel.basic),
    );
    await _pump(
      tester,
      ValueListenableBuilder<GlassSettings>(
        valueListenable: settings,
        child: RichComposerEditor(controller: controller),
        builder: (_, value, child) =>
            GlassSettingsScope(settings: value, child: child!),
      ),
      desktop: true,
      width: 1200,
    );
    final h = await _insertImage(tester);
    await tester.pump();
    final surface = find.byKey(
      const ValueKey('composer-block-control-surface'),
    );
    final handle = find.byKey(const ValueKey('composer-block-hover-select'));
    expect(
      find.descendant(of: surface, matching: find.byType(TextButton)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: surface, matching: find.byType(IconButton)),
      findsNothing,
    );
    expect(
      find.descendant(of: surface, matching: find.byType(BackdropFilter)),
      findsWidgets,
    );
    final element = tester.element(handle);
    final bounds = tester.getRect(handle);
    final selected = h.state.selection;
    settings.value = const GlassSettings(enabled: false);
    await tester.pump();
    expect(
      find.descendant(of: surface, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
    expect(tester.element(handle), same(element));
    expect(tester.getRect(handle), bounds);
    expect(h.state.selection, selected);
    for (final x in [.25, .75]) {
      final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
      editor.contentActions!.selectObject(
        EditorImageTarget(h.imageId, 0, 'https://example.com/test.png'),
      );
      await tester.pump();
      await tester.pump();
      final rect = tester.getRect(handle);
      await tester.tapAt(
        Offset(rect.left + rect.width * x, rect.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      final panel = tester.getRect(
        find.byKey(const ValueKey('composer-anchored-panel')),
      );
      expect(panel.width, closeTo(rect.width, 1), reason: '从整个控件展开，而不是左右半边');
      expect(find.text('删除图片'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 260));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    settings.dispose();
  });

  testWidgets('窄窗 630：正文左右留白相等，单控件仍可切换类型', (tester) async {
    final controller = TextEditingController();
    await _pump(
      tester,
      RichComposerEditor(controller: controller),
      desktop: true,
      width: 630,
    );
    await tester.pump(const Duration(milliseconds: 800));
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
    editor.state.insertText('窄窗中继续编辑');
    await tester.pump();
    await tester.pump();
    final document = tester.getRect(find.byType(FluxdoEditor));
    expect(document.left, closeTo(630 - document.right, .1));
    expect(document.left, lessThanOrEqualTo(48));
    final handle = find.byKey(const ValueKey('composer-block-hover-select'));
    expect(tester.getSize(handle).width, 32);
    await tester.tap(handle, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    await tester.tap(find.text('切换块类型'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    await tester.tap(find.byKey(const ValueKey('composer-block-choice-h2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect((editor.state.blocks.first as TextBlock).headingLevel, 2);
    expect((editor.state.blocks.first as TextBlock).content.text, '窄窗中继续编辑');
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  for (final width in [390.0, 1200.0]) {
    testWidgets('PC $width：固定块控件不跟随鼠标，正文和格式栏保持原位', (tester) async {
      final controller = TextEditingController();
      await _pump(
        tester,
        RichComposerEditor(controller: controller),
        desktop: true,
        width: width,
      );
      final editorBefore = tester.getRect(find.byType(FluxdoEditor));
      final format = find.byKey(
        ValueKey(
          width >= 1040 ? 'composer-desktop-rail' : 'composer-format-row',
        ),
      );
      final formatBefore = tester.getRect(format);
      final h = await _insertImage(tester);
      expect(
        find.byKey(const ValueKey('composer-object-toolbar')),
        findsNothing,
      );
      expect(tester.getRect(format), formatBefore);
      final editorRect = tester.getRect(find.byType(FluxdoEditor));
      expect(editorRect.left, editorBefore.left);
      expect(editorRect.width, editorBefore.width);
      final image = tester
          .getRect(find.byType(LazyImage).first)
          .intersect(Rect.fromLTRB(0, 100, width, 600));
      final point = image.topLeft + Offset(image.width / 3, image.height / 2);
      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.pump();
      await tester.pump();
      final handle = find.byKey(const ValueKey('composer-block-hover-select'));
      final handleRect = tester.getRect(handle);
      expect(handleRect.right, lessThanOrEqualTo(editorRect.left));
      expect(handleRect.overlaps(tester.getRect(format)), isFalse);
      expect(tester.getRect(format), formatBefore);
      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.moveTo(point);
      await tester.pump();
      final anchored = tester.getRect(handle);
      await pointer.moveTo(point + const Offset(0, 80));
      await tester.pump();
      expect(tester.getRect(handle), anchored, reason: '同一长图内不能跟着鼠标所在行移动');
      expect(
        find.byKey(const ValueKey('composer-block-hover-outline')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('composer-object-quick-actions')),
        findsNothing,
      );
      await pointer.removePointer();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      expect(h.state.selection, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }

  for (final width in [390.0, 1200.0]) {
    testWidgets('PC hover $width：不改文字选区，穿过左侧间隙仍能一击选择段落', (tester) async {
      final controller = TextEditingController();
      await _pump(
        tester,
        RichComposerEditor(controller: controller),
        desktop: true,
        width: width,
      );
      await tester.pump(const Duration(milliseconds: 800));
      final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
      editor.state.pasteBlocks([
        TextBlock(
          id: 'first',
          content: EditableTextContent(text: '第一段可以继续编辑'),
        ),
        TextBlock(
          id: 'second',
          content: EditableTextContent(text: '第二段独立选择'),
        ),
      ]);
      await tester.pump();
      await tester.pump();
      final first = editor.state.blocks.whereType<TextBlock>().firstWhere(
        (b) => b.content.text.contains('第一段'),
      );
      final bounds = editor.contentActions!.objectBounds(
        EditorBlockTarget(first.id),
      )!;
      final selection = editor.state.selection;
      final revision = editor.state.docRevision;
      final layout = tester.getRect(find.byType(FluxdoEditor));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(5, 70));
      await mouse.moveTo(bounds.topLeft + Offset(60, bounds.height / 2));
      await tester.pump();
      final handle = find.byKey(const ValueKey('composer-block-hover-select'));
      expect(handle, findsOneWidget);
      expect(find.byTooltip('段落操作'), findsOneWidget);
      expect(editor.state.selection, selection);
      expect(editor.state.docRevision, revision);
      expect(tester.getRect(find.byType(FluxdoEditor)), layout);
      final handleRect = tester.getRect(handle);
      expect(handleRect.right, lessThanOrEqualTo(bounds.left));
      expect(handleRect.left, greaterThanOrEqualTo(0));
      await mouse.moveTo(Offset(bounds.left - 2, handleRect.center.dy));
      await tester.pump();
      expect(tester.getRect(handle), handleRect);
      await mouse.moveTo(handleRect.center);
      await tester.pump();
      expect(handle, findsOneWidget);
      await mouse.down(handleRect.center);
      await mouse.up();
      await tester.pump();
      await tester.pump();
      expect(editor.state.selection!.base.blockId, first.id);
      expect(editor.state.selection!.extent.blockId, first.id);
      expect(editor.state.selection!.isCollapsed, isFalse);
      expect(handle, findsOneWidget);
      expect(
        find.byKey(const ValueKey('composer-object-quick-actions')),
        findsNothing,
        reason: '块菜单不叠加浮动操作条',
      );
      expect(tester.getRect(find.byType(FluxdoEditor)), layout);
      expect(find.text('删除段落'), findsOneWidget);
      expect(handle, findsOneWidget, reason: '菜单展开时保留原按钮');
      await tester.pump(const Duration(milliseconds: 240));
      final menu = tester.getRect(
        find.byKey(const ValueKey('composer-anchored-panel')),
      );
      expect(menu.left, closeTo(handleRect.left, 1));
      expect(menu.top - handleRect.bottom, inInclusiveRange(0, 8));
      await tester.tapAt(Offset(width - 8, 720), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(editor.state.selection, isNull);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }

  testWidgets('PC hover：滚动收起旧入口，再悬停按当前位置选择块', (tester) async {
    final controller = TextEditingController();
    await _pump(
      tester,
      RichComposerEditor(controller: controller),
      desktop: true,
      width: 1200,
    );
    await tester.pump(const Duration(milliseconds: 800));
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
    editor.state.pasteBlocks([
      for (var i = 0; i < 30; i++)
        TextBlock(
          id: 'scroll-$i',
          content: EditableTextContent(text: '第 $i 段滚动后仍可准确选中'),
        ),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final scroll = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(CustomScrollView).first,
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    scroll.jumpTo(0);
    await tester.pump();
    await tester.pump();
    final first = editor.contentActions!.objectBounds(
      EditorBlockTarget(editor.state.blocks.first.id),
    )!;
    final point = first.topLeft + Offset(60, first.height / 2);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(5, 70));
    await mouse.moveTo(point);
    await tester.pump();
    final handle = find.byKey(const ValueKey('composer-block-hover-select'));
    expect(handle, findsOneWidget);
    final selection = editor.state.selection;
    final revision = editor.state.docRevision;

    scroll.jumpTo(120);
    await tester.pump();
    await tester.pump();
    expect(handle, findsNothing, reason: '滚动后不能保留指向旧块的入口');
    expect(editor.state.selection, selection);
    expect(editor.state.docRevision, revision);

    final movedPoint = point + const Offset(1, 0);
    final target = editor.contentActions!.blockAt(movedPoint)!.target;
    expect(target.blockId, isNot(editor.state.blocks.first.id));
    await mouse.moveTo(movedPoint);
    await tester.pump();
    expect(handle, findsOneWidget);
    await mouse.moveTo(tester.getCenter(handle));
    await mouse.down(tester.getCenter(handle));
    await mouse.up();
    await tester.pump();
    await tester.pump();
    expect(editor.state.selection!.base.blockId, target.blockId);
    expect(editor.state.selection!.extent.blockId, target.blockId);
    expect(editor.state.selection!.isCollapsed, isFalse);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('PC hover：详情标题选外框，正文选内层段落，点击文字仍能编辑', (tester) async {
    final controller = TextEditingController();
    await _pump(
      tester,
      RichComposerEditor(controller: controller),
      desktop: true,
      width: 1200,
    );
    await tester.pump(const Duration(milliseconds: 800));
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
    const frame = DetailsFrame(groupId: 'hover-details', summary: 'hover详情标题');
    editor.state.pasteBlocks([
      TextBlock(
        id: 'a',
        content: EditableTextContent(text: '可加粗的第一段'),
        containers: const [frame],
      ),
      TextBlock(
        id: 'b',
        content: EditableTextContent(text: '可斜体的第二段'),
        containers: const [frame],
      ),
    ]);
    await tester.pump();
    await tester.pump();
    final blocks = editor.state.blocks
        .whereType<TextBlock>()
        .where((b) => b.containers.isNotEmpty)
        .toList();
    final title = tester.getRect(find.text('hover详情标题'));
    final inner = editor.contentActions!.objectBounds(
      EditorBlockTarget(blocks.first.id),
    )!;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(5, 70));
    await mouse.moveTo(inner.topLeft + Offset(60, inner.height / 2));
    await tester.pump();
    expect(find.byTooltip('段落操作'), findsOneWidget);
    final childHandle = tester.getRect(
      find.byKey(const ValueKey('composer-block-hover-select')),
    );
    await mouse.moveTo(Offset(inner.left - 2, childHandle.center.dy));
    await tester.pump();
    expect(find.byTooltip('段落操作'), findsOneWidget, reason: '移向子段落按钮时不能突然变成父容器');
    await mouse.moveTo(title.center);
    await tester.pump();
    expect(find.byTooltip('折叠详情操作'), findsOneWidget);
    final handle = tester.getCenter(
      find.byKey(const ValueKey('composer-block-hover-select')),
    );
    await mouse.moveTo(handle);
    await mouse.down(handle);
    await mouse.up();
    await tester.pump();
    await tester.pump();
    expect(editor.state.selection!.base.blockId, blocks.first.id);
    expect(editor.state.selection!.extent.blockId, blocks.last.id);
    await tester.pump(const Duration(milliseconds: 240));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final textPoint = inner.topLeft + Offset(60, inner.height / 2);
    await mouse.moveTo(textPoint);
    await mouse.down(textPoint);
    await tester.pump(const Duration(milliseconds: 20));
    expect(
      find.byKey(const ValueKey('composer-object-quick-actions')),
      findsNothing,
      reason: '点回文字时不应先闪出浮动工具条',
    );
    await mouse.up();
    await tester.pump();
    await tester.pump();
    expect(editor.state.selection!.isCollapsed, isTrue);
    expect(
      find.byKey(const ValueKey('composer-object-quick-actions')),
      findsNothing,
    );
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('PC 长图：控件仅在块顶部出屏后吸顶，菜单从按钮展开', (tester) async {
    final controller = TextEditingController();
    await _pump(
      tester,
      RichComposerEditor(controller: controller),
      desktop: true,
      width: 1200,
    );
    final h = await _insertImage(tester);
    final scroll = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(CustomScrollView).first,
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    scroll.jumpTo(0);
    await tester.pump();
    await tester.pump();
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
    final imageBounds = editor.contentActions!.objectBounds(
      EditorBlockTarget(h.imageId),
    )!;
    final handle = find.byKey(const ValueKey('composer-block-hover-select'));
    final before = tester.getRect(handle);
    expect(before.top, closeTo(imageBounds.top + 4, 1));
    scroll.jumpTo(160);
    await tester.pump();
    await tester.pump();
    final sticky = tester.getRect(handle);
    expect(sticky.left, before.left);
    expect(
      sticky.top,
      greaterThanOrEqualTo(
        tester.getRect(find.byType(CustomScrollView).first).top,
      ),
    );
    await tester.tap(handle, kind: PointerDeviceKind.mouse);
    await tester.pump();
    final panel = find.byKey(const ValueKey('composer-anchored-panel'));
    final start = tester.getRect(panel);
    expect(start.center.dx, closeTo(sticky.center.dx, 1));
    expect(start.center.dy, closeTo(sticky.center.dy, 1));
    await tester.pump(const Duration(milliseconds: 80));
    final middle = tester.getRect(panel);
    expect(middle.width, greaterThan(start.width));
    await tester.pump(const Duration(milliseconds: 200));
    final end = tester.getRect(panel);
    expect(end.width, greaterThan(middle.width));
    expect(end.left, closeTo(sticky.left, 1));
    expect(find.text('删除图片').hitTestable(), findsOneWidget);
    expect(handle, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(panel, findsNothing);
    expect(h.state.selection, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  for (final desktop in [false, true]) {
    testWidgets('末尾已有空段时点击续写区，光标必须进入下一行 desktop=$desktop', (tester) async {
      final controller = TextEditingController();
      await _pump(
        tester,
        RichComposerEditor(controller: controller),
        desktop: desktop,
        width: desktop ? 1000 : 390,
      );
      await tester.pump(const Duration(milliseconds: 800));
      final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
      final previous = editor.state.blocks.last.id;
      final tail = find.byKey(const ValueKey('editor-trailing-paragraph'));
      final count = editor.state.blocks.length;
      await tester.tap(
        tail,
        kind: desktop ? PointerDeviceKind.mouse : PointerDeviceKind.touch,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(editor.state.blocks.length, count + 1);
      expect(editor.state.selection!.extent.blockId, isNot(previous));
      final inserted = editor.state.blocks.last as TextBlock;
      expect(editor.state.selection!.extent.blockId, inserted.id);
      expect(inserted.content.length, 0);
      editor.state.insertText('在新的一行输入');
      expect(editor.state.textBlockById(previous)!.content.length, 0);
      expect(editor.state.textBlockById(inserted.id)!.content.text, '在新的一行输入');
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });

    testWidgets('空行加块与文末续写 desktop=$desktop', (tester) async {
      final controller = TextEditingController();
      await _pump(
        tester,
        RichComposerEditor(controller: controller),
        desktop: desktop,
        width: desktop ? 1200 : 390,
        dark: desktop,
        disableAnimations: !desktop,
      );
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump();
      final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
      final initialCount = editor.state.blocks.length;
      final add = find.byKey(const ValueKey('composer-block-add'));
      expect(add, desktop ? findsOneWidget : findsNothing);
      if (!desktop) {
        expect(tester.getRect(find.byType(FluxdoEditor)).left, 20);
        expect(
          find.byKey(const ValueKey('composer-block-control-surface')),
          findsNothing,
        );
      }
      expect(
        find.byKey(const ValueKey('editor-empty-paragraph-hint')),
        findsOneWidget,
      );
      if (desktop) {
        await tester.tap(add);
      } else {
        editor.state.insertText('/');
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      expect(
        find.byKey(const ValueKey('composer-block-picker')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('composer-block-choice-h2')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      expect((editor.state.blocks.first as TextBlock).headingLevel, 2);
      expect(editor.state.blocks.length, initialCount, reason: '空行转换不插入额外空段');
      editor.state.insertText('标题内容');
      await tester.pump();
      await tester.pump();
      final before = editor.state.exportMarkdown();
      expect(before, contains('标题内容'));
      final tail = find.byKey(const ValueKey('editor-trailing-paragraph'));
      expect(tail, findsOneWidget);
      expect(
        editor.state.blocks.length,
        initialCount,
        reason: '预留续写行不属于已保存的文档',
      );
      await tester.tap(tail);
      await tester.pump();
      await tester.pump();
      expect(editor.state.blocks.length, initialCount + 1);
      final last = editor.state.blocks.last as TextBlock;
      expect(last.isParagraph, isTrue);
      expect(last.containers, isEmpty);
      expect(editor.state.selection!.extent.blockId, last.id);
      await tester.tap(tail);
      await tester.pump();
      await tester.pump();
      expect(
        editor.state.blocks.length,
        initialCount + 2,
        reason: '再次点击下一行，应在所点位置新增一行',
      );
      editor.state.undo();
      await tester.pump();
      expect(editor.state.blocks.length, initialCount + 1);
      editor.state.undo();
      expect(editor.state.blocks.length, initialCount);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }

  testWidgets('代码块操作有明确入口，选中后支持块前后输入', (tester) async {
    final controller = TextEditingController();
    await _pump(tester, RichComposerEditor(controller: controller));
    await tester.pump(const Duration(milliseconds: 800));
    final state = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    state.pastePlainText('开头');
    state.insertIslandAfter(
      state.blocks.first.id,
      const CodeBlockNode(id: 'code', code: 'final x = 1;', language: 'dart'),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byTooltip('代码块操作'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('在前面输入'), findsOneWidget);
    await tester.tap(find.text('在前面输入'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.selection!.isCollapsed, isTrue);
    expect(state.selection!.extent.blockId, state.blocks.first.id);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  for (final desktop in [true, false]) {
    testWidgets('浏览图片组时切换模式和撤销保持位置，继续输入才追随光标 desktop=$desktop', (tester) async {
      final controller = TextEditingController();
      await _pump(
        tester,
        RichComposerEditor(controller: controller),
        desktop: desktop,
        width: desktop ? 1000 : 390,
      );
      await tester.pump(const Duration(milliseconds: 800));
      final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
      editor.state.pasteBlocks([
        IslandBlock(
          id: 'group',
          node: ImageGridNode(
            id: 'node',
            images: [
              for (var i = 0; i < 6; i++)
                ImageRun(src: 'image-$i', width: 120, height: 80),
            ],
          ),
        ),
        for (var i = 0; i < 45; i++)
          TextBlock(
            id: 'after-$i',
            content: EditableTextContent(text: '后续正文 $i'),
          ),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView).first)
          .controller!;
      final selection = editor.state.selection;
      expect(selection!.extent.blockId, editor.state.blocks.last.id);
      expect(scroll.offset, greaterThan(500));
      scroll.jumpTo(0);
      await tester.pump();
      final grid = find.byType(EditorImageGrid);
      for (final label in ['轮播', '网格', '轮播']) {
        await tester.tap(
          find.descendant(of: grid, matching: find.text(label)),
          kind: desktop ? PointerDeviceKind.mouse : PointerDeviceKind.touch,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(editor.state.selection, selection);
        expect(scroll.offset, closeTo(0, 1), reason: '切换$label不能追到文末旧光标');
      }
      editor.state.undo();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(scroll.offset, closeTo(0, 1));
      editor.focusNode!.requestFocus();
      editor.state.insertText('继续输入');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(scroll.offset, greaterThan(500), reason: '真正输入后仍要跟随光标');
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }

  for (final horizontal in [false, true]) {
    testWidgets('滚动中一次点击图片操作按钮，轻微移动也不拖图 horizontal=$horizontal', (
      tester,
    ) async {
      final controller = TextEditingController();
      await _pump(
        tester,
        RichComposerEditor(controller: controller),
        desktop: true,
        width: 600,
      );
      await tester.pump(const Duration(milliseconds: 800));
      final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
      editor.state.pasteBlocks([
        IslandBlock(
          id: 'group',
          node: ImageGridNode(
            id: 'node',
            mode: ImageGridMode.carousel,
            images: [
              for (var i = 0; i < 8; i++)
                ImageRun(src: 'image-$i', width: 120, height: 80),
            ],
          ),
        ),
        for (var i = 0; i < 40; i++)
          TextBlock(
            id: 'text-$i',
            content: EditableTextContent(text: '后续正文 $i'),
          ),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final outer = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView).first)
          .controller!;
      outer.jumpTo(0);
      await tester.pump();
      final group = editor.state.blocks.whereType<IslandBlock>().single;
      editor.contentActions!.selectObject(
        EditorGridImageTarget(group.id, 1, 'image-1'),
      );
      await tester.pump();
      await tester.pump();
      final scroll = horizontal
          ? tester
                .widget<SingleChildScrollView>(
                  find.byKey(ValueKey('grid-viewport-${group.id}')),
                )
                .controller!
          : outer;
      unawaited(
        scroll.animateTo(
          60,
          duration: const Duration(seconds: 1),
          curve: Curves.linear,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(scroll.position.shouldIgnorePointer, isTrue);
      final before = editor.state.blocks;
      final point = tester.getCenter(
        find.byKey(ValueKey('grid-image-more-${group.id}-1')),
      );
      final mouse = await tester.startGesture(
        point,
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(3, 2));
      await mouse.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      expect(find.text('后移一张').hitTestable(), findsOneWidget);
      expect(editor.state.blocks, before);
      expect(scroll.position.isScrollingNotifier.value, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }

  for (final desktop in [true, false]) {
    testWidgets('网格图片菜单关闭不把光标和页面送到文末 desktop=$desktop', (tester) async {
      final controller = TextEditingController();
      await _pump(
        tester,
        RichComposerEditor(controller: controller),
        desktop: desktop,
        width: desktop ? 1200 : 390,
      );
      await tester.pump(const Duration(milliseconds: 800));
      final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
      editor.state.pasteBlocks([
        const IslandBlock(
          id: 'group',
          node: ImageGridNode(
            id: 'node',
            images: [
              ImageRun(src: 'a', width: 120, height: 80),
              ImageRun(src: 'b', width: 120, height: 80),
            ],
          ),
        ),
        for (var i = 0; i < 45; i++)
          TextBlock(
            id: 'after-$i',
            content: EditableTextContent(text: '后续正文 $i'),
          ),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView).first)
          .controller!;
      scroll.jumpTo(0);
      await tester.pump();
      await tester.pump();
      final group = editor.state.blocks.whereType<IslandBlock>().single;
      for (final escape in [true, false]) {
        editor.contentActions!.selectObject(
          EditorGridImageTarget(group.id, 0, 'a'),
        );
        await tester.pump();
        await tester.pump();
        expect(editor.state.selection, isNull);
        final before = scroll.offset;
        final transitions = <EditorSelection?>[];
        void record() => transitions.add(editor.state.selection);
        editor.state.addListener(record);
        await tester.tap(
          find.byKey(ValueKey('grid-image-more-${group.id}-0')),
          kind: desktop ? PointerDeviceKind.mouse : PointerDeviceKind.touch,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 260));
        expect(find.text('后移一张').hitTestable(), findsOneWidget);
        if (escape) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        } else {
          await tester.tapAt(
            tester.getRect(find.byType(CustomScrollView).first).bottomRight -
                const Offset(12, 12),
          );
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        editor.state.removeListener(record);
        expect(find.text('后移一张').hitTestable(), findsNothing);
        expect(
          transitions.whereType<EditorSelection>(),
          isEmpty,
          reason: '菜单恢复焦点期间也不能短暂补一个文末光标',
        );
        expect(editor.state.selection, isNull);
        expect(scroll.offset, closeTo(before, 1));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }

  testWidgets('网格左键小菜单支持前后移动，添加图片锁定原网格而非光标', (tester) async {
    final controller = TextEditingController();
    final key = GlobalKey<RichComposerEditorState>();
    await _pump(
      tester,
      RichComposerEditor(key: key, controller: controller),
      desktop: true,
      width: 1200,
    );
    await tester.pump(const Duration(milliseconds: 800));
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
    editor.state.pasteBlocks([
      const IslandBlock(
        id: 'group',
        node: ImageGridNode(
          id: 'node',
          images: [
            ImageRun(src: 'a', width: 120, height: 80),
            ImageRun(src: 'b', width: 120, height: 80),
          ],
          mode: ImageGridMode.carousel,
        ),
      ),
      TextBlock(
        id: 'after',
        content: EditableTextContent(text: '不要改动此处正文'),
      ),
    ]);
    await tester.pump();
    await tester.pump();
    final group = editor.state.blocks.whereType<IslandBlock>().single;
    editor.contentActions!.selectObject(
      EditorGridImageTarget(group.id, 0, 'a'),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(
      find.byKey(ValueKey('grid-image-more-${group.id}-0')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(find.text('后移一张').hitTestable(), findsOneWidget);
    await tester.tap(find.text('后移一张'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump();
    ImageGridNode grid() =>
        (editor.state.blocks.firstWhere((b) => b.id == group.id) as IslandBlock)
                .node
            as ImageGridNode;
    expect(grid().images.map((image) => image.src), ['b', 'a']);
    final paragraph = editor.state.blocks.whereType<TextBlock>().last;
    editor.state.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: paragraph.id, offset: 2),
      ),
    );
    final selection = editor.state.selection;
    DiscourseImageUtils.seedUploadUrl(
      'upload://new',
      'https://example.com/new.png',
    );
    expect(
      key.currentState!.insertUploadedImage(
        targetGridId: group.id,
        shortUrl: 'upload://new',
        width: 100,
        height: 80,
      ),
      isTrue,
    );
    await tester.pump();
    expect(grid().images.map((image) => image.src), ['b', 'a', 'upload://new']);
    expect(grid().mode, ImageGridMode.carousel);
    expect(editor.state.selection, selection);
    expect(editor.state.textBlockById(paragraph.id)!.content.text, '不要改动此处正文');
    deleteEditorObject(editor.state, EditorBlockTarget(group.id));
    final before = editor.state.blocks;
    expect(
      key.currentState!.insertUploadedImage(
        targetGridId: group.id,
        shortUrl: 'upload://late',
      ),
      isFalse,
    );
    expect(editor.state.blocks, before, reason: '不能将迟到的上传结果插到其他段落');
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('网格单图操作清除旧文字选区，删除只影响目标图片且可撤销', (tester) async {
    final controller = TextEditingController();
    await _pump(tester, RichComposerEditor(controller: controller));
    await tester.pump(const Duration(milliseconds: 800));
    final state = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    state.pastePlainText('保留这段文字');
    state.insertIslandAfter(
      state.blocks.first.id,
      const ImageGridNode(
        id: 'grid',
        images: [
          ImageRun(src: 'https://example.com/a.png', width: 120, height: 80),
          ImageRun(src: 'https://example.com/b.png', width: 120, height: 80),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tapAt(tester.getRect(find.byType(LazyImage).first).center);
    await tester.pump();
    await tester.pump();
    expect(state.selection, isNull);
    expect(find.byType(ComposerObjectToolbar), findsNothing);
    final groupId = state.blocks.whereType<IslandBlock>().single.id;
    await tester.tap(find.byKey(ValueKey('grid-image-more-$groupId-0')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('删除图片'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final grid =
        (state.blocks.whereType<IslandBlock>().single.node as ImageGridNode);
    expect(grid.images.length, 1);
    expect(grid.images.single.src, 'https://example.com/b.png');
    expect((state.blocks.first as TextBlock).content.text, '保留这段文字');
    state.undo();
    expect(
      (state.blocks.whereType<IslandBlock>().single.node as ImageGridNode)
          .images
          .length,
      2,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  for (final alreadySelected in [false, true]) {
    testWidgets(
      '右键在鼠标处直接开菜单，不叠工具条，单击外部或 Escape 一次退出 selected=$alreadySelected',
      (tester) async {
        final controller = TextEditingController();
        await _pump(
          tester,
          RichComposerEditor(controller: controller),
          desktop: true,
          width: 1000,
          height: 900,
        );
        final h = await _insertImage(tester);
        if (!alreadySelected) {
          tester
              .widget<FluxdoEditor>(find.byType(FluxdoEditor))
              .contentActions!
              .clearObjectSelection();
          await tester.pump();
          await tester.pump();
          final scroll = tester
              .state<ScrollableState>(
                find
                    .descendant(
                      of: find.byType(CustomScrollView).first,
                      matching: find.byType(Scrollable),
                    )
                    .first,
              )
              .position;
          unawaited(
            scroll.animateTo(
              scroll.pixels > 0
                  ? scroll.minScrollExtent
                  : scroll.maxScrollExtent,
              duration: const Duration(seconds: 5),
              curve: Curves.linear,
            ),
          );
          await tester.pump();
          expect(
            scroll.shouldIgnorePointer,
            isTrue,
            reason: '明确覆盖自动滚动屏蔽正文命中的场景',
          );
        }
        final image = tester
            .getRect(find.byType(LazyImage).first)
            .intersect(const Rect.fromLTRB(0, 100, 1000, 600));
        final point = image.topLeft + const Offset(24, 24);
        await tester.tapAt(
          point,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await tester.pump();
        expect(find.text('图片尺寸'), findsOneWidget, reason: '第一帧即可构建菜单，不等待工具条落位');
        expect(
          find.byKey(const ValueKey('composer-object-toolbar')),
          findsNothing,
        );
        await tester.pump(const Duration(milliseconds: 240));
        final menu = find.ancestor(
          of: find.text('在前面输入'),
          matching: find.byType(SingleChildScrollView),
        );
        expect(tester.getRect(menu).top, closeTo(point.dy, 1));
        expect(tester.getRect(menu).left, closeTo(point.dx, 1));
        await tester.tapAt(const Offset(950, 850));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.text('图片尺寸'), findsNothing);
        expect(
          find.byKey(const ValueKey('composer-object-toolbar')),
          findsNothing,
        );
        expect(h.state.selection, isNull);
        await tester.tapAt(
          point,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));
        expect(find.text('图片尺寸'), findsOneWidget, reason: '滚动停止后仍能直接右键图片');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.text('图片尺寸'), findsNothing);
        expect(
          find.byKey(const ValueKey('composer-object-toolbar')),
          findsNothing,
        );
        expect(h.state.selection, isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      },
    );
  }

  testWidgets('普通全文选区仍是文字，显式块操作可删除整段并撤销', (tester) async {
    final controller = TextEditingController();
    await _pump(tester, RichComposerEditor(controller: controller));
    await tester.pump(const Duration(milliseconds: 800));
    final widget = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
    final state = widget.state;
    state.pastePlainText('这一整段需要保留格式');
    final id = state.blocks.first.id;
    state.selectAll();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('composer-object-toolbar')), findsNothing);
    widget.contentActions!.selectObject(EditorBlockTarget(id), showMenu: true);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('删除段落'), findsOneWidget);
    await tester.tap(find.text('删除段落'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect((state.blocks.single as TextBlock).content.text, isEmpty);
    state.undo();
    expect((state.blocks.single as TextBlock).content.text, '这一整段需要保留格式');
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('容器共用块菜单：移除外框保留多段内容，退出不残留文字工具条', (tester) async {
    final controller = TextEditingController();
    await _pump(tester, RichComposerEditor(controller: controller));
    await tester.pump(const Duration(milliseconds: 800));
    final widget = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
    final state = widget.state;
    const frame = DetailsFrame(groupId: 'review-container', summary: '详情');
    state.pasteBlocks([
      TextBlock(
        id: 'x',
        content: EditableTextContent(text: '容器第一段'),
        containers: const [frame],
      ),
      TextBlock(
        id: 'y',
        content: EditableTextContent(text: '容器第二段'),
        containers: const [frame],
      ),
    ]);
    await tester.pump();
    await tester.pump();
    final first = state.blocks.whereType<TextBlock>().firstWhere(
      (block) => block.containers.isNotEmpty,
    );
    final groupId = first.containers.last.groupId;
    widget.contentActions!.selectObject(
      EditorContainerTarget(first.id, groupId),
      showMenu: true,
    );
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('移除外框，保留内容'), findsOneWidget);
    await tester.tap(find.text('移除外框，保留内容'));
    await tester.pumpAndSettle();
    expect(
      state.blocks.whereType<TextBlock>().every(
        (block) => block.containers.isEmpty,
      ),
      isTrue,
    );
    expect(docToMarkdown(state.blocks), contains('容器第一段'));
    expect(docToMarkdown(state.blocks), contains('容器第二段'));
    expect(find.byKey(const ValueKey('composer-object-toolbar')), findsNothing);
    state.undo();
    expect(
      state.blocks.whereType<TextBlock>().any(
        (block) => block.containers.isNotEmpty,
      ),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets('容器标题右键直接开临时菜单，关闭一次即清除选中', (tester) async {
    final controller = TextEditingController();
    await _pump(
      tester,
      RichComposerEditor(controller: controller),
      desktop: true,
      width: 1000,
      height: 900,
    );
    await tester.pump(const Duration(milliseconds: 800));
    final state = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    state.pasteBlocks([
      TextBlock(
        id: 'x',
        content: EditableTextContent(text: '详情正文'),
        containers: const [DetailsFrame(groupId: 'details', summary: '右键此标题')],
      ),
    ]);
    await tester.pump();
    await tester.pump();
    final point = tester.getCenter(find.text('右键此标题'));
    await tester.tapAt(
      point,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    expect(find.text('移除外框，保留内容'), findsOneWidget);
    expect(find.byKey(const ValueKey('composer-object-toolbar')), findsNothing);
    await tester.pump(const Duration(milliseconds: 240));
    await tester.tapAt(const Offset(950, 850));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    expect(find.text('移除外框，保留内容'), findsNothing);
    expect(state.selection, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets('短详情：原地右键直接操作，关闭一次回到正文', (tester) async {
    final controller = TextEditingController();
    await _pump(
      tester,
      RichComposerEditor(controller: controller),
      desktop: true,
      width: 1000,
      height: 850,
    );
    await tester.pump(const Duration(milliseconds: 800));
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
    editor.state.pasteBlocks([
      TextBlock(
        id: 'intro',
        content: EditableTextContent(text: '图片和详情都应保持可见'),
      ),
      IslandBlock(
        id: 'grid',
        node: const ImageGridNode(
          id: 'grid-node',
          images: [
            ImageRun(
              src: 'https://example.com/test.png',
              width: 320,
              height: 300,
            ),
          ],
        ),
      ),
      TextBlock(
        id: 'details',
        content: EditableTextContent(text: '详情里面的文字'),
        containers: const [
          DetailsFrame(groupId: 'details-frame', summary: '短详情标题'),
        ],
      ),
    ]);
    await tester.pump();
    await tester.pump();
    final block = editor.state.blocks.whereType<TextBlock>().firstWhere(
      (b) => b.containers.isNotEmpty,
    );
    final before = tester.getRect(find.text('短详情标题'));
    editor.contentActions!.selectObject(
      EditorContainerTarget(block.id, block.containers.last.groupId),
    );
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(find.text('短详情标题')), before);
    final point = before.topLeft + const Offset(20, 6);
    await tester.tapAt(
      point,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('composer-object-quick-actions')),
      findsNothing,
    );
    await tester.pump(const Duration(milliseconds: 300));
    final menu = tester.getRect(
      find
          .ancestor(
            of: find.text('删除折叠详情'),
            matching: find.byType(SingleChildScrollView),
          )
          .first,
    );
    expect(menu.inflate(1).contains(point), isTrue);
    expect(find.text('删除折叠详情').hitTestable(), findsOneWidget);
    await tester.tapAt(const Offset(20, 820));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('网格重排布局后，统一选中事件跟随实际图片位置', (tester) async {
    final controller = TextEditingController();
    await _pump(tester, RichComposerEditor(controller: controller));
    await tester.pump(const Duration(milliseconds: 800));
    final state = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    state.pastePlainText('三张图片');
    state.insertIslandAfter(
      state.blocks.first.id,
      const ImageGridNode(
        id: 'g',
        images: [
          ImageRun(src: 'https://example.com/a.png', width: 120, height: 80),
          ImageRun(src: 'https://example.com/b.png', width: 120, height: 80),
          ImageRun(src: 'https://example.com/c.png', width: 120, height: 80),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tapAt(tester.getRect(find.byType(LazyImage).at(2)).center);
    await tester.pump();
    await tester.pump();
    final actions = tester
        .widget<FluxdoEditor>(find.byType(FluxdoEditor))
        .contentActions!;
    final before = actions.objectSelection!.globalRect;
    tester.view.physicalSize = const Size(600, 760);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    final after = actions.objectSelection!.globalRect;
    final image = tester.getRect(find.byType(LazyImage).at(2));
    expect(after.center.dx, closeTo(image.center.dx, 1));
    expect(after.center.dy, closeTo(image.center.dy, 1));
    expect(after.center, isNot(before.center));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets('触摸选词后的块操作入口选中整段，不改变普通选词习惯', (tester) async {
    final controller = TextEditingController();
    await _pump(tester, RichComposerEditor(controller: controller));
    await tester.pump(const Duration(milliseconds: 800));
    final state = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    const text = '这里选择一段文字';
    state.pastePlainText(text);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.longPress(find.text(text));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('composer-object-toolbar')), findsNothing);
    expect(find.text('块操作').hitTestable(), findsOneWidget);
    await tester.tap(find.text('块操作'));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('删除段落'), findsOneWidget);
    expect(state.selection!.base.offset, 0);
    expect(state.selection!.extent.offset, text.length);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
