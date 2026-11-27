import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_ocr/fluxdo_ocr.dart';

// fixture 是 TensorFlow 2.21.0 导出的 [1,3,H,W] -> x[:, :1] * 2，
// 不含第三方权重，用真实随包运行库覆盖动态输出和内存生命周期。
const _fixture = 'test/fixtures/ocr/channel_double.tflite';

void main() {
  test('连续扩缩尺寸后读取完整动态输出，NCHW 通道不混淆', () {
    final model = OcrInferenceModel.open(_fixture);
    addTearDown(model.close);
    for (final size in [(3, 2), (17, 11), (3, 2), (1, 1)]) {
      final (width, height) = size;
      final plane = width * height;
      final input = Float32List.fromList([
        for (var i = 0; i < plane; i++) i / 2,
        ...List.filled(plane, 1000),
        ...List.filled(plane, -1000),
      ]);
      model.infer(width, height, input, (shape, scores) {
        expect(shape, [1, 1, height, width]);
        expect(scores, [for (var i = 0; i < plane; i++) i.toDouble()]);
      });
    }
  });

  test('输出回调抛错后可继续推理，读取期间禁止重入和释放', () {
    final model = OcrInferenceModel.open(_fixture);
    addTearDown(model.close);
    final input = Float32List.fromList([3, 100, 200]);
    expect(
      () => model.infer<void>(1, 1, input, (_, _) {
        expect(model.close, throwsStateError);
        expect(() => model.infer(1, 1, input, (_, _) {}), throwsStateError);
        throw const FormatException('业务解码失败');
      }),
      throwsFormatException,
    );
    expect(model.infer(1, 1, input, (_, scores) => scores.single), 6);
  });

  test('拒绝错误输入；释放可重复且释放后不再进入原生代码', () {
    final model = OcrInferenceModel.open(_fixture);
    expect(
      () => model.infer(1, 1, Float32List(2), (_, _) {}),
      throwsArgumentError,
    );
    model.close();
    model.close();
    expect(
      () => model.infer(1, 1, Float32List(3), (_, _) {}),
      throwsStateError,
    );
    expect(() => OcrInferenceModel.open('pubspec.yaml'), throwsFormatException);
  });

  test('原生 C 检测/识别预处理与白底 Alpha 合成及桶宽零填充精度一致', () {
    // 2x2 RGBA 图像：(0,0)=半透明红(200,0,0,128), (1,0)=不透明蓝(0,0,255,255)
    final rgba = Uint8List.fromList([
      200, 0, 0, 128, 0, 0, 255, 255,
      10, 20, 30, 255, 255, 255, 255, 0,
    ]);
    final nativeImg = OcrNativeImage.fromBytes(
      bytes: rgba,
      width: 2,
      height: 2,
      channels: 4,
    );
    addTearDown(nativeImg.dispose);

    using((arena) {
      // 1. 检测 1:1 预处理
      final detOut = arena<Float>(3 * 2 * 2);
      OcrNativeOps.prepareDetNchw(
        src: nativeImg.pointer,
        srcWidth: 2,
        srcHeight: 2,
        channels: 4,
        cropY: 0,
        cropHeight: 2,
        dstWidth: 2,
        dstHeight: 2,
        dstNchw: detOut,
      );
      final det = detOut.asTypedList(12);
      // (0,0) 白底合成: r=(200*128+255*127+127)~/255=227, g=127, b=127
      expect(det[0], closeTo((127 / 255.0 - 0.485) / 0.229, 1e-4));
      expect(det[4], closeTo((127 / 255.0 - 0.456) / 0.224, 1e-4));
      expect(det[8], closeTo((227 / 255.0 - 0.406) / 0.225, 1e-4));
      // (1,1) 全透明 -> 纯白 (255,255,255)
      expect(det[3], closeTo((1.0 - 0.485) / 0.229, 1e-4));
      expect(det[7], closeTo((1.0 - 0.456) / 0.224, 1e-4));
      expect(det[11], closeTo((1.0 - 0.406) / 0.225, 1e-4));

      // 2. 识别预处理 + 桶宽右侧零填充（resizedW=2, bucketW=4, dstH=2）
      final recOut = arena<Float>(3 * 4 * 2);
      OcrNativeOps.prepareRecNchw(
        src: nativeImg.pointer,
        srcWidth: 2,
        srcHeight: 2,
        channels: 4,
        cropX: 0,
        cropY: 0,
        cropWidth: 2,
        cropHeight: 2,
        resizedWidth: 2,
        bucketWidth: 4,
        dstHeight: 2,
        dstNchw: recOut,
      );
      final rec = recOut.asTypedList(24);
      // (1,0) 纯蓝 (0,0,255): B=+1.0, G=-1.0, R=-1.0
      expect(rec[1], closeTo(1.0, 1e-4));
      expect(rec[8 + 1], closeTo(-1.0, 1e-4));
      expect(rec[16 + 1], closeTo(-1.0, 1e-4));
      // 右侧零填充列 [2, 3] 应严格为 0.0
      expect(rec[2], 0.0);
      expect(rec[3], 0.0);
      expect(rec[8 + 2], 0.0);
      expect(rec[16 + 3], 0.0);
    });
  });

  test('原生 C DB 连通域提取与 CTC 贪心解码结果准确', () {
    using((arena) {
      // 1. 20x10 概率图，在 [4..12) × [2..7) 放一个高置信文本块
      const w = 20, h = 10;
      final map = arena<Float>(w * h);
      final mapView = map.asTypedList(w * h);
      mapView.fillRange(0, w * h, 0.05);
      for (var y = 2; y < 7; y++) {
        for (var x = 4; x < 12; x++) {
          mapView[y * w + x] = 0.85;
        }
      }
      final boxes = OcrNativeOps.extractDetBoxes(
        scores: map,
        width: w,
        height: h,
      );
      expect(boxes.length, 4);
      expect(boxes[0], lessThan(4.0));
      expect(boxes[1], lessThan(2.0));
      expect(boxes[2], greaterThan(12.0));
      expect(boxes[3], greaterThan(7.0));

      // 2. CTC argmax：steps=6, classes=4, 序列 [1, 1, 0, 2, 3, 3] -> labels [1, 2, 3]
      const steps = 6, classes = 4;
      final scores = arena<Float>(steps * classes);
      final sView = scores.asTypedList(steps * classes);
      sView.fillRange(0, sView.length, -1.0);
      final seq = [1, 1, 0, 2, 3, 3];
      for (var t = 0; t < steps; t++) {
        sView[t * classes + seq[t]] = 5.0;
      }
      final decoded = OcrNativeOps.ctcArgmax(
        scores: scores,
        steps: steps,
        classes: classes,
        width: 60,
        fromPx: 0,
        untilPx: 60,
      );
      expect(decoded.labels, [1, 2, 3]);
      expect(decoded.leftPx[0], closeTo(0.0, 1e-4));
      expect(decoded.rightPx[0], closeTo(20.0, 1e-4));
      expect(decoded.leftPx[1], closeTo(30.0, 1e-4));
      expect(decoded.rightPx[1], closeTo(40.0, 1e-4));
      expect(decoded.leftPx[2], closeTo(40.0, 1e-4));
      expect(decoded.rightPx[2], closeTo(60.0, 1e-4));
    });
  });

  test('inferDirect 零拷贝原生指针推理与 infer 一致', () {
    final model = OcrInferenceModel.open(_fixture);
    addTearDown(model.close);
    final out = model.inferDirect(
      4,
      3,
      (input) {
        final view = input.asTypedList(3 * 4 * 3);
        for (var i = 0; i < 12; i++) {
          view[i] = i.toDouble();
        }
      },
      (shape, output) {
        expect(shape, [1, 1, 3, 4]);
        return Float32List.fromList(output.asTypedList(12));
      },
    );
    expect(out, [for (var i = 0; i < 12; i++) i * 2.0]);
  });
}
