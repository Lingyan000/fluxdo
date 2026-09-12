import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_tools_panel.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_quick_panel.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_workbench.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_tools_anchor.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_island.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_chrome.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> pumpApp(
  WidgetTester tester,
  Widget child, {
  bool desktop = true,
}) async {
  PlatformUtils.debugDesktopOverride = desktop;
  addTearDown(() => PlatformUtils.debugDesktopOverride = null);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
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
          home: child,
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> openPalette(
  WidgetTester tester,
  List<ComposerToolAction> commands,
) async {
  await pumpApp(
    tester,
    Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showComposerQuickPanel(context, commands),
          child: const Text('Open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

ComposerToolAction command(
  String label,
  VoidCallback run, {
  String alias = '',
  bool enabled = true,
}) => ComposerToolAction(
  label: label,
  searchText: alias,
  icon: const Icon(Icons.code),
  run: run,
  enabled: enabled,
);

void main() {
  for (final symbol in [FontAwesomeIcons.bold, FontAwesomeIcons.link]) {
    for (final desktop in [true, false]) {
      testWidgets(
        '底栏连续展开、工具元素落位、自定义后收起 desktop=$desktop glyph=${symbol.data.codePoint}',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(desktop ? 1000 : 390, 760);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.runAsync(() async {
            final loader =
                FontLoader(
                  'packages/font_awesome_flutter/FontAwesomeSolid',
                )..addFont(
                  rootBundle.load(
                    'packages/font_awesome_flutter/lib/fonts/Font-Awesome-7-Free-Solid-900.otf',
                  ),
                );
            await loader.load();
          });
          final anchor = ComposerToolsAnchor();
          var pinned = false;
          var ran = false;
          await pumpApp(
            tester,
            Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: Builder(
                  builder: (context) {
                    void open() => showComposerTools(context, [
                      ComposerToolAction(
                        id: 'bold',
                        label: '粗体',
                        icon: FaIcon(symbol, size: 20),
                        run: () => ran = true,
                        isPinned: () => true,
                      ),
                      ComposerToolAction(
                        id: 'table',
                        label: '表格',
                        icon: const Icon(Icons.table_chart),
                        group: ComposerToolGroup.insert,
                        run: () => ran = true,
                        isPinned: () => pinned,
                        togglePinned: () => pinned = !pinned,
                      ),
                      ComposerToolAction(
                        id: 'italic',
                        label: '斜体',
                        icon: const Icon(Icons.format_italic),
                        run: () {},
                      ),
                    ], anchor: anchor);
                    return ComposerWorkbench(
                      editing: true,
                      controls: const [],
                      toolsAnchor: anchor,
                      onExpandTools: open,
                      tools: Row(
                        children: [
                          Expanded(
                            child: ComposerCompactTools(
                              anchor: anchor,
                              child: Row(
                                children: [
                                  IconButton(
                                    onPressed: () {},
                                    icon: anchor.icon(
                                      'bold',
                                      FaIcon(symbol, size: 16),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Tools',
                            onPressed: open,
                            icon: const Icon(Icons.tune),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            desktop: desktop,
          );
          await tester.pumpAndSettle();
          final origin = anchor.rect!;
          final originalGlyph = anchor.visibleIcons()['bold']!;
          expect(
            (originalGlyph.width - originalGlyph.height).abs(),
            greaterThan(1),
            reason: '使用真实非正方形字形，避免方形测试图标掩盖形变',
          );
          final flyingIcon = find.descendant(
            of: find.byType(Flow),
            matching: find.byType(FaIcon),
          );
          void expectUniformScale() {
            final transform = tester
                .renderObject<RenderBox>(flyingIcon)
                .getTransformTo(null);
            expect(
              transform.entry(0, 0),
              closeTo(transform.entry(1, 1), .0001),
              reason: '迁移图标两轴必须等比缩放',
            );
          }

          final barrierCount = find.byType(ModalBarrier).evaluate().length;
          final island = tester.renderObject(find.byType(ComposerIsland));
          if (desktop) {
            await tester.tap(find.byTooltip('Tools'));
          } else {
            final gesture = await tester.startGesture(
              tester.getCenter(
                find.byKey(const ValueKey('composer-tools-handle')),
              ),
            );
            await gesture.moveBy(const Offset(0, -24));
            await tester.pump();
            final beforeDrag = anchor.rect!.height;
            await gesture.moveBy(const Offset(0, -80));
            await tester.pump();
            expect(
              anchor.rect!.height - beforeDrag,
              closeTo(80, .5),
              reason: '托柄拖动应直接改变浮岛高度',
            );
            await gesture.up();
          }
          await tester.pump();
          expectUniformScale();
          if (desktop) {
            final firstFrame = tester.getRect(flyingIcon);
            expect(firstFrame.width, closeTo(originalGlyph.width, .1));
            expect(firstFrame.height, closeTo(originalGlyph.height, .1));
            expect(
              (firstFrame.center - originalGlyph.center).distance,
              lessThan(.1),
            );
            expect(anchor.rect!.height, closeTo(origin.height, .1));
          }
          await tester.pump(const Duration(milliseconds: 170));
          expectUniformScale();
          expect(
            tester.renderObject(find.byType(ComposerIsland)),
            same(island),
          );
          expect(anchor.animation!.value, inExclusiveRange(0, 1));
          expect(anchor.targets.keys, contains('bold'));
          expect(
            find.byType(ModalBarrier),
            findsNWidgets(barrierCount),
            reason: '展开态属于浮岛，不能新起遮罩',
          );
          expect(find.byType(Dialog), findsNothing);
          final moving = anchor.rect!;
          expect(moving.top, lessThan(origin.top));
          expect(moving.bottom, closeTo(origin.bottom, .1));
          await tester.pumpAndSettle();
          expect(anchor.rect!.top, lessThan(moving.top));
          expect(find.byType(TextField), findsNothing);
          expect(
            find.byKey(const ValueKey('composer-quick-panel')),
            findsNothing,
          );
          final formatGroup = find.byKey(
            const ValueKey('composer-tools-group-format'),
          );
          final insertGroup = find.byKey(
            const ValueKey('composer-tools-group-insert'),
          );
          final bold = find.byKey(const ValueKey('composer-tool-bold'));
          expect(bold, findsOneWidget, reason: '固定工具不在所属分类中重复列出');
          expect(
            tester.getRect(bold).bottom,
            lessThan(tester.getRect(formatGroup).top),
          );
          expect(
            tester.getRect(formatGroup).top,
            lessThan(tester.getRect(insertGroup).top),
          );
          for (final (heading, toolId) in [
            (formatGroup, 'italic'),
            (insertGroup, 'table'),
          ]) {
            final iconCard = find
                .ancestor(
                  of: find.byKey(anchor.targets[toolId]!),
                  matching: find.byWidgetPredicate(
                    (widget) =>
                        widget is Container &&
                        widget.decoration is BoxDecoration,
                  ),
                )
                .first;
            expect(
              tester.getRect(heading).left,
              closeTo(tester.getRect(iconCard).left, .1),
              reason: '分类标题与第一列图标卡片左缘对齐',
            );
          }
          expect(
            find.byKey(const ValueKey('composer-tools-group-editing')),
            findsNothing,
            reason: '空分类不占空间',
          );
          final customize = find.text(S.current.toolPanel_customize);
          final toolbarRect = tester.getRect(
            find.byKey(const ValueKey('composer-format-row')),
          );
          expect(
            tester.getRect(customize).center.dy,
            inInclusiveRange(toolbarRect.top, toolbarRect.bottom),
            reason: '自定义入口留在原底栏',
          );
          await tester.tap(customize);
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('composer-tool-table')));
          await tester.pump();
          expect(pinned, isTrue);
          expect(ran, isFalse);
          final destinationGlyph = tester.getRect(
            find.descendant(
              of: find.byKey(anchor.targets['bold']!),
              matching: find.byType(FaIcon),
            ),
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pump();
          expectUniformScale();
          final returnStart = tester.getRect(flyingIcon);
          expect(returnStart.width, closeTo(destinationGlyph.width, .1));
          expect(returnStart.height, closeTo(destinationGlyph.height, .1));
          expect(
            (returnStart.center - destinationGlyph.center).distance,
            lessThan(.1),
          );
          await tester.pump(const Duration(milliseconds: 20));
          expectUniformScale();
          final customizeVisibility = find.byKey(
            const ValueKey('composer-customize-visibility'),
          );
          expect(
            tester.widget<Opacity>(customizeVisibility).opacity,
            lessThan(.5),
            reason: '开始收起时自定义入口先退场',
          );
          await tester.pump(const Duration(milliseconds: 40));
          expect(tester.widget<Opacity>(customizeVisibility).opacity, 0);
          expect(
            anchor.animation!.value,
            greaterThan(0),
            reason: '工具仍在返程时，入口已完全让位',
          );
          await tester.pumpAndSettle();
          expect(anchor.rect!.height, closeTo(origin.height, .1));
          expect(
            find.byKey(const ValueKey('composer-tools-panel')),
            findsNothing,
          );
          expect(find.byTooltip('Tools').hitTestable(), findsOneWidget);
        },
      );
    }
  }

  testWidgets('工具自动聚焦、搜索别名后回车直接执行', (tester) async {
    var ran = '';
    await openPalette(tester, [
      command('粗体', () => ran = 'bold', alias: 'bold'),
      command('插入表格', () => ran = 'table', alias: 'table'),
    ]);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
    tester.testTextInput.enterText('tbl');
    await tester.pump();
    expect(find.text('粗体'), findsNothing);
    expect(find.text('插入表格'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(ran, 'table');
    expect(find.byKey(const ValueKey('composer-quick-panel')), findsNothing);
  });

  testWidgets('方向键跳过不可用动作，Esc 取消不执行', (tester) async {
    var ran = '';
    await openPalette(tester, [
      command('不可用', () => ran = 'bad', enabled: false),
      command('第一项', () => ran = 'first'),
      command('第二项', () => ran = 'second'),
    ]);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(ran, 'second');
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(ran, 'second');
    expect(find.byKey(const ValueKey('composer-quick-panel')), findsNothing);
  });

  testWidgets('输入法确认不执行，空结果回车不关闭', (tester) async {
    var count = 0;
    await openPalette(tester, [command('Bold', () => count++)]);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'b',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(count, 0);
    expect(find.byKey(const ValueKey('composer-quick-panel')), findsOneWidget);
    tester.testTextInput.enterText('zzzz');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(count, 0);
    expect(find.text(S.current.composer_noTools), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('快捷面板键盘选中项滚入可见区', (tester) async {
    await openPalette(tester, [
      command('第一项', () {}),
      for (var i = 1; i <= 35; i++) command('Command $i', () {}),
    ]);
    await tester.tap(find.byKey(const ValueKey('composer-tools-search')));
    for (var i = 0; i < 30; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    await tester.pump();
    await tester.pump();
    final selected = find.widgetWithText(ListTile, 'Command 30');
    expect(selected, findsOneWidget);
    expect(tester.widget<ListTile>(selected).selected, isTrue);
    expect(
      tester.getRect(selected).bottom,
      lessThanOrEqualTo(tester.getRect(find.byType(ListView)).bottom + 1),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('触底回弹不恢复顶栏，主动反向滚动才恢复', (tester) async {
    final chrome = ComposerChromeController();
    final scroll = ScrollController();
    await pumpApp(
      tester,
      ComposerChromeScope(
        controller: chrome,
        child: Scaffold(
          body: ListView(
            controller: scroll,
            physics: const BouncingScrollPhysics(),
            children: const [SizedBox(height: 2400)],
          ),
        ),
      ),
    );
    scroll.jumpTo(scroll.position.maxScrollExtent - 150);
    await tester.pump();
    await tester.fling(find.byType(ListView), const Offset(0, -300), 2200);
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, 1));
    expect(chrome.hidden, isTrue, reason: '碰到底部的物理回弹不代表用户往回阅读');
    await tester.drag(find.byType(ListView), const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(chrome.hidden, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
    chrome.dispose();
  });

  testWidgets('阅读滚动收起两栏，反向/点击/边缘悬停恢复，程序滚动不收起', (tester) async {
    final chrome = ComposerChromeController();
    final scroll = ScrollController();
    await pumpApp(
      tester,
      ComposerChromeScope(
        controller: chrome,
        child: Scaffold(
          appBar: ComposerAutoHideAppBar(
            child: AppBar(title: const Text('Title')),
          ),
          body: Stack(
            children: [
              ListView(
                controller: scroll,
                children: const [SizedBox(height: 2400)],
              ),
              const Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: ComposerChromeVisibility(
                  child: SizedBox(height: 48, child: Text('Tools')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    scroll.jumpTo(300);
    await tester.pumpAndSettle();
    expect(chrome.hidden, isFalse);
    await tester.drag(find.byType(ListView), const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(chrome.hidden, isTrue);
    await tester.drag(find.byType(ListView), const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(chrome.hidden, isFalse);
    chrome.hide();
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(240, 200));
    await tester.pumpAndSettle();
    expect(chrome.hidden, isFalse);
    chrome.hide();
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(240, 200));
    await mouse.moveTo(const Offset(240, 12));
    await tester.pumpAndSettle();
    expect(chrome.hidden, isFalse);
    final release = chrome.hold();
    chrome.hide();
    expect(chrome.hidden, isFalse);
    release();
    chrome.hide();
    expect(chrome.hidden, isTrue);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
    chrome.dispose();
  });
}
