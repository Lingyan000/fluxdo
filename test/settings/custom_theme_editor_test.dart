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
import 'package:fluxdo/theme/theme_resolver.dart';
import 'package:fluxdo/theme/theme_spec.dart';
import 'package:fluxdo/theme/shape_presets.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/preview_fonts.dart';

Finder _choice(String label) => find.byWidgetPredicate(
  (widget) =>
      widget is Semantics &&
      widget.properties.button == true &&
      widget.properties.label == label,
);

List<ThemeSpec> _themes() => [
  for (final f in Directory(
    'assets/themes',
  ).listSync().whereType<File>().where((f) => f.path.endsWith('.json')))
    ThemeSpec.fromJson(
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
    ),
];

void main() {
  String? clipboard;

  setUp(() {
    ThemeRegistry.setFixed(_themes());
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              clipboard = (call.arguments as Map)['text'] as String?;
              return null;
            case 'Clipboard.getData':
              return clipboard == null ? null : {'text': clipboard};
          }
          return null;
        });
  });

  tearDown(() {
    ThemeRegistry.setFixed(const []);
    ThemeRegistry.setCustom(const []);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  const previewDir = String.fromEnvironment('THEME_PREVIEW_DIR');

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
    bool preview = false,
  }) async {
    tester.view.physicalSize = preview
        ? const Size(840, 2000)
        : const Size(480, 3200);
    tester.view.devicePixelRatio = preview ? 2 : 1;
    addTearDown(tester.view.reset);
    LocaleSettings.setLocale(AppLocale.zh);
    SharedPreferences.setMockInitialValues(prefs);
    final instance = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(instance)],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: TranslationProvider(
          child: Consumer(
            builder: (context, ref, _) {
              final state = ref.watch(themeProvider);
              final resolved = ThemeResolver.resolve(
                spec: state.effectiveColorSpec,
                mode: ThemeMode.dark,
                black: false,
                transparent: false,
                seed: state.effectiveSeedColor,
                variant: state.schemeVariant,
                accentId: state.accentFor(state.effectiveColorSpec),
              );
              return RepaintBoundary(
                key: const ValueKey('app'),
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  themeMode: ThemeMode.dark,
                  darkTheme: ThemeData(
                    colorScheme: resolved.dark,
                    fontFamily: previewDir.isEmpty ? null : 'MiSans',
                    extensions: [resolved.darkColors],
                  ),
                  locale: const Locale('zh'),
                  supportedLocales: AppLocaleUtils.supportedLocales,
                  localizationsDelegates: const [
                    GlobalMaterialLocalizations.delegate,
                    GlobalWidgetsLocalizations.delegate,
                    GlobalCupertinoLocalizations.delegate,
                  ],
                  home: Scaffold(
                    body: Builder(
                      builder: (context) => ListView(
                        children: [
                          for (final item
                              in buildAppearanceSearchGroups(context)
                                  .expand((g) => g.items)
                                  .where((i) => i.id == 'themeGallery'))
                            SettingsRenderer(model: item),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets('新建主题：通过按钮组切换明暗和圆角，保存后自动选中', (tester) async {
    final c = await pump(tester);
    expect(find.text('我的主题'), findsOneWidget);
    await tester.tap(_choice('新建主题'));
    await tester.pumpAndSettle();

    expect(find.text('编辑主题'), findsOneWidget);
    // 底稿名默认为「当前主题 副本」
    expect(find.text('Material 副本'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '晨雾');
    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<M3eButtonGroup<Brightness>>(
            find.byType(M3eButtonGroup<Brightness>),
          )
          .selected,
      Brightness.light,
    );
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<M3eButtonGroup<Brightness>>(
            find.byType(M3eButtonGroup<Brightness>),
          )
          .selected,
      Brightness.dark,
    );
    await tester.ensureVisible(find.text('方正'));
    await tester.tap(find.text('方正'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final state = c.read(themeProvider);
    expect(state.customThemes.single.name['zh'], '晨雾');
    expect(state.customThemes.single.shape, ShapePreset.sharp);
    expect(state.themeId, state.customThemes.single.id);
    expect(find.text('晨雾'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按自定义主题可复制代码与删除', (tester) async {
    final c = await pump(tester);
    await tester.tap(_choice('新建主题'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '待删');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    await tester.longPress(_choice('待删'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制主题代码'));
    await tester.pumpAndSettle();
    expect(jsonDecode(clipboard!)['name']['zh'], '待删');

    await tester.longPress(_choice('待删'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(c.read(themeProvider).customThemes, isEmpty);
    expect(c.read(themeProvider).themeId, ThemeRegistry.materialId);
    // 等提示自动消失，避免残留计时器
    await tester.pump(const Duration(seconds: 6));
  });

  // 视觉自查：THEME_PREVIEW_DIR=<目录> 时导出编辑器截图
  testWidgets('导出编辑器截图', (tester) async {
    if (previewDir.isEmpty) return;
    await tester.runAsync(() async {
      await loadPreviewCjkFont();
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
    });
    await pump(tester, prefs: {'theme_id': 'catppuccin-mocha'}, preview: true);
    await tester.ensureVisible(find.text('新建主题'));
    await tester.pumpAndSettle();
    await tester.tap(_choice('新建主题'));
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('app')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$previewDir/theme_editor.png')
          .writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.scrollUntilVisible(
      find.byType(M3eButtonGroup<ShapePreset>),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$previewDir/theme_editor_shape.png')
          .writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });

  testWidgets('从剪贴板导入主题代码', (tester) async {
    final c = await pump(tester);
    clipboard = File('assets/themes/gruvbox.json').readAsStringSync();
    await tester.tap(find.text('从剪贴板导入'));
    await tester.pumpAndSettle();
    expect(c.read(themeProvider).customThemes.single.group, ThemeGroup.custom);
    await tester.pump(const Duration(seconds: 6));

    clipboard = 'not a theme';
    await tester.tap(find.text('从剪贴板导入'));
    await tester.pumpAndSettle();
    expect(c.read(themeProvider).customThemes, hasLength(1));
    await tester.pump(const Duration(seconds: 6));
  });
}
