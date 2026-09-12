import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_tools_anchor.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_tools_panel.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_workbench.dart';

import 'composer_interaction_test.dart' show pumpApp;

Future<(ComposerToolsAnchor, List<String>)> _openTools(
  WidgetTester tester, {
  int count = 36,
  bool desktop = false,
  bool withKeyboard = false,
  VoidCallback? onResumeKeyboard,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 760);
  addTearDown(tester.view.reset);
  if (withKeyboard) {
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    tester.view.viewPadding = const FakeViewPadding(bottom: 20);
    const native = MethodChannel('com.fluxdo/interactive_keyboard');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      native,
      (call) async => call.method == 'begin' ? {'supported': false} : null,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (call) async {
        if (call.method == 'TextInput.hide') {
          tester.view.viewInsets = const FakeViewPadding();
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        native,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.textInput,
        null,
      );
    });
  }
  final anchor = ComposerToolsAnchor();
  final executed = <String>[];
  await pumpApp(
    tester,
    Scaffold(
      resizeToAvoidBottomInset: false,
      body: Align(
        alignment: Alignment.bottomCenter,
        child: Builder(
          builder: (context) {
            void open() => showComposerTools(context, [
              for (var i = 0; i < count; i++)
                ComposerToolAction(
                  id: 'tool-$i',
                  label: '工具 $i',
                  icon: const Icon(Icons.format_bold),
                  run: () => executed.add('$i'),
                ),
            ], anchor: anchor);
            final toolbar = ComposerWorkbench(
              editing: true,
              toolsAnchor: anchor,
              onExpandTools: open,
              controls: const [],
              tools: Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: 'Open tools',
                  onPressed: open,
                  icon: const Icon(Icons.expand_less),
                ),
              ),
            );
            if (!withKeyboard) return toolbar;
            return ComposerEditorLayout(
              editing: true,
              toolsAnchor: anchor,
              onResumeKeyboard: () {
                onResumeKeyboard?.call();
                tester.view.viewInsets = const FakeViewPadding(bottom: 300);
              },
              bodyBuilder: (_, _, _) => const SizedBox.expand(),
              toolbar: toolbar,
              panel: const ComposerKeyboardSpace(),
            );
          },
        ),
      ),
    ),
    desktop: desktop,
  );
  await tester.tap(find.byTooltip('Open tools'));
  await tester.pumpAndSettle();
  return (anchor, executed);
}

Finder get _list => find.descendant(
  of: find.byKey(const ValueKey('composer-tools-panel')),
  matching: find.byType(CustomScrollView),
);

void main() {
  testWidgets('列表下拉收起与键盘交接保持同一次拖动', (tester) async {
    var resumes = 0;
    final (anchor, executed) = await _openTools(
      tester,
      withKeyboard: true,
      onResumeKeyboard: () => resumes++,
    );
    final space = find.byKey(const ValueKey('composer-keyboard-space'));
    final island = find.byKey(const ValueKey('composer-workbench'));
    expect(tester.getSize(space).height, 20);
    final expanded = tester.getSize(island).height;
    final gesture = await tester.startGesture(tester.getCenter(_list));
    await gesture.moveBy(const Offset(0, 24));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    expect(resumes, 1);
    expect(anchor.presenting, isTrue);
    expect(tester.getSize(space).height, 300);
    expect(tester.getSize(island).height, lessThan(expanded));
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(anchor.presenting, isFalse);
    expect(tester.getSize(space).height, 300);
    expect(executed, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    anchor.dispose();
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('工具列表到顶后同次下拉收起，反向还原后继续滚动 $platform', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final (anchor, executed) = await _openTools(tester);
      final scroll = tester.widget<CustomScrollView>(_list).controller!;
      final island = find.byKey(const ValueKey('composer-workbench'));
      final expanded = tester.getRect(island);
      scroll.jumpTo(90);
      await tester.pump();
      final gesture = await tester.startGesture(tester.getCenter(_list));
      await gesture.moveBy(const Offset(0, 24));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      expect(scroll.offset, greaterThan(0));
      expect(tester.getRect(island), expanded, reason: '未到顶时只滚列表');
      final remaining = scroll.offset;
      await gesture.moveBy(Offset(0, remaining + 50));
      await tester.pump();
      expect(scroll.offset, 0);
      expect(
        expanded.height - tester.getSize(island).height,
        closeTo(50, .5),
        reason: '到顶后只把剩余手势交给面板',
      );
      await gesture.moveBy(const Offset(0, -80));
      await tester.pump();
      expect(tester.getRect(island), expanded);
      expect(scroll.offset, closeTo(30, .5), reason: '反向还原后剩余距离继续滚列表');
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(anchor.expanded, isTrue);
      expect(executed, isEmpty);

      scroll.jumpTo(0);
      await tester.pump();
      final dismiss = await tester.startGesture(tester.getCenter(_list));
      await dismiss.moveBy(const Offset(0, 24));
      await tester.pump();
      await dismiss.moveBy(const Offset(0, 130));
      await tester.pump();
      expect(tester.getSize(island).height, lessThan(expanded.height));
      await dismiss.up();
      await tester.pumpAndSettle();
      expect(anchor.presenting, isFalse);
      expect(executed, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      anchor.dispose();
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('短工具列表也能下拉，取消后保持展开且不会误选工具', (tester) async {
    final (anchor, executed) = await _openTools(tester, count: 2);
    final scroll = tester.widget<CustomScrollView>(_list).controller!;
    expect(scroll.position.maxScrollExtent, 0);
    final island = find.byKey(const ValueKey('composer-workbench'));
    final expanded = tester.getRect(island);
    final gesture = await tester.startGesture(tester.getCenter(_list));
    await gesture.moveBy(const Offset(0, 24));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();
    expect(tester.getSize(island).height, lessThan(expanded.height));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(anchor.expanded, isTrue);
    expect(tester.getRect(island), expanded);
    expect(executed, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    anchor.dispose();
  });

  testWidgets('列表惯性到顶和桌面下拉不收起面板', (tester) async {
    for (final desktop in [false, true]) {
      final (anchor, _) = await _openTools(tester, desktop: desktop);
      final scroll = tester.widget<CustomScrollView>(_list).controller!;
      scroll.jumpTo(260);
      await tester.pump();
      await tester.timedDrag(
        _list,
        const Offset(0, 100),
        const Duration(milliseconds: 100),
      );
      await tester.pumpAndSettle();
      expect(anchor.expanded, isTrue, reason: '手指已松开后的惯性不触发收起');
      if (desktop) {
        scroll.jumpTo(0);
        await tester.pump();
        await tester.drag(_list, const Offset(0, 160));
        await tester.pumpAndSettle();
        expect(anchor.expanded, isTrue);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      anchor.dispose();
    }
  });
}
