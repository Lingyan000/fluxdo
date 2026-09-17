import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/sticker.dart';
import 'package:fluxdo/providers/sticker_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/sticker_market_service.dart';
import 'package:fluxdo/widgets/markdown_editor/sticker_picker.dart';
import 'package:fluxdo/widgets/markdown_editor/sticker_market_sheet.dart';

class _Service extends StickerMarketService {
  _Service(super.prefs);
  @override
  Future<List<StickerMarketTopic>> getTopics() async => [];
  @override
  Future<(List<StickerGroup>, int)> getGroupsPageWithMeta(
    int page, {
    String topic = 'all',
    bool forceRefresh = false,
  }) async => (<StickerGroup>[], 1);
}

void main() {
  for (final dismissHost in [true, false]) {
    testWidgets('市场关闭正常且下层暂停，宿主移除=$dismissHost', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var visible = true;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            stickerMarketServiceProvider.overrideWithValue(_Service(prefs)),
          ],
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
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) {
                    return visible
                        ? StickerPicker(
                            onStickerSelected: (_) {},
                            onDismissRequested: dismissHost
                                ? () => setState(() => visible = false)
                                : null,
                          )
                        : const Text('宿主页');
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.current.sticker_addFromMarket));
      await tester.pumpAndSettle();
      expect(
        find.byType(StickerPicker, skipOffstage: false),
        dismissHost ? findsNothing : findsOneWidget,
      );
      expect(
        find.text(S.current.sticker_addFromMarket, skipOffstage: false),
        findsNothing,
      );
      expect(find.byType(StickerMarketSheet), findsOneWidget);
      await tester.tap(find.text(S.current.common_done));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(StickerMarketSheet), findsNothing);
      expect(
        dismissHost
            ? find.text('宿主页')
            : find.text(S.current.sticker_addFromMarket),
        findsOneWidget,
      );
    });
  }
}
