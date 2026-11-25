import 'dart:typed_data';

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
}
