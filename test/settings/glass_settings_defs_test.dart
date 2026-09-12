import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/settings/definitions/appearance_defs.dart';
import 'package:fluxdo/settings/definitions/bottom_nav_defs.dart';
import 'package:fluxdo/settings/settings_renderer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('外观玻璃档位可选，关闭总开关后禁用但保留选择', (tester) async {
    SharedPreferences.setMockInitialValues({});
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
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  final groups = buildAppearanceGroups(context);
                  final group = groups.firstWhere(
                    (g) => g.items.any((i) => i.id == 'glassEnabled'),
                  );
                  expect(
                    groups
                        .expand((g) => g.items)
                        .any((i) => i.id == 'dialogBlur'),
                    isTrue,
                  );
                  final bottomItems = buildBottomNavGroups(
                    context,
                  ).expand((g) => g.items).toList();
                  expect(
                    bottomItems.any((i) => i.id == 'bottomNavFloatingBlur'),
                    isFalse,
                  );
                  expect(
                    bottomItems.any((i) => i.id == 'glassSettings'),
                    isTrue,
                  );
                  return ListView(
                    children: [
                      for (final item in group.items)
                        SettingsRenderer(model: item),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RadioListTile<GlassEffectLevel>), findsNWidgets(3));
    await tester.tap(find.text('基础磨砂'));
    await tester.pumpAndSettle();
    expect(
      container.read(preferencesProvider).glassEffectLevel,
      GlassEffectLevel.basic,
    );
    await container.read(preferencesProvider.notifier).setGlassEnabled(false);
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<RadioListTile<GlassEffectLevel>>(
            find.byType(RadioListTile<GlassEffectLevel>),
          )
          .every((tile) => tile.enabled == false),
      isTrue,
    );
    expect(
      container.read(preferencesProvider).glassEffectLevel,
      GlassEffectLevel.basic,
    );
    expect(tester.takeException(), isNull);
  });
}
