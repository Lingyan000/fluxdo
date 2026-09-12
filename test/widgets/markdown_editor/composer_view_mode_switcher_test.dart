import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_view_mode_switcher.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_header_actions.dart';

void main() {
  for (final (width, count, folded) in [
    (320.0, 1, 0),
    (320.0, 2, 2),
    (700.0, 2, 0),
    (390.0, 3, 3),
    (420.0, 3, 2),
    (700.0, 3, 0),
  ]) {
    testWidgets('页头按空间收纳，菜单不出现单项 $width/$count', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 760);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            locale: const Locale('zh'),
            navigatorKey: navigatorKey,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: Scaffold(
              appBar: AppBar(
                leading: const CloseButton(),
                title: const Text('回复话题'),
                actions: [
                  ComposerHeaderActions(
                    availableWidth: width,
                    submitLabel: '发送',
                    onSubmit: () {},
                    previewing: false,
                    onTogglePreview: () {},
                    showDiscard: count >= 2,
                    onDiscard: () {},
                    reviewBuilder: count == 3
                        ? (builder) => builder(false, () {})
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final send = find.byKey(const ValueKey('composer-header-submit'));
      final surface = find.descendant(
        of: send,
        matching: find.byType(Material),
      );
      expect(tester.getSize(send).height, 44, reason: '视觉变轻仍保留触控高度');
      expect(tester.getSize(surface).height, 36);
      expect(tester.getSize(surface).width, greaterThanOrEqualTo(64));
      final more = find.byKey(const ValueKey('composer-header-more'));
      expect(more, folded == 0 ? findsNothing : findsOneWidget);
      if (folded > 0) {
        await tester.tap(more);
        await tester.pumpAndSettle();
        expect(
          find.byWidgetPredicate((widget) => widget is PopupMenuItem),
          findsNWidgets(folded),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('预览开关不改变源码模式，模式在独立入口切换', (tester) async {
    var rich = false;
    var preview = false;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          locale: const Locale('zh'),
          navigatorKey: navigatorKey,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: Column(
                children: [
                  ComposerPreviewButton(
                    previewing: preview,
                    onPressed: () => setState(() => preview = !preview),
                  ),
                  ComposerModeButton(
                    rich: rich,
                    onPressed: preview
                        ? null
                        : () => setState(() => rich = !rich),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      find.descendant(
        of: find.byType(ComposerModeButton),
        matching: find.byType(Text),
      ),
      findsNothing,
    );
    expect(find.byIcon(AppIcons.book), findsOneWidget);
    await tester.tap(find.byType(ComposerPreviewButton));
    await tester.pump();
    expect(preview, isTrue);
    expect(
      tester
          .widget<ComposerModeButton>(find.byType(ComposerModeButton))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byType(ComposerPreviewButton));
    await tester.pump();
    expect(rich, isFalse);
    await tester.tap(find.byType(ComposerModeButton));
    await tester.pump();
    expect(rich, isTrue);
  });
}
