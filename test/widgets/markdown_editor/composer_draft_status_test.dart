import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/draft_controller.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_draft_status.dart';

void main() {
  testWidgets('快速保存不闪转圈，成功淡出；新的输入取消旧提示定时器', (tester) async {
    final status = ValueNotifier(DraftSaveStatus.idle);
    addTearDown(status.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: Scaffold(body: ComposerDraftStatus(status: status)),
        ),
      ),
    );
    status.value = DraftSaveStatus.pending;
    await tester.pumpAndSettle();
    expect(find.text(S.current.composer_draftPending), findsOneWidget);
    status.value = DraftSaveStatus.saving;
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    status.value = DraftSaveStatus.saved;
    await tester.pumpAndSettle();
    expect(find.text(S.current.composer_draftSaved), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    status.value = DraftSaveStatus.pending;
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text(S.current.composer_draftPending), findsOneWidget);
    status.value = DraftSaveStatus.saved;
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text(S.current.composer_draftSaved), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('失败提示常驻，重试不重复提交也不收起键盘', (tester) async {
    final status = ValueNotifier(DraftSaveStatus.error);
    final focus = FocusNode();
    final pending = Completer<void>();
    var retries = 0;
    addTearDown(status.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: Scaffold(
            body: Column(
              children: [
                TextField(focusNode: focus),
                ComposerDraftStatus(
                  status: status,
                  onRetry: () async {
                    retries++;
                    await pending.future;
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.showKeyboard(find.byType(TextField));
    await tester.pump(const Duration(seconds: 6));
    final retry = find.byKey(const ValueKey('composer-draft-retry'));
    expect(retry, findsOneWidget);
    expect(tester.getSize(retry).height, greaterThanOrEqualTo(48));
    tester.testTextInput.log.clear();
    await tester.tap(retry);
    await tester.pump();
    expect(tester.widget<TextButton>(retry).onPressed, isNull);
    expect(retries, 1);
    expect(focus.hasFocus, isTrue);
    expect(
      tester.testTextInput.log.where((call) => call.method == 'TextInput.hide'),
      isEmpty,
    );
    status.value = DraftSaveStatus.saved;
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text(S.current.composer_draftSaved), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final reduced in [false, true]) {
    testWidgets('大字体窄屏的保存失败与字数提示不重叠 reduced=$reduced', (tester) async {
      final status = ValueNotifier(DraftSaveStatus.saving);
      addTearDown(status.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: MediaQuery(
              data: MediaQueryData(
                textScaler: const TextScaler.linear(2),
                disableAnimations: reduced,
              ),
              child: Scaffold(
                body: SizedBox(
                  width: 280,
                  child: ComposerStatusBar(
                    length: 1,
                    minimumLength: 10,
                    draftStatus: status,
                    onRetry: () async {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byType(CircularProgressIndicator),
        reduced ? findsNothing : findsOneWidget,
      );
      status.value = DraftSaveStatus.error;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final retry = tester.getRect(
        find.byKey(const ValueKey('composer-draft-retry')),
      );
      final count = tester.getRect(find.textContaining('1 / 10'));
      expect(retry.bottom, lessThanOrEqualTo(count.top));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
