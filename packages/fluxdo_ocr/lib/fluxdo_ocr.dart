import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

part 'src/litert_bindings.dart';

const _runtime = 'package:fluxdo_ocr/litert';

void _check(int status, String operation) {
  if (status != 0) throw StateError('LiteRT $operation 失败（$status）');
}

/// 随包 LiteRT 的 CPU 会话。动态输出由解释器持有，每个任务在工作 isolate 内使用。
final class OcrInferenceModel {
  OcrInferenceModel._();

  Pointer<Void> _model = nullptr;
  Pointer<Void> _interpreter = nullptr;
  Pointer<Void> _delegate = nullptr;
  Pointer<Uint8> _modelBytes = nullptr;
  int _width = 0;
  int _height = 0;
  bool _busy = false;

  factory OcrInferenceModel.open(String path) {
    final bytes = File(path).readAsBytesSync();
    if (bytes.length < 8 ||
        bytes[4] != 0x54 ||
        bytes[5] != 0x46 ||
        bytes[6] != 0x4c ||
        bytes[7] != 0x33) {
      throw const FormatException('OCR 模型不是 LiteRT FlatBuffer');
    }
    final session = OcrInferenceModel._();
    try {
      // LiteRT 不复制模型数据，必须保留至解释器和模型都释放后。
      session._modelBytes = calloc<Uint8>(bytes.length);
      session._modelBytes.asTypedList(bytes.length).setAll(0, bytes);
      session._model = _modelCreate(session._modelBytes, bytes.length);
      if (session._model == nullptr) {
        throw const FormatException('LiteRT 无法读取识字模型');
      }
      final options = _optionsCreate();
      if (options == nullptr) throw StateError('LiteRT 无法创建推理配置');
      try {
        _optionsThreads(options, 2);
        using((arena) {
          final xnnOptions = arena<_XnnOptions>()..ref = _xnnOptionsDefault();
          xnnOptions.ref.numThreads = 2;
          session._delegate = _xnnCreate(xnnOptions);
        });
        if (session._delegate != nullptr) {
          _optionsAddDelegate(options, session._delegate);
        }
        session._interpreter = _interpreterCreate(session._model, options);
      } finally {
        _optionsDelete(options);
      }
      if (session._interpreter == nullptr) throw StateError('LiteRT 无法创建识字会话');
      if (_inputCount(session._interpreter) != 1 ||
          _outputCount(session._interpreter) != 1) {
        throw const FormatException('OCR 模型需要单个输入和输出');
      }
      final input = _inputTensor(session._interpreter, 0);
      final output = _outputTensor(session._interpreter, 0);
      if (_tensorType(input) != 1 ||
          _tensorRank(input) != 4 ||
          _tensorDim(input, 1) != 3) {
        throw const FormatException('OCR 模型输入必须是 NCHW float32');
      }
      if (_tensorType(output) != 1) {
        throw const FormatException('OCR 模型输出必须是 float32');
      }
      return session;
    } catch (_) {
      session.close();
      rethrow;
    }
  }

  /// 输出视图只在回调内有效。同尺寸复用输入，变宽文本和长截图切片按需调整张量。
  T infer<T>(
    int width,
    int height,
    Float32List pixels,
    T Function(List<int> shape, Float32List scores) read,
  ) {
    if (_interpreter == nullptr) throw StateError('识字模型已释放');
    if (_busy) throw StateError('同一识字会话不能重入');
    if (width < 1 || height < 1 || pixels.length != width * height * 3) {
      throw ArgumentError('OCR 图片尺寸不匹配');
    }
    _busy = true;
    try {
      if (_width != width || _height != height) {
        _width = _height = 0;
        using((arena) {
          final dimensions = arena<Int32>(4);
          dimensions.asTypedList(4).setAll(0, [1, 3, height, width]);
          _check(_resizeInput(_interpreter, 0, dimensions, 4), '调整图片尺寸');
          _check(_allocateTensors(_interpreter), '分配张量');
        });
        _width = width;
        _height = height;
      }
      final input = _inputTensor(_interpreter, 0);
      if (_tensorBytes(input) != pixels.lengthInBytes ||
          _tensorData(input) == nullptr) {
        throw const FormatException('OCR 输入缓冲区尺寸不匹配');
      }
      _tensorData(input).asTypedList(pixels.length).setAll(0, pixels);
      _check(_invoke(_interpreter), '执行模型');
      // 动态输出只有 Invoke 后才具有最终尺寸；每次都重新读取 tensor 指针和 shape。
      final output = _outputTensor(_interpreter, 0);
      final rank = _tensorRank(output);
      if (rank < 1 || rank > 4) throw const FormatException('OCR 输出维度无效');
      final shape = List<int>.generate(rank, (i) => _tensorDim(output, i));
      if (shape.any((d) => d <= 0)) throw const FormatException('OCR 输出尺寸无效');
      final length = shape.reduce((a, b) => a * b);
      if (_tensorBytes(output) != length * sizeOf<Float>() ||
          _tensorData(output) == nullptr) {
        throw const FormatException('OCR 输出缓冲区尺寸不匹配');
      }
      return read(shape, _tensorData(output).asTypedList(length));
    } finally {
      _busy = false;
    }
  }

  void close() {
    if (_busy) throw StateError('不能在读取输出时释放识字会话');
    if (_interpreter != nullptr) _interpreterDelete(_interpreter);
    if (_delegate != nullptr) _xnnDelete(_delegate);
    if (_model != nullptr) _modelDelete(_model);
    if (_modelBytes != nullptr) calloc.free(_modelBytes);
    _interpreter = nullptr;
    _delegate = nullptr;
    _model = nullptr;
    _modelBytes = nullptr;
  }
}
