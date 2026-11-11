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

void main() {
  for (final width in [320.0, 1000.0]) {
    testWidgets('原生设置 $width 保存失败保留输入，仅提交改动字段', (tester) async {
      tester.view.physicalSize = Size(width, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({'pref_dialog_blur': false});
      final preferences = await SharedPreferences.getInstance();
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
              locale: const Locale('zh'),
              supportedLocales: AppLocaleUtils.supportedLocales,
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: const ForumPreferencesPage(
                username: 'tester',
                initialSection: ForumPreferenceSection.profile,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
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
