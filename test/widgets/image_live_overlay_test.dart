import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:extended_image_lite/extended_image_lite.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/image_ocr_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/ocr/local_ocr_service.dart';
import 'package:fluxdo/services/ocr/ocr_model_store.dart';
import 'package:fluxdo/widgets/common/image_live_overlay.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ReadyModelStore extends Fake implements OcrModelStore {
  @override
  Future<bool> isReady() async => true;

  @override
  Future<OcrModelPaths> paths() async =>
      (detector: 'det', recognizer: 'rec', config: 'cfg');
}

class _FailingDownloadModelStore extends Fake implements OcrModelStore {
  int downloadAttempts = 0;

  @override
  Future<bool> isReady() async => false;

  @override
  Future<void> download({
    required CancelToken cancelToken,
    required void Function(double) onProgress,
  }) async {
    downloadAttempts++;
    throw DioException.badResponse(
      statusCode: 302,
      requestOptions: RequestOptions(path: 'https://modelscope.cn/det.tflite'),
      response: Response<void>(
        statusCode: 302,
        requestOptions: RequestOptions(path: 'https://modelscope.cn/det.tflite'),
      ),
    );
  }
}

class _StubOcrService extends Fake implements LocalOcrService {
  _StubOcrService(this.ocrResult);
  final OcrResult ocrResult;

  @override
  Future<OcrResult> recognizeDetailed(
    Uint8List pngBytes,
    OcrModelPaths paths, {
    CancelToken? cancelToken,
    Future<OcrRgbaImage?> Function()? loadRgba,
    void Function(OcrProgress)? onProgress,
    void Function(int imageWidth, int imageHeight, List<Rect> boxes)?
    onDetected,
    void Function(OcrResult partial)? onPartial,
    Offset? priorityPoint,
  }) async {
    onDetected?.call(
      ocrResult.imageWidth,
      ocrResult.imageHeight,
      [for (final l in ocrResult.lines) l.bounds],
    );
    onPartial?.call(ocrResult);
    return ocrResult;
  }
}

void main() {
  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets(
      kind == PointerDeviceKind.mouse
          ? 'PC 端鼠标在细文字行上直接按下拖动即可跨行选字且不被底图抢走'
          : '移动端普通滑动文字仍交给底图，不抢占平移或翻页',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(400, 400);
        addTearDown(tester.view.reset);

        final png = Uint8List.fromList(
          img.encodePng(img.Image(width: 400, height: 400)),
        );
        final ocr = OcrResult(
          imageWidth: 400,
          imageHeight: 400,
          lines: [
            OcrTextLine(
              text: 'Hello',
              bounds: const Rect.fromLTWH(50, 100, 150, 16),
              charBounds: [
                for (var i = 0; i < 5; i++)
                  Rect.fromLTWH(50.0 + i * 30, 100, 30, 16),
              ],
              rowIndex: 0,
            ),
            OcrTextLine(
              text: 'World',
              bounds: const Rect.fromLTWH(50, 160, 150, 16),
              charBounds: [
                for (var i = 0; i < 5; i++)
                  Rect.fromLTWH(50.0 + i * 30, 160, 30, 16),
              ],
              rowIndex: 1,
            ),
          ],
        );

        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final chromeVisible = ValueNotifier(true);
        final gestureController = ImageGestureController();
        final overlayKey = GlobalKey<ImageLiveOverlayState>();
        var backgroundPanned = false;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              ocrModelStoreProvider.overrideWithValue(_ReadyModelStore()),
              localOcrServiceProvider.overrideWithValue(_StubOcrService(ocr)),
            ],
            child: TranslationProvider(
              child: MaterialApp(
                navigatorKey: navigatorKey,
                home: Scaffold(
                  body: Stack(
                    fit: StackFit.expand,
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onScaleStart: (_) => backgroundPanned = true,
                        onScaleUpdate: (_) => backgroundPanned = true,
                      ),
                      ImageLiveOverlay(
                        key: overlayKey,
                        mode: ImageLiveOverlayMode.liveText,
                        loadImage: (_) async => png,
                        gestureController: gestureController,
                        chromeVisible: chromeVisible,
                        onClose: () {},
                        onModeChanged: (_) {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump(const Duration(milliseconds: 100));

        // 从第一行 "Hello" 中部直接向下拖动到第二行 "World" 中部（模拟直接滑动选字）
        final gesture = await tester.startGesture(
          const Offset(80, 108),
          kind: kind,
        );
        await tester.pump();
        await gesture.moveTo(const Offset(110, 130));
        await tester.pump();
        await gesture.moveTo(const Offset(140, 168));
        await tester.pump();
        await gesture.up();
        await tester.pump();

        final isMouse = kind == PointerDeviceKind.mouse;
        expect(overlayKey.currentState!.hasSelection, isMouse);
        expect(find.text('复制'), isMouse ? findsOneWidget : findsNothing);
        expect(backgroundPanned, !isMouse);
        expect(tester.takeException(), isNull);

        chromeVisible.dispose();
        gestureController.dispose();
      },
    );
  }

  testWidgets('静默直选模式不展示底栏、空白点击透传底图，直接鼠标划选立即出选区', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 400);
    addTearDown(tester.view.reset);

    final png = Uint8List.fromList(
      img.encodePng(img.Image(width: 400, height: 400)),
    );
    final ocr = OcrResult(
      imageWidth: 400,
      imageHeight: 400,
      lines: [
        OcrTextLine(
          text: 'Hello',
          bounds: const Rect.fromLTWH(50, 100, 150, 16),
          charBounds: [
            for (var i = 0; i < 5; i++)
              Rect.fromLTWH(50.0 + i * 30, 100, 30, 16),
          ],
          rowIndex: 0,
        ),
      ],
    );

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final chromeVisible = ValueNotifier(true);
    final gestureController = ImageGestureController();
    final overlayKey = GlobalKey<ImageLiveOverlayState>();
    var backgroundTapped = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          ocrModelStoreProvider.overrideWithValue(_ReadyModelStore()),
          localOcrServiceProvider.overrideWithValue(_StubOcrService(ocr)),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: Scaffold(
              body: Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => backgroundTapped = true,
                  ),
                  ImageLiveOverlay(
                    key: overlayKey,
                    sourceKey: 'passive-test',
                    mode: ImageLiveOverlayMode.liveText,
                    passive: true,
                    loadImage: (_) async => png,
                    gestureController: gestureController,
                    chromeVisible: chromeVisible,
                    onClose: () {},
                    onModeChanged: (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(milliseconds: 100));

    // 静默模式下不显示识字底栏
    expect(find.text('点击或拖动文字选择'), findsNothing);

    // 无选区时点击空白处透传给底层（不拦截单击/双击）
    await tester.tapAt(const Offset(20, 20));
    await tester.pump();
    expect(backgroundTapped, isTrue);

    // 鼠标按在文字上直接拖动立即划选
    final gesture = await tester.startGesture(
      const Offset(60, 108),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(const Offset(160, 108));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(overlayKey.currentState!.hasSelection, isTrue);
    expect(find.text('复制'), findsOneWidget);

    // 有选区时点击空白清除选区
    await tester.tapAt(const Offset(20, 20));
    await tester.pump();
    expect(overlayKey.currentState!.hasSelection, isFalse);
    expect(tester.takeException(), isNull);

    chromeVisible.dispose();
    gestureController.dispose();
  });

  testWidgets('长按空白落点未命中文字时关闭覆盖层并触发回退菜单回调', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 400);
    addTearDown(tester.view.reset);

    final png = Uint8List.fromList(
      img.encodePng(img.Image(width: 400, height: 400)),
    );
    final ocr = OcrResult(
      imageWidth: 400,
      imageHeight: 400,
      lines: [
        OcrTextLine(
          text: 'Hello',
          bounds: const Rect.fromLTWH(50, 100, 150, 16),
          charBounds: [
            for (var i = 0; i < 5; i++)
              Rect.fromLTWH(50.0 + i * 30, 100, 30, 16),
          ],
          rowIndex: 0,
        ),
      ],
    );

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final chromeVisible = ValueNotifier(true);
    final gestureController = ImageGestureController();
    var closed = false;
    var missed = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          ocrModelStoreProvider.overrideWithValue(_ReadyModelStore()),
          localOcrServiceProvider.overrideWithValue(_StubOcrService(ocr)),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: Scaffold(
              body: ImageLiveOverlay(
                sourceKey: 'long-press-miss',
                mode: ImageLiveOverlayMode.liveText,
                initialTapGlobalPosition: const Offset(350, 350),
                onInitialTapMissed: () => missed = true,
                loadImage: (_) async => png,
                gestureController: gestureController,
                chromeVisible: chromeVisible,
                onClose: () => closed = true,
                onModeChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(milliseconds: 100));

    expect(closed, isTrue);
    expect(missed, isTrue);
    expect(tester.takeException(), isNull);

    chromeVisible.dispose();
    gestureController.dispose();
  });

  testWidgets('多图画廊 + 静默直选：非文字处快速鼠标拖动与触控板双指滑屏可顺畅切图，仅命中文字时划选', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 400);
    addTearDown(tester.view.reset);

    final png = Uint8List.fromList(
      img.encodePng(img.Image(width: 400, height: 400)),
    );
    final ocr = OcrResult(
      imageWidth: 400,
      imageHeight: 400,
      lines: [
        OcrTextLine(
          text: 'Hello',
          bounds: const Rect.fromLTWH(50, 100, 150, 16),
          charBounds: [
            for (var i = 0; i < 5; i++)
              Rect.fromLTWH(50.0 + i * 30, 100, 30, 16),
          ],
          rowIndex: 0,
        ),
      ],
    );

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final chromeVisible = ValueNotifier(true);
    final pageController = ExtendedPageController();
    final controllers = [
      ImageGestureController(
        config: GestureConfig(inPageView: true, hitTestBehavior: HitTestBehavior.opaque),
      ),
      ImageGestureController(
        config: GestureConfig(inPageView: true, hitTestBehavior: HitTestBehavior.opaque),
      ),
    ];
    final overlayKey = GlobalKey<ImageLiveOverlayState>();
    var currentPage = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          ocrModelStoreProvider.overrideWithValue(_ReadyModelStore()),
          localOcrServiceProvider.overrideWithValue(_StubOcrService(ocr)),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => Stack(
                  fit: StackFit.expand,
                  children: [
                    ExtendedImageGesturePageView.builder(
                      itemCount: 2,
                      physics: const BouncingScrollPhysics(),
                      controller: pageController,
                      onPageChanged: (idx) => setState(() => currentPage = idx),
                      itemBuilder: (context, index) => GestureImageView(
                        image: MemoryImage(png),
                        controller: controllers[index],
                        fit: BoxFit.contain,
                        inPageView: true,
                      ),
                    ),
                    ImageLiveOverlay(
                      key: overlayKey,
                      sourceKey: 'page-$currentPage',
                      mode: ImageLiveOverlayMode.liveText,
                      passive: true,
                      loadImage: (_) async => png,
                      gestureController: controllers[currentPage],
                      chromeVisible: chromeVisible,
                      onClose: () {},
                      onModeChanged: (_) {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(milliseconds: 100));

    // 1. 鼠标在空白处（距文字 12px 以外）以真实桌面步长（>2px/帧）向左快拖 -> 切到下一页
    final blankDrag = await tester.startGesture(
      const Offset(300, 260),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    for (var step = 1; step <= 14; step++) {
      await blankDrag.moveBy(const Offset(-18, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await blankDrag.up();
    await tester.pumpAndSettle();
    expect(currentPage, 1);

    // 2. 鼠标在文字下方 10px 的行间空白向右快拖 -> 切回第 0 页，不误触发选字
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(milliseconds: 100));
    final nearBlankDrag = await tester.startGesture(
      const Offset(80, 128),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    for (var step = 1; step <= 14; step++) {
      await nearBlankDrag.moveBy(const Offset(18, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await nearBlankDrag.up();
    await tester.pumpAndSettle();
    expect(currentPage, 0);
    expect(overlayKey.currentState!.hasSelection, isFalse);

    // 3. 触控板双指横向滑屏（即使指针正停在文字上方）-> 顺畅切到第 1 页，不被选字吞掉
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(milliseconds: 100));
    await tester.trackpadFling(
      find.byType(ExtendedImageGesturePageView),
      const Offset(-250, 0),
      600,
    );
    await tester.pumpAndSettle();
    expect(currentPage, 1);

    // 4. 回到第 0 页，鼠标直接按在文字内部拖动 -> 划选文字且不切页
    pageController.jumpToPage(0);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(milliseconds: 100));
    final textDrag = await tester.startGesture(
      const Offset(60, 108),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await textDrag.moveTo(const Offset(160, 108));
    await tester.pump();
    await textDrag.up();
    await tester.pump(const Duration(milliseconds: 60));
    expect(currentPage, 0);
    expect(overlayKey.currentState!.hasSelection, isTrue);
    expect(tester.takeException(), isNull);

    chromeVisible.dispose();
    pageController.dispose();
    for (final c in controllers) {
      c.dispose();
    }
  });

  testWidgets('模型下载失败时展示错误与查看详情/重试按钮，不被下载提示覆盖', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 400);
    addTearDown(tester.view.reset);

    final png = Uint8List.fromList(
      img.encodePng(img.Image(width: 200, height: 200)),
    );
    final failingStore = _FailingDownloadModelStore();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final chromeVisible = ValueNotifier(true);
    final gestureController = ImageGestureController();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          ocrModelStoreProvider.overrideWithValue(failingStore),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: Scaffold(
              body: ImageLiveOverlay(
                sourceKey: 'download-fail',
                mode: ImageLiveOverlayMode.liveText,
                loadImage: (_) async => png,
                gestureController: gestureController,
                chromeVisible: chromeVisible,
                onClose: () {},
                onModeChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('确定'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(failingStore.downloadAttempts, 1);
    expect(find.text('模型下载或校验失败，请重试'), findsOneWidget);
    expect(find.text('查看详情'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(failingStore.downloadAttempts, 2);
    expect(tester.takeException(), isNull);

    chromeVisible.dispose();
    gestureController.dispose();
  });
}
