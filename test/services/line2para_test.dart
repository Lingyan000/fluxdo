import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect, TextAlign;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/ocr/image_translation_service.dart';
import 'package:fluxdo/services/ocr/local_ocr_service.dart';
import 'package:fluxdo/services/ocr/ocr_model_store.dart';
import 'package:fluxdo/services/ocr/picture_text_layout.dart';
import 'package:fluxdo_ocr/fluxdo_ocr.dart';

OcrTextLine _line(
  String text, {
  required double left,
  required double top,
  required double right,
  required double bottom,
  int rowIndex = 0,
}) {
  final bounds = Rect.fromLTRB(left, top, right, bottom);
  final len = text.length;
  final charBounds = [
    for (var i = 0; i < len; i++)
      Rect.fromLTRB(
        left + (right - left) * (i / len),
        top,
        left + (right - left) * ((i + 1) / len),
        bottom,
      ),
  ];
  return OcrTextLine(
    text: text,
    bounds: bounds,
    charBounds: charBounds,
    rowIndex: rowIndex,
  );
}

Float32List _rectQuads(List<Rect> rects) {
  final out = Float32List(rects.length * 8);
  for (var i = 0; i < rects.length; i++) {
    final r = rects[i];
    final off = i * 8;
    out[off] = r.left;
    out[off + 1] = r.top;
    out[off + 2] = r.right;
    out[off + 3] = r.top;
    out[off + 4] = r.right;
    out[off + 5] = r.bottom;
    out[off + 6] = r.left;
    out[off + 7] = r.bottom;
  }
  return out;
}

// ============================================================================
// 最小 ONNX Protobuf 构造器（仅用于构造无训练权重的合法 B-Scale 结构做端到端单测）
// ============================================================================

void _writeVarint(BytesBuilder out, int value) {
  var v = value;
  while (true) {
    final b = v & 0x7F;
    v >>>= 7;
    if (v == 0) {
      out.addByte(b);
      return;
    }
    out.addByte(b | 0x80);
  }
}

void _writeBytesField(BytesBuilder out, int field, Uint8List bytes) {
  _writeVarint(out, (field << 3) | 2);
  _writeVarint(out, bytes.length);
  out.add(bytes);
}

void _writeStringField(BytesBuilder out, int field, String value) =>
    _writeBytesField(out, field, Uint8List.fromList(utf8.encode(value)));

void _writeIntField(BytesBuilder out, int field, int value) {
  _writeVarint(out, (field << 3) | 0);
  _writeVarint(out, value);
}

Uint8List _encodeTensor(String name, List<int> dims, Float32List data) {
  final b = BytesBuilder();
  for (final d in dims) {
    _writeIntField(b, 1, d);
  }
  _writeIntField(b, 2, 1); // FLOAT
  _writeStringField(b, 8, name);
  _writeBytesField(
    b,
    9,
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
  return b.toBytes();
}

Uint8List _encodeMatMulNode(String nodeName, String weightName) {
  final b = BytesBuilder();
  _writeStringField(b, 1, 'in');
  _writeStringField(b, 1, weightName);
  _writeStringField(b, 3, nodeName);
  _writeStringField(b, 4, 'MatMul');
  return b.toBytes();
}

/// 构造包含全部 88 个权重张量与 4 个 attention_final/MatMul 节点的紧凑 If 包装 ONNX。
/// 所有权重置零，仅将 classifier.2.bias 设为 [classifierBias]，从而严格输出恒定 logit。
Uint8List _buildSyntheticBScaleOnnx({required double classifierBias}) {
  final innerGraph = BytesBuilder();

  void addTensor(String name, List<int> dims, [double fill = 0.0]) {
    final count = dims.reduce((a, b) => a * b);
    final data = Float32List(count);
    if (fill != 0.0) data.fillRange(0, count, fill);
    _writeBytesField(innerGraph, 5, _encodeTensor(name, dims, data));
  }

  addTensor('node.0.weight', [96, 3]);
  addTensor('node.0.bias', [96]);
  addTensor('node.2.weight', [96, 96]);
  addTensor('node.2.bias', [96]);
  addTensor('edge_encoder.0.weight', [144, 26]);
  addTensor('edge_encoder.0.bias', [144]);
  addTensor('edge_encoder.2.weight', [144, 144]);
  addTensor('edge_encoder.2.bias', [144]);

  for (var i = 0; i < 4; i++) {
    final p = 'layers.$i';
    addTensor('$p.edge_update.0.weight', [144, 336]);
    addTensor('$p.edge_update.0.bias', [144]);
    addTensor('$p.edge_update.2.weight', [144, 144]);
    addTensor('$p.edge_update.2.bias', [144]);
    addTensor('$p.edge_norm.weight', [144], 1.0);
    addTensor('$p.edge_norm.bias', [144]);
    addTensor('$p.attention_mixed.weight', [96, 336]);
    addTensor('$p.attention_mixed.bias', [96]);
    final attnName = 'onnx::MatMul_test_$i';
    addTensor(attnName, [96, 1]);
    _writeBytesField(
      innerGraph,
      1,
      _encodeMatMulNode('/$p/attention_final/MatMul', attnName),
    );
    addTensor('$p.message.0.weight', [96, 336]);
    addTensor('$p.message.0.bias', [96]);
    addTensor('$p.message.2.weight', [96, 96]);
    addTensor('$p.message.2.bias', [96]);
    addTensor('$p.update.0.weight', [96, 192]);
    addTensor('$p.update.0.bias', [96]);
    addTensor('$p.update.2.weight', [96, 96]);
    addTensor('$p.update.2.bias', [96]);
    addTensor('$p.node_norm.weight', [96], 1.0);
    addTensor('$p.node_norm.bias', [96]);
  }

  addTensor('classifier.0.weight', [96, 336]);
  addTensor('classifier.0.bias', [96]);
  addTensor('classifier.2.weight', [1, 96]);
  addTensor('classifier.2.bias', [1], classifierBias);

  // 包进外层 If.then_branch，验证与真实紧凑导出模型一致的子图解析逻辑。
  final attr = BytesBuilder();
  _writeStringField(attr, 1, 'then_branch');
  _writeBytesField(attr, 6, innerGraph.toBytes());

  final ifNode = BytesBuilder();
  _writeStringField(ifNode, 1, 'has_pairs');
  _writeStringField(ifNode, 4, 'If');
  _writeBytesField(ifNode, 5, attr.toBytes());

  final outerGraph = BytesBuilder();
  _writeBytesField(outerGraph, 1, ifNode.toBytes());

  final model = BytesBuilder();
  _writeBytesField(model, 7, outerGraph.toBytes());
  return model.toBytes();
}

class _FakeHttpAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  late FutureOr<ResponseBody> Function(RequestOptions) respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('line2para 原生 Signed 解码与阅读顺序（对齐上游 decode.rs）', () {
    test('强互斥边按强度顺序阻断传递合并，支持偏置延迟较弱互斥', () {
      final quads = _rectQuads([
        const Rect.fromLTWH(0, 10, 50, 10),
        const Rect.fromLTWH(0, 25, 50, 10),
        const Rect.fromLTWH(0, 40, 50, 10),
        const Rect.fromLTWH(0, 55, 50, 10),
        const Rect.fromLTWH(0, 70, 50, 10),
      ]);
      final vertical = Uint8List(5);
      final pairs = Int32List.fromList([0, 2, 0, 1, 1, 2, 2, 3, 3, 4]);

      // 强互斥 (0,2)=-4.0 先建立互斥，阻止 (1,2)=2.0 合并 {0,1} 与 {2,3}；(3,4)=1.624 低于阈值 1.625。
      final groups1 = OcrParagraphModel.decodeSignedForTest(
        quads: quads,
        vertical: vertical,
        pairs: pairs,
        logits: Float32List.fromList([-4.0, 3.0, 2.0, 1.625, 1.624]),
      );
      expect(groups1, [
        [0, 1],
        [2, 3],
        [4],
      ]);

      // 弱互斥 (0,2)=-1.25 经 SIGNED_SUPPORT (-0.65) 偏置后强度为 0.10，排在 (1,2) 强度 0.375 之后。
      final groups2 = OcrParagraphModel.decodeSignedForTest(
        quads: quads,
        vertical: vertical,
        pairs: pairs,
        logits: Float32List.fromList([-1.25, 3.0, 2.0, 1.625, 1.624]),
      );
      expect(groups2, [
        [0, 1, 2, 3],
        [4],
      ]);
    });

    test('竖排文本列按从右到左、列内从上到下排序', () {
      final quads = _rectQuads([
        const Rect.fromLTWH(12, 4, 5, 20), // 左列
        const Rect.fromLTWH(25, 30, 5, 20), // 右列下
        const Rect.fromLTWH(25, 4, 5, 20), // 右列上
      ]);
      final groups = OcrParagraphModel.decodeSignedForTest(
        quads: quads,
        vertical: Uint8List.fromList([1, 1, 1]),
        pairs: Int32List.fromList([1, 2]),
        logits: Float32List.fromList([2.5]),
      );
      expect(groups, [
        [2, 1],
        [0],
      ]);
    });
  });

  group('line2para 原生 ONNX 解析与端到端 B-Scale GNN 推理', () {
    test('非法或截断 ONNX 字节流抛 FormatException', () {
      expect(
        () => OcrParagraphModel.fromBytes(Uint8List(0)),
        throwsFormatException,
      );
      expect(
        () => OcrParagraphModel.fromBytes(Uint8List.fromList([1, 2, 3, 4])),
        throwsFormatException,
      );
    });

    test('紧凑 If 子图 B-Scale 模型端到端提取特征、推理与分组', () {
      const width = 200;
      const height = 120;
      final pixels = Uint8List(width * height * 4)..fillRange(0, width * height * 4, 255);
      // 绘制两行深色像素条
      for (var y = 12; y < 28; y++) {
        for (var x = 12; x < 180; x += 3) {
          final off = (y * width + x) * 4;
          pixels[off] = 20;
          pixels[off + 1] = 20;
          pixels[off + 2] = 20;
        }
      }
      for (var y = 36; y < 52; y++) {
        for (var x = 12; x < 180; x += 3) {
          final off = (y * width + x) * 4;
          pixels[off] = 20;
          pixels[off + 1] = 20;
          pixels[off + 2] = 20;
        }
      }
      final nativeImg = OcrNativeImage.fromBytes(
        bytes: pixels,
        width: width,
        height: height,
        channels: 4,
      );
      final quads = _rectQuads([
        const Rect.fromLTRB(10, 10, 185, 30),
        const Rect.fromLTRB(10, 34, 185, 54),
      ]);

      final mergeModel = OcrParagraphModel.fromBytes(
        _buildSyntheticBScaleOnnx(classifierBias: 2.5),
      );
      final splitModel = OcrParagraphModel.fromBytes(
        _buildSyntheticBScaleOnnx(classifierBias: -2.5),
      );
      try {
        expect(
          mergeModel.groupLines(image: nativeImg, quads: quads, lineCount: 2),
          [
            [0, 1],
          ],
        );
        expect(
          splitModel.groupLines(image: nativeImg, quads: quads, lineCount: 2),
          [
            [0],
            [1],
          ],
        );
      } finally {
        mergeModel.close();
        splitModel.close();
        nativeImg.dispose();
      }
    });
  });

  group('PictureTextLayout 与 ImageTranslationService 接入 line2para 段落分组', () {
    test('双栏场景叠加 XY-Cut 块序：即使右栏块中心更高，仍保持标题→左栏→右栏', () {
      final ocr = OcrResult(
        imageWidth: 800,
        imageHeight: 600,
        lines: [
          _line('Article Title', left: 100, top: 20, right: 700, bottom: 56),
          _line('Left para one line one', left: 40, top: 100, right: 350, bottom: 122),
          _line('Left para one line two', left: 40, top: 130, right: 350, bottom: 152),
          _line('Left para one line three', left: 40, top: 160, right: 260, bottom: 182),
          _line('Left para two line one', left: 40, top: 220, right: 350, bottom: 242),
          _line('Left para two line two', left: 40, top: 250, right: 300, bottom: 272),
          _line('Right col line one', left: 440, top: 100, right: 750, bottom: 122),
          _line('Right col line two', left: 440, top: 130, right: 750, bottom: 152),
        ],
        // 故意按 center_y 顺序把右栏 [6,7] 放在左栏 [1,2,3] 之前
        paragraphGroups: const [
          [0],
          [6, 7],
          [1, 2, 3],
          [4, 5],
        ],
      );

      final layout = PictureTextLayout.fromOcr(ocr);
      expect(layout.paragraphs, hasLength(4));
      expect(layout.paragraphs[0].text, 'Article Title');
      expect(
        layout.paragraphs[1].text,
        'Left para one line one Left para one line two Left para one line three',
      );
      expect(
        layout.paragraphs[2].text,
        'Left para two line one Left para two line two',
      );
      expect(layout.paragraphs[3].text, 'Right col line one Right col line two');
    });

    test('同间距异色/异字重由 line2para 拆段时，识字与译图均保留为两段并修复软连字符', () {
      final ocr = OcrResult(
        imageWidth: 600,
        imageHeight: 300,
        lines: [
          _line('Section Heading', left: 40, top: 40, right: 240, bottom: 62),
          _line('This is an implemen-', left: 40, top: 68, right: 380, bottom: 90),
          _line('tation detail of FluxDO.', left: 40, top: 96, right: 320, bottom: 118),
        ],
        paragraphGroups: const [
          [0],
          [1, 2],
        ],
      );

      final layout = PictureTextLayout.fromOcr(ocr);
      expect(layout.paragraphs, hasLength(2));
      expect(layout.paragraphs[0].text, 'Section Heading');
      expect(layout.paragraphs[1].text, 'This is an implementation detail of FluxDO.');
      expect(
        layout.fullText,
        'Section Heading\nThis is an implementation detail of FluxDO.',
      );

      final blocks = ImageTranslationService.groupBlocks(ocr);
      expect(blocks, hasLength(2));
      expect(blocks[0].originalText, 'Section Heading');
      expect(blocks[0].lineCount, 1);
      expect(blocks[1].originalText, 'This is an implementation detail of FluxDO.');
      expect(blocks[1].lineCount, 2);
      expect(blocks[1].sourceRows, hasLength(2));
      expect(blocks[1].textAlign, TextAlign.left);
    });
  });

  group('OcrModelStore line2para 按需下载、校验与清理', () {
    late Directory mainDir;
    late Directory paraDir;
    late _FakeHttpAdapter adapter;
    late OcrModelStore store;
    final payload = Uint8List.fromList(List<int>.generate(128, (i) => i));
    final payloadSha = sha256.convert(payload).toString();

    setUp(() async {
      mainDir = await Directory.systemTemp.createTemp('fluxdo-ocr-main-');
      paraDir = await Directory.systemTemp.createTemp('fluxdo-ocr-para-');
      adapter = _FakeHttpAdapter()
        ..respond = (req) {
          if (req.uri.host == 'modelscope.cn') {
            return ResponseBody.fromString(
              'redirect',
              302,
              headers: {
                HttpHeaders.locationHeader: [
                  'https://cdn.example/line2para.onnx',
                ],
              },
            );
          }
          return ResponseBody.fromBytes(payload, 200);
        };
      store = OcrModelStore(
        dio: Dio()..httpClientAdapter = adapter,
        directory: () async => mainDir,
        paragraphDirectory: () async => paraDir,
        paragraphModelUrl: 'https://modelscope.cn/models/test/line2para.onnx',
        paragraphModelFile: OcrModelFile(
          'line2para.onnx',
          'line2para.onnx',
          payload.length,
          payloadSha,
        ),
      );
    });

    tearDown(() async {
      store.dispose();
      if (await mainDir.exists()) await mainDir.delete(recursive: true);
      if (await paraDir.exists()) await paraDir.delete(recursive: true);
    });

    test('跟随 302 下载并校验 SHA-256，计入空间占用且 clear 一并清理', () async {
      expect(await store.paragraphModelPathIfReady(), isNull);
      expect(await store.installedBytes(), 0);

      final path = await store.ensureParagraphModel();
      expect(path, isNotNull);
      expect(await File(path!).exists(), isTrue);
      expect(await store.paragraphModelPathIfReady(), path);
      expect(await store.installedBytes(), payload.length);
      expect(adapter.requests, hasLength(2));

      // 二次调用直接命中磁盘缓存，不再联网。
      final cached = await store.ensureParagraphModel();
      expect(cached, path);
      expect(adapter.requests, hasLength(2));

      await store.clear();
      expect(await store.installedBytes(), 0);
      expect(await store.paragraphModelPathIfReady(), isNull);
    });

    test('下载失败时静默回退 null 并进入冷却，不反复阻塞识字', () async {
      adapter.respond = (_) => ResponseBody.fromString('error', 503);
      expect(await store.ensureParagraphModel(), isNull);
      expect(adapter.requests, hasLength(1));

      // 冷却期间直接返回 null，不再发网络请求。
      expect(await store.ensureParagraphModel(), isNull);
      expect(adapter.requests, hasLength(1));
    });
  });
}
