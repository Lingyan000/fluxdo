import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/sticker.dart';
import 'package:fluxdo/providers/sticker_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/dio_http_client.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/sticker_market_service.dart';
import 'package:fluxdo/services/sticker_thumbnail_provider.dart';
import 'package:fluxdo/widgets/common/cached_image.dart';
import 'package:fluxdo/widgets/markdown_editor/sticker_market_sheet.dart';
import 'package:fluxdo/widgets/markdown_editor/sticker_picker.dart';

const _marketIcon = 'https://sticker-priority.invalid/market.avif';
const _recentIcon = 'https://sticker-priority.invalid/recent.avif';

class _MarketService extends StickerMarketService {
  _MarketService(super.prefs);

  @override
  Future<List<StickerMarketTopic>> getTopics() async => [];

  @override
  Future<(List<StickerGroup>, int)> getGroupsPageWithMeta(
    int page, {
    String topic = 'all',
    bool forceRefresh = false,
  }) async => (
    const [
      StickerGroup(
        id: 'priority-market',
        name: '高优先级市场分组',
        icon: _marketIcon,
        order: 0,
        emojiCount: 1,
        isArchived: false,
      ),
    ],
    1,
  );

  @override
  List<StickerGroup> getSubscribedGroups() => const [
    StickerGroup(
      id: 'local',
      name: '本地分组',
      icon: _recentIcon,
      order: 0,
      emojiCount: 0,
      isArchived: false,
    ),
  ];

  @override
  Future<StickerGroupDetail> getGroupDetail(String groupId) async =>
      StickerGroupDetail(
        id: groupId,
        name: '本地分组',
        icon: _recentIcon,
        emojis: const [],
      );

  @override
  List<StickerItem> getRecentStickers() => const [
    StickerItem(
      id: 'priority-recent',
      name: '下层最近表情',
      url: _recentIcon,
      width: 40,
      height: 40,
      groupId: 'recent',
    ),
  ];
}

ImageProvider _unwrap(ImageProvider provider) {
  while (provider is ResizeImage) {
    provider = provider.imageProvider;
  }
  return provider;
}

void main() {
  testWidgets('真实选择器打开市场后保留宿主但移除下层图片，市场缩略图使用高优先级', (tester) async {
    // 在缓存目录解析处阻止图片 IO，不读取或修改本机缓存，也不发起网络请求。
    // 本测试验证实际组件的请求优先级传递，不把占位图当作首帧解码成功。
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (_) async => throw PlatformException(code: 'test-image-io-disabled'),
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathChannel,
        null,
      );
    });
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          stickerMarketServiceProvider.overrideWithValue(_MarketService(prefs)),
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
            home: Scaffold(body: StickerPicker(onStickerSelected: (_) {})),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final picker = find.byType(StickerPicker, skipOffstage: false);
    final pickerElement = tester.element(picker);
    Finder imagesUnder(Finder parent) => find.descendant(
      of: parent,
      matching: find.byType(Image, skipOffstage: false),
      skipOffstage: false,
    );

    // 先证明下层原本确有图片，避免对空选择器做无效的“无图片”断言。
    final recentImages = tester.widgetList<Image>(imagesUnder(picker));
    expect(recentImages, isNotEmpty);
    expect(
      recentImages.map((image) => _unwrap(image.image)),
      contains(
        isA<StickerThumbnailProvider>().having(
          (provider) => provider.url,
          'url',
          _recentIcon,
        ),
      ),
    );

    await tester.tap(find.byTooltip(S.current.sticker_addTooltip));
    await tester.pumpAndSettle();

    expect(picker, findsOneWidget);
    expect(tester.element(picker), same(pickerElement));
    expect(pickerElement.mounted, isTrue);
    // 包括 offstage 子树，不能仅仅隐藏下层而继续持有图片加载组件。
    expect(imagesUnder(picker), findsNothing);
    expect(
      find.descendant(
        of: picker,
        matching: find.byType(CachedImage, skipOffstage: false),
        skipOffstage: false,
      ),
      findsNothing,
    );
    final market = find.byType(StickerMarketSheet);
    expect(market, findsOneWidget);
    expect(find.text('高优先级市场分组'), findsOneWidget);
    final marketImages = tester.widgetList<Image>(imagesUnder(market));
    expect(marketImages, hasLength(1));
    final provider = _unwrap(marketImages.single.image);
    expect(provider, isA<StickerThumbnailProvider>());
    final thumbnail = provider as StickerThumbnailProvider;
    expect(thumbnail.url, _marketIcon);
    expect(thumbnail.priority, DownloadPriority.high);
    expect(thumbnail.targetSize, 80);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text(S.current.common_done));
    await tester.pumpAndSettle();
    expect(find.byType(StickerMarketSheet), findsNothing);
    expect(tester.element(picker), same(pickerElement));
    expect(imagesUnder(picker), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
