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
import 'package:fluxdo/pages/appearance_page.dart';
import 'package:fluxdo/pages/preferences_page.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/app_icon_provider.dart';
import 'package:fluxdo/settings/definitions/appearance_defs.dart';
import 'package:fluxdo/settings/settings_model.dart';
import 'package:fluxdo/settings/settings_renderer.dart';
import 'package:fluxdo/settings/search/settings_search_index.dart';
import 'package:fluxdo/theme/theme_registry.dart';
import 'package:fluxdo/theme/theme_resolver.dart';
import 'package:fluxdo/theme/theme_spec.dart';
import 'package:fluxdo/theme/shape_presets.dart';
import 'package:fluxdo/widgets/common/app_background_layer.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/preview_fonts.dart';

const _previewDir = String.fromEnvironment('APPEARANCE_PREVIEW_DIR');

void _expectAlignedShapes(WidgetTester tester) {
  final l10n = tester.element(find.byType(AppearancePage)).l10n;
  final labels = [
    l10n.appearance_shapeFollow,
    l10n.appearance_shapeStandard,
    l10n.appearance_shapeCompact,
    l10n.appearance_shapeSharp,
  ];
  final rects = [
    for (final label in labels)
      tester.getRect(
        find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.label == label,
        ),
      ),
  ];
  for (final rect in rects.skip(1)) {
    expect(rect.top, closeTo(rects.first.top, 0.01));
    expect(rect.height, closeTo(rects.first.height, 0.01));
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  Map<String, Object> values = const {},
  String? highlightId,
  Size size = const Size(390, 844),
  double textScale = 1,
  bool english = false,
  bool iconPreview = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final imagePath = values['bg_image_path'] as String?;
  if (imagePath != null || iconPreview) {
    // 文件图片先在真实异步区完成解码，避免测试假时钟只绘制空白占位。
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    final context = tester.element(find.byType(MaterialApp));
    await tester.runAsync(() async {
      if (imagePath != null) {
        await precacheImage(FileImage(File(imagePath)), context);
        if (!context.mounted) return;
        await precacheImage(
          ResizeImage(
            FileImage(File(imagePath)),
            width: size.longestSide.clamp(0, 4096).round(),
          ),
          context,
        );
      }
      if (iconPreview) {
        for (final name in [
          'icon_default_preview',
          'icon_default_dark_preview',
          'icon_modern_light_preview',
          'icon_modern_preview',
        ]) {
          if (!context.mounted) return;
          await precacheImage(AssetImage('assets/images/$name.png'), context);
        }
      }
    });
  }
  LocaleSettings.setLocale(english ? AppLocale.en : AppLocale.zh);
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
        child: Consumer(
          builder: (context, ref, _) {
            final state = ref.watch(themeProvider);
            final resolved = ThemeResolver.resolve(
              spec: state.effectiveColorSpec,
              mode: state.mode,
              black: state.blackEnabled,
              seed: state.effectiveSeedColor,
              variant: state.schemeVariant,
              accentId: state.accentFor(state.effectiveColorSpec),
            );
            ThemeData data(bool dark) {
              final colors = dark ? resolved.darkColors : resolved.lightColors;
              final shapes = state.effectiveShapes;
              return ThemeData(
                colorScheme: dark ? resolved.dark : resolved.light,
                scaffoldBackgroundColor: state.isTransparentActive
                    ? Colors.transparent
                    : null,
                fontFamily: _previewDir.isEmpty ? null : 'MiSans',
                extensions: [
                  colors,
                  colors.render,
                  shapes,
                  shapes.render,
                  M3eFlags(enabled: state.m3eEnabled),
                ],
              );
            }

            return MaterialApp(
              locale: Locale(english ? 'en' : 'zh'),
              supportedLocales: AppLocaleUtils.supportedLocales,
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              themeMode: state.mode,
              theme: data(false),
              darkTheme: data(true),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: RepaintBoundary(
                  key: const ValueKey('appearance-screen'),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (state.isTransparentActive)
                        AppBackgroundLayer(background: state.background),
                      child!,
                    ],
                  ),
                ),
              ),
              home: iconPreview
                  ? Scaffold(
                      appBar: AppBar(title: const Text('应用图标')),
                      body: Builder(
                        builder: (context) {
                          // 图标入口仅在移动端显示，直接验证同一模型的实际内容。
                          final model =
                              buildAppearanceSearchGroups(context)
                                      .expand((group) => group.items)
                                      .firstWhere(
                                        (item) => item.id == 'appIcon',
                                      )
                                  as PlatformConditionalModel;
                          return Padding(
                            padding: const EdgeInsets.all(16),
                            child: SettingsRenderer(model: model.inner),
                          );
                        },
                      ),
                    )
                  : AppearancePage(highlightId: highlightId),
            );
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<String> _background(WidgetTester tester) async {
  final temp = Directory.systemTemp.createTempSync('appearance_background_');
  final file = File('${temp.path}/preview.png');
  await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const bounds = Rect.fromLTWH(0, 0, 240, 320);
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xff669da0), Color(0xffb88471), Color(0xffb9bb93)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(bounds),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(240, 320);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    file.writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
  });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await tester.runAsync(() async {
      await file.delete();
      await temp.delete();
    });
  });
  return file.path;
}

void main() {
  setUp(() {
    ThemeRegistry.setFixed([
      for (final file in Directory(
        'assets/themes',
      ).listSync().whereType<File>())
        if (file.path.endsWith('.json'))
          ThemeSpec.fromJson(
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
          ),
    ]);
  });
  tearDown(() {
    ThemeRegistry.setFixed(const []);
    ThemeRegistry.setCustom(const []);
  });

  testWidgets('主页面保留预览和快捷主题，完整画廊在独立入口内', (tester) async {
    final container = await _pump(tester);
    _expectAlignedShapes(tester);
    expect(find.text('让阅读更合你的习惯'), findsOneWidget);
    expect(find.text('经典配色'), findsNothing);
    expect(find.text('字体下载源'), findsNothing);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(
      position.maxScrollExtent + position.viewportDimension,
      lessThan(1350),
    );
    await tester.tap(find.byKey(const ValueKey('quick-theme-catppuccin')));
    await tester.pumpAndSettle();
    expect(container.read(themeProvider).themeSpec.familyId, 'catppuccin');
    await tester.tap(find.text('全部主题'));
    await tester.pumpAndSettle();
    expect(find.byType(AppearanceSectionPage), findsOneWidget);
    expect(find.text('经典配色'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('新建主题'),
      400,
      scrollable: find.byType(Scrollable).last,
    );
    final l10n = tester.element(find.byType(AppearanceSectionPage)).l10n;
    expect(find.text(l10n.appearance_customThemeImport), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('预览卡片仅在用户确认切换成功后震动', (tester) async {
    final feedback = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        feedback.add(call.arguments as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final container = await _pump(tester);
    final card = find.byKey(const ValueKey('quick-theme-catppuccin'));
    final gesture = await tester.startGesture(tester.getCenter(card));
    await tester.pump(const Duration(milliseconds: 150));
    expect(feedback, isEmpty);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(feedback, isEmpty);
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(container.read(themeProvider).themeSpec.familyId, 'catppuccin');
    expect(feedback, ['HapticFeedbackType.selectionClick']);
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(feedback, hasLength(1));
    await container.read(themeProvider.notifier).setThemeId('nord');
    await tester.pumpAndSettle();
    expect(feedback, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换主题后顶部预览显示当前选择，快捷卡片位置保持不变', (tester) async {
    final container = await _pump(tester);
    const families = ['material', 'catppuccin', 'nord'];
    Finder card(String family) => find.byKey(ValueKey('quick-theme-$family'));
    void expectCurrent(String name) {
      expect(
        find.descendant(of: find.byTooltip(name), matching: find.text(name)),
        findsOneWidget,
      );
    }

    expectCurrent('Material');
    final positions = {
      for (final family in families) family: tester.getTopLeft(card(family)),
    };
    for (final family in ['catppuccin', 'nord', 'material']) {
      await tester.tap(card(family));
      await tester.pumpAndSettle();
      expect(container.read(themeProvider).themeSpec.familyId, family);
      for (final family in families) {
        expect(tester.getTopLeft(card(family)), positions[family]);
      }
    }
    for (final (id, name) in [
      ('paper', '纸质'),
      ('catppuccin-macchiato', 'Catppuccin · Macchiato'),
    ]) {
      await container.read(themeProvider.notifier).setThemeId(id);
      await tester.pumpAndSettle();
      expectCurrent(name);
      for (final family in families) {
        expect(tester.getTopLeft(card(family)), positions[family]);
      }
    }
    await tester.tap(card('catppuccin'));
    await tester.pumpAndSettle();
    expect(container.read(themeProvider).themeId, 'catppuccin-macchiato');

    // 从图库选择自定义主题并返回，外层仍能识别当前选择。
    final custom = ThemeRegistry.byId('paper').copyWith(
      id: 'custom-summary',
      name: {'zh': '晨雾'},
      group: ThemeGroup.custom,
    );
    await container.read(themeProvider.notifier).saveCustomTheme(custom);
    await tester.tap(find.text('全部主题'));
    await tester.pumpAndSettle();
    final choice = find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.label == '晨雾',
    );
    await tester.scrollUntilVisible(
      choice,
      400,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(choice);
    await tester.pumpAndSettle();
    expect(container.read(themeProvider).themeId, custom.id);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expectCurrent('晨雾');
    for (final family in families) {
      expect(tester.getTopLeft(card(family)), positions[family]);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('应用图标完整显示，切换前后卡片与名称保持对齐', (tester) async {
    final container = await _pump(
      tester,
      iconPreview: true,
      size: const Size(320, 320),
    );
    void expectIconsFit() {
      final icons = find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName.contains('icon_'),
      );
      expect(icons, findsNWidgets(2));
      for (final icon in icons.evaluate()) {
        final finder = find.byWidget(icon.widget);
        final frame = find
            .ancestor(of: finder, matching: find.byType(ClipRSuperellipse))
            .first;
        final rect = tester.getRect(finder);
        final bounds = tester.getRect(frame);
        expect(rect.width, closeTo(rect.height, 0.01));
        expect(rect.top - bounds.top, greaterThanOrEqualTo(8));
        expect(bounds.bottom - rect.bottom, greaterThanOrEqualTo(8));
        expect(rect.left - bounds.left, greaterThanOrEqualTo(8));
        expect(bounds.right - rect.right, greaterThanOrEqualTo(8));
      }
      final classic = tester.getRect(find.text('经典'));
      final modern = tester.getRect(find.text('现代'));
      expect(classic.top, modern.top);
      expect(classic.height, modern.height);
    }

    expectIconsFit();
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.label == '现代',
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(appIconProvider).currentStyle, AppIconStyle.modern);
    expectIconsFit();
    expect(tester.takeException(), isNull);
  });

  testWidgets('语言迁至偏好且详情搜索和旧入口仍能定位', (tester) async {
    await _pump(tester);
    final context = tester.element(find.byType(AppearancePage));
    final results = buildSearchIndex(context);
    final language = results.singleWhere((item) => item.model.id == 'language');
    expect(
      language.pageBuilder(highlightId: 'language'),
      isA<PreferencesPage>(),
    );
    final font = results.singleWhere((item) => item.model.id == 'fontBody');
    expect(
      (font.pageBuilder(
        highlightId: 'fontBody',
      ) as AppearanceSectionPage).section,
      AppearanceSection.fonts,
    );
    expect(find.text('语言 / Language'), findsNothing);
    await _pump(tester, highlightId: 'glassEnabled');
    expect(find.text('背景与效果'), findsOneWidget);
    final l10n = tester.element(find.byType(AppearanceSectionPage)).l10n;
    expect(
      find.widgetWithText(M3eSwitchListTile, l10n.appearance_glassEnabled),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('背景图使用统一开关，关闭再开启保留图片及两套遮罩参数', (tester) async {
    final imagePath = await _background(tester);
    final container = await _pump(
      tester,
      highlightId: 'customBackground',
      values: {
        'theme_transparent': true,
        'bg_image_path': imagePath,
        'bg_scrim_light': 0.25,
        'bg_scrim_dark': 0.65,
      },
    );
    expect(find.byType(AppBackgroundLayer), findsNWidgets(2));
    final tile = find.widgetWithText(M3eSwitchListTile, '显示背景图');
    expect(tile, findsOneWidget);
    expect(
      find.descendant(of: tile, matching: find.byType(M3eSwitch)),
      findsOneWidget,
    );
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(container.read(themeProvider).transparentEnabled, isFalse);
    expect(find.byType(AppBackgroundLayer), findsNothing);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    final state = container.read(themeProvider);
    expect(state.transparentEnabled, isTrue);
    expect(state.background.imagePath, imagePath);
    expect(state.background.scrimLight, 0.25);
    expect(state.background.scrimDark, 0.65);
    await container.read(themeProvider.notifier).setM3eEnabled(false);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SwitchListTile, '显示背景图'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字体和宽屏布局无溢出', (tester) async {
    for (final configuration in [
      (320.0, 1.6, false),
      (360.0, 1.5, true),
      (1100.0, 1.0, false),
    ]) {
      await _pump(
        tester,
        size: Size(configuration.$1, 1200),
        textScale: configuration.$2,
        english: configuration.$3,
      );
      final scrollable = find.byType(Scrollable).first;
      await tester.drag(scrollable, const Offset(0, -900));
      await tester.pumpAndSettle();
      _expectAlignedShapes(tester);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('导出外观页和透明背景预览', (tester) async {
    if (_previewDir.isEmpty) return;
    await loadPreviewCjkFont();
    final monoFont = Platform.environment['PREVIEW_MONO_FONT'];
    if (monoFont != null && File(monoFont).existsSync()) {
      final bytes = File(monoFont).readAsBytesSync();
      await (FontLoader(
        'monospace',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final entry in manifest) {
      if (!(entry['family'] as String).contains('Material')) continue;
      final loader = FontLoader(entry['family'] as String);
      for (final font in entry['fonts'] as List) {
        loader.addFont(rootBundle.load(font['asset'] as String));
      }
      await loader.load();
    }
    final background = await _background(tester);
    Future<void> capture(String name) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('appearance-screen')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$_previewDir/appearance_$name.png')
            .writeAsBytesSync(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    for (final sample in [
      'main',
      'dark',
      'paper',
      'catppuccin',
      'transparent',
      'transparent_main',
      'icons',
    ]) {
      await _pump(
        tester,
        size: Size(430, sample == 'icons' ? 240 : 1250),
        iconPreview: sample == 'icons',
        highlightId: sample == 'transparent' ? 'customBackground' : null,
        values: sample.startsWith('transparent')
            ? {
                'theme_transparent': true,
                'bg_image_path': background,
                'bg_scrim_light': 0.25,
                'bg_scrim_dark': 0.35,
                'theme_mode': 'dark',
              }
            : {
                if (sample == 'dark') 'theme_mode': 'dark',
                if (sample == 'paper') 'theme_id': 'paper',
                if (sample == 'catppuccin') 'theme_id': 'catppuccin-macchiato',
              },
      );
      await capture(sample);
      if (sample == 'main') {
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('quick-theme-material'))),
        );
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump(const Duration(milliseconds: 80));
        await capture('theme_pressed');
        await gesture.up();
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(AppearancePage));
        final dot = find.byTooltip(context.l10n.appearance_modeAuto);
        final colorGesture = await tester.startGesture(tester.getCenter(dot));
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump(const Duration(milliseconds: 80));
        await capture('accent_pressed');
        await colorGesture.up();
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    }
  });
}
