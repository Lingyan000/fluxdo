import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_workbench.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_keyboard_dismiss.dart';
import 'composer_interaction_test.dart' show pumpApp;

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('离开编辑页结束原生键盘接管 platform=$platform', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 760);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.reset);
      final calls = <MethodCall>[];
      const native = MethodChannel('com.fluxdo/interactive_keyboard');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
        call,
      ) async {
        calls.add(call);
        return call.method == 'begin' ? {'supported': true} : null;
      });
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.textInput,
        (call) async {
          calls.add(call);
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
      final controller = ComposerKeyboardDismissController(
        vsync: tester,
        platform: platform,
      );
      expect(controller.begin(tester.view), isTrue);
      await tester.pump();
      controller.update(60);
      await tester.pump();
      controller.dispose();
      await tester.pump();
      if (platform == TargetPlatform.android) {
        expect(
          (calls.singleWhere((c) => c.method == 'cancel').arguments
              as Map)['dismiss'],
          isTrue,
        );
      } else {
        final end = calls.lastWhere(
          (c) => c.method == 'TextInput.onPointerUpForInteractiveKeyboard',
        );
        expect((end.arguments as Map)['pointerY'], greaterThan(760));
      }
    });

    for (final cancel in [false, true]) {
      testWidgets('折叠工具栏下拖跟手收键盘并保留草稿 platform=$platform cancel=$cancel', (
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
        final delayedReady = platform == TargetPlatform.android && cancel
            ? Completer<Map<String, dynamic>>()
            : null;
        const native = MethodChannel('com.fluxdo/interactive_keyboard');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
          call,
        ) async {
          calls.add(call);
          if (call.method == 'begin') {
            return delayedReady?.future ?? {'supported': true, 'height': 300.0};
          }
          if (call.method == 'end') {
            final dismiss = (call.arguments as Map)['dismiss'] == true;
            tester.view.viewInsets = FakeViewPadding(bottom: dismiss ? 0 : 300);
          }
          return null;
        });
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.textInput,
          (call) async {
            calls.add(call);
            if (call.method ==
                'TextInput.onPointerMoveForInteractiveKeyboard') {
              // iOS 引擎接管后，系统 IME inset 会先归零；浮岛必须继续跟随接管高度。
              tester.view.viewInsets = FakeViewPadding(bottom: 0);
            }
            if (call.method == 'TextInput.onPointerUpForInteractiveKeyboard') {
              tester.view.viewInsets = FakeViewPadding(
                bottom: cancel ? 300 : 0,
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
        var toolOpenCount = 0;
        await pumpApp(
          tester,
          Scaffold(
            resizeToAvoidBottomInset: false,
            body: ComposerEditorLayout(
              editing: true,
              bodyBuilder: (_, _, _) =>
                  TextField(controller: text, focusNode: focus),
              toolbar: ComposerWorkbench(
                editing: true,
                controls: const [],
                tools: const Row(
                  children: [
                    Icon(Icons.format_bold),
                    Expanded(child: SizedBox(height: 48)),
                  ],
                ),
                onExpandTools: () => toolOpenCount++,
              ),
              panel: Builder(
                builder: (context) => SizedBox(
                  height: math.max(20, MediaQuery.viewInsetsOf(context).bottom),
                ),
              ),
            ),
          ),
          desktop: false,
        );
        focus.requestFocus();
        await tester.pump();
        final selection = text.selection;
        final toolbar = find.byKey(const ValueKey('composer-format-row'));
        final space = find.byKey(const ValueKey('composer-keyboard-space'));
        final gesture = await tester.startGesture(
          tester.getCenter(
            cancel
                ? toolbar
                : find.byKey(const ValueKey('composer-tools-handle')),
          ),
        );
        await gesture.moveBy(const Offset(0, 24));
        await tester.pump();
        await gesture.moveBy(const Offset(0, 30));
        await tester.pump();
        if (delayedReady != null) {
          expect(
            tester.getSize(space).height,
            300,
            reason: '系统尚未交出键盘控制权时，浮岛不能先滑进键盘',
          );
          delayedReady.complete({'supported': true, 'height': 300.0});
          await tester.pump();
          await tester.pump();
        }
        final before = tester.getSize(space).height;
        final toolbarBefore = tester.getRect(toolbar).bottom;
        await gesture.moveBy(const Offset(0, 60));
        await tester.pump();
        expect(before - tester.getSize(space).height, closeTo(60, .1));
        expect(tester.getRect(toolbar).bottom - toolbarBefore, closeTo(60, .1));
        expect(toolOpenCount, 0, reason: '下拖不能误开工具或抢走编辑焦点');
        expect(
          find.byKey(const ValueKey('composer-tools-panel')),
          findsNothing,
        );
        expect(calls.where((c) => c.method == 'TextInput.hide'), isEmpty);
        expect(text.text, 'draft stays here');
        expect(text.selection, selection);
        if (cancel) {
          await gesture.cancel();
        } else {
          await gesture.moveBy(const Offset(0, 400));
          await tester.pump();
          expect(tester.getSize(space).height, 20);
          await gesture.up();
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 120));
        await tester.pump();
        final controller = ComposerKeyboardDismissScope.maybeOf(
          tester.element(find.byType(ComposerWorkbench)),
        )!;
        expect(controller.active, isFalse);
        expect(tester.getSize(space).height, cancel ? 300 : 20);
        if (platform == TargetPlatform.android) {
          final end = calls.singleWhere((c) => c.method == 'end');
          expect((end.arguments as Map)['dismiss'], !cancel);
          expect(calls.any((c) => c.method == 'update'), isTrue);
        } else {
          expect(
            calls.any(
              (c) => c.method == 'TextInput.onPointerUpForInteractiveKeyboard',
            ),
            isTrue,
          );
        }
        expect(text.text, 'draft stays here');
        expect(text.selection, selection);
        await tester.pumpWidget(const SizedBox.shrink());
        focus.dispose();
        text.dispose();
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }
}
