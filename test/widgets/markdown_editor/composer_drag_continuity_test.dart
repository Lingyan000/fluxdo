import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_tools_anchor.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_keyboard_dismiss.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_tools_panel.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_workbench.dart';

import 'composer_interaction_test.dart' show pumpApp;

void main() {
  testWidgets('Android 取消待定控制后可立即重新拖动，迟到答复不覆盖新会话', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 760);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);
    final pending = Completer<Map<String, dynamic>>();
    final calls = <MethodCall>[];
    var begins = 0;
    const native = MethodChannel('com.fluxdo/interactive_keyboard');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'begin') {
        return ++begins == 1 ? pending.future : {'supported': true};
      }
      return null;
    });
    addTearDown(() {
      if (!pending.isCompleted) pending.complete({'supported': false});
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        native,
        null,
      );
    });
    final keyboard = ComposerKeyboardDismissController(
      vsync: tester,
      platform: TargetPlatform.android,
    );
    addTearDown(keyboard.dispose);
    expect(keyboard.begin(tester.view), isTrue);
    await tester.pump();
    keyboard.update(60);
    unawaited(keyboard.end(0, cancel: true));
    await tester.pump();
    expect(keyboard.active, isFalse, reason: '取消不必等系统交出控制权');
    expect(
      calls.any(
        (call) =>
            call.method == 'cancel' &&
            (call.arguments as Map)['dismiss'] == false,
      ),
      isTrue,
    );
    expect(keyboard.begin(tester.view), isTrue);
    await tester.pump();
    keyboard.update(80);
    await tester.pump();
    expect(keyboard.visibleHeight, 220);
    pending.complete({'supported': true});
    await tester.pump();
    expect(keyboard.active, isTrue);
    expect(keyboard.visibleHeight, 220);
  });

  for (final (delayed, releaseEarly) in [
    (false, false),
    (true, false),
    (true, true),
  ]) {
    testWidgets(
      'Android 控制权异常时上拉不中断 delayed=$delayed releaseEarly=$releaseEarly',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 760);
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        tester.view.viewPadding = const FakeViewPadding(bottom: 20);
        addTearDown(tester.view.reset);
        final pending = Completer<Map<String, dynamic>>();
        final calls = <MethodCall>[];
        const native = MethodChannel('com.fluxdo/interactive_keyboard');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
          call,
        ) async {
          calls.add(call);
          if (call.method == 'begin') {
            return delayed ? pending.future : {'supported': false};
          }
          return null;
        });
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.textInput,
          (call) async {
            calls.add(call);
            return null;
          },
        );
        addTearDown(() {
          if (!pending.isCompleted) pending.complete({'supported': false});
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
        final controller = TextEditingController(text: '保留这一段')
          ..selection = const TextSelection(baseOffset: 0, extentOffset: 2);
        final focus = FocusNode();
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
                onResumeKeyboard: () => SystemChannels.textInput
                    .invokeMethod<void>('TextInput.show'),
                bodyBuilder: (_, _, _) =>
                    TextField(controller: controller, focusNode: focus),
                toolbar: ComposerWorkbench(
                  editing:
                      MediaQuery.viewInsetsOf(context).bottom > 0 ||
                      anchor.presenting,
                  toolsAnchor: anchor,
                  controls: const [],
                  tools: const SizedBox(height: 48),
                  onExpandTools: () => showComposerTools(context, [
                    ComposerToolAction(
                      id: 'bold',
                      label: '粗体',
                      icon: const Icon(Icons.format_bold),
                      run: () {},
                    ),
                  ], anchor: anchor),
                ),
                panel: const ComposerKeyboardSpace(),
              ),
            ),
          ),
          desktop: false,
        );
        focus.requestFocus();
        await tester.pump();
        final selection = controller.selection;
        final handle = find.byKey(const ValueKey('composer-tools-handle'));
        final island = find.byKey(const ValueKey('composer-workbench'));
        final space = find.byKey(const ValueKey('composer-keyboard-space'));
        final gesture = await tester.startGesture(tester.getCenter(handle));
        await gesture.moveBy(const Offset(0, -24));
        await tester.pump();
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump();
        await gesture.moveBy(const Offset(0, -120));
        await tester.pump();
        if (releaseEarly) {
          await gesture.up();
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          calls.any((call) => call.method == 'TextInput.hide'),
          isTrue,
          reason: '不能在上沿到达行程后卡着等松手才让键盘让位',
        );
        final top = tester.getTopLeft(island).dy;
        for (final height in [240.0, 120.0, 0.0]) {
          tester.view.viewInsets = FakeViewPadding(bottom: height);
          await tester.pump();
          expect(tester.getTopLeft(island).dy, closeTo(top, .5));
        }
        expect(tester.getSize(space).height, 20);
        expect(anchor.animation!.value, 1, reason: '手指仍然按住时已经完成几何展开');
        if (releaseEarly) {
          anchor.collapse();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
        } else {
          await gesture.moveBy(const Offset(0, 24));
          await tester.pump();
        }
        expect(
          tester.getTopLeft(island).dy,
          greaterThan(top),
          reason: '不用松手就能反向',
        );
        expect(calls.any((call) => call.method == 'TextInput.show'), isTrue);
        if (delayed) {
          final hideCount = calls
              .where((call) => call.method == 'TextInput.hide')
              .length;
          pending.complete({'supported': true, 'height': 300.0});
          await tester.pump();
          expect(
            calls.where((call) => call.method == 'update'),
            isEmpty,
            reason: '迟到的控制权不能重新接管已经反向的手势',
          );
          expect(
            calls.where((call) => call.method == 'TextInput.hide').length,
            hideCount,
          );
          expect(
            calls.any(
              (call) =>
                  call.method == 'cancel' &&
                  (call.arguments as Map)['dismiss'] == true,
            ),
            isTrue,
          );
        }
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pump();
        if (!releaseEarly) await gesture.cancel();
        await tester.pumpAndSettle();
        expect(anchor.presenting, isFalse);
        expect(controller.text, '保留这一段');
        expect(controller.selection, selection);
        expect(focus.hasFocus, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
        anchor.dispose();
        controller.dispose();
        focus.dispose();
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}
