import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:fluxdo/theme/app_theme.dart';
import 'package:fluxdo/theme/theme_registry.dart';
import 'package:fluxdo/theme/theme_resolver.dart';

import '../helpers/preview_fonts.dart';

import 'package:fluxdo/widgets/settings/settings_group_page.dart';
import 'package:fluxdo/services/local_notification_service.dart';

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/forum_preferences/forum_preferences_page.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:m3e_ui/m3e_ui.dart';

void main() {
  const captureDir = String.fromEnvironment('PROFILE_CAPTURE_DIR');
  for (final width in [320.0, 390.0, 1000.0]) {
    testWidgets('原生设置 $width 保存失败保留输入，仅提交改动字段', (tester) async {
      if (captureDir.isNotEmpty) {
        await tester.runAsync(() async {
          await loadPreviewCjkFont();
          final manifest = jsonDecode(
            await rootBundle.loadString('FontManifest.json'),
          ) as List;
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
      }
      tester.view.physicalSize = Size(width, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({'pref_dialog_blur': false});
      final preferences = await SharedPreferences.getInstance();
      const themeState = ThemeState(
        mode: ThemeMode.system,
        seedColor: Colors.blue,
      );
      final resolved = ThemeResolver.resolve(
        spec: ThemeRegistry.material,
        mode: ThemeMode.system,
        black: false,
        seed: themeState.seedColor,
        variant: themeState.schemeVariant,
      );
      final appTheme = buildAppTheme(
        width == 390 ? resolved.dark : resolved.light,
        width == 390 ? resolved.darkColors : resolved.lightColors,
        themeState.effectiveShapes,
        themeState,
        fullscreenSwipeBack: false,
        pageBackground: false,
      );
      final user = <String, dynamic>{
        'id': 1,
        'username': 'tester',
        'can_edit': true,
        'can_change_bio': true,
        'can_change_location': true,
        'can_change_website': true,
        'bio_raw': '原简介',
        'location': '原位置',
        'website': '',
        'user_option': {'hide_profile': false, 'future_option': 8},
      };
      await tester.runAsync(
        () => PreloadedDataService().hydrateFromHtml(
          '<meta id="data-discourse-setup"><script id="data-preloaded" type="application/json">${jsonEncode({
            'currentUser': {'id': 1, 'username': 'tester'},
            'siteSettings': {},
            'site': {'categories': []},
          })}</script>',
        ),
      );
      var failSave = true;
      final payloads = <Map<String, dynamic>>[];
      final service = DiscourseService();
      final mock = InterceptorsWrapper(
        onRequest: (options, handler) {
          Object data = {'user': user};
          if (options.method == 'PUT') {
            payloads.add(Map<String, dynamic>.from(options.data as Map));
            expect(options.extra['noRecovery'], true);
            data = failSave
                ? {'success': false, 'error': '测试保存失败'}
                : {'success': true};
          }
          handler.resolve(Response(requestOptions: options, data: data));
        },
      );
      service.dio.interceptors.insert(0, mock);
      addTearDown(() => service.dio.interceptors.remove(mock));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: navigatorKey,
              theme: captureDir.isEmpty
                  ? appTheme
                  : appTheme.copyWith(
                      textTheme: appTheme.textTheme.apply(fontFamily: 'MiSans'),
                    ),
              builder: (context, child) => RepaintBoundary(
                key: const ValueKey('preferences-capture'),
                child: child!,
              ),
              locale: const Locale('zh'),
              supportedLocales: AppLocaleUtils.supportedLocales,
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: const ForumPreferencesPage(username: 'tester'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Symbols.account_circle_rounded), findsOneWidget);
      expect(find.byIcon(Symbols.shield_rounded), findsOneWidget);
      await _capture(tester, captureDir, 'preferences-navigation-$width');
      await tester.tap(
        find.byKey(const ValueKey(ForumPreferenceSection.profile)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SettingsGroupPage), findsOneWidget);
      await _capture(tester, captureDir, 'preferences-$width');
      await tester.enterText(
        find.widgetWithText(TextFormField, '个人简介'),
        '修改后的简介',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(payloads, [
        {'bio_raw': '修改后的简介'},
      ]);
      expect(find.text('修改后的简介'), findsOneWidget);
      failSave = false;
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(payloads.last, {'bio_raw': '修改后的简介'});
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.widgetWithText(M3eSwitchListTile, '隐藏公开资料与活动'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(payloads.last, {'hide_profile': true});
      await tester.enterText(
        find.widgetWithText(TextFormField, '个人简介'),
        '尚未保存的简介',
      );
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(find.text('尚未保存的简介'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}

Future<void> _capture(WidgetTester tester, String dir, String name) async {
  if (dir.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('preferences-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
