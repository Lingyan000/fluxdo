import 'dart:io';

import 'package:app_icons/app_icons.dart';
import 'package:extended_image_lite/extended_image_lite.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/image_viewer_page.dart';
import 'package:fluxdo/providers/image_ocr_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse_cache_manager.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/ocr/ocr_model_store.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NotReadyModelStore extends Fake implements OcrModelStore {
  @override
  Future<bool> isReady() async => false;
}

void main() {
  testWidgets('桌面端三分区布局：无下拉关闭、放大后工具栏与关闭常驻、支持旋转/1:1/适配宽度与点暗幕关闭', (
    tester,
  ) async {
    PlatformUtils.debugDesktopOverride = true;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 700);
    addTearDown(tester.view.reset);

    // 生成一张 200x400 的竖图（在 1000x~600 画布中左右有大片空白暗幕，且 1:1 / 适配宽度均有明确缩放效果）
    final png = Uint8List.fromList(
      img.encodePng(img.Image(width: 200, height: 400)),
    );
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    late BuildContext hostContext;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          ocrModelStoreProvider.overrideWithValue(_NotReadyModelStore()),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: Builder(
              builder: (context) {
                hostContext = context;
                return Scaffold(
                  body: Center(
                    child: TextButton(
                      onPressed: () => ImageViewerPage.openBytes(context, png),
                      child: const Text('打开'),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await precacheImage(MemoryImage(png), hostContext);
    });

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.byType(ImageViewerPage), findsOneWidget);
    // 桌面端不使用下滑关闭容器
    expect(find.byType(ExtendedImageSlidePage), findsNothing);
    // 顶部显示图片像素尺寸，底部有直接复制/旋转/1:1/适配宽度按钮
    expect(find.text('200 × 400'), findsOneWidget);
    expect(find.byIcon(Symbols.content_copy_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.rotate_right_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.rotate_left_rounded), findsOneWidget);
    expect(find.text('1:1'), findsOneWidget);
    expect(find.byIcon(Symbols.fit_screen_rounded), findsOneWidget);

    // 放大到 150%：工具栏和关闭按钮依然保持可见
    await tester.tap(find.byIcon(Symbols.add_rounded));
    await tester.pumpAndSettle();
    expect(find.text('150%'), findsOneWidget);
    expect(find.byIcon(Symbols.close_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.content_copy_rounded), findsOneWidget);

    // 点击百分比复原 100%
    await tester.tap(find.text('150%'));
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget);

    // 顺时针旋转 90°
    await tester.tap(find.byIcon(Symbols.rotate_right_rounded));
    await tester.pumpAndSettle();
    final rotated = tester.widget<RotatedBox>(find.byType(RotatedBox));
    expect(rotated.quarterTurns, 1);

    // 逆时针转回 0°
    await tester.tap(find.byIcon(Symbols.rotate_left_rounded));
    await tester.pumpAndSettle();
    expect(tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 0);

    // 点击图片正中央不应关闭查看器
    await tester.tapAt(const Offset(500, 350));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsOneWidget);

    // 点击图片左侧空白暗幕应关闭查看器
    await tester.tapAt(const Offset(60, 350));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面端多图画廊展示底部缩略图条并支持直接点击切图', (tester) async {
    PlatformUtils.debugDesktopOverride = true;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 700);
    addTearDown(tester.view.reset);

    final urls = [
      'https://example.test/desktop-1.png',
      'https://example.test/desktop-2.png',
      'https://example.test/desktop-3.png',
    ];
    final png = Uint8List.fromList(
      img.encodePng(img.Image(width: 120, height: 90)),
    );
    final dir = Directory.systemTemp.createTempSync('fluxdo-desktop-viewer-');
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (_) async => dir.path,
    );
    await tester.runAsync(() async {
      await BlobImageCache.configureForTesting(root: dir);
      for (final u in urls) {
        await BlobImageCache.write(BlobImageCache.originalBucket, u, png);
        await BlobImageCache.write(BlobImageCache.contentBucket, u, png);
      }
    });
    addTearDown(() async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathChannel,
        null,
      );
      await BlobImageCache.configureForTesting();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    late BuildContext hostContext;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          ocrModelStoreProvider.overrideWithValue(_NotReadyModelStore()),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: Builder(
              builder: (context) {
                hostContext = context;
                return Scaffold(
                  body: Center(
                    child: TextButton(
                      onPressed: () => ImageViewerPage.open(
                        context,
                        urls.first,
                        galleryImages: urls,
                        filenames: const ['photo-1.png', 'photo-2.png', 'photo-3.png'],
                        initialIndex: 0,
                      ),
                      child: const Text('打开画廊'),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      for (final u in urls) {
        await precacheImage(
          ResizeImage(
            discourseImageProvider(u, bucket: BlobImageCache.originalBucket),
            width: 3000,
            height: 3000,
            policy: ResizeImagePolicy.fit,
          ),
          hostContext,
        );
        await precacheImage(
          discourseImageProvider(u, bucket: BlobImageCache.contentBucket),
          hostContext,
        );
      }
    });

    await tester.tap(find.text('打开画廊'));
    await tester.pumpAndSettle();

    expect(find.text('1 / 3'), findsOneWidget);
    // 顶部有文件名时，关闭按钮仍紧贴顶栏最右侧（不被 Flexible + Spacer 挤到中间偏右）
    final closeRect = tester.getRect(
      find.widgetWithIcon(IconButton, Symbols.close_rounded),
    );
    expect(closeRect.right, closeTo(1000 - 12, 1));
    // 底部 3 张缩略图全部渲染
    final thumbImages = find.descendant(
      of: find.byType(ImageViewerPage),
      matching: find.byType(Image),
    );
    expect(thumbImages, findsNWidgets(3));

    // 点击第 3 张缩略图直接跳到 3 / 3
    await tester.tap(thumbImages.at(2));
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
