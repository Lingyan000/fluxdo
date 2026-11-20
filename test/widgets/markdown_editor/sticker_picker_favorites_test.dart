import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/sticker.dart';
import 'package:fluxdo/providers/sticker_favorites_provider.dart';
import 'package:fluxdo/providers/sticker_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/sticker_favorites_service.dart';
import 'package:fluxdo/services/sticker_market_service.dart';
import 'package:fluxdo/widgets/markdown_editor/sticker_picker.dart';
import 'package:fluxdo/widgets/markdown_editor/sticker_preview.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

StickerItem _item(String name) => StickerItem(
  id: 'id-$name',
  name: name,
  url: 'https://sticker-favorites.invalid/$name.png',
  width: 100,
  height: 100,
  groupId: '',
);

void main() {
  Future<ProviderContainer> pumpPicker(
    WidgetTester tester,
    Map<String, Object> prefsValues,
  ) async {
    SharedPreferences.setMockInitialValues(prefsValues);
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        stickerMarketServiceProvider.overrideWithValue(
          StickerMarketService(prefs),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            locale: const Locale('zh'),
            supportedLocales: AppLocaleUtils.supportedLocales,
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Scaffold(body: StickerPicker(onStickerSelected: (_) {})),
          ),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  testWidgets('只有收藏、没有订阅时显示收藏分区而不是空态', (tester) async {
    await pumpPicker(tester, {
      'sticker_favorites': jsonEncode({
        'categories': [
          {
            'id': StickerFavoriteCategory.defaultId,
            'name': '',
            'items': [_item('a').toJson()],
          },
        ],
      }),
    });

    expect(find.text(S.current.sticker_noStickers), findsNothing);
    expect(find.text(S.current.sticker_favorites), findsOneWidget);
    expect(find.byType(StickerGridCell), findsOneWidget);
  });

  testWidgets('长按最近使用的表情停留,菜单里收藏后出现在收藏分区', (tester) async {
    final container = await pumpPicker(tester, {
      'sticker_recent_items': [jsonEncode(_item('r').toJson())],
      // 有一个订阅分组,面板才不是空态
      'sticker_subscribed_groups': ['group-x'],
    });

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(StickerGridCell).first),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(StickerPreviewController.menuDelay);
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pump();

    await tester.tap(find.text(S.current.sticker_favoriteAction));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));

    final favorites = container.read(stickerFavoritesProvider);
    expect(favorites.single.isDefault, isTrue);
    expect(favorites.single.items.single.url, _item('r').url);
    expect(find.text(S.current.sticker_favorites), findsOneWidget);
  });
}
