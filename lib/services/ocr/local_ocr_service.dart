import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fluxdo_ocr/fluxdo_ocr.dart';
import 'package:image/image.dart' as img;
import 'package:yaml/yaml.dart';

import 'ocr_model_store.dart';
import 'picture_text_layout.dart';

/// OCR 识别阶段。
enum OcrStage { decoding, detecting, recognizing }

/// OCR 识别进度事件。
class OcrProgress {
  const OcrProgress({
    required this.stage,
    this.completed = 0,
    this.total = 0,
  });

  final OcrStage stage;
  final int completed;
  final int total;

  double? get fraction =>
      total > 0 ? (completed / total).clamp(0.0, 1.0) : null;
}

/// 单段 OCR 识别文本行（原图坐标系）。
class OcrTextLine {
  const OcrTextLine({
    required this.text,
    required this.bounds,
    required this.charBounds,
    required this.rowIndex,
  });

  final String text;

  /// 该段文本在原图中的包围盒。
  final Rect bounds;

  /// 与 [text] 的 UTF-16 字符索引一一对应的原图包围盒。
  final List<Rect> charBounds;

  /// 所属视觉行序号（从上到下递增；同一水平行内的多段共享同一个序号）。
  final int rowIndex;

  /// 返回子串 `[start, end)` 在原图中的合并包围盒。
  Rect boundsForRange(int start, int end) {
    if (text.isEmpty || start >= end) return bounds;
    final safeStart = start.clamp(0, text.length);
    final safeEnd = end.clamp(safeStart, text.length);
    if (safeStart >= safeEnd) return bounds;
    if (charBounds.length == text.length) {
      var rect = charBounds[safeStart];
      for (var i = safeStart + 1; i < safeEnd; i++) {
        rect = rect.expandToInclude(charBounds[i]);
      }
      return rect;
    }
    final left = bounds.left + bounds.width * (safeStart / text.length);
    final right = bounds.left + bounds.width * (safeEnd / text.length);
    return Rect.fromLTRB(left, bounds.top, right, bounds.bottom);
  }
}

/// 完整 OCR 识别结果（含原图尺寸与结构化文本行）。
class OcrResult {
  const OcrResult({
    required this.imageWidth,
    required this.imageHeight,
    required this.lines,
  });

  final int imageWidth;
  final int imageHeight;
  final List<OcrTextLine> lines;

  bool get isEmpty => lines.isEmpty;

  /// 按段落规则与中英自动间距拼合后的可读纯文本。
  String get plainText => PictureTextLayout.fromOcr(this).fullText;
}

/// 在独立 isolate 内执行 PP-OCRv6 small 的检测、识别和 CTC 解码。
class LocalOcrService {
  static const _maxCacheEntries = 8;

  final LinkedHashMap<String, OcrResult> _cache = LinkedHashMap();
  String? _cachedDictPath;
  int? _cachedDictSize;
  int? _cachedDictModifiedMs;
  List<String>? _cachedDictionary;

  /// 清空识别结果内存缓存。
  void clearCache() => _cache.clear();

  /// 兼容接口：仅返回拼合后的纯文本。
  Future<String> recognize(
    Uint8List pngBytes,
    OcrModelPaths paths, {
    CancelToken? cancelToken,
  }) async {
    final result = await recognizeDetailed(
      pngBytes,
      paths,
      cancelToken: cancelToken,
    );
    return result.plainText;
  }

  /// 完整识别接口：返回原图尺寸、逻辑行分组及每个字符的原图坐标，供识字、实况选字与隐私打码共用。
  ///
  /// - [priorityPoint]：可选的原图像素坐标；传入时优先识别离该点最近的那一行并立刻回调 [onPartial]。
  /// - [onDetected]：检测阶段完成后立刻触发（几百毫秒内），供 UI 播放文字行波纹点亮动画。
  /// - [onPartial]：识别过程中分批回传当前已识别出的 [OcrResult]，实现边识别边选字。
  Future<OcrResult> recognizeDetailed(
    Uint8List pngBytes,
    OcrModelPaths paths, {
    CancelToken? cancelToken,
    void Function(OcrProgress)? onProgress,
    void Function(int imageWidth, int imageHeight, List<Rect> boxes)?
    onDetected,
    void Function(OcrResult partial)? onPartial,
    Offset? priorityPoint,
  }) async {
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;

    final cacheKey = pngBytes.isEmpty ? null : _fingerprint(pngBytes);
    if (cacheKey != null) {
      final cached = _cache.remove(cacheKey);
      if (cached != null) {
        _cache[cacheKey] = cached;
        onDetected?.call(
          cached.imageWidth,
          cached.imageHeight,
          [for (final l in cached.lines) l.bounds],
        );
        onPartial?.call(cached);
        return cached;
      }
    }

    final cachedDictionary = await _tryGetCachedDictionary(paths.config);
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;

    final channel = ReceivePort();
    var detectedWidth = 0;
    var detectedHeight = 0;
    final partialLines = <OcrTextLine>[];
    final subscription = channel.listen((message) {
      if (message is SendPort) {
        cancelToken?.whenCancel.then((_) => message.send(null));
      } else if (message is _ProgressMessage) {
        onProgress?.call(
          OcrProgress(
            stage: OcrStage.values[message.stage],
            completed: message.completed,
            total: message.total,
          ),
        );
      } else if (message is _DetectedMessage) {
        detectedWidth = message.imageWidth;
        detectedHeight = message.imageHeight;
        final boxes = <Rect>[
          for (var i = 0; i < message.boxes.length; i += 4)
            Rect.fromLTRB(
              message.boxes[i],
              message.boxes[i + 1],
              message.boxes[i + 2],
              message.boxes[i + 3],
            ),
        ];
        onDetected?.call(detectedWidth, detectedHeight, boxes);
      } else if (message is _PartialBatchMessage) {
        for (final item in message.lines) {
          partialLines.add(_hydrateLine(item));
        }
        if (detectedWidth > 0 && detectedHeight > 0) {
          onPartial?.call(
            OcrResult(
              imageWidth: detectedWidth,
              imageHeight: detectedHeight,
              lines: List<OcrTextLine>.of(partialLines),
            ),
          );
        }
      }
    });
    try {
      final raw = await _startWorker(
        pngBytes,
        paths,
        cachedDictionary,
        priorityPoint?.dx,
        priorityPoint?.dy,
        onDetected != null,
        onPartial != null,
        channel.sendPort,
      );
      if (raw.dictionary != null) {
        await _storeCachedDictionary(paths.config, raw.dictionary!);
      }
      final result = OcrResult(
        imageWidth: raw.imageWidth,
        imageHeight: raw.imageHeight,
        lines: [for (final item in raw.lines) _hydrateLine(item)],
      );
      if (cacheKey != null) {
        _cache[cacheKey] = result;
        while (_cache.length > _maxCacheEntries) {
          _cache.remove(_cache.keys.first);
        }
      }
      return result;
    } finally {
      await subscription.cancel();
      channel.close();
    }
  }

  static OcrTextLine _hydrateLine(_WorkerLine item) => OcrTextLine(
    text: item.text,
    bounds: Rect.fromLTRB(
      item.bounds[0],
      item.bounds[1],
      item.bounds[2],
      item.bounds[3],
    ),
    charBounds: [
      for (var i = 0; i < item.charBounds.length; i += 4)
        Rect.fromLTRB(
          item.charBounds[i],
          item.charBounds[i + 1],
          item.charBounds[i + 2],
          item.charBounds[i + 3],
        ),
    ],
    rowIndex: item.rowIndex,
  );

  static String _fingerprint(Uint8List bytes) =>
      '${bytes.length}:${sha256.convert(bytes)}';

  Future<List<String>?> _tryGetCachedDictionary(String configPath) async {
    if (_cachedDictionary == null || _cachedDictPath != configPath) return null;
    final stat = await File(configPath).stat();
    if (stat.type != FileSystemEntityType.file) return null;
    if (stat.size == _cachedDictSize &&
        stat.modified.millisecondsSinceEpoch == _cachedDictModifiedMs) {
      return _cachedDictionary;
    }
    return null;
  }

  Future<void> _storeCachedDictionary(
    String configPath,
    List<String> dictionary,
  ) async {
    final stat = await File(configPath).stat();
    if (stat.type != FileSystemEntityType.file) return;
    _cachedDictPath = configPath;
    _cachedDictSize = stat.size;
    _cachedDictModifiedMs = stat.modified.millisecondsSinceEpoch;
    _cachedDictionary = dictionary;
  }

  // 不把主 isolate 中持有的 CancelToken 或回调闭包捕获进工作 isolate。
  static Future<_WorkerResult> _startWorker(
    Uint8List bytes,
    OcrModelPaths paths,
    List<String>? cachedDictionary,
    double? priorityX,
    double? priorityY,
    bool emitDetected,
    bool emitPartial,
    SendPort channel,
  ) => Isolate.run(
    () => _recognize(
      bytes,
      paths,
      cachedDictionary,
      priorityX,
      priorityY,
      emitDetected,
      emitPartial,
      channel,
    ),
  );

  static Future<_WorkerResult> _recognize(
    Uint8List bytes,
    OcrModelPaths paths,
    List<String>? cachedDictionary,
    double? priorityX,
    double? priorityY,
    bool emitDetected,
    bool emitPartial,
    SendPort channel,
  ) async {
    final cancellation = ReceivePort();
    var cancelled = false;
    cancellation.listen((_) => cancelled = true);
    channel.send(cancellation.sendPort);

    Future<void> checkCancellation() async {
      await Future<void>.delayed(Duration.zero);
      if (cancelled) throw StateError('OCR 已取消');
    }

    void report(OcrStage stage, [int completed = 0, int total = 0]) {
      channel.send(_ProgressMessage(stage.index, completed, total));
    }

    OcrInferenceModel? detector;
    OcrInferenceModel? recognizer;
    try {
      report(OcrStage.decoding);
      var image = img.decodeImage(bytes);
      if (image == null) throw const FormatException('无法解码 OCR 图片');
      if (image.hasAlpha) {
        final background = img.Image(width: image.width, height: image.height);
        img.fill(background, color: img.ColorRgb8(255, 255, 255));
        image = img.compositeImage(background, image);
      } else if (image.format != img.Format.uint8) {
        image = image.convert(format: img.Format.uint8);
      }
      await checkCancellation();

      report(OcrStage.detecting);
      detector = OcrInferenceModel.open(paths.detector);
      final boxes = await _detect(image, detector, checkCancellation, report);
      detector.close();
      detector = null;

      if (emitDetected) {
        final flat = Float64List(boxes.length * 4);
        for (var i = 0; i < boxes.length; i++) {
          final b = boxes[i].box;
          flat[i * 4] = b.left;
          flat[i * 4 + 1] = b.top;
          flat[i * 4 + 2] = b.right;
          flat[i * 4 + 3] = b.bottom;
        }
        channel.send(_DetectedMessage(image.width, image.height, flat));
      }

      if (boxes.isEmpty) {
        return _WorkerResult(
          imageWidth: image.width,
          imageHeight: image.height,
          lines: const [],
        );
      }
      await checkCancellation();

      List<String>? newlyLoadedDictionary;
      final dictionary =
          cachedDictionary ??
          (newlyLoadedDictionary = await _loadDictionary(paths.config));

      // 如果指定了优先点，将距离最近的行排到最前面先识别，做到点哪行秒出哪行。
      final order = List<int>.generate(boxes.length, (i) => i);
      int? priorityIdx;
      if (priorityX != null && priorityY != null) {
        var bestGap = double.infinity;
        for (var i = 0; i < boxes.length; i++) {
          final r = boxes[i].box;
          final gap =
              math.max(math.max(r.left - priorityX, 0.0), priorityX - r.right) +
              math.max(math.max(r.top - priorityY, 0.0), priorityY - r.bottom);
          if (gap < bestGap) {
            bestGap = gap;
            priorityIdx = i;
          }
        }
        if (priorityIdx != null && priorityIdx != 0) {
          order.remove(priorityIdx);
          order.insert(0, priorityIdx);
        }
      }

      report(OcrStage.recognizing, 0, boxes.length);
      recognizer = OcrInferenceModel.open(paths.recognizer);
      final recognized = List<_WorkerLine?>.filled(boxes.length, null);
      final pendingBatch = <_WorkerLine>[];
      for (var step = 0; step < order.length; step++) {
        final idx = order[step];
        final entry = boxes[idx];
        final line = await _read(
          image,
          entry.box,
          entry.rowIndex,
          recognizer,
          dictionary,
          checkCancellation,
        );
        if (line != null) {
          recognized[idx] = line;
          if (emitPartial) pendingBatch.add(line);
        }
        final isPriorityDone = step == 0 && priorityIdx != null;
        final isBatchDue = (step + 1) % 4 == 0 || step + 1 == order.length;
        if (emitPartial &&
            pendingBatch.isNotEmpty &&
            (isPriorityDone || isBatchDue)) {
          channel.send(_PartialBatchMessage(List<_WorkerLine>.of(pendingBatch)));
          pendingBatch.clear();
        }
        if ((step + 1) % 2 == 0 || step + 1 == order.length) {
          report(OcrStage.recognizing, step + 1, boxes.length);
        }
      }
      final orderedLines = <_WorkerLine>[
        for (final line in recognized) ?line,
      ];
      return _WorkerResult(
        imageWidth: image.width,
        imageHeight: image.height,
        lines: orderedLines,
        dictionary: newlyLoadedDictionary,
      );
    } finally {
      recognizer?.close();
      detector?.close();
      cancellation.close();
    }
  }

  static Future<List<String>> _loadDictionary(String configPath) async {
    final Object? config = loadYaml(await File(configPath).readAsString());
    final Object? postProcess = config is YamlMap
        ? config['PostProcess']
        : null;
    final Object? characters = postProcess is YamlMap
        ? postProcess['character_dict']
        : null;
    if (characters is! YamlList ||
        characters.isEmpty ||
        characters.any((c) => c is! String)) {
      throw const FormatException('OCR 配置缺少字符字典');
    }
    return <String>['', ...characters.cast<String>(), ' '];
  }

  static Future<List<({Rect box, int rowIndex})>> _detect(
    img.Image image,
    OcrInferenceModel model,
    Future<void> Function() checkCancellation,
    void Function(OcrStage, [int, int]) report,
  ) async {
    // 长截图以原图坐标切片，重叠区域让跨边界的文字能在相邻片中完整出现。
    final scale = math.min(1.0, 1280 / image.width);
    int aligned(double dimension) => math.max(1, (dimension / 32).round()) * 32;
    final width = aligned(image.width * scale);
    final bandHeight = (1024 / scale).round();
    final overlap = (160 / scale).round();
    final stride = bandHeight - overlap;
    final totalBands = image.height <= bandHeight
        ? 1
        : ((image.height - overlap - 1) ~/ stride) + 1;
    final boxes = <Rect>[];
    var bandIndex = 0;
    for (var top = 0; top < image.height; top += stride) {
      await checkCancellation();
      final height = math.min(bandHeight, image.height - top);
      final band = top == 0 && height == image.height
          ? image
          : img.copyCrop(
              image,
              x: 0,
              y: top,
              width: image.width,
              height: height,
            );
      final inputHeight = aligned(height * scale);
      final resized = img.copyResize(
        band,
        width: width,
        height: inputHeight,
        interpolation: img.Interpolation.linear,
      );
      final input = _pixels(resized, width, detection: true);
      final detected = model.infer(width, inputHeight, input, (shape, scores) {
        if (shape.length != 4 ||
            shape[0] != 1 ||
            shape[1] != 1 ||
            shape[2] != inputHeight ||
            shape[3] != width) {
          throw const FormatException('OCR 检测输出尺寸不匹配');
        }
        return _regions(scores, width, inputHeight);
      });
      final last = top + height == image.height;
      for (final box in detected) {
        if ((top > 0 && box.top <= 1) ||
            (!last && box.bottom >= inputHeight - 1)) {
          continue;
        }
        boxes.add(
          Rect.fromLTRB(
            box.left * image.width / width,
            top + box.top * height / inputHeight,
            box.right * image.width / width,
            top + box.bottom * height / inputHeight,
          ),
        );
      }
      bandIndex++;
      if (totalBands > 1) {
        report(OcrStage.detecting, bandIndex, totalBands);
      }
      if (last) break;
    }
    return _readingOrder(boxes);
  }

  // 两个模型都接收平面的 BGR 张量。未填充的识别列保持归一化后的零值。
  static Float32List _pixels(
    img.Image image,
    int width, {
    required bool detection,
  }) {
    final plane = width * image.height;
    final values = Float32List(3 * plane);
    for (final pixel in image) {
      final pos = pixel.y * width + pixel.x;
      if (detection) {
        values[pos] = (pixel.b / 255 - 0.485) / 0.229;
        values[plane + pos] = (pixel.g / 255 - 0.456) / 0.224;
        values[2 * plane + pos] = (pixel.r / 255 - 0.406) / 0.225;
      } else {
        values[pos] = pixel.b / 127.5 - 1;
        values[plane + pos] = pixel.g / 127.5 - 1;
        values[2 * plane + pos] = pixel.r / 127.5 - 1;
      }
    }
    return values;
  }

  // 按水平连续段遍历概率图，使用官方检测配置的二值化、置信度和扩边参数。
  static List<Rect> _regions(Float32List scores, int width, int height) {
    const threshold = 0.2;
    final regions = <Rect>[];
    final pending = <int>[];
    for (var seed = 0; seed < scores.length; seed++) {
      if (scores[seed] <= threshold) continue;
      pending.add(seed);
      var left = width, right = 0, top = height, bottom = 0, count = 0;
      var sum = 0.0;
      while (pending.isNotEmpty) {
        final pos = pending.removeLast();
        if (scores[pos] <= threshold) continue;
        final y = pos ~/ width;
        final row = y * width;
        var x = pos - row;
        while (x > 0 && scores[row + x - 1] > threshold) {
          x--;
        }
        left = math.min(left, x);
        top = math.min(top, y);
        bottom = math.max(bottom, y + 1);
        var above = false, below = false;
        while (x < width && scores[row + x] > threshold) {
          final i = row + x;
          sum += scores[i];
          count++;
          scores[i] = 0;
          final hasAbove = y > 0 && scores[i - width] > threshold;
          final hasBelow = y + 1 < height && scores[i + width] > threshold;
          if (hasAbove && !above) pending.add(i - width);
          if (hasBelow && !below) pending.add(i + width);
          above = hasAbove;
          below = hasBelow;
          x++;
        }
        right = math.max(right, x);
      }
      final w = right - left, h = bottom - top;
      if (math.min(w, h) < 3 || sum / count < 0.45) continue;
      final padding = 1.4 * w * h / (2 * (w + h));
      regions.add(
        Rect.fromLTWH(
          left.toDouble(),
          top.toDouble(),
          w.toDouble(),
          h.toDouble(),
        ).inflate(padding),
      );
    }
    return regions;
  }

  static List<({Rect box, int rowIndex})> _readingOrder(List<Rect> boxes) {
    double area(Rect box) => box.width * box.height;
    boxes.sort((a, b) => area(b).compareTo(area(a)));
    final unique = <Rect>[];
    for (final box in boxes) {
      if (!unique.any((other) {
        final overlap = box.intersect(other);
        return !overlap.isEmpty && area(overlap) > 0.6 * area(box);
      })) {
        unique.add(box);
      }
    }
    unique.sort((a, b) => a.center.dy.compareTo(b.center.dy));
    final ordered = <({Rect box, int rowIndex})>[];
    final row = <Rect>[];
    var rowIndex = 0;

    void finishRow() {
      if (row.isEmpty) return;
      row.sort((a, b) => a.left.compareTo(b.left));
      for (final item in row) {
        ordered.add((box: item, rowIndex: rowIndex));
      }
      rowIndex++;
      row.clear();
    }

    for (final box in unique) {
      if (row.isNotEmpty &&
          box.center.dy - row.first.center.dy >
              math.min(box.height, row.first.height) / 2) {
        finishRow();
      }
      row.add(box);
    }
    finishRow();
    return ordered;
  }

  static Future<_WorkerLine?> _read(
    img.Image image,
    Rect box,
    int rowIndex,
    OcrInferenceModel model,
    List<String> dictionary,
    Future<void> Function() checkCancellation,
  ) async {
    final bounds = box.intersect(
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    );
    if (bounds.isEmpty) return null;
    final top = bounds.top.floor(), bottom = bounds.bottom.ceil();
    final left = bounds.left.floor(), right = bounds.right.ceil();
    if (right <= left || bottom <= top) return null;
    const height = 48, maxWidth = 1600, overlap = 96;
    final lineWidth = math.max(
      1,
      ((right - left) * height / (bottom - top)).ceil(),
    );
    final text = StringBuffer();
    final charBounds = <double>[];
    for (var start = 0; start < lineWidth; start += maxWidth - overlap) {
      await checkCancellation();
      final end = math.min(lineWidth, start + maxWidth);
      final x = left + (start * (right - left) / lineWidth).floor();
      final xEnd = math.max(
        x + 1,
        left + (end * (right - left) / lineWidth).ceil(),
      );
      final part = img.copyCrop(
        image,
        x: x,
        y: top,
        width: math.min(image.width - x, xEnd - x),
        height: math.min(image.height - top, bottom - top),
      );
      final resized = img.copyResize(
        part,
        height: height,
        width: math.max(1, end - start),
        interpolation: img.Interpolation.linear,
      );
      final width = math.max(320, ((resized.width + 7) ~/ 8) * 8);
      final last = end == lineWidth;
      final tokens = model.infer(
        width,
        height,
        _pixels(resized, width, detection: false),
        (shape, scores) {
          if (shape.length != 3 ||
              shape[0] != 1 ||
              shape[2] != dictionary.length) {
            throw const FormatException('OCR 模型与字典不匹配');
          }
          return _decodeTokens(
            scores,
            shape[1],
            dictionary,
            width,
            start == 0 ? 0 : overlap ~/ 2,
            last ? resized.width : resized.width - overlap ~/ 2,
          );
        },
      );
      final scaleX = part.width / resized.width;
      for (final token in tokens) {
        final rawLeft = (x + token.leftPx * scaleX)
            .clamp(bounds.left, bounds.right)
            .toDouble();
        final rawRight = (x + token.rightPx * scaleX)
            .clamp(math.min(rawLeft + 1.0, bounds.right), bounds.right)
            .toDouble();
        final unitCount = token.text.length;
        text.write(token.text);
        if (unitCount == 1) {
          charBounds
            ..add(rawLeft)
            ..add(bounds.top)
            ..add(rawRight)
            ..add(bounds.bottom);
        } else {
          final span = rawRight - rawLeft;
          for (var u = 0; u < unitCount; u++) {
            final uLeft = rawLeft + span * (u / unitCount);
            final uRight = rawLeft + span * ((u + 1) / unitCount);
            charBounds
              ..add(uLeft)
              ..add(bounds.top)
              ..add(uRight)
              ..add(bounds.bottom);
          }
        }
      }
      if (last) break;
    }
    final rawText = text.toString();
    final trimmed = rawText.trim();
    if (trimmed.isEmpty) return null;

    // 同步裁掉首尾空白对应的字符框，保持 text 与 charBounds 一一对齐。
    final leading = rawText.length - rawText.trimLeft().length;
    final trailing = rawText.length - rawText.trimRight().length;
    final keptCharBounds = charBounds.sublist(
      leading * 4,
      charBounds.length - trailing * 4,
    );
    return _WorkerLine(
      text: trimmed,
      bounds: Float64List.fromList([
        bounds.left,
        bounds.top,
        bounds.right,
        bounds.bottom,
      ]),
      charBounds: Float64List.fromList(keptCharBounds),
      rowIndex: rowIndex,
    );
  }

  static List<({String text, double leftPx, double rightPx})> _decodeTokens(
    Float32List scores,
    int steps,
    List<String> dictionary,
    int width,
    int from,
    int until,
  ) {
    final result = <({String text, double leftPx, double rightPx})>[];
    final classes = dictionary.length;
    var previous = 0, start = 0;
    for (var step = 0; step <= steps; step++) {
      var label = 0;
      if (step < steps) {
        final offset = step * classes;
        for (var c = 1; c < classes; c++) {
          if (scores[offset + c] > scores[offset + label]) label = c;
        }
      }
      if (label == previous) continue;
      final leftPx = start * width / steps;
      final rightPx = step * width / steps;
      final center = (leftPx + rightPx) / 2;
      if (previous != 0 && center >= from && center < until) {
        result.add((
          text: dictionary[previous],
          leftPx: leftPx,
          rightPx: rightPx,
        ));
      }
      previous = label;
      start = step;
    }
    return result;
  }
}

class _ProgressMessage {
  const _ProgressMessage(this.stage, this.completed, this.total);
  final int stage;
  final int completed;
  final int total;
}

class _DetectedMessage {
  const _DetectedMessage(this.imageWidth, this.imageHeight, this.boxes);
  final int imageWidth;
  final int imageHeight;
  final Float64List boxes;
}

class _PartialBatchMessage {
  const _PartialBatchMessage(this.lines);
  final List<_WorkerLine> lines;
}

class _WorkerLine {
  const _WorkerLine({
    required this.text,
    required this.bounds,
    required this.charBounds,
    required this.rowIndex,
  });

  final String text;
  final Float64List bounds;
  final Float64List charBounds;
  final int rowIndex;
}

class _WorkerResult {
  const _WorkerResult({
    required this.imageWidth,
    required this.imageHeight,
    required this.lines,
    this.dictionary,
  });

  final int imageWidth;
  final int imageHeight;
  final List<_WorkerLine> lines;
  final List<String>? dictionary;
}
