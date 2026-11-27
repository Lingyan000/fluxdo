part of '../fluxdo_ocr.dart';

const _opsRuntime = 'package:fluxdo_ocr/ocr_ops';

@Native<
  Int32 Function(
    Pointer<Uint8>,
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
    Pointer<Float>,
  )
>(symbol: 'fluxdo_ocr_prepare_det_nchw', assetId: _opsRuntime)
external int _prepareDetNchw(
  Pointer<Uint8> src,
  int srcW,
  int srcH,
  int channels,
  int cropY,
  int cropH,
  int dstW,
  int dstH,
  Pointer<Float> dstNchw,
);

@Native<
  Int32 Function(
    Pointer<Uint8>,
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
    Pointer<Float>,
  )
>(symbol: 'fluxdo_ocr_prepare_rec_nchw', assetId: _opsRuntime)
external int _prepareRecNchw(
  Pointer<Uint8> src,
  int srcW,
  int srcH,
  int channels,
  int cropX,
  int cropY,
  int cropW,
  int cropH,
  int resizedW,
  int bucketW,
  int dstH,
  Pointer<Float> dstNchw,
);

@Native<
  Int32 Function(
    Pointer<Float>,
    Int32,
    Int32,
    Float,
    Float,
    Float,
    Pointer<Float>,
    Int32,
  )
>(symbol: 'fluxdo_ocr_extract_det_boxes', assetId: _opsRuntime)
external int _extractDetBoxes(
  Pointer<Float> scores,
  int width,
  int height,
  double threshold,
  double minScore,
  double unclipRatio,
  Pointer<Float> outBoxes,
  int maxBoxes,
);

@Native<
  Int32 Function(
    Pointer<Float>,
    Int32,
    Int32,
    Int32,
    Float,
    Float,
    Pointer<Int32>,
    Pointer<Float>,
    Pointer<Float>,
    Int32,
  )
>(symbol: 'fluxdo_ocr_ctc_argmax', assetId: _opsRuntime)
external int _ctcArgmax(
  Pointer<Float> scores,
  int steps,
  int classes,
  int width,
  double fromPx,
  double untilPx,
  Pointer<Int32> outLabels,
  Pointer<Float> outLeftPx,
  Pointer<Float> outRightPx,
  int maxTokens,
);

/// 托管原生内存中的 uint8 RGB/RGBA 原图缓冲区，供单次 OCR 任务内全部检测切片与识别行零拷贝复用。
final class OcrNativeImage {
  OcrNativeImage.fromBytes({
    required Uint8List bytes,
    required this.width,
    required this.height,
    required this.channels,
  }) : _ptr = _allocAndCopy(bytes, width, height, channels);

  final int width;
  final int height;
  final int channels;
  Pointer<Uint8> _ptr;

  static Pointer<Uint8> _allocAndCopy(
    Uint8List bytes,
    int width,
    int height,
    int channels,
  ) {
    if (width <= 0 || height <= 0 || (channels != 3 && channels != 4)) {
      throw ArgumentError('OCR 原生图像参数无效');
    }
    final expected = width * height * channels;
    if (bytes.length < expected) {
      throw ArgumentError('OCR 原生图像字节数不足');
    }
    final ptr = malloc<Uint8>(expected);
    ptr.asTypedList(expected).setRange(0, expected, bytes);
    return ptr;
  }

  Pointer<Uint8> get pointer {
    if (_ptr == nullptr) throw StateError('OCR 原生图像缓冲区已释放');
    return _ptr;
  }

  void dispose() {
    if (_ptr != nullptr) {
      malloc.free(_ptr);
      _ptr = nullptr;
    }
  }
}

/// 原生 C 加速的 OCR 图像预处理、检测框连通域提取与 CTC 解码算子。
abstract final class OcrNativeOps {
  /// 检测单片一站式零拷贝执行：C 融合预处理直写张量 → LiteRT 推理 → C 连通域提取检测框。
  static Float32List runDetectionBand({
    required OcrInferenceModel detector,
    required OcrNativeImage image,
    required int cropY,
    required int cropHeight,
    required int dstWidth,
    required int dstHeight,
    double threshold = 0.3,
    double minScore = 0.45,
    double unclipRatio = 1.4,
  }) {
    final srcPtr = image.pointer;
    return detector.inferDirect(
      dstWidth,
      dstHeight,
      (inputBuffer) {
        prepareDetNchw(
          src: srcPtr,
          srcWidth: image.width,
          srcHeight: image.height,
          channels: image.channels,
          cropY: cropY,
          cropHeight: cropHeight,
          dstWidth: dstWidth,
          dstHeight: dstHeight,
          dstNchw: inputBuffer,
        );
      },
      (shape, outputBuffer) {
        if (shape.length != 4 ||
            shape[0] != 1 ||
            shape[1] != 1 ||
            shape[2] != dstHeight ||
            shape[3] != dstWidth) {
          throw const FormatException('OCR 检测输出尺寸不匹配');
        }
        return extractDetBoxes(
          scores: outputBuffer,
          width: dstWidth,
          height: dstHeight,
          threshold: threshold,
          minScore: minScore,
          unclipRatio: unclipRatio,
        );
      },
    );
  }

  /// 识别单行切片一站式零拷贝执行：C 融合裁剪缩放归一化直写张量 → LiteRT 推理 → C CTC 贪心解码。
  static ({Int32List labels, Float32List leftPx, Float32List rightPx})
  runRecognitionSlice({
    required OcrInferenceModel recognizer,
    required OcrNativeImage image,
    required int cropX,
    required int cropY,
    required int cropWidth,
    required int cropHeight,
    required int resizedWidth,
    required int bucketWidth,
    required int dstHeight,
    required double fromPx,
    required double untilPx,
    required int expectedClasses,
  }) {
    final srcPtr = image.pointer;
    return recognizer.inferDirect(
      bucketWidth,
      dstHeight,
      (inputBuffer) {
        prepareRecNchw(
          src: srcPtr,
          srcWidth: image.width,
          srcHeight: image.height,
          channels: image.channels,
          cropX: cropX,
          cropY: cropY,
          cropWidth: cropWidth,
          cropHeight: cropHeight,
          resizedWidth: resizedWidth,
          bucketWidth: bucketWidth,
          dstHeight: dstHeight,
          dstNchw: inputBuffer,
        );
      },
      (shape, outputBuffer) {
        if (shape.length != 3 ||
            shape[0] != 1 ||
            shape[2] != expectedClasses) {
          throw const FormatException('OCR 模型与字典不匹配');
        }
        return ctcArgmax(
          scores: outputBuffer,
          steps: shape[1],
          classes: expectedClasses,
          width: bucketWidth,
          fromPx: fromPx,
          untilPx: untilPx,
        );
      },
    );
  }

  /// 融合裁剪 + 双线性缩放 + 内联白底 Alpha 合成 + BGR ImageNet 归一化，直接写入张量内存。
  static void prepareDetNchw({
    required Pointer<Uint8> src,
    required int srcWidth,
    required int srcHeight,
    required int channels,
    required int cropY,
    required int cropHeight,
    required int dstWidth,
    required int dstHeight,
    required Pointer<Float> dstNchw,
  }) {
    final status = _prepareDetNchw(
      src,
      srcWidth,
      srcHeight,
      channels,
      cropY,
      cropHeight,
      dstWidth,
      dstHeight,
      dstNchw,
    );
    if (status != 0) {
      throw StateError('OCR 原生检测预处理失败（$status）');
    }
  }

  /// 融合裁剪 + 双线性缩放 + 内联白底 Alpha 合成 + [-1, 1] BGR 归一化 + 桶宽零填充。
  static void prepareRecNchw({
    required Pointer<Uint8> src,
    required int srcWidth,
    required int srcHeight,
    required int channels,
    required int cropX,
    required int cropY,
    required int cropWidth,
    required int cropHeight,
    required int resizedWidth,
    required int bucketWidth,
    required int dstHeight,
    required Pointer<Float> dstNchw,
  }) {
    final status = _prepareRecNchw(
      src,
      srcWidth,
      srcHeight,
      channels,
      cropX,
      cropY,
      cropWidth,
      cropHeight,
      resizedWidth,
      bucketWidth,
      dstHeight,
      dstNchw,
    );
    if (status != 0) {
      throw StateError('OCR 原生识别预处理失败（$status）');
    }
  }

  /// 原生 C 扫描线连通域提取，返回扁平 `[left, top, right, bottom, ...]` 浮点列表。
  static Float32List extractDetBoxes({
    required Pointer<Float> scores,
    required int width,
    required int height,
    double threshold = 0.3,
    double minScore = 0.45,
    double unclipRatio = 1.4,
    int maxBoxes = 2048,
  }) {
    return using((arena) {
      final out = arena<Float>(maxBoxes * 4);
      final count = _extractDetBoxes(
        scores,
        width,
        height,
        threshold,
        minScore,
        unclipRatio,
        out,
        maxBoxes,
      );
      if (count <= 0) return Float32List(0);
      return Float32List.fromList(out.asTypedList(count * 4));
    });
  }

  /// 原生 C CTC 贪心解码，返回解码后的字典索引与左右像素范围。
  static ({Int32List labels, Float32List leftPx, Float32List rightPx})
  ctcArgmax({
    required Pointer<Float> scores,
    required int steps,
    required int classes,
    required int width,
    required double fromPx,
    required double untilPx,
  }) {
    return using((arena) {
      final maxTokens = steps;
      final labels = arena<Int32>(maxTokens);
      final lefts = arena<Float>(maxTokens);
      final rights = arena<Float>(maxTokens);
      final count = _ctcArgmax(
        scores,
        steps,
        classes,
        width,
        fromPx,
        untilPx,
        labels,
        lefts,
        rights,
        maxTokens,
      );
      if (count <= 0) {
        return (
          labels: Int32List(0),
          leftPx: Float32List(0),
          rightPx: Float32List(0),
        );
      }
      return (
        labels: Int32List.fromList(labels.asTypedList(count)),
        leftPx: Float32List.fromList(lefts.asTypedList(count)),
        rightPx: Float32List.fromList(rights.asTypedList(count)),
      );
    });
  }
}
