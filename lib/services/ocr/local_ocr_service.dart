import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:dio/dio.dart';
import 'package:fluxdo_ocr/fluxdo_ocr.dart';
import 'package:image/image.dart' as img;
import 'package:yaml/yaml.dart';

import 'ocr_model_store.dart';

/// 在独立 isolate 内执行 PP-OCRv6 small 的检测、识别和 CTC 解码。
class LocalOcrService {
  Future<String> recognize(
    Uint8List pngBytes,
    OcrModelPaths paths, {
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
    final ready = ReceivePort();
    final subscription = ready.listen((port) {
      cancelToken?.whenCancel.then((_) => (port as SendPort).send(null));
    });
    try {
      return await _startWorker(pngBytes, paths, ready.sendPort);
    } finally {
      await subscription.cancel();
      ready.close();
    }
  }

  // 不把主 isolate 中持有的 CancelToken 捕获进工作闭包。
  static Future<String> _startWorker(
    Uint8List bytes,
    OcrModelPaths paths,
    SendPort ready,
  ) => Isolate.run(() => _recognize(bytes, paths, ready));

  static Future<String> _recognize(
    Uint8List bytes,
    OcrModelPaths paths,
    SendPort ready,
  ) async {
    final cancellation = ReceivePort();
    var cancelled = false;
    cancellation.listen((_) => cancelled = true);
    ready.send(cancellation.sendPort);
    Future<void> checkCancellation() async {
      await Future<void>.delayed(Duration.zero);
      if (cancelled) throw StateError('OCR 已取消');
    }

    OcrInferenceModel? detector;
    OcrInferenceModel? recognizer;
    try {
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
      detector = OcrInferenceModel.open(paths.detector);
      final boxes = await _detect(image, detector, checkCancellation);
      detector.close();
      detector = null;
      if (boxes.isEmpty) return '';
      await checkCancellation();
      final Object? config = loadYaml(await File(paths.config).readAsString());
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
      final dictionary = <String>['', ...characters.cast<String>(), ' '];
      recognizer = OcrInferenceModel.open(paths.recognizer);
      final lines = <String>[];
      for (final box in boxes) {
        final text = await _read(
          image,
          box,
          recognizer,
          dictionary,
          checkCancellation,
        );
        if (text.trim().isNotEmpty) lines.add(text);
      }
      return lines.join('\n');
    } finally {
      recognizer?.close();
      detector?.close();
      cancellation.close();
    }
  }

  static Future<List<Rect>> _detect(
    img.Image image,
    OcrInferenceModel model,
    Future<void> Function() checkCancellation,
  ) async {
    // 长截图以原图坐标切片，重叠区域让跨边界的文字能在相邻片中完整出现。
    final scale = math.min(1.0, 1280 / image.width);
    int aligned(double dimension) => math.max(1, (dimension / 32).round()) * 32;
    final width = aligned(image.width * scale);
    final bandHeight = (1024 / scale).round();
    final overlap = (160 / scale).round();
    final boxes = <Rect>[];
    for (var top = 0; top < image.height; top += bandHeight - overlap) {
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

  static List<Rect> _readingOrder(List<Rect> boxes) {
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
    final ordered = <Rect>[], row = <Rect>[];
    void finishRow() {
      row.sort((a, b) => a.left.compareTo(b.left));
      ordered.addAll(row);
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

  static Future<String> _read(
    img.Image image,
    Rect box,
    OcrInferenceModel model,
    List<String> dictionary,
    Future<void> Function() checkCancellation,
  ) async {
    final bounds = box.intersect(
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    );
    if (bounds.isEmpty) return '';
    final top = bounds.top.floor(), bottom = bounds.bottom.ceil();
    final left = bounds.left.floor(), right = bounds.right.ceil();
    const height = 48, maxWidth = 1600, overlap = 96;
    final lineWidth = ((right - left) * height / (bottom - top)).ceil();
    final text = StringBuffer();
    for (var start = 0; start < lineWidth; start += maxWidth - overlap) {
      await checkCancellation();
      final end = math.min(lineWidth, start + maxWidth);
      final x = left + (start * (right - left) / lineWidth).floor();
      final xEnd = left + (end * (right - left) / lineWidth).ceil();
      final part = img.copyCrop(
        image,
        x: x,
        y: top,
        width: xEnd - x,
        height: bottom - top,
      );
      final resized = img.copyResize(
        part,
        height: height,
        width: end - start,
        interpolation: img.Interpolation.linear,
      );
      final width = math.max(320, ((resized.width + 7) ~/ 8) * 8);
      final last = end == lineWidth;
      final value = model.infer(
        width,
        height,
        _pixels(resized, width, detection: false),
        (shape, scores) {
          if (shape.length != 3 ||
              shape[0] != 1 ||
              shape[2] != dictionary.length) {
            throw const FormatException('OCR 模型与字典不匹配');
          }
          return _decode(
            scores,
            shape[1],
            dictionary,
            width,
            start == 0 ? 0 : overlap ~/ 2,
            last ? resized.width : resized.width - overlap ~/ 2,
          );
        },
      );
      text.write(value);
      if (last) break;
    }
    return text.toString();
  }

  static String _decode(
    Float32List scores,
    int steps,
    List<String> dictionary,
    int width,
    int from,
    int until,
  ) {
    final result = StringBuffer();
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
      final center = (start + step) / 2 * width / steps;
      if (previous != 0 && center >= from && center < until) {
        result.write(dictionary[previous]);
      }
      previous = label;
      start = step;
    }
    return result.toString();
  }
}
