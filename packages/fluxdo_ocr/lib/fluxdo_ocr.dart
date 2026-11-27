import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

part 'src/litert_bindings.dart';
part 'src/ocr_ops_bindings.dart';

const _runtime = 'package:fluxdo_ocr/litert';
// 来自 LiteRT 2.4.0 xnnpack_delegate.h：
// FORCE_FP16 (0x04) 仅在具备原生 ARM64 NEON FP16 硬件的平台上启用（x86 模拟反而更慢）；
// Subgraph reshaping 在 LiteRT 2.4.0 中已默认开启，无需再显式传废弃标志位。
const _xnnFlagForceFp16 = 0x00000004;

bool _supportsNativeFp16() => switch (Abi.current()) {
  Abi.macosArm64 ||
  Abi.iosArm64 ||
  Abi.androidArm64 ||
  Abi.linuxArm64 ||
  Abi.windowsArm64 => true,
  _ => false,
};

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
  int _allocateCount = 0;
  bool _busy = false;

  /// 当前会话累计触发的 `AllocateTensors` 次数（用于观测宽度分桶效果）。
  int get allocateCount => _allocateCount;

  /// 清零张量分配计数。
  void resetAllocateCount() => _allocateCount = 0;

  /// 按当前平台 CPU 核心数推导默认推理线程数：桌面 2~6，移动 2~4。
  static int defaultThreads() {
    final cores = Platform.numberOfProcessors;
    final half = cores ~/ 2;
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      return half.clamp(2, 6);
    }
    return half.clamp(2, 4);
  }

  factory OcrInferenceModel.open(String path, {int? threads}) {
    final numThreads = (threads ?? defaultThreads()).clamp(1, 8);
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
        _optionsThreads(options, numThreads);
        using((arena) {
          final xnnOptions = arena<_XnnOptions>()..ref = _xnnOptionsDefault();
          xnnOptions.ref.numThreads = numThreads;
          final baseFlags = xnnOptions.ref.flags;
          final tunedFlags = _supportsNativeFp16()
              ? (baseFlags | _xnnFlagForceFp16)
              : baseFlags;
          xnnOptions.ref.flags = tunedFlags;
          session._delegate = _xnnCreate(xnnOptions);
          if (session._delegate == nullptr && tunedFlags != baseFlags) {
            xnnOptions.ref.flags = baseFlags;
            session._delegate = _xnnCreate(xnnOptions);
          }
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
    if (width < 1 || height < 1 || pixels.length != width * height * 3) {
      throw ArgumentError('OCR 图片尺寸不匹配');
    }
    return inferDirect(
      width,
      height,
      (inputBuffer) => inputBuffer.asTypedList(pixels.length).setAll(0, pixels),
      (shape, outputBuffer) {
        final length = shape.reduce((a, b) => a * b);
        return read(shape, outputBuffer.asTypedList(length));
      },
    );
  }

  /// 零拷贝原生张量推理：直接暴露 LiteRT 输入/输出 `Pointer<Float>` 给 C 预处理与后处理算子，
  /// 省去中间 Dart `Float32List` 分配与跨边界内存拷贝。
  T inferDirect<T>(
    int width,
    int height,
    void Function(Pointer<Float> inputBuffer) fillInput,
    T Function(List<int> shape, Pointer<Float> outputBuffer) readOutput,
  ) {
    if (_interpreter == nullptr) throw StateError('识字模型已释放');
    if (_busy) throw StateError('同一识字会话不能重入');
    if (width < 1 || height < 1) {
      throw ArgumentError('OCR 图片尺寸无效');
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
        _allocateCount++;
        _width = width;
        _height = height;
      }
      final input = _inputTensor(_interpreter, 0);
      final expectedBytes = width * height * 3 * sizeOf<Float>();
      final inputPtr = _tensorData(input);
      if (_tensorBytes(input) != expectedBytes || inputPtr == nullptr) {
        throw const FormatException('OCR 输入缓冲区尺寸不匹配');
      }
      fillInput(inputPtr);
      _check(_invoke(_interpreter), '执行模型');
      // 动态输出只有 Invoke 后才具有最终尺寸；每次都重新读取 tensor 指针和 shape。
      final output = _outputTensor(_interpreter, 0);
      final rank = _tensorRank(output);
      if (rank < 1 || rank > 4) throw const FormatException('OCR 输出维度无效');
      final shape = List<int>.generate(rank, (i) => _tensorDim(output, i));
      if (shape.any((d) => d <= 0)) throw const FormatException('OCR 输出尺寸无效');
      final length = shape.reduce((a, b) => a * b);
      final outputPtr = _tensorData(output);
      if (_tensorBytes(output) != length * sizeOf<Float>() ||
          outputPtr == nullptr) {
        throw const FormatException('OCR 输出缓冲区尺寸不匹配');
      }
      return readOutput(shape, outputPtr);
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
