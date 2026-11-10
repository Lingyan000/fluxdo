import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/fonts/font_catalog.dart';
import 'package:fluxdo/services/fonts/font_download_service.dart';
import 'package:fluxdo/settings/definitions/appearance_defs.dart';
import 'package:fluxdo/settings/settings_renderer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late FontDownloadService original;
  late Directory tmp;
  final requested = <String>[];

  setUp(() {
    original = FontDownloadService.instance;
    tmp = Directory.systemTemp.createTempSync('font_section');
    FontCatalog.setAll(
      FontCatalog.parse(File(FontCatalog.assetPath).readAsStringSync()),
    );
    requested.clear();
  });

  tearDown(() {
    FontDownloadService.instance = original;
    FontCatalog.setAll(const []);
    tmp.deleteSync(recursive: true);
  });

  Future<ProviderContainer> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(480, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    LocaleSettings.setLocale(AppLocale.zh);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // 网络全部不可达：验证失败态展示，不触发真实请求
    final service = FontDownloadService(
      fetch: (url, {from, cancelToken}) async {
        requested.add(url);
        throw DioException(
          requestOptions: RequestOptions(path: url),
          message: 'offline',
        );
      },
      rootDir: () async => tmp,
      probeOverride: (_) async => null,
    );
    await service.initialize(prefs);
    FontDownloadService.instance = service;
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
                builder: (context) => ListView(
                  children: [
                    for (final item
                        in buildAppearanceSearchGroups(context)
                            .expand((g) => g.items)
                            .where(
                              (i) => {
                                'fontBody',
                                'fontMono',
                                'fontSource',
                              }.contains(i.id),
                            ))
                      SettingsRenderer(model: item),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('列出正文与等宽字体及其下载状态', (tester) async {
    await pump(tester);
    expect(find.text('正文字体'), findsOneWidget);
    expect(find.text('等宽字体'), findsOneWidget);
    expect(find.text('霞鹜文楷'), findsOneWidget);
    expect(find.text('Fira Code'), findsOneWidget);
    expect(find.textContaining('未下载'), findsWidgets);
    expect(find.text('字体下载源'), findsOneWidget);
    expect(find.text('自动（测速选最快）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选中未下载的字体会开始下载，失败后显示原因', (tester) async {
    final c = await pump(tester);
    await tester.tap(find.text('霞鹜文楷'));
    await tester.pumpAndSettle();
    expect(c.read(themeProvider).bodyFont, 'lxgw-wenkai');
    expect(requested, isNotEmpty);
    expect(find.text('网络连接失败'), findsOneWidget);
    // 字体没下载成功，界面继续用系统字体
    expect(c.read(themeProvider).fontFamilyName, isNull);
    expect(tester.takeException(), isNull);
  });
}
