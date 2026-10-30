import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_view_mode_switcher.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_header_actions.dart';

void main() {
  testWidgets('图标提交保留动作说明，加载时尺寸稳定且不可重复提交', (tester) async {
    final semantics = tester.ensureSemantics();
    var submitting = false;
    var calls = 0;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              appBar: AppBar(
                actions: [
                  ComposerHeaderActions(
                    availableWidth: 390,
                    submitLabel: '保存',
                    submitIcon: Symbols.check_rounded,
                    submitting: submitting,
                    onSubmit: () => setState(() {
                      calls++;
                      submitting = true;
                    }),
                    previewing: false,
                    onTogglePreview: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final button = find.byKey(const ValueKey('composer-header-submit'));
    final bounds = tester.getRect(button);
    expect(find.byTooltip('保存'), findsOneWidget);
    expect(find.byIcon(Symbols.check_rounded), findsOneWidget);
    expect(tester.getSemantics(button).label, '保存');
    await tester.tap(button);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.getRect(button), bounds);
    expect(tester.getSemantics(button).label, '保存');
    await tester.tap(button);
    expect(calls, 1);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (width, count, folded) in [
    (320.0, 1, 0),
    (320.0, 2, 2),
    (700.0, 2, 0),
    (390.0, 3, 2),
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
      expect(tester.getSize(send).height, 48, reason: '视觉变轻仍保留触控高度');
      expect(tester.getSize(surface), const Size.square(40));
      expect(tester.widget<Material>(surface).shape, isA<CircleBorder>());
      expect(find.byTooltip('发送'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is AppIcon && w.icon == AppIcons.paperPlane,
        ),
        findsOneWidget,
      );
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
    expect(
      find.byWidgetPredicate(
        (w) => w is AppIcon && w.icon == AppIcons.openBook,
      ),
      findsOneWidget,
    );
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
