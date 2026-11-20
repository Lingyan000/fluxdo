import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fluxdo/pages/image_viewer_page.dart';
import 'package:fluxdo/services/discourse_cache_manager.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/common/hero_image.dart';
import 'package:fluxdo/widgets/layout/immersive_insets_hold.dart';

void main() {
  const url = 'https://example.test/portrait.png';
  const size = Size(200, 400);
  const tag = 'portrait';
  late GlobalKey boundary;

  Future<void> open(
    WidgetTester tester, {
    bool cover = false,
    bool filename = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    PlatformUtils.debugDesktopOverride = false;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);

    // 同一张纯白竖图同时填入缩略图与原图缓存，排除解码时序和图片内容的影响。
    final thumb = discourseImageProvider(url);
    final original = ResizeImage(
      discourseImageProvider(url, bucket: BlobImageCache.originalBucket),
      width: 2048,
      height: 2048,
      policy: ResizeImagePolicy.fit,
    );
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.white, BlendMode.src);
    final picture = recorder.endRecording();
    final white = picture.toImageSync(20, 40);
    picture.dispose();
    for (final provider in [thumb, original]) {
      final key = await provider.obtainKey(ImageConfiguration.empty);
      PaintingBinding.instance.imageCache.putIfAbsent(
        key,
        () => OneFrameImageStreamCompleter(
          SynchronousFuture(ImageInfo(image: white.clone())),
        ),
      );
    }
    white.dispose();

    boundary = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        child: RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            builder: (_, child) => ImmersiveInsetsHoldScope(child: child!),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: HeroImage(
                    heroTag: tag,
                    coverFlight: cover,
                    flightImage: thumb,
                    onTap: () => ImageViewerPage.open(
                      context,
                      url,
                      heroTag: tag,
                      thumbnailUrl: url,
                      filenames: filename ? const ['portrait.png'] : null,
                      heroSourceFit: cover ? BoxFit.cover : null,
                    ),
                    child: SizedBox(
                      width: 64,
                      height: 128,
                      child: Image(
                        image: thumb,
                        fit: cover ? BoxFit.cover : BoxFit.contain,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(HeroImage));
    await tester.pump();
  }

  // 从包含 Navigator 和飞行图片的整帧取样。两点避开图标和文字，中点确认是在白图上。
  Future<List<int>> edgeBrightness(WidgetTester tester) async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final sample = (await tester.runAsync(() async {
      final image = await render.toImage();
      try {
        final pixels = (await image.toByteData())!;
        int brightness(int y) => pixels.getUint8((y * image.width + 70) * 4);
        return [brightness(18), brightness(391), brightness(200)];
      } finally {
        image.dispose();
      }
    }))!;
    expect(sample.last, 255, reason: '视口中央应为白色图片');
    return sample.sublist(0, 2);
  }

  void expectContinuous(List<int> before, List<int> after) {
    for (var i = 0; i < 2; i++) {
      expect(after[i], closeTo(before[i], 12), reason: '$before → $after');
    }
  }

  testWidgets('点开时，飞行末帧和落位后的上下渐变连续', (tester) async {
    await open(tester);
    await tester.pump(const Duration(milliseconds: 284));
    expect(find.byType(CoverContainFlightImage), findsOneWidget);
    final before = await edgeBrightness(tester);
    await tester.pumpAndSettle();
    final after = await edgeBrightness(tester);
    expect(after, everyElement(lessThan(180)));
    expectContinuous(before, after);
  });

  testWidgets('点关闭时，图片开始缩回的首帧保留上下渐变', (tester) async {
    await open(tester);
    await tester.pumpAndSettle();
    final before = await edgeBrightness(tester);
    await tester.tap(find.byIcon(Symbols.close_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 8));
    final after = await edgeBrightness(tester);
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
    expectContinuous(before, after);
  });

  testWidgets('打开途中立即关闭，上下渐变在换向时连续', (tester) async {
    await open(tester);
    await tester.pump(const Duration(milliseconds: 254));
    expect(find.byType(CoverContainFlightImage), findsOneWidget);
    final before = await edgeBrightness(tester);
    await tester.tap(find.byIcon(Symbols.close_rounded));
    await tester.pump();
    final after = await edgeBrightness(tester);
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
    expect(before, everyElement(lessThan(180)));
    expectContinuous(before, after);
  });

  testWidgets('取消交互式返回，渐变和关闭按钮都交回查看器', (tester) async {
    Future<void> backGesture(String method, [double? progress]) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/backgesture',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(
              method,
              progress == null
                  ? null
                  : {
                      'touchOffset': <double>[5, 200],
                      'progress': progress,
                      'swipeEdge': 0,
                    },
            ),
          ),
          (_) {},
        );
    await open(tester, cover: true);
    await tester.pumpAndSettle();
    final route = ModalRoute.of(tester.element(find.byType(ImageViewerPage)))!;
    final before = await edgeBrightness(tester);
    await backGesture('startBackGesture', 0);
    await tester.pump();
    await backGesture('updateBackGestureProgress', 0.02);
    await tester.pump();
    expect(route.navigator!.userGestureInProgress, isTrue);
    expect(find.byType(CoverContainFlightImage), findsOneWidget);
    expectContinuous(before, await edgeBrightness(tester));
    await backGesture('cancelBackGesture');
    await tester.pumpAndSettle();
    expect(await edgeBrightness(tester), before);
    await tester.tap(find.byIcon(Symbols.close_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('返回裁剪缩略图时，顶部渐变连续，无文件名的图片底部保持原亮度', (tester) async {
    await open(tester, cover: true, filename: false);
    await tester.pumpAndSettle();
    final before = await edgeBrightness(tester);
    expect(before.first, lessThan(180));
    expect(before.last, 255);
    await tester.tap(find.byIcon(Symbols.close_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 8));
    expect(find.byType(CoverContainFlightImage), findsOneWidget);
    expectContinuous(before, await edgeBrightness(tester));
    await tester.pumpAndSettle();
  });

  testWidgets('点图隐藏工具栏后，返回首帧不会重新画出渐变', (tester) async {
    await open(tester);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(70, 18));
    await tester.pumpAndSettle(const Duration(milliseconds: 350));
    expect(await edgeBrightness(tester), [255, 255]);
    Navigator.of(tester.element(find.byType(ImageViewerPage))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 8));
    expect(await edgeBrightness(tester), [255, 255]);
    await tester.pumpAndSettle();
  });
}
