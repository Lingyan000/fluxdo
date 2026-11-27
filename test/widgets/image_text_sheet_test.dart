import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/image_ocr_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/ocr/local_ocr_service.dart';
import 'package:fluxdo/services/ocr/ocr_model_store.dart';
import 'package:fluxdo/widgets/common/error_view.dart';
import 'package:fluxdo/widgets/common/image_text_sheet.dart';

class _ModelStore extends Fake implements OcrModelStore {
  bool ready = false;
  int downloads = 0;
  Completer<void>? downloadGate;
  void Function(double)? lastProgress;
  bool invalidated = false;

  @override
  Future<bool> isReady() async => ready;

  @override
  void invalidateVerificationCache() {
    invalidated = true;
  }

  @override
  Future<void> download({
    required CancelToken cancelToken,
    required void Function(double) onProgress,
  }) async {
    downloads++;
    lastProgress = onProgress;
    if (downloadGate != null) {
      await downloadGate!.future;
    }
    onProgress(0.5);
    ready = true;
    onProgress(1);
  }

  @override
  Future<OcrModelPaths> paths() async =>
      (detector: 'detector', recognizer: 'reader', config: 'config');
}

class _OcrService extends Fake implements LocalOcrService {
  final result = Completer<OcrResult>();
  CancelToken? token;
  void Function(OcrProgress)? progressCallback;

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
  }) {
    token = cancelToken;
    progressCallback = onProgress;
    return result.future;
  }
}

void main() {
  for (final closeDuringRecognition in [false, true]) {
    testWidgets(
      closeDuringRecognition ? '关闭识字面板会取消识别任务' : '首次识字先提示下载，下载后可选择和复制识别文字',
      (tester) async {
        final store = _ModelStore();
        final service = _OcrService();
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        var imageLoads = 0;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              ocrModelStoreProvider.overrideWithValue(store),
              localOcrServiceProvider.overrideWithValue(service),
            ],
            child: TranslationProvider(
              child: MaterialApp(
                navigatorKey: navigatorKey,
                home: Scaffold(
                  body: ImageTextSheet(
                    loadImage: (_) async {
                      imageLoads++;
                      return Uint8List.fromList([1, 2, 3]);
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('下载文字识别模型'), findsOneWidget);
        expect(find.textContaining('29.7 MiB'), findsOneWidget);
        expect(store.downloads, 0);
        expect(imageLoads, 0);
        await tester.tap(find.text('下载文字识别模型'));
        await tester.pump();
        expect(store.downloads, 1);
        expect(imageLoads, 1);
        if (closeDuringRecognition) {
          await tester.pumpWidget(const SizedBox());
          expect(service.token!.isCancelled, isTrue);
          service.result.complete(
            const OcrResult(
              imageWidth: 100,
              imageHeight: 40,
              lines: [
                OcrTextLine(
                  text: '迟到结果',
                  bounds: Rect.fromLTWH(0, 0, 80, 20),
                  charBounds: [],
                  rowIndex: 0,
                ),
              ],
            ),
          );
          await tester.pump();
        } else {
          service.progressCallback?.call(
            const OcrProgress(
              stage: OcrStage.recognizing,
              completed: 2,
              total: 5,
            ),
          );
          await tester.pump();
          expect(find.text('正在识别文字（2/5）'), findsOneWidget);

          service.result.complete(
            const OcrResult(
              imageWidth: 200,
              imageHeight: 60,
              lines: [
                OcrTextLine(
                  text: '<原文> Hello',
                  bounds: Rect.fromLTWH(0, 0, 120, 24),
                  charBounds: [],
                  rowIndex: 0,
                ),
              ],
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(SelectableText), findsOneWidget);
          expect(find.text('<原文> Hello'), findsOneWidget);
          expect(find.text('复制'), findsOneWidget);
          expect(find.text('翻译'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('下载模型刚启动尚未收到进度时显示下载中文案而非识别中', (tester) async {
    final store = _ModelStore()..downloadGate = Completer<void>();
    final service = _OcrService();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          ocrModelStoreProvider.overrideWithValue(store),
          localOcrServiceProvider.overrideWithValue(service),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: Scaffold(
              body: ImageTextSheet(
                loadImage: (_) async => Uint8List.fromList([1, 2, 3]),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载文字识别模型'));
    await tester.pump();

    expect(find.text('正在下载识字模型'), findsOneWidget);
    expect(find.text('正在识别文字'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('识字失败时展示统一 ErrorView 并支持查看详情', (tester) async {
    final store = _ModelStore()..ready = true;
    final service = _OcrService();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          ocrModelStoreProvider.overrideWithValue(store),
          localOcrServiceProvider.overrideWithValue(service),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: Scaffold(
              body: ImageTextSheet(
                loadImage: (_) async => Uint8List.fromList([1, 2, 3]),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    service.result.completeError(StateError('native library missing'));
    await tester.pumpAndSettle();

    expect(find.byType(ErrorView), findsOneWidget);
    expect(find.text('文字识别失败，请重试'), findsOneWidget);
    expect(find.text('查看详情'), findsOneWidget);
    expect(store.invalidated, isTrue);
    expect(tester.takeException(), isNull);
  });
}
