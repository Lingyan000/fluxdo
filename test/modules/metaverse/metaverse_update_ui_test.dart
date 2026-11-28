import 'dart:io';
import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/modules/metaverse/market/metaverse_update_page.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_update_provider.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_update_store.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_market_provider.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/providers/metaverse_plugin_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/theme/app_colors.dart';
import 'package:fluxdo/theme/app_theme.dart';

import '../../helpers/preview_fonts.dart';
import 'metaverse_auto_update_test.dart'
    show updatePackage, updateSource, updateEntry;

class _UpdateUiState extends MetaverseUpdatesController {
  @override
  Future<MetaverseUpdateState> build() async => MetaverseUpdateState(
    lastCheck: DateTime(2026, 11, 20, 10).millisecondsSinceEpoch,
    nextCheck: DateTime(2026, 11, 21, 10).millisecondsSinceEpoch,
    reports: {
      'example.updates': {
        'status': 'review',
        'version': '1.1.0',
        'source': updateSource.id,
      },
    },
  );
  @override
  Future<void> setFrequency(MetaverseUpdateFrequency value) async {
    final previous = state.requireValue;
    state = AsyncData(
      MetaverseUpdateState(
        frequency: value,
        reports: previous.reports,
        excluded: previous.excluded,
      ),
    );
  }

  @override
  Future<void> setAllowed(InstalledMetaversePlugin plugin, bool allowed) async {
    final previous = state.requireValue;
    state = AsyncData(
      MetaverseUpdateState(
        frequency: previous.frequency,
        reports: previous.reports,
        excluded: allowed ? {} : {MetaverseUpdateState.keyFor(plugin)},
      ),
    );
  }
}

class _UpdateUiPlugins extends MetaversePluginsController {
  @override
  List<InstalledMetaversePlugin> build() => [
    InstalledMetaversePlugin(
      manifest: updatePackage('1.0.0').manifest,
      source: updateSource.id,
      enabled: true,
    ),
  ];
}

class _UpdateUiMarket extends MetaverseMarketController {
  @override
  Future<void> refresh({bool force = false}) async {}
  @override
  MetaverseMarketState build() => MetaverseMarketState(
    sources: [updateSource],
    entries: [updateEntry(updatePackage('1.1.0', expanded: true))],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const snapshots = bool.fromEnvironment('PLUGIN_SNAPSHOTS');
  late SharedPreferences prefs;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    if (!snapshots) return;
    expect(await loadPreviewCjkFont(), isTrue);
    await (FontLoader('packages/material_symbols_icons/MaterialSymbolsRounded')
          ..addFont(
            rootBundle.load(
              'packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf',
            ),
          ))
        .load();
  });
  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.4]) {
      testWidgets('自动更新设置与频率弹框，小屏明暗和大字 $dark $scale', (tester) async {
        tester.view.physicalSize = Size(scale > 1 ? 320 : 390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final boundary = GlobalKey();
        final brightness = dark ? Brightness.dark : Brightness.light;
        final theme = buildAppTheme(
          ColorScheme.fromSeed(
            seedColor: Colors.indigo,
            brightness: brightness,
          ),
          AppColors.material(brightness),
          UiShapes.standard,
          const ThemeState(mode: ThemeMode.system, seedColor: Colors.indigo),
          fullscreenSwipeBack: false,
          pageBackground: false,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              metaverseUpdatesProvider.overrideWith(_UpdateUiState.new),
              metaversePluginsProvider.overrideWith(_UpdateUiPlugins.new),
              metaverseMarketProvider.overrideWith(_UpdateUiMarket.new),
              metaverseUpdateDriverProvider.overrideWithValue(null),
            ],
            child: RepaintBoundary(
              key: boundary,
              child: TranslationProvider(
                child: MaterialApp(
                  navigatorKey: navigatorKey,
                  theme: snapshots
                      ? theme.copyWith(
                          textTheme: theme.textTheme.apply(
                            fontFamily: 'MiSans',
                          ),
                        )
                      : theme,
                  debugShowCheckedModeBanner: false,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: const MetaverseUpdatePage(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        Future<void> capture(String name) async {
          if (!snapshots) return;
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            image.dispose();
            await Directory('build/plugin-update-ui').create(recursive: true);
            await File('build/plugin-update-ui/$name.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
          });
        }

        await capture('settings-$dark-$scale');
        await tester.tap(find.text(S.current.metaverse_updateFrequency));
        await tester.pumpAndSettle();
        expect(find.text(S.current.metaverse_updateWeekly), findsOneWidget);
        expect(find.byIcon(Symbols.check_rounded), findsOneWidget);
        await capture('frequency-$dark-$scale');
        await tester.tap(find.text(S.current.metaverse_updateWeekly));
        await tester.pumpAndSettle();
        expect(find.text(S.current.metaverse_updateWeekly), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('更新测试'),
          150,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('更新测试'));
        await tester.pumpAndSettle();
        expect(find.text(S.current.metaverse_updateExcluded), findsOneWidget);
        expect(tester.takeException(), isNull);
        await capture('plugin-$dark-$scale');
      });
    }
  }
}
