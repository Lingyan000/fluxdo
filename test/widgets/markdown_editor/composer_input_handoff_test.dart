import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_tools_anchor.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_tools_panel.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_workbench.dart';

import 'composer_interaction_test.dart' show pumpApp;

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final cancel in [false, true]) {
      testWidgets('工具接管键盘空间，上拉反向与回键盘连续 $platform cancel=$cancel', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 760);
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        tester.view.viewPadding = const FakeViewPadding(bottom: 20);
        addTearDown(tester.view.reset);
        final calls = <MethodCall>[];
        const native = MethodChannel('com.fluxdo/interactive_keyboard');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
          call,
        ) async {
          calls.add(call);
          if (call.method == 'begin') {
            return {'supported': true, 'height': 300.0};
          }
          if (call.method == 'end') {
            tester.view.viewInsets = FakeViewPadding(
              bottom: (call.arguments as Map)['dismiss'] == true ? 0 : 300,
            );
          }
          return null;
        });
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.textInput,
          (call) async {
            calls.add(call);
            if (call.method ==
                'TextInput.onPointerMoveForInteractiveKeyboard') {
              tester.view.viewInsets = const FakeViewPadding();
            }
            if (call.method == 'TextInput.onPointerUpForInteractiveKeyboard') {
              final y = (call.arguments as Map)['pointerY'] as double;
              tester.view.viewInsets = FakeViewPadding(
                bottom: y > 760 ? 0 : 300,
              );
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
        final text = TextEditingController(text: 'draft stays here')
          ..selection = const TextSelection(baseOffset: 0, extentOffset: 5);
        final focus = FocusNode();
        final anchor = ComposerToolsAnchor();
        var resumes = 0;
        await pumpApp(
          tester,
          Scaffold(
            resizeToAvoidBottomInset: false,
            body: Builder(
              builder: (context) => ComposerEditorLayout(
                toolsAnchor: anchor,
                editing:
                    MediaQuery.viewInsetsOf(context).bottom > 0 ||
                    anchor.presenting,
                onResumeKeyboard: () {
                  resumes++;
                  SystemChannels.textInput.invokeMethod<void>('TextInput.show');
                },
                bodyBuilder: (_, _, _) => SizedBox.expand(
                  key: const ValueKey('draft-viewport'),
                  child: TextField(controller: text, focusNode: focus),
                ),
                toolbar: ComposerWorkbench(
                  editing:
                      MediaQuery.viewInsetsOf(context).bottom > 0 ||
                      anchor.presenting,
                  toolsAnchor: anchor,
                  onExpandTools: () => showComposerTools(context, [
                    ComposerToolAction(
                      id: 'bold',
                      label: '粗体',
                      icon: const Icon(Icons.format_bold),
                      run: () {},
                    ),
                  ], anchor: anchor),
                  controls: const [],
                  tools: const SizedBox(height: 48),
                ),
                panel: const ComposerKeyboardSpace(),
              ),
            ),
          ),
          desktop: false,
        );
        focus.requestFocus();
        await tester.pump();
        final selection = text.selection;
        final handle = find.byKey(const ValueKey('composer-tools-handle'));
        final island = find.byKey(const ValueKey('composer-workbench'));
        final space = find.byKey(const ValueKey('composer-keyboard-space'));
        final body = find.byKey(const ValueKey('draft-viewport'));
        final initialBody = tester.getRect(body);
        final initialIsland = tester.getRect(island);
        final gesture = await tester.startGesture(tester.getCenter(handle));
        await gesture.moveBy(const Offset(0, -24));
        await tester.pump();
        await gesture.moveBy(const Offset(0, -28));
        await tester.pump();
        await tester.pump();
        final first = tester.getRect(island);
        expect(first.top, lessThan(initialIsland.top));
        expect(
          first.bottom,
          greaterThan(initialIsland.bottom),
          reason: '下沿接住键盘让出的空间',
        );
        expect(tester.getRect(body), initialBody, reason: '交接不重新布局正文');
        await gesture.moveBy(const Offset(0, -12));
        await tester.pump();
        expect(
          first.top - tester.getRect(island).top,
          closeTo(12, .5),
          reason: '上沿在受限距离内一比一跟手',
        );
        await gesture.moveBy(const Offset(0, 12));
        await tester.pump();
        expect(tester.getRect(island).top, closeTo(first.top, .5));
        if (cancel) {
          await gesture.cancel();
        } else {
          await gesture.moveBy(const Offset(0, -200));
          await tester.pump();
          expect(
            calls.where(
              (c) =>
                  c.method == 'end' ||
                  c.method == 'TextInput.onPointerUpForInteractiveKeyboard',
            ),
            isEmpty,
            reason: '手指未松开时，即使拖到终点也保留反向控制权',
          );
          await gesture.up();
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pump();
        expect(text.text, 'draft stays here');
        expect(text.selection, selection);
        expect(focus.hasFocus, isTrue);
        expect(tester.getRect(body), initialBody);
        if (cancel) {
          expect(anchor.presenting, isFalse);
          expect(tester.getSize(space).height, 300);
          expect(tester.getRect(island), initialIsland);
        } else {
          expect(anchor.presenting, isTrue);
          expect(tester.getSize(space).height, 20);
          expect(
            tester.getRect(island).top,
            greaterThan(160),
            reason: '展开后仍有正文空间',
          );
          anchor.collapse();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(resumes, 1);
          expect(anchor.presenting, isTrue, reason: '键盘回报前保留工具占位');
          final beforeReturn = tester.getRect(island);
          for (final height in [60.0, 180.0, 300.0]) {
            tester.view.viewInsets = FakeViewPadding(bottom: height);
            await tester.pump();
            await tester.pump();
            expect(
              tester.getRect(island).top,
              closeTo(beforeReturn.top, .5),
              reason: '键盘上升和工具缩短互相补偿',
            );
          }
          await tester.pump();
          expect(anchor.presenting, isFalse);
          expect(tester.getRect(island), initialIsland);
          expect(tester.getRect(body), initialBody);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        text.dispose();
        focus.dispose();
        anchor.dispose();
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }
  for (final size in [const Size(375, 667), const Size(760, 390)]) {
    testWidgets('小屏和横屏接管、表情切换与键盘不可用兜底 size=$size', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      tester.view.viewPadding = const FakeViewPadding(bottom: 20);
      addTearDown(tester.view.reset);
      const native = MethodChannel('com.fluxdo/interactive_keyboard');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
        call,
      ) async {
        return call.method == 'begin' ? {'supported': false} : null;
      });
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.textInput,
        (call) async {
          calls.add(call);
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
      final anchor = ComposerToolsAnchor();
      late StateSetter rebuild;
      var emoji = false;
      var resumes = 0;
      await pumpApp(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations: true,
                textScaler: TextScaler.linear(size.width < 400 ? 3 : 1),
              ),
              child: Scaffold(
                resizeToAvoidBottomInset: false,
                appBar: AppBar(title: const Text('写作')),
                body: Builder(
                  builder: (context) => ComposerEditorLayout(
                    editing:
                        MediaQuery.viewInsetsOf(context).bottom > 0 ||
                        anchor.presenting ||
                        emoji,
                    toolsAnchor: anchor,
                    customPanelVisible: emoji,
                    holdInputToolbar: emoji,
                    onResumeKeyboard: () => resumes++,
                    bodyBuilder: (_, _, _) => const SizedBox.expand(),
                    toolbar: ComposerWorkbench(
                      editing:
                          MediaQuery.viewInsetsOf(context).bottom > 0 ||
                          anchor.presenting ||
                          emoji,
                      toolsAnchor: anchor,
                      onExpandTools: () {
                        rebuild(() => emoji = false);
                        showComposerTools(context, [
                          ComposerToolAction(
                            id: 'bold',
                            label: '粗体',
                            icon: const Icon(Icons.format_bold),
                            run: () {},
                          ),
                        ], anchor: anchor);
                      },
                      controls: const [],
                      tools: const SizedBox(height: 48),
                    ),
                    panel: emoji
                        ? const SizedBox(
                            height: 200,
                            child: ColoredBox(color: Colors.blue),
                          )
                        : const ComposerKeyboardSpace(),
                  ),
                ),
              ),
            );
          },
        ),
        desktop: false,
      );
      final handle = find.byKey(const ValueKey('composer-tools-handle'));
      final island = find.byKey(const ValueKey('composer-workbench'));
      final space = find.byKey(const ValueKey('composer-keyboard-space'));
      await tester.tap(handle);
      await tester.pumpAndSettle();
      expect(anchor.expanded, isTrue);
      expect(tester.getSize(space).height, 20);
      expect(
        tester.getRect(island).top,
        greaterThanOrEqualTo(tester.getRect(find.byType(AppBar)).bottom),
      );
      expect(
        calls.any((call) => call.method == 'TextInput.hide'),
        isTrue,
        reason: '不支持跟手控制时仍能完成切换',
      );
      tester.view.physicalSize = const Size(760, 240);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '旋转或分屏缩小视口时，正文约束不能变成负数');
      tester.view.physicalSize = size;
      await tester.pump();

      // 键盘尚未唤起时再次系统返回，应结束输入，不能留下空面板。
      anchor.collapse();
      await tester.pump();
      expect(resumes, 1);
      expect(anchor.presenting, isTrue);
      anchor.dismiss();
      await tester.pumpAndSettle();
      expect(anchor.presenting, isFalse);
      expect(tester.getSize(space).height, 20);

      // 从表情展开，再切回表情，共用同一块空间。
      rebuild(() => emoji = true);
      await tester.pumpAndSettle();
      await tester.tap(handle);
      await tester.pumpAndSettle();
      expect(anchor.presenting, isTrue);
      rebuild(() => emoji = true);
      await tester.pump();
      anchor.dismiss();
      await tester.pumpAndSettle();
      expect(anchor.presenting, isFalse);
      expect(tester.getSize(space).height, 200);
      expect(resumes, 1, reason: '切回表情不唤起键盘');

      await tester.tap(handle);
      await tester.pumpAndSettle();
      anchor.collapse();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();
      expect(anchor.presenting, isFalse, reason: '键盘拒绝唤起时最终释放占位');
      expect(tester.getSize(space).height, 20);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      anchor.dispose();
    });
  }
}
