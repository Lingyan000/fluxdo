import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
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
import 'package:fluxdo/services/ocr/local_ocr_service.dart';
import 'package:fluxdo/services/ocr/ocr_model_store.dart';
import 'package:fluxdo/utils/platform_utils.dart';
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

  @override
  Future<String?> paragraphModelPathIfReady() async => null;

  @override
  Future<String?> ensureParagraphModel({Duration? waitTimeout}) async => null;
}

class _StubOcrService extends Fake implements LocalOcrService {
  _StubOcrService({this.streaming = false});

  final bool streaming;
  final completion = Completer<OcrResult>();
  void Function(OcrResult)? publishPartial;
  int calls = 0;

  @override
  Future<bool> isSystemEngineAvailable() async => false;

  final result = OcrResult(
    imageWidth: 400,
    imageHeight: 800,
    lines: [
      for (final (row, text, top) in [(0, 'Hello', 220.0), (1, 'World', 400.0)])
        OcrTextLine(
          text: text,
          bounds: Rect.fromLTWH(50, top, 200, 20),
          charBounds: [
            for (var i = 0; i < text.length; i++)
              Rect.fromLTWH(50 + i * 40, top, 40, 20),
          ],
          rowIndex: row,
        ),
    ],
  );

  @override
  Future<OcrResult> recognizeDetailed(
    Uint8List pngBytes,
    OcrModelPaths? paths, {
    bool useSystemEngine = false,
    String? paragraphModelPath,
    CancelToken? cancelToken,
    Future<OcrRgbaImage?> Function()? loadRgba,
    void Function(OcrProgress)? onProgress,
    void Function(int imageWidth, int imageHeight, List<Rect> boxes)?
    onDetected,
    void Function(OcrResult partial)? onPartial,
    Offset? priorityPoint,
  }) async {
    calls++;
    onDetected?.call(400, 800, [for (final line in result.lines) line.bounds]);
    if (streaming) {
      publishPartial = onPartial;
      onPartial?.call(
        OcrResult(
          imageWidth: 400,
          imageHeight: 800,
          lines: [result.lines.first],
        ),
      );
      return completion.future;
    }
    onPartial?.call(result);
    return result;
  }
}

ImageLiveOverlayState _overlay(WidgetTester tester) =>
    tester.state<ImageLiveOverlayState>(find.byType(ImageLiveOverlay));

Future<void> _waitForSelection(WidgetTester tester) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    });
    await tester.pump(const Duration(milliseconds: 50));
    if (find.byType(ImageLiveOverlay).evaluate().isNotEmpty &&
        _overlay(tester).hasSelection) {
      await tester.pump(const Duration(milliseconds: 500));
      return;
    }
  }
  fail('长按后没有出现文字选区');
}

Future<_StubOcrService> _openViewer(
  WidgetTester tester, {
  required bool gallery,
  _StubOcrService? ocrService,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(400, 800);
  addTearDown(tester.view.reset);
  PlatformUtils.debugDesktopOverride = false;
  addTearDown(() => PlatformUtils.debugDesktopOverride = null);

  final png = Uint8List.fromList(
    img.encodePng(img.Image(width: 400, height: 800)),
  );
  const urls = [
    'https://example.test/ocr-first.png',
    'https://example.test/ocr-second.png',
  ];
  final directory = Directory.systemTemp.createTempSync('fluxdo-ocr-gesture-');
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    pathChannel,
    (_) async => directory.path,
  );
  await tester.runAsync(() async {
    await BlobImageCache.configureForTesting(root: directory);
    for (final url in urls) {
      await BlobImageCache.write(BlobImageCache.originalBucket, url, png);
    }
  });
  addTearDown(() async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      null,
    );
    await BlobImageCache.configureForTesting();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  SharedPreferences.setMockInitialValues({'pref_dialog_blur': false});
  final prefs = await SharedPreferences.getInstance();
  final service = ocrService ?? _StubOcrService();
  String? clipboardText;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardText = (call.arguments as Map)['text'] as String?;
      } else if (call.method == 'Clipboard.getData') {
        return {'text': clipboardText};
      }
      return null;
    },
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });
  late BuildContext sourceContext;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        ocrModelStoreProvider.overrideWithValue(_ReadyModelStore()),
        localOcrServiceProvider.overrideWithValue(service),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                sourceContext = context;
                return TextButton(
                  onPressed: () {
                    if (gallery) {
                      ImageViewerPage.open(
                        context,
                        urls.first,
                        galleryImages: urls,
                      );
                    } else {
                      ImageViewerPage.openBytes(context, png);
                    }
                  },
                  child: const Text('打开图片'),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.runAsync(() async {
    for (final url in urls) {
      await precacheImage(
        ResizeImage(
          discourseImageProvider(url, bucket: BlobImageCache.originalBucket),
          width: 2400,
          height: 2400,
          policy: ResizeImagePolicy.fit,
        ),
        sourceContext,
      );
    }
  });
  await tester.tap(find.text('打开图片'));
  // 等待实际显示的图片完成原生解码，避免依赖查看器内部的缓存键。
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (find.byType(GestureImageView).evaluate().isNotEmpty) break;
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  }
  final views = tester.widgetList<GestureImageView>(
    find.byType(GestureImageView),
  );
  expect(views, isNotEmpty);
  await tester.runAsync(() async {
    for (final view in views) {
      await precacheImage(view.image, sourceContext).timeout(
        const Duration(seconds: 5),
      );
    }
  });
  await tester.pumpAndSettle();
  return service;
}

void main() {
  for (final gallery in [false, true]) {
    testWidgets('${gallery ? '画廊' : '内存图片'}复制后可以再次长按其他行，无需重新识别', (
      tester,
    ) async {
      final service = await _openViewer(tester, gallery: gallery);
      for (final (point, expected) in [
        (const Offset(140, 230), 'Hello'),
        (const Offset(140, 410), 'World'),
        (const Offset(140, 230), 'Hello'),
      ]) {
        await tester.longPressAt(point);
        await _waitForSelection(tester);
        expect(await _overlay(tester).copySelectionIfAny(), isTrue);
        expect((await Clipboard.getData('text/plain'))?.text, expected);
        await tester.pump();
        expect(_overlay(tester).hasSelection, isFalse);
      }
      expect(service.calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  for (final start in [const Offset(140, 230), const Offset(300, 600)]) {
    testWidgets('识字模式从${start.dy == 230 ? '文字' : '空白'}处横滑直接切图，下一张仍可长按', (
      tester,
    ) async {
      final service = await _openViewer(tester, gallery: true);
      await tester.longPressAt(const Offset(140, 230));
      await _waitForSelection(tester);

      await tester.dragFrom(start, const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      expect(find.byType(ImageViewerPage), findsOneWidget);
      expect(find.byType(ImageLiveOverlay), findsNothing);

      await tester.longPressAt(const Offset(140, 410));
      await _waitForSelection(tester);
      expect(service.calls, 2);
      await tester.dragFrom(const Offset(300, 600), const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.byType(ImageViewerPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('识别中再次长按新行不受缩放影响，复制后不会被后续结果重新选中', (tester) async {
    final service = _StubOcrService(streaming: true);
    await _openViewer(tester, gallery: false, ocrService: service);
    await tester.longPressAt(const Offset(140, 230));
    await _waitForSelection(tester);

    await tester.longPressAt(const Offset(140, 410));
    tester
        .widget<GestureImageView>(find.byType(GestureImageView))
        .controller
        .zoomTo(2, focalPoint: Offset.zero);
    await tester.pump();
    service.publishPartial!(service.result);
    await tester.pump();
    expect(await _overlay(tester).copySelectionIfAny(), isTrue);
    expect((await Clipboard.getData('text/plain'))?.text, 'World');

    service.publishPartial!(service.result);
    await tester.pump();
    expect(_overlay(tester).hasSelection, isFalse);
    service.completion.complete(service.result);
    await tester.pump();
    expect(_overlay(tester).hasSelection, isFalse);
    expect(service.calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('已有选区时长按空白打开菜单，继续移动不会修改原选区', (tester) async {
    await _openViewer(tester, gallery: false);
    await tester.longPressAt(const Offset(140, 230));
    await _waitForSelection(tester);

    final hold = await tester.startGesture(const Offset(300, 600));
    await tester.pump(const Duration(milliseconds: 600));
    await hold.moveTo(const Offset(240, 425));
    await hold.up();
    await tester.pumpAndSettle();
    expect(await _overlay(tester).copySelectionIfAny(), isTrue);
    expect((await Clipboard.getData('text/plain'))?.text, 'Hello');
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('首次长按可不抬手跨行划选，随后仍可拖手柄调整选区', (tester) async {
    await _openViewer(tester, gallery: true);
    final hold = await tester.startGesture(const Offset(140, 230));
    await tester.pump(const Duration(milliseconds: 600));
    await _waitForSelection(tester);
    await hold.moveTo(const Offset(240, 425));
    await tester.pump();
    await hold.up();
    await tester.pump();
    expect(await _overlay(tester).copySelectionIfAny(), isTrue);
    final copied = (await Clipboard.getData('text/plain'))!.text!;
    expect(copied, contains('Hello'));
    expect(copied, contains('World'));

    await tester.longPressAt(const Offset(140, 230));
    await _waitForSelection(tester);
    await tester.dragFrom(const Offset(250, 230), const Offset(-10, 195));
    await tester.pump(const Duration(milliseconds: 100));
    expect(await _overlay(tester).copySelectionIfAny(), isTrue);
    expect((await Clipboard.getData('text/plain'))?.text, copied);
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
