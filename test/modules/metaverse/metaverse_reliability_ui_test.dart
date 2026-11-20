import 'dart:io';
import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/secret_store_provider.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_installer.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_restore_page.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_plugin_management_page.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_plugin_dialogs.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_plugin_surface_view.dart';
import 'package:fluxdo/modules/metaverse/plugin/providers/metaverse_plugin_providers.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_update_provider.dart';
import 'package:fluxdo/theme/app_theme.dart';
import 'package:fluxdo/theme/app_colors.dart';

import '../../helpers/preview_fonts.dart';
import 'metaverse_auto_update_test.dart' show updatePackage, updateManifest;

class _NoAccount extends CurrentUserNotifier {
  @override
  Future<User?> build() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const snapshots = bool.fromEnvironment('PLUGIN_SNAPSHOTS');
  setUpAll(() async {
    if (snapshots) {
      expect(await loadPreviewCjkFont(), true);
      await (FontLoader(
            'packages/material_symbols_icons/MaterialSymbolsRounded',
          )..addFont(
            rootBundle.load(
              'packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf',
            ),
          ))
          .load();
    }
  });
  for (final dark in [false, true]) {
    testWidgets('恢复队列、偏好设置和回退审阅支持小屏大字 $dark', (tester) async {
      tester.view.physicalSize = const Size(360, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync(
        'plugin-reliability-ui-',
      );
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          secretStoreProvider.overrideWithValue(InMemorySecretStore()),
          currentUserProvider.overrideWith(_NoAccount.new),
          metaversePluginDirectoryProvider.overrideWith(
            (ref) async => directory,
          ),
          metaverseUpdateDriverProvider.overrideWithValue(null),
          metaverseTaskDriverProvider.overrideWithValue(null),
        ],
      );
      addTearDown(() {
        container.dispose();
        directory.deleteSync(recursive: true);
      });
      final controller = container.read(metaversePluginsProvider.notifier);
      final raw = updateManifest('1.0.0')
        ..['requiredFeatures'] = ['pluginPreferences']
        ..['preferences'] = [
          {
            'key': 'compact',
            'title': '紧凑显示',
            'type': 'toggle',
            'default': false,
          },
          {
            'key': 'sort',
            'title': '排序方式',
            'type': 'choice',
            'default': 'latest',
            'options': {'latest': '最新优先', 'oldest': '最早优先'},
          },
          {'key': 'note', 'title': '备注', 'type': 'text', 'default': '本地设置'},
        ];
      final package = MetaversePluginPackage(
        manifest: MetaversePluginManifest.parse(raw),
        source: updatePackage('1.0.0').source,
        code: updatePackage('1.0.0').code,
      );
      await tester.runAsync(() async {
        await controller.install(package);
        final backup = await container.read(
          metaversePluginBackupProvider.future,
        );
        backup.stage(
          await backup.export(container.read(metaversePluginStoreProvider)),
        );
      });
      final boundary = GlobalKey();
      final brightness = dark ? Brightness.dark : Brightness.light;
      final theme = buildAppTheme(
        ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: brightness),
        AppColors.material(brightness),
        UiShapes.standard,
        const ThemeState(mode: ThemeMode.system, seedColor: Colors.indigo),
        fullscreenSwipeBack: false,
        pageBackground: false,
      );
      Future<void> settle() async {
        // 磁盘 Future 在真实事件循环完成，避免用 pump 的虚拟时间等待 IO。
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
      }

      Future<void> show(Widget page) async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
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
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(dark ? 1.4 : 1)),
                    child: child!,
                  ),
                  home: page,
                ),
              ),
            ),
          ),
        );
        await settle();
      }

      Future<void> capture(String name) async {
        expect(tester.takeException(), isNull);
        if (!snapshots) return;
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await Directory('build/plugin-reliability-ui')
              .create(recursive: true);
          await File('build/plugin-reliability-ui/$name-$dark.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        });
      }

      await show(const MetaverseRestorePage());
      expect(find.text('更新测试'), findsOneWidget);
      await capture('restore');
      await show(
        const MetaversePluginSettingsPage(pluginId: 'example.updates'),
      );
      expect(find.text('紧凑显示'), findsOneWidget);
      await tester.tap(find.text('紧凑显示'));
      await settle();
      expect(
        (await tester.runAsync(
          () => container
              .read(metaversePluginStoreProvider)
              .preferences(package.manifest),
        ))!['compact'],
        true,
      );
      await tester.tap(find.text('排序方式'));
      await tester.pumpAndSettle();
      await capture('preference');
      await tester.tap(find.text('最早优先'));
      await settle();
      await capture('settings');
      await show(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMetaversePluginInstallSheet(
                context,
                updatePackage('2.0.0', expanded: true).manifest,
                previous: controller.byId('example.updates'),
                isUpdate: true,
              ),
              child: const Text('review'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('review'));
      await tester.pumpAndSettle();
      expect(find.textContaining('访问范围变化'), findsOneWidget);
      await capture('review');
      expect(find.textContaining('network'), findsNothing);
      await show(
        Scaffold(
          body: MetaversePluginErrorView(
            message: '恢复旧版会增加访问范围，请到插件管理审阅后再恢复。',
            pluginId: 'example.updates',
          ),
        ),
      );
      await capture('diagnostics');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
