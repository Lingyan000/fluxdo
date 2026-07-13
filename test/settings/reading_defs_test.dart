import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/settings/definitions/reading_defs.dart';
import 'package:fluxdo/settings/settings_model.dart';
import 'package:fluxdo/utils/platform_utils.dart';

Future<List<SettingsModel>> _pumpAndCollectBasicItems(
  WidgetTester tester, {
  required Size size,
  bool? desktopOverride,
  bool readingGroup = false,
}) async {
  addTearDown(() async {
    PlatformUtils.debugDesktopOverride = null;
  });
  PlatformUtils.debugDesktopOverride = desktopOverride;

  late List<SettingsModel> items;
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocaleUtils.supportedLocales,
        home: MediaQuery(
          data: MediaQueryData(size: size),
          child: Builder(
            builder: (context) {
              final targetTitle = readingGroup
                  ? context.l10n.appearance_reading
                  : context.l10n.preferences_basic;
              items = buildReadingGroups(context)
                  .firstWhere((group) => group.title == targetTitle)
                  .items
                  .where((item) {
                    if (item is PlatformConditionalModel) {
                      return item.shouldShow;
                    }
                    return true;
                  })
                  .map(
                    (item) =>
                        item is PlatformConditionalModel ? item.inner : item,
                  )
                  .toList();
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    ),
  );

  return items;
}

void main() {
  testWidgets('桌面宽屏显示默认打开标签页方式设置', (tester) async {
    final items = await _pumpAndCollectBasicItems(
      tester,
      size: const Size(1400, 900),
      desktopOverride: true,
    );

    expect(items.map((item) => item.id), contains('bookmarksOpenMode'));
  });

  testWidgets('桌面窄屏显示默认打开标签页方式设置', (tester) async {
    final items = await _pumpAndCollectBasicItems(
      tester,
      size: const Size(900, 900),
      desktopOverride: true,
    );

    expect(items.map((item) => item.id), contains('bookmarksOpenMode'));
  });

  testWidgets('手机端显示默认打开标签页方式设置', (tester) async {
    final items = await _pumpAndCollectBasicItems(
      tester,
      size: const Size(390, 844),
      desktopOverride: false,
    );

    expect(items.map((item) => item.id), contains('bookmarksOpenMode'));
  });

  testWidgets('reading font sliders share the 80 to 300 percent range', (
    tester,
  ) async {
    final items = await _pumpAndCollectBasicItems(
      tester,
      size: const Size(390, 844),
      desktopOverride: false,
      readingGroup: true,
    );
    final ids = items.map((item) => item.id).toList();
    final contentIndex = ids.indexOf('contentFontScale');
    final topicIndex = ids.indexOf('topicTitleFontScale');

    expect(contentIndex, greaterThanOrEqualTo(0));
    expect(topicIndex, contentIndex + 1);
    for (final slider in <DoubleSliderModel>[
      items[contentIndex] as DoubleSliderModel,
      items[topicIndex] as DoubleSliderModel,
    ]) {
      expect(slider.min, kReadingFontScaleMin);
      expect(slider.max, kReadingFontScaleMax);
      expect(slider.divisions, kReadingFontScaleDivisions);
      expect(slider.labelBuilder(1.75), '175%');
      expect(slider.onReset, isNotNull);
    }
  });
}
