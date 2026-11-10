import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/notion_settings_page.dart';
import 'package:fluxdo/providers/notion_config_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/user_content_providers.dart';
import 'package:fluxdo/services/notion/notion_config.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _DelayedRepository extends NotionConfigRepository {
  _DelayedRepository(super.prefs);

  final saved = Completer<void>();

  @override
  NotionConfig read(String accountId) => const NotionConfig(
    integrationToken: 'test-token',
    databaseId: 'test-database',
  );

  @override
  Future<void> write(String accountId, NotionConfig config) async {
    await saved.future;
    await super.write(accountId, config);
  }
}

void main() {
  testWidgets('Notion 同步范围等待异步保存后再震动，按下和重复选择不震动', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final repository = _DelayedRepository(prefs);
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
    LocaleSettings.setLocale(AppLocale.zh);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          currentUsernameProvider.overrideWith((ref) async => 'tester'),
          notionConfigRepositoryProvider.overrideWithValue(repository),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(extensions: const [M3eFlags()]),
            locale: const Locale('zh'),
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: const NotionSettingsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final group = find.byType(M3eButtonGroup<NotionSyncScope>);
    final target = find.text(tester.element(group).l10n.export_firstPostOnly);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(tester.getCenter(target));
    await tester.pump(const Duration(milliseconds: 150));
    expect(feedback, isEmpty);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(feedback, isEmpty);

    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(
      tester.widget<M3eButtonGroup<NotionSyncScope>>(group).selected,
      NotionSyncScope.allPosts,
    );
    expect(feedback, isEmpty);
    repository.saved.complete();
    await tester.pumpAndSettle();
    expect(
      tester.widget<M3eButtonGroup<NotionSyncScope>>(group).selected,
      NotionSyncScope.firstPostOnly,
    );
    expect(feedback, ['HapticFeedbackType.selectionClick']);
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(feedback, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
