import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/settings/definitions/appearance_defs.dart';
import 'package:fluxdo/settings/settings_renderer.dart';
import 'package:fluxdo/theme/theme_registry.dart';
import 'package:fluxdo/theme/shape_presets.dart';
import 'package:fluxdo/theme/theme_resolver.dart';
import 'package:fluxdo/theme/theme_spec.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sectionIds = {
  'themePreview',
  'themeMode',
  'themeGallery',
  'themeOptions',
  'black',
  'shapePreset',
};

List<ThemeSpec> _loadAssets() => [
  for (final f
      in Directory('assets/themes').listSync().whereType<File>().where(
        (f) => f.path.endsWith('.json'),
      ))
    ThemeSpec.fromJson(
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
    ),
];

Widget _app(ProviderContainer container, {ThemeMode mode = ThemeMode.light}) {
  return UncontrolledProviderScope(
    container: container,
    child: TranslationProvider(
      child: Consumer(
        builder: (context, ref, _) {
          final state = ref.watch(themeProvider);
          final resolved = ThemeResolver.resolve(
            spec: state.themeSpec,
            mode: mode,
            black: state.blackEnabled,
            transparent: false,
            seed: state.effectiveSeedColor,
            variant: state.schemeVariant,
            accentId: state.accentFor(state.themeSpec),
          );
          final shapes = state.effectiveShapes;
          ThemeData data(ColorScheme scheme, colors) => ThemeData(
            colorScheme: scheme,
            // 截图导出时用真实字体，常规断言保持测试默认字体
            fontFamily: const String.fromEnvironment('THEME_PREVIEW_DIR').isEmpty
                ? null
                : 'MiSans',
            extensions: [colors, colors.render, shapes, shapes.render],
          );
          return MaterialApp(
            locale: const Locale('zh'),
            supportedLocales: AppLocaleUtils.supportedLocales,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            themeMode: mode,
            theme: data(resolved.light, resolved.lightColors),
            darkTheme: data(resolved.dark, resolved.darkColors),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  final items = buildAppearanceGroups(context)
                      .expand((g) => g.items)
                      .where((i) => _sectionIds.contains(i.id))
                      .where((i) => i.isVisible(ref))
                      .toList();
                  return RepaintBoundary(
                    key: const ValueKey('section'),
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        for (final item in items) SettingsRenderer(model: item),
                      ],
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    ),
  );
}

void main() {
  setUpAll(() => ThemeRegistry.setFixed(_loadAssets()));
  tearDownAll(() => ThemeRegistry.setFixed(const []));

  Future<ProviderContainer> container(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    final instance = await SharedPreferences.getInstance();
    return ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(instance)],
    );
  }

  testWidgets('画廊按分组列出主题，点卡片切换主题并显示对应子选项', (tester) async {
    tester.view.physicalSize = const Size(420, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = await container({});
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(c));
    await tester.pumpAndSettle();

    // 「终端」既是分组名也是主题名
    for (final group in ['取色', '经典配色', '阅读', '终端']) {
      expect(find.text(group), findsWidgets, reason: group);
    }
    // 同族合并成一张卡
    expect(find.text('Catppuccin'), findsOneWidget);
    expect(find.text('纸质'), findsOneWidget);
    // Material 下显示原有色板与配色风格
    expect(find.text('配色风格'), findsOneWidget);
    expect(find.text('口味'), findsNothing);

    await tester.tap(find.text('Catppuccin'));
    await tester.pumpAndSettle();
    expect(c.read(themeProvider).themeSpec.familyId, 'catppuccin');
    expect(find.text('口味'), findsOneWidget);
    expect(find.text('强调色'), findsOneWidget);
    expect(find.text('配色风格'), findsNothing);

    await tester.tap(find.text('Mocha'));
    await tester.pumpAndSettle();
    expect(c.read(themeProvider).themeId, 'catppuccin-mocha');

    await tester.tap(find.byTooltip('Peach'));
    await tester.pumpAndSettle();
    expect(c.read(themeProvider).themeAccents['catppuccin'], 'peach');
    expect(tester.takeException(), isNull);
  });

  testWidgets('纯黑开关只在当前主题支持时出现', (tester) async {
    tester.view.physicalSize = const Size(420, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = await container({'theme_id': 'paper'});
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(c));
    await tester.pumpAndSettle();
    expect(find.text('纯黑'), findsNothing);

    await c.read(themeProvider.notifier).setThemeId('terminal');
    await tester.pumpAndSettle();
    expect(find.text('纯黑'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('圆角风格：跟随主题显示主题推荐档，可指定与恢复跟随', (tester) async {
    tester.view.physicalSize = const Size(420, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = await container({'theme_id': 'terminal'});
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(c));
    await tester.pumpAndSettle();
    expect(find.text('跟随主题'), findsOneWidget);
    // 终端主题推荐方正：「跟随主题」下方标注 + 「方正」选项本身
    expect(find.text('方正'), findsNWidgets(2));
    expect(c.read(themeProvider).effectiveShapePreset, ShapePreset.sharp);

    await tester.tap(find.text('标准'));
    await tester.pumpAndSettle();
    expect(c.read(themeProvider).shapeOverride, ShapePreset.standard);

    await tester.tap(find.text('跟随主题'));
    await tester.pumpAndSettle();
    expect(c.read(themeProvider).shapeOverride, isNull);
    expect(tester.takeException(), isNull);
  });

  // 视觉自查：THEME_PREVIEW_DIR=<目录> 时导出明暗两张截图
  testWidgets('导出主题区块截图', (tester) async {
    const dir = String.fromEnvironment('THEME_PREVIEW_DIR');
    if (dir.isEmpty) return;
    await (FontLoader(
      'MiSans',
    )..addFont(rootBundle.load('assets/fonts/MiSansVF.ttf'))).load();
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final entry in manifest) {
      final family = entry['family'] as String;
      if (!family.contains('Material')) continue;
      final loader = FontLoader(family);
      for (final font in entry['fonts'] as List) {
        loader.addFont(rootBundle.load(font['asset'] as String));
      }
      await loader.load();
    }
    tester.view.physicalSize = const Size(840, 4000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    for (final (themeId, mode) in [
      ('catppuccin-mocha', ThemeMode.dark),
      ('paper', ThemeMode.light),
      ('terminal', ThemeMode.dark),
    ]) {
      final c = await container({'theme_id': themeId});
      await tester.pumpWidget(_app(c, mode: mode));
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('section')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '$dir/theme_section_$themeId.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
      c.dispose();
    }
  });
}
