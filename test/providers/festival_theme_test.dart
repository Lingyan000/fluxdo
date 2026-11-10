import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/settings/definitions/appearance_defs.dart';
import 'package:fluxdo/settings/settings_renderer.dart';
import 'package:fluxdo/theme/festival_calendar.dart';
import 'package:fluxdo/theme/shape_presets.dart';
import 'package:fluxdo/theme/theme_registry.dart';
import 'package:fluxdo/theme/theme_spec.dart';
import 'package:fluxdo/widgets/festival_greeting.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<ThemeSpec> _themes() => [
  for (final f in Directory(
    'assets/themes',
  ).listSync().whereType<File>().where((f) => f.path.endsWith('.json')))
    ThemeSpec.fromJson(
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
    ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ThemeRegistry.setFixed(_themes());
    FestivalCalendar.setAll(
      FestivalCalendar.parse(
        File(FestivalCalendar.assetPath).readAsStringSync(),
      ),
    );
    // 2026 年春节（2 月 17 日）期间
    FestivalCalendar.clock = () => DateTime(2026, 2, 18, 10);
  });

  tearDown(() {
    ThemeRegistry.setFixed(const []);
    FestivalCalendar.setAll(const []);
    FestivalCalendar.clock = DateTime.now;
  });

  Future<ThemeNotifier> load(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return ThemeNotifier(await SharedPreferences.getInstance());
  }

  test('节日开关打开时节日期间换上节日配色，圆角仍跟随用户主题', () async {
    final notifier = await load({
      'festival_enabled': true,
      'theme_id': 'terminal',
    });
    final state = notifier.state;
    expect(state.festival?.festival.id, 'spring');
    expect(state.activeFestival, isNotNull);
    expect(state.effectiveColorSpec.id, 'festival-spring');
    expect(state.themeSpec.id, 'terminal');
    expect(state.effectiveShapePreset, ShapePreset.sharp);
  });

  test('开关关闭或不在节日窗口时用用户主题', () async {
    final off = await load({'theme_id': 'paper'});
    expect(off.state.activeFestival, isNull);
    expect(off.state.effectiveColorSpec.id, 'paper');

    FestivalCalendar.clock = () => DateTime(2026, 7, 1);
    final outside = await load({'festival_enabled': true});
    expect(outside.state.festival, isNull);
    expect(outside.state.effectiveColorSpec.id, ThemeRegistry.materialId);
  });

  test('本次关闭只跳过这一次节日', () async {
    final notifier = await load({'festival_enabled': true});
    await notifier.skipCurrentFestival();
    expect(notifier.state.activeFestival, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('festival_skipped'), ['spring-20260217']);

    // 下一年的春节不受影响
    FestivalCalendar.clock = () => DateTime(2027, 2, 7);
    notifier.refreshFestival();
    expect(notifier.state.activeFestival?.key, startsWith('spring-2027'));
  });

  test('节日期间手动换主题视为本次跳过', () async {
    final notifier = await load({'festival_enabled': true});
    await notifier.setThemeId('nord');
    expect(notifier.state.activeFestival, isNull);
    expect(notifier.state.effectiveColorSpec.id, 'nord');
  });

  test('跨日重新判定：窗口结束后恢复用户主题', () async {
    final notifier = await load({'festival_enabled': true});
    expect(notifier.state.activeFestival, isNotNull);
    FestivalCalendar.clock = () => DateTime(2026, 2, 24);
    notifier.refreshFestival();
    expect(notifier.state.activeFestival, isNull);
  });

  group('界面', () {
    Future<ProviderContainer> pump(
      WidgetTester tester,
      Map<String, Object> values,
    ) async {
      LocaleSettings.setLocale(AppLocale.zh);
      SharedPreferences.setMockInitialValues(values);
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(c.dispose);
      tester.view.physicalSize = const Size(480, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
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
                body: Consumer(
                  builder: (context, ref, _) => ListView(
                    children: [
                      for (final item
                          in buildAppearanceSearchGroups(context)
                              .expand((g) => g.items)
                              .where(
                                (i) => {
                                  'festivalBanner',
                                  'festivalEnabled',
                                  'festivalGreeting',
                                }.contains(i.id),
                              )
                              .where((i) => i.isVisible(ref)))
                        SettingsRenderer(model: item),
                      TextButton(
                        onPressed: () =>
                            FestivalGreeting.maybeShow(context, ref),
                        child: const Text('greet'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('节日生效时显示横幅，本次关闭后横幅消失', (tester) async {
      final c = await pump(tester, {'festival_enabled': true});
      expect(find.textContaining('春节主题生效中'), findsOneWidget);
      await tester.tap(find.text('本次关闭'));
      await tester.pumpAndSettle();
      expect(find.textContaining('春节主题生效中'), findsNothing);
      expect(c.read(themeProvider).activeFestival, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('开关关闭时无横幅，节日问候开关隐藏', (tester) async {
      await pump(tester, {});
      expect(find.textContaining('主题生效中'), findsNothing);
      expect(find.text('节日主题'), findsOneWidget);
      expect(find.text('节日问候'), findsNothing);
    });

    testWidgets('问候只出现一次', (tester) async {
      final c = await pump(tester, {'festival_enabled': true});
      await tester.tap(find.text('greet'));
      await tester.pump();
      final prefs = c.read(sharedPreferencesProvider);
      expect(prefs.getStringList(FestivalGreeting.greetedKey), [
        'spring-20260217',
      ]);
      await tester.tap(find.text('greet'));
      await tester.pump();
      expect(prefs.getStringList(FestivalGreeting.greetedKey), [
        'spring-20260217',
      ]);
      // 等提示自动消失，避免残留计时器
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
    });
  });
}
