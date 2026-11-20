import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/sticker.dart';
import 'package:fluxdo/providers/sticker_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/sticker_market_service.dart';
import 'package:fluxdo/widgets/markdown_editor/sticker_picker.dart';
import 'package:fluxdo/widgets/markdown_editor/sticker_preview.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

StickerItem _item(String name) => StickerItem(
  id: 'id-$name',
  name: name,
  url: 'https://sticker-search.invalid/$name',
  width: 200,
  height: 100,
  groupId: '',
);

void main() {
  test('插入比例写进图片语法', () {
    expect(_item('a.png').toMarkdown(), contains('|200x100,30%]'));
    expect(_item('a.png').toMarkdown(scale: 55), contains('|200x100,55%]'));
  });

  testWidgets('内联搜索:按表情名(去扩展名)或分区名命中', (tester) async {
    SharedPreferences.setMockInitialValues({
      'sticker_recent_items': [
        jsonEncode(_item('猫猫叹气.gif').toJson()),
        jsonEncode(_item('G939nNFaoAALSUX.avif').toJson()),
      ],
      'sticker_favorites': jsonEncode({
        'categories': [
          {
            'id': 'c1',
            'name': '狗狗',
            'items': [_item('x1.png').toJson(), _item('x2.png').toJson()],
          },
        ],
      }),
    });
    final prefs = await SharedPreferences.getInstance();
    String? sent;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          stickerMarketServiceProvider.overrideWithValue(
            StickerMarketService(prefs),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            locale: const Locale('zh'),
            supportedLocales: AppLocaleUtils.supportedLocales,
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Scaffold(
              body: StickerPicker(
                inlineSearch: true,
                onStickerSelected: (markdown) => sent = markdown,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip(S.current.sticker_searchTooltip));
    await tester.pump();

    Future<void> search(String query) async {
      await tester.enterText(find.byType(TextField), query);
      await tester.pump(const Duration(milliseconds: 200));
    }

    await search('叹气');
    expect(find.byType(StickerGridCell), findsOneWidget);
    expect(find.text(S.current.common_recentlyUsed), findsOneWidget);

    await search('狗');
    expect(
      find.byType(StickerGridCell),
      findsNWidgets(2),
      reason: '分类名命中时整个分类都算命中',
    );

    await search('不存在的词');
    expect(find.text(S.current.sticker_searchEmpty), findsOneWidget);

    await search('叹气');
    await tester.tap(find.byType(StickerGridCell));
    await tester.pump();
    expect(sent, contains('猫猫叹气.gif|200x100,30%'));
  });
}
