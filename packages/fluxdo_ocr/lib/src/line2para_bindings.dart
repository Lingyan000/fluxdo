part of '../fluxdo_ocr.dart';

@Native<Pointer<Void> Function(Pointer<Uint8>, Int32)>(
  symbol: 'fluxdo_line2para_open',
  assetId: _opsRuntime,
)
external Pointer<Void> _line2paraOpen(Pointer<Uint8> onnxBytes, int byteLen);

@Native<Void Function(Pointer<Void>)>(
  symbol: 'fluxdo_line2para_close',
  assetId: _opsRuntime,
)
external void _line2paraClose(Pointer<Void> handle);

@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<Uint8>,
    Int32,
    Int32,
    Int32,
    Pointer<Float>,
    Int32,
    Pointer<Int32>,
    Pointer<Int32>,
    Int32,
  )
>(symbol: 'fluxdo_line2para_group', assetId: _opsRuntime)
external int _line2paraGroup(
  Pointer<Void> handle,
  Pointer<Uint8> image,
  int width,
  int height,
  int channels,
  Pointer<Float> quadsFlat,
  int lineCount,
  Pointer<Int32> outOrder,
  Pointer<Int32> outGroupOffsets,
  int maxGroups,
);

@Native<
  Int32 Function(
    Pointer<Float>,
    Pointer<Uint8>,
    Int32,
    Pointer<Int32>,
    Pointer<Float>,
    Int32,
    Pointer<Int32>,
    Pointer<Int32>,
    Int32,
  )
>(symbol: 'fluxdo_line2para_decode_signed', assetId: _opsRuntime)
external int _line2paraDecodeSigned(
  Pointer<Float> quadsFlat,
  Pointer<Uint8> vertical,
  int lineCount,
  Pointer<Int32> pairsFlat,
  Pointer<Float> logits,
  int pairCount,
  Pointer<Int32> outOrder,
  Pointer<Int32> outGroupOffsets,
  int maxGroups,
);

/// line2para 原生段落归并模型会话。
///
/// 模型权重来自 `mgchao/SnowShotOCR`（Apache-2.0），推理算法移植自
/// `mg-chao/simd-paddle-ocr-rs`（Apache-2.0）。
final class OcrParagraphModel {
  OcrParagraphModel._(this._handle);

  Pointer<Void> _handle;

  /// 从磁盘 ONNX 文件加载 line2para B-Scale 模型。
  factory OcrParagraphModel.open(String path) =>
      OcrParagraphModel.fromBytes(File(path).readAsBytesSync());

  /// 从内存 ONNX 字节流加载 line2para B-Scale 模型。
  factory OcrParagraphModel.fromBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const FormatException('line2para 模型文件为空');
    }
    return using((arena) {
      final buf = arena<Uint8>(bytes.length);
      buf.asTypedList(bytes.length).setAll(0, bytes);
      final handle = _line2paraOpen(buf, bytes.length);
      if (handle == nullptr) {
        throw const FormatException('无法解析 line2para ONNX 模型');
      }
      return OcrParagraphModel._(handle);
    });
  }

  /// 对原图与文本行四点坐标执行视觉 + 几何 GNN 段落归并。
  ///
  /// - [quads]：长度为 `lineCount * 8` 的扁平数组，每 8 个值表示一行的四个顶点
  ///   `[x0, y0, x1, y1, x2, y2, x3, y3]`；
  /// - 返回按阅读顺序排列的段落列表，每段包含原始行索引。
  List<List<int>> groupLines({
    required OcrNativeImage image,
    required Float32List quads,
    required int lineCount,
  }) {
    if (_handle == nullptr) throw StateError('line2para 模型已释放');
    if (lineCount < 0 || quads.length != lineCount * 8) {
      throw ArgumentError('line2para 行坐标数量不匹配');
    }
    if (lineCount == 0) return const [];
    if (lineCount == 1) {
      return const [
        [0],
      ];
    }
    final imagePtr = image.pointer;
    return using((arena) {
      final quadsPtr = arena<Float>(quads.length);
      quadsPtr.asTypedList(quads.length).setAll(0, quads);
      final outOrder = arena<Int32>(lineCount);
      final outOffsets = arena<Int32>(lineCount + 1);
      final groupCount = _line2paraGroup(
        _handle,
        imagePtr,
        image.width,
        image.height,
        image.channels,
        quadsPtr,
        lineCount,
        outOrder,
        outOffsets,
        lineCount,
      );
      if (groupCount < 0) {
        throw StateError('line2para 段落归并失败（$groupCount）');
      }
      final orderList = outOrder.asTypedList(lineCount);
      final offsetList = outOffsets.asTypedList(groupCount + 1);
      return [
        for (var g = 0; g < groupCount; g++)
          [
            for (var k = offsetList[g]; k < offsetList[g + 1]; k++)
              orderList[k],
          ],
      ];
    });
  }

  /// 供单元测试直接验证 Signed 聚类与几何阅读顺序解码。
  static List<List<int>> decodeSignedForTest({
    required Float32List quads,
    required Uint8List vertical,
    required Int32List pairs,
    required Float32List logits,
  }) {
    final lineCount = vertical.length;
    final pairCount = logits.length;
    if (quads.length != lineCount * 8 || pairs.length != pairCount * 2) {
      throw ArgumentError('decodeSignedForTest 参数长度不匹配');
    }
    if (lineCount == 0) return const [];
    return using((arena) {
      final qPtr = arena<Float>(quads.length);
      qPtr.asTypedList(quads.length).setAll(0, quads);
      final vPtr = arena<Uint8>(lineCount);
      vPtr.asTypedList(lineCount).setAll(0, vertical);
      final pPtr = pairCount > 0 ? arena<Int32>(pairs.length) : nullptr;
      if (pairCount > 0) pPtr.asTypedList(pairs.length).setAll(0, pairs);
      final lPtr = pairCount > 0 ? arena<Float>(pairCount) : nullptr;
      if (pairCount > 0) lPtr.asTypedList(pairCount).setAll(0, logits);
      final outOrder = arena<Int32>(lineCount);
      final outOffsets = arena<Int32>(lineCount + 1);
      final groupCount = _line2paraDecodeSigned(
        qPtr,
        vPtr,
        lineCount,
        pPtr,
        lPtr,
        pairCount,
        outOrder,
        outOffsets,
        lineCount,
      );
      if (groupCount < 0) {
        throw StateError('line2para Signed 解码失败（$groupCount）');
      }
      final orderList = outOrder.asTypedList(lineCount);
      final offsetList = outOffsets.asTypedList(groupCount + 1);
      return [
        for (var g = 0; g < groupCount; g++)
          [
            for (var k = offsetList[g]; k < offsetList[g + 1]; k++)
              orderList[k],
          ],
      ];
    });
  }

  void close() {
    if (_handle != nullptr) {
      _line2paraClose(_handle);
      _handle = nullptr;
    }
  }
}
