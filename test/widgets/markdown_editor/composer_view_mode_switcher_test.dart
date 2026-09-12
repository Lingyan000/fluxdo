import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_view_mode_switcher.dart';

void main() {
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
