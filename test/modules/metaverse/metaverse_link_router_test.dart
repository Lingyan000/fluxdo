import 'dart:io';
import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/constants.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/theme/app_colors.dart';
import 'package:fluxdo/theme/app_theme.dart';
import 'package:fluxdo/modules/metaverse/core/metaverse_link_rule.dart';
import 'package:fluxdo/modules/metaverse/metaverse_link_router.dart';
import 'package:fluxdo/modules/metaverse/metaverse_registry.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_service.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_permission.dart';
import 'package:fluxdo/modules/metaverse/plugin/providers/metaverse_plugin_providers.dart';

import 'metaverse_auto_update_test.dart' show updateManifest;
import '../../helpers/preview_fonts.dart';

class _Plugins extends MetaversePluginsController {
  @override
  List<InstalledMetaversePlugin> build() => [];
  void change(List<InstalledMetaversePlugin> plugins) => state = plugins;
}

class _Service extends MetaversePluginService {
  _Service(super.plugin, this.opened);
  final List<String> opened;
  @override
  Future<void> openPage(
    BuildContext context,
    String page,
    Map<String, Object?> params,
  ) async {
    opened.add(id);
  }
}

InstalledMetaversePlugin _plugin(String id, {String host = 'example.org'}) =>
    InstalledMetaversePlugin(
      manifest: MetaversePluginManifest.parse({
        ...updateManifest('1.0.0'),
        'id': id,
        'name': id,
        'links': [
          {'host': host, 'path': '/items/:id', 'page': 'home'},
        ],
      }),
      source: 'https://example.org/index.json',
      enabled: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const snapshots = bool.fromEnvironment('PLUGIN_SNAPSHOTS');
  setUpAll(() async {
    if (!snapshots) return;
    expect(await loadPreviewCjkFont(), isTrue);
    final icon = Symbols.extension_rounded;
    await (FontLoader(
          'packages/${icon.fontPackage}/${icon.fontFamily}',
        )..addFont(
          rootBundle.load(
            'packages/${icon.fontPackage}/lib/fonts/MaterialSymbolsRounded.ttf',
          ),
        ))
        .load();
  });
  late ProviderContainer container;
  late _Plugins plugins;
  final opened = <String>[];
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        metaversePluginsProvider.overrideWith(_Plugins.new),
        metaverseServicesProvider.overrideWith(
          (ref) => [
            for (final p in ref.watch(metaversePluginsProvider))
              _Service(p, opened),
          ],
        ),
      ],
    );
    plugins = container.read(metaversePluginsProvider.notifier) as _Plugins;
    opened.clear();
  });
  tearDown(() => container.dispose());
  final uri = Uri.parse('https://example.org/items/42');

  test('静态匹配覆盖空、单、多候选且不允许第三方接管论坛内链', () {
    expect(matchAllMetaverseLinks(container, uri), isEmpty);
    plugins.change([_plugin('example.one'), _plugin('example.two')]);
    final matches = matchAllMetaverseLinks(container, uri);
    expect(matches.map((m) => m.service.id), ['example.one', 'example.two']);
    expect(matches.first.params, {'id': '42'});
    plugins.change([
      _plugin('example.forum', host: Uri.parse(AppConstants.baseUrl).host),
    ]);
    expect(
      matchAllMetaverseLinks(
        container,
        Uri.parse('${AppConstants.baseUrl}/items/42'),
      ),
      isEmpty,
    );
    expect(
      MetaverseHostPattern.overlaps('*.example.org', 'img.example.org'),
      isTrue,
    );
    expect(
      MetaverseHostPattern.overlaps('*.example.org', 'example.org'),
      isFalse,
    );
    expect(
      MetaverseHostPattern.overlaps('*.a.example.org', '*.example.org'),
      isTrue,
    );
    expect(
      MetaverseHostPattern.overlaps('a.example.org', 'b.example.org'),
      isFalse,
    );
  });

  for (final change in ['disabled', 'removed', 'permission']) {
    test('记住的插件在 $change 时清理，恢复后不重新接管', () async {
      final a = _plugin('example.one'), b = _plugin('example.two');
      plugins.change([a, b]);
      await container
          .read(metaverseLinkDefaultsProvider.notifier)
          .remember(uri.host, a.id);
      plugins.change([
        if (change != 'removed')
          a.copyWith(
            enabled: change != 'disabled',
            blockedPermissions: change == 'permission'
                ? {MetaversePluginPermission.links}
                : {},
          ),
        b,
      ]);
      await container.pump();
      expect(container.read(metaverseLinkDefaultsProvider), isEmpty);
      plugins.change([a, b]);
      await container.pump();
      expect(container.read(metaverseLinkDefaultsProvider), isEmpty);
    });
  }

  test('并发保存不丢失其他域名，保存中卸载不恢复旧选择', () async {
    final a = _plugin('example.one'), b = _plugin('example.two');
    plugins.change([a, b]);
    final defaults = container.read(metaverseLinkDefaultsProvider.notifier);
    final first = defaults.remember('example.org', a.id);
    final second = defaults.remember('other.example.org', b.id);
    plugins.change([b]);
    await container.pump();
    await Future.wait([first, second]);
    expect(container.read(metaverseLinkDefaultsProvider), {
      'other.example.org': b.id,
    });
    expect(
      container
          .read(sharedPreferencesProvider)
          .getString(MetaverseLinkDefaults.preferenceKey),
      '{"other.example.org":"example.two"}',
    );
    plugins.change([a, b]);
    await container.pump();
    expect(container.read(metaverseLinkDefaultsProvider), {
      'other.example.org': b.id,
    });
  });

  for (final dark in [false, true]) {
    testWidgets('链接选择器小屏大字可滚动且操作完整 $dark', (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      plugins.change([_plugin('example.one'), _plugin('example.two')]);
      final brightness = dark ? Brightness.dark : Brightness.light;
      var theme = buildAppTheme(
        ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: brightness),
        AppColors.material(brightness),
        UiShapes.standard,
        const ThemeState(mode: ThemeMode.system, seedColor: Colors.indigo),
        fullscreenSwipeBack: false,
        pageBackground: false,
      );
      if (snapshots) {
        theme = theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'MiSans'),
        );
      }
      final boundary = GlobalKey();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TranslationProvider(
            child: RepaintBoundary(
              key: boundary,
              child: MaterialApp(
                navigatorKey: navigatorKey,
                theme: theme,
                debugShowCheckedModeBanner: false,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(1.5)),
                  child: child!,
                ),
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () =>
                          openMetaverseLink(context, uri.toString()),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(S.current.metaverse_chooseLink), findsOneWidget);
      expect(find.text('example.one'), findsOneWidget);
      expect(find.text('example.two'), findsOneWidget);
      expect(find.text(S.current.metaverse_linkBrowser), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (snapshots) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await Directory('build/plugin-followup-ui').create(recursive: true);
          await File(
            'build/plugin-followup-ui/links-${dark ? 'dark' : 'light'}.png',
          ).writeAsBytes(png!.buffer.asUint8List());
        });
      }
      await tester.ensureVisible(find.byType(M3eSwitchListTile));
      await tester.tap(find.byType(M3eSwitchListTile));
      await tester.ensureVisible(find.text('example.two'));
      await tester.tap(find.text('example.two'));
      await tester.pumpAndSettle();
      expect(opened, ['example.two']);
      expect(
        container.read(metaverseLinkDefaultsProvider)[uri.host],
        'example.two',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('多候选弹出公共选择器，可取消、记住并直达；单候选直接打开', (tester) async {
    plugins.change([_plugin('example.one'), _plugin('example.two')]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('open'),
                  onPressed: () => openMetaverseLink(context, uri.toString()),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(S.current.metaverse_chooseLink), findsOneWidget);
    expect(find.text(S.current.metaverse_linkBrowser), findsOneWidget);
    Navigator.of(tester.element(find.text(S.current.metaverse_chooseLink)))
        .pop();
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(M3eSwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('example.two'));
    await tester.pumpAndSettle();
    expect(opened, ['example.two']);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(S.current.metaverse_chooseLink), findsNothing);
    expect(opened, ['example.two', 'example.two']);
    plugins.change([_plugin('example.one')]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(opened.last, 'example.one');
    expect(tester.takeException(), isNull);
  });
}
