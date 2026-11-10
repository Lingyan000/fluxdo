import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/fonts/font_catalog.dart';
import 'package:fluxdo/widgets/fonts/font_migration_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _misans = FontEntry(
  id: 'misans',
  family: 'MiSans',
  slot: FontSlot.body,
  name: {'zh': 'MiSans', 'en': 'MiSans'},
  license: 'MiSans',
  package: '@fontpkg/mi-sans-vf',
  version: '4.3.0',
  file: 'MiSans VF.ttf',
  size: 20000736,
  sha256: '0000000000000000000000000000000000000000000000000000000000000000',
  tarballSize: 1,
  tarballIntegrity: 'sha512-x',
);

void main() {
  setUp(() => FontCatalog.setAll(const [_misans]));
  tearDown(() => FontCatalog.setAll(const []));

  Future<ProviderContainer> pump(
    WidgetTester tester,
    Map<String, Object> values,
  ) async {
    LocaleSettings.setLocale(AppLocale.zh);
    SharedPreferences.setMockInitialValues(values);
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            locale: const Locale('zh'),
            supportedLocales: AppLocaleUtils.supportedLocales,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: TextButton(
                  onPressed: () => FontMigrationPrompt.maybeShow(context, ref),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('旧版选了 MiSans 且未下载时弹框，选系统字体后不再弹', (tester) async {
    final c = await pump(tester, {'font_family': 'miSans'});
    expect(find.text('需要下载 MiSans 字体'), findsOneWidget);

    await tester.tap(find.text('先用系统字体'));
    await tester.pumpAndSettle();
    expect(find.text('需要下载 MiSans 字体'), findsNothing);
    expect(c.read(themeProvider).bodyFont, FontChoice.system);
    final prefs = c.read(sharedPreferencesProvider);
    expect(prefs.getBool(FontMigrationPrompt.promptedKey), isTrue);

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('需要下载 MiSans 字体'), findsNothing);
  });

  testWidgets('没选过 MiSans 的用户不弹框', (tester) async {
    await pump(tester, {'font_family': 'system'});
    expect(find.text('需要下载 MiSans 字体'), findsNothing);
  });

  testWidgets('已改选其他字体的用户不弹框', (tester) async {
    await pump(tester, {'font_family': 'miSans', 'font_body': 'system'});
    expect(find.text('需要下载 MiSans 字体'), findsNothing);
  });
}
