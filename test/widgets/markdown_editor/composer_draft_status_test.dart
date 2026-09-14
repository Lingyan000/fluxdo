import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/draft_controller.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_header_actions.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_draft_status.dart';

Future<void> _pump(
  WidgetTester tester,
  ValueNotifier<DraftSaveStatus> status, {
  FocusNode? focus,
  VoidCallback? onRetry,
  double width = 390,
  double scale = 1,
  bool reduced = false,
}) async {
  PlatformUtils.debugDesktopOverride = false;
  addTearDown(() => PlatformUtils.debugDesktopOverride = null);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 760);
  addTearDown(tester.view.reset);
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
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: reduced,
            ),
            child: child!,
          ),
          home: Scaffold(
            resizeToAvoidBottomInset: false,
            appBar: AppBar(
              title: const Text('回复话题'),
              actions: [
                ComposerHeaderActions(
                  availableWidth: width,
                  submitLabel: '发送',
                  onSubmit: () {},
                  previewing: false,
                  onTogglePreview: () {},
                  showDiscard: true,
                  onDiscard: () {},
                  draftStatus: status,
                  onRetryDraft: onRetry,
                ),
              ],
            ),
            body: TextField(focusNode: focus),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('冲突可以选择云端版本，加载操作不会同时授权覆盖云端', (tester) async {
    final status = ValueNotifier(DraftSaveStatus.conflict);
    await _pump(tester, status, width: 320, scale: 2);
    var reloaded = false;
    final resolution = confirmComposerDraftOverwrite(
      tester.element(find.byType(TextField)),
      onReload: () async => reloaded = true,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.current.composer_draftUseRemote));
    await tester.pumpAndSettle();
    expect(await resolution, isFalse);
    expect(reloaded, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    status.dispose();
  });

  testWidgets('覆盖云端需要明确选择，取消不会授权覆盖', (tester) async {
    final status = ValueNotifier(DraftSaveStatus.conflict);
    await _pump(tester, status, width: 320, scale: 2);
    final context = tester.element(find.byType(TextField));
    final cancel = confirmComposerDraftOverwrite(context);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text(S.current.common_cancel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(await cancel, isFalse);
    final overwrite = confirmComposerDraftOverwrite(context);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text(S.current.composer_draftOverwrite));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(await overwrite, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    status.dispose();
  });
  testWidgets('草稿状态不占正文，更多菜单实时展示结果且重试保留键盘', (tester) async {
    final status = ValueNotifier(DraftSaveStatus.idle);
    final focus = FocusNode();
    var retries = 0;
    await _pump(
      tester,
      status,
      focus: focus,
      onRetry: () {
        retries++;
        status.value = DraftSaveStatus.saving;
      },
    );
    await tester.showKeyboard(find.byType(TextField));
    final bodyRect = tester.getRect(find.byType(TextField));
    final more = find.byKey(const ValueKey('composer-header-more'));
    final moreRect = tester.getRect(more);
    for (final value in [
      DraftSaveStatus.pending,
      DraftSaveStatus.saving,
      DraftSaveStatus.saved,
      DraftSaveStatus.error,
    ]) {
      status.value = value;
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.getRect(find.byType(TextField)), bodyRect);
      expect(tester.getRect(more), moreRect);
      expect(find.text(S.current.composer_draftSaved), findsNothing);
      expect(
        find.byKey(const ValueKey('composer-draft-attention')),
        value == DraftSaveStatus.error ? findsOneWidget : findsNothing,
      );
    }
    tester.testTextInput.log.clear();
    await tester.tap(more);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.textContaining(S.current.composer_draftError), findsOneWidget);
    status.value = DraftSaveStatus.saved;
    await tester.pump();
    expect(find.text(S.current.composer_draftSaved), findsOneWidget);
    status.value = DraftSaveStatus.error;
    await tester.pump();
    final retry = find.byKey(const ValueKey('composer-draft-status-item'));
    expect(tester.getSize(retry).height, greaterThanOrEqualTo(48));
    await tester.tap(retry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(retries, 1);
    expect(focus.hasFocus, isTrue);
    expect(
      tester.testTextInput.log.where((call) => call.method == 'TextInput.hide'),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    status.dispose();
    focus.dispose();
  });

  for (final reduced in [false, true]) {
    testWidgets('窄屏大字体草稿菜单可读，尊重减少动态效果 reduced=$reduced', (tester) async {
      final status = ValueNotifier(DraftSaveStatus.saving);
      await _pump(
        tester,
        status,
        width: 320,
        scale: 2,
        reduced: reduced,
        onRetry: () {},
      );
      await tester.tap(find.byKey(const ValueKey('composer-header-more')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byType(CircularProgressIndicator),
        reduced ? findsNothing : findsOneWidget,
      );
      status.value = DraftSaveStatus.error;
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      expect(
        find.textContaining(S.current.composer_draftError),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      status.dispose();
    });
  }
}
