import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/ocr_engine_preference.dart';
import 'package:fluxdo/services/ocr/apple_vision_ocr.dart';
import 'package:fluxdo/services/ocr/local_ocr_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppleVisionOcr.parseNativeResult', () {
    test('按视觉行顺序归并同行多段文本并保持逐字包围盒对齐', () {
      final raw = <Object?, Object?>{
        'imageWidth': 1000,
        'imageHeight': 800,
        'lines': [
          {
            'text': 'Second Row',
            'bounds': [40.0, 200.0, 240.0, 230.0],
            'charBounds': Float64List.fromList([
              for (var i = 0; i < 10; i++) ...[
                40.0 + i * 20.0,
                200.0,
                60.0 + i * 20.0,
                230.0,
              ],
            ]),
          },
          {
            'text': 'Right',
            'bounds': [300.0, 52.0, 400.0, 82.0],
            'charBounds': Float64List.fromList([
              for (var i = 0; i < 5; i++) ...[
                300.0 + i * 20.0,
                52.0,
                320.0 + i * 20.0,
                82.0,
              ],
            ]),
          },
          {
            'text': '  Left  ',
            'bounds': [50.0, 50.0, 150.0, 80.0],
            // 故意省略 charBounds，验证自动均分兜底。
          },
          {
            'text': '   ',
            'bounds': [10.0, 10.0, 20.0, 20.0],
          },
        ],
      };

      final result = AppleVisionOcr.parseNativeResult(raw);
      expect(result.imageWidth, 1000);
      expect(result.imageHeight, 800);
      expect(result.lines.length, 3);

      // 第一视觉行：Left 在前、Right 在后，共享 rowIndex=0。
      expect(result.lines[0].text, 'Left');
      expect(result.lines[0].rowIndex, 0);
      expect(result.lines[0].charBounds.length, 4);
      expect(result.lines[0].charBounds.first.left, closeTo(50.0, 1e-6));
      expect(result.lines[0].charBounds.last.right, closeTo(150.0, 1e-6));

      expect(result.lines[1].text, 'Right');
      expect(result.lines[1].rowIndex, 0);
      expect(result.lines[1].charBounds.length, 5);

      // 第二视觉行：rowIndex=1。
      expect(result.lines[2].text, 'Second Row');
      expect(result.lines[2].rowIndex, 1);
      expect(result.lines[2].charBounds.length, 10);
    });
  });

  group('AppleVisionOcr MethodChannel', () {
    const channel = MethodChannel('com.fluxdo/vision_ocr_test');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('未注册原生通道时 isAvailable 安全返回 false', () async {
      final available = await AppleVisionOcr.isAvailable(channel: channel);
      expect(available, isFalse);
    });

    test('调用原生 recognize 并返回解析后的 OcrResult', () async {
      Uint8List? receivedBytes;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'isAvailable') return true;
            if (call.method == 'recognize') {
              receivedBytes = call.arguments as Uint8List?;
              return {
                'imageWidth': 640,
                'imageHeight': 480,
                'lines': [
                  {
                    'text': '你好',
                    'bounds': [10.0, 20.0, 90.0, 50.0],
                    'charBounds': Float64List.fromList([
                      10.0,
                      20.0,
                      50.0,
                      50.0,
                      50.0,
                      20.0,
                      90.0,
                      50.0,
                    ]),
                  },
                ],
              };
            }
            return null;
          });

      expect(await AppleVisionOcr.isAvailable(channel: channel), isTrue);
      final input = Uint8List.fromList([1, 2, 3, 4]);
      final result = await AppleVisionOcr.recognize(input, channel: channel);
      expect(receivedBytes, equals(input));
      expect(result.imageWidth, 640);
      expect(result.imageHeight, 480);
      expect(result.lines.single.text, '你好');
      expect(result.lines.single.charBounds.length, 2);
      expect(
        result.lines.single.boundsForRange(0, 1),
        const Rect.fromLTRB(10, 20, 50, 50),
      );
    });
  });

  group('LocalOcrService 系统引擎路由与偏好解析', () {
    test('OcrEnginePreference.parse 兼容缺省与未知值', () {
      expect(OcrEnginePreference.parse(null), OcrEnginePreference.system);
      expect(OcrEnginePreference.parse('unknown'), OcrEnginePreference.system);
      expect(OcrEnginePreference.parse('system'), OcrEnginePreference.system);
      expect(OcrEnginePreference.parse('litert'), OcrEnginePreference.litert);
    });

    test('useSystemEngine 为 true 时免模型路径直接识别、跳过 RGBA 回读并命中缓存', () async {
      var calls = 0;
      var rgbaLoads = 0;
      final stubResult = OcrResult(
        imageWidth: 200,
        imageHeight: 100,
        lines: [
          OcrTextLine(
            text: 'Hi',
            bounds: const Rect.fromLTRB(10, 10, 50, 30),
            charBounds: const [
              Rect.fromLTRB(10, 10, 30, 30),
              Rect.fromLTRB(30, 10, 50, 30),
            ],
            rowIndex: 0,
          ),
        ],
      );
      final service = LocalOcrService(
        systemRecognizer: (_) async {
          calls++;
          return stubResult;
        },
      );
      addTearDown(service.dispose);

      List<Rect>? detectedBoxes;
      OcrResult? partialResult;
      final bytes = Uint8List.fromList([9, 8, 7, 6]);

      final first = await service.recognizeDetailed(
        bytes,
        null,
        useSystemEngine: true,
        loadRgba: () async {
          rgbaLoads++;
          return null;
        },
        onDetected: (_, _, boxes) => detectedBoxes = boxes,
        onPartial: (partial) => partialResult = partial,
      );

      expect(calls, 1);
      expect(rgbaLoads, 0);
      expect(first.plainText, 'Hi');
      expect(detectedBoxes, hasLength(1));
      expect(partialResult, same(stubResult));

      // 二次识别同一图片应直接命中缓存。
      final second = await service.recognizeDetailed(
        bytes,
        null,
        useSystemEngine: true,
      );
      expect(calls, 1);
      expect(second.plainText, 'Hi');
    });

    test('useSystemEngine 失败且未提供离线模型路径时上抛异常', () async {
      final service = LocalOcrService(
        systemRecognizer: (_) async => throw StateError('vision boom'),
      );
      addTearDown(service.dispose);

      await expectLater(
        service.recognizeDetailed(
          Uint8List.fromList([4, 5, 6]),
          null,
          useSystemEngine: true,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
