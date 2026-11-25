import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const _bridge = 'package:fluxdo_ocr/bridge';

@Native<Pointer<Void> Function()>(
  symbol: 'OrtGetApiBase',
  assetId: 'package:fluxdo_ocr/onnxruntime',
)
external Pointer<Void> _ortApiBase();

@Native<
  Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, Size, Pointer<Utf8>)
>(symbol: 'ocr_open', assetId: _bridge)
external Pointer<Void> _open(
  Pointer<Void> api,
  Pointer<Uint8> bytes,
  int length,
  Pointer<Utf8> error,
);

@Native<Void Function(Pointer<Void>)>(symbol: 'ocr_close', assetId: _bridge)
external void _close(Pointer<Void> model);

final class _Output extends Struct {
  external Pointer<Void> value;
  external Pointer<Float> data;
  @Array(4)
  external Array<Int64> dimensions;
  @Size()
  external int rank;
}

@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<Float>,
    Int32,
    Int32,
    Pointer<_Output>,
    Pointer<Utf8>,
  )
>(symbol: 'ocr_run', assetId: _bridge)
external int _run(
  Pointer<Void> model,
  Pointer<Float> pixels,
  int width,
  int height,
  Pointer<_Output> out,
  Pointer<Utf8> error,
);

@Native<Void Function(Pointer<Void>, Pointer<_Output>)>(
  symbol: 'ocr_release_output',
  assetId: _bridge,
)
external void _releaseOutput(Pointer<Void> model, Pointer<_Output> out);

/// PP-OCR 的 CPU 会话。每个识字任务在自己的 isolate 内创建并释放。
final class OcrInferenceModel {
  OcrInferenceModel._(this._handle);
  Pointer<Void> _handle;

  factory OcrInferenceModel.open(String path) => using((arena) {
    final bytes = File(path).readAsBytesSync();
    final data = arena<Uint8>(bytes.length);
    data.asTypedList(bytes.length).setAll(0, bytes);
    final error = arena<Uint8>(512).cast<Utf8>();
    final handle = _open(
      Platform.isIOS ? nullptr : _ortApiBase(),
      data,
      bytes.length,
      error,
    );
    if (handle == nullptr) throw StateError(error.toDartString());
    return OcrInferenceModel._(handle);
  });

  /// 输出视图只在回调执行期间有效，避免把整幅概率图复制到 Dart 堆。
  T infer<T>(
    int width,
    int height,
    Float32List pixels,
    T Function(List<int> shape, Float32List scores) read,
  ) => using((arena) {
    if (_handle == nullptr) throw StateError('识字模型已释放');
    if (width < 1 || height < 1 || pixels.length != width * height * 3) {
      throw ArgumentError('OCR 图片尺寸不匹配');
    }
    final input = arena<Float>(pixels.length);
    input.asTypedList(pixels.length).setAll(0, pixels);
    final out = arena<_Output>();
    final error = arena<Uint8>(512).cast<Utf8>();
    if (_run(_handle, input, width, height, out, error) == 0) {
      throw StateError(error.toDartString());
    }
    try {
      final shape = List.generate(out.ref.rank, (i) => out.ref.dimensions[i]);
      final length = shape.reduce((a, b) => a * b);
      return read(shape, out.ref.data.asTypedList(length));
    } finally {
      _releaseOutput(_handle, out);
    }
  });

  void close() {
    _close(_handle);
    _handle = nullptr;
  }
}
