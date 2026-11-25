import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

import '../../models/translation_engine.dart';
import '../ai_translation_service.dart';
import '../translation_service.dart';
import 'local_ocr_service.dart';

/// 待翻译的逻辑文本块（由一段或多段连续 OCR 文本行聚合而成）。
class ImageTextBlock {
  const ImageTextBlock({
    required this.bounds,
    required this.originalText,
    required this.lineCount,
  });

  final Rect bounds;
  final String originalText;
  final int lineCount;
}

/// 已完成翻译并提取原图配色的覆盖渲染块（原图像素坐标系）。
class TranslatedTextBlock {
  const TranslatedTextBlock({
    required this.bounds,
    required this.originalText,
    required this.translatedText,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.lineCount,
    this.textAlign = TextAlign.left,
  });

  final Rect bounds;
  final String originalText;
  final String translatedText;
  final Color backgroundColor;
  final Color foregroundColor;
  final int lineCount;
  final TextAlign textAlign;
}

/// 图片覆盖式翻译服务：
/// 1. 将 OCR 文本行按视觉段落聚合成独立块（保留表格/菜单/按钮独立性）；
/// 2. 复用应用已配置的 Google / 哔哩哔哩 / AI 翻译引擎批量翻译并 1:1 映射回原块；
/// 3. 在后台 isolate 提取每块背景色与文字前景色（兼容 8-bit/16-bit PNG）；
/// 4. 通过统一矢量绘制函数在原图上实时高清覆盖，并支持合成高清 PNG 保存。
abstract final class ImageTranslationService {
  /// 跳过无需翻译的纯数字、纯符号、IP、常见可执行文件名等。
  static final _skipPattern = RegExp(
    r'^(?:[\d\s.,:%/\\\-+_=<>()\[\]{}|@#\$^&*!?;:"' "'" r'`~]+|'
    r'(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?|'
    r'[A-Za-z0-9_.\-]+\.(?:exe|dll|so|dylib|png|jpg|jpeg|webp|gif|pdf|zip|tar|gz|json|yml|yaml|md|txt|dart|js|ts|py|rs|go|sh))$',
    caseSensitive: false,
  );

  /// 将 OCR 行聚合成适合原位翻译的区块。
  static List<ImageTextBlock> groupBlocks(OcrResult ocr) {
    if (ocr.isEmpty) return const [];
    final lines = ocr.lines.where((l) => l.text.trim().isNotEmpty).toList()
      ..sort((a, b) {
        final dy = a.bounds.top.compareTo(b.bounds.top);
        return dy != 0 ? dy : a.bounds.left.compareTo(b.bounds.left);
      });

    // 标记同一水平行存在多个独立文本框的行（例如表格多列、带标签徽章的下拉菜单项），
    // 这类结构化列表项保持逐行独立，不合并为大段落。
    final multiColIndices = <int>{};
    for (var i = 0; i < lines.length; i++) {
      for (var j = i + 1; j < lines.length; j++) {
        if (_sharesHorizontalRow(lines[i], lines[j])) {
          multiColIndices.add(i);
          multiColIndices.add(j);
        }
      }
    }

    final clusters = <List<OcrTextLine>>[];
    final clusterLocked = <bool>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final isStructuredRow = multiColIndices.contains(i);
      List<OcrTextLine>? target;
      if (!isStructuredRow) {
        for (var c = 0; c < clusters.length; c++) {
          if (clusterLocked[c]) continue;
          if (_shouldMergeIntoParagraph(clusters[c].last, line)) {
            target = clusters[c];
            break;
          }
        }
      }
      if (target != null) {
        target.add(line);
      } else {
        clusters.add([line]);
        clusterLocked.add(isStructuredRow);
      }
    }

    final blocks = <ImageTextBlock>[];
    for (final cluster in clusters) {
      var bounds = cluster.first.bounds;
      final textBuffer = StringBuffer();
      for (var i = 0; i < cluster.length; i++) {
        final item = cluster[i];
        bounds = bounds.expandToInclude(item.bounds);
        if (i > 0) {
          final prevText = cluster[i - 1].text.trimRight();
          final nextText = item.text.trimLeft();
          final needSpace =
              prevText.isNotEmpty &&
              nextText.isNotEmpty &&
              _isAsciiAlphaNum(prevText.codeUnitAt(prevText.length - 1)) &&
              _isAsciiAlphaNum(nextText.codeUnitAt(0));
          if (needSpace) textBuffer.write(' ');
        }
        textBuffer.write(item.text.trim());
      }
      final text = textBuffer.toString().trim();
      if (text.isEmpty || _skipPattern.hasMatch(text)) continue;
      blocks.add(
        ImageTextBlock(
          bounds: bounds,
          originalText: text,
          lineCount: cluster.length,
        ),
      );
    }
    return blocks;
  }

  static bool _sharesHorizontalRow(OcrTextLine a, OcrTextLine b) {
    final vOverlap =
        math.min(a.bounds.bottom, b.bounds.bottom) -
        math.max(a.bounds.top, b.bounds.top);
    final minH = math.min(a.bounds.height, b.bounds.height);
    return minH > 0 && vOverlap >= minH * 0.45;
  }

  static bool _shouldMergeIntoParagraph(OcrTextLine prev, OcrTextLine next) {
    // 同一水平行不合并。
    final vOverlap =
        math.min(prev.bounds.bottom, next.bounds.bottom) -
        math.max(prev.bounds.top, next.bounds.top);
    final minH = math.min(prev.bounds.height, next.bounds.height);
    if (minH <= 0 || vOverlap > minH * 0.25) return false;

    final gap = next.bounds.top - prev.bounds.bottom;
    if (gap < -minH * 0.15 || gap > minH * 0.55) return false;

    final heightRatio = prev.bounds.height / next.bounds.height;
    if (heightRatio < 0.78 || heightRatio > 1.28) return false;

    // 短行菜单/列表项（宽度不足 7.5 倍行高，或上一行已以句末标点结尾）不强行合并成段落。
    if (prev.bounds.width < minH * 7.5) return false;
    final prevTrim = prev.text.trimRight();
    if (prevTrim.isNotEmpty &&
        RegExp(r'[。！？.!?…]$').hasMatch(prevTrim)) {
      return false;
    }

    // 必须严格左对齐且水平重叠充分，避免跨列合并。
    final leftDiff = (next.bounds.left - prev.bounds.left).abs();
    if (leftDiff > minH * 0.85) return false;
    final hOverlap =
        math.min(prev.bounds.right, next.bounds.right) -
        math.max(prev.bounds.left, next.bounds.left);
    final minW = math.min(prev.bounds.width, next.bounds.width);
    return minW > 0 && hOverlap >= minW * 0.6;
  }

  static bool _isAsciiAlphaNum(int u) =>
      (u >= 0x30 && u <= 0x39) ||
      (u >= 0x41 && u <= 0x5A) ||
      (u >= 0x61 && u <= 0x7A);

  /// 在后台 isolate 提取每个文本块的背景色（主色）和文字前景色（对比色）。
  static Future<List<({Color bg, Color fg})>> sampleBlockColors(
    Uint8List imageBytes,
    List<Rect> boundsList,
  ) async {
    if (boundsList.isEmpty) return const [];
    final rawRects = [
      for (final r in boundsList) [r.left, r.top, r.right, r.bottom],
    ];
    final pairs = await Isolate.run(
      () => _sampleColorsInIsolate(imageBytes, rawRects),
    );
    return [
      for (final p in pairs) (bg: Color(p[0]), fg: Color(p[1])),
    ];
  }

  static List<List<int>> _sampleColorsInIsolate(
    Uint8List imageBytes,
    List<List<double>> rawRects,
  ) {
    var image = img.decodeImage(imageBytes);
    if (image == null) {
      return List.filled(rawRects.length, [0xFF1F2126, 0xFFFFFFFF]);
    }
    if (image.format != img.Format.uint8 || image.hasPalette) {
      image = image.convert(
        format: img.Format.uint8,
        numChannels: image.hasAlpha ? 4 : 3,
      );
    }

    final results = <List<int>>[];
    for (final raw in rawRects) {
      final x1 = raw[0].floor().clamp(0, image.width - 1);
      final y1 = raw[1].floor().clamp(0, image.height - 1);
      final x2 = raw[2].ceil().clamp(x1 + 1, image.width);
      final y2 = raw[3].ceil().clamp(y1 + 1, image.height);

      // 1. 统计外沿 2px 边框环 + 区域内量化直方图，外沿权重更高以精准锁定背景色。
      final bgBuckets = <int, _ColorBucket>{};
      final allBuckets = <int, _ColorBucket>{};

      void accumulate(Map<int, _ColorBucket> map, int px, int py, int weight) {
        if (px < 0 || py < 0 || px >= image!.width || py >= image.height) return;
        final p = image.getPixel(px, py);
        final r = p.r.toInt();
        final g = p.g.toInt();
        final b = p.b.toInt();
        final key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
        final bucket = map.putIfAbsent(key, _ColorBucket.new);
        bucket.rSum += r * weight;
        bucket.gSum += g * weight;
        bucket.bSum += b * weight;
        bucket.weight += weight;
      }

      // 外沿边框环采样（上下左右各向外 1~2px）
      final stepBorderX = math.max(1, (x2 - x1) ~/ 32);
      for (var x = x1; x < x2; x += stepBorderX) {
        accumulate(bgBuckets, x, y1 - 1, 3);
        accumulate(bgBuckets, x, y1 - 2, 2);
        accumulate(bgBuckets, x, y2, 3);
        accumulate(bgBuckets, x, y2 + 1, 2);
      }
      final stepBorderY = math.max(1, (y2 - y1) ~/ 16);
      for (var y = y1; y < y2; y += stepBorderY) {
        accumulate(bgBuckets, x1 - 1, y, 3);
        accumulate(bgBuckets, x2, y, 3);
      }

      // 区域内部均匀采样
      final stepX = math.max(1, (x2 - x1) ~/ 48);
      final stepY = math.max(1, (y2 - y1) ~/ 24);
      for (var y = y1; y < y2; y += stepY) {
        for (var x = x1; x < x2; x += stepX) {
          accumulate(allBuckets, x, y, 1);
          accumulate(bgBuckets, x, y, 1);
        }
      }

      final sortedBg = bgBuckets.values.toList()
        ..sort((a, b) => b.weight.compareTo(a.weight));
      final bgRgb = sortedBg.isNotEmpty
          ? sortedBg.first.average
          : (r: 255, g: 255, b: 255);
      final bgLuma = _luma(bgRgb.r, bgRgb.g, bgRgb.b);

      // 2. 在内部直方图中寻找与背景亮度对比显著的最常见文字前景色。
      final sortedAll = allBuckets.values.toList()
        ..sort((a, b) => b.weight.compareTo(a.weight));
      ({int r, int g, int b})? fgRgb;
      for (final bucket in sortedAll) {
        final avg = bucket.average;
        if ((_luma(avg.r, avg.g, avg.b) - bgLuma).abs() >= 65) {
          fgRgb = avg;
          break;
        }
      }
      fgRgb ??= bgLuma > 135
          ? (r: 24, g: 26, b: 32)
          : (r: 250, g: 250, b: 252);

      results.add([
        _argb(255, bgRgb.r, bgRgb.g, bgRgb.b),
        _argb(255, fgRgb.r, fgRgb.g, fgRgb.b),
      ]);
    }
    return results;
  }

  static double _luma(int r, int g, int b) =>
      0.299 * r + 0.587 * g + 0.114 * b;

  static int _argb(int a, int r, int g, int b) =>
      ((a & 0xFF) << 24) | ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF);

  /// 批量翻译所有文本块并合并配色，返回可直接用于覆盖绘制的 [TranslatedTextBlock] 列表。
  static Future<List<TranslatedTextBlock>> translateImage({
    required Uint8List imageBytes,
    required OcrResult ocr,
    required TranslationEngine engine,
    required String targetCode,
    required String targetName,
    required TranslationService translationService,
    AiTranslationService? aiTranslationService,
    ({AiProvider provider, AiModel model})? aiModel,
    String? apiKey,
    required CancelToken cancelToken,
  }) async {
    final blocks = groupBlocks(ocr);
    if (blocks.isEmpty) return const [];

    // 并行：后台采样原图前/背景色 + 批量翻译文字块。
    final colorsFuture = sampleBlockColors(
      imageBytes,
      [for (final b in blocks) b.bounds],
    );
    final translations = await _translateBlocks(
      blocks: blocks,
      engine: engine,
      targetCode: targetCode,
      targetName: targetName,
      translationService: translationService,
      aiTranslationService: aiTranslationService,
      aiModel: aiModel,
      apiKey: apiKey,
      cancelToken: cancelToken,
    );
    final colors = await colorsFuture;

    final result = <TranslatedTextBlock>[];
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      final translated = (i < translations.length ? translations[i] : '').trim();
      if (translated.isEmpty) continue;
      // 译文与原文完全一致（如软件名、命令、已是目标语言）时保留原图高清字样。
      if (translated.toLowerCase() == block.originalText.trim().toLowerCase()) {
        continue;
      }
      final palette = colors[i];
      result.add(
        TranslatedTextBlock(
          bounds: block.bounds,
          originalText: block.originalText,
          translatedText: translated,
          backgroundColor: palette.bg,
          foregroundColor: palette.fg,
          lineCount: block.lineCount,
        ),
      );
    }
    return result;
  }

  static Future<List<String>> _translateBlocks({
    required List<ImageTextBlock> blocks,
    required TranslationEngine engine,
    required String targetCode,
    required String targetName,
    required TranslationService translationService,
    AiTranslationService? aiTranslationService,
    ({AiProvider provider, AiModel model})? aiModel,
    String? apiKey,
    required CancelToken cancelToken,
  }) async {
    final outputs = List<String>.filled(blocks.length, '');
    final maxBatchChars = engine == TranslationEngine.google ? 700 : 2200;

    var start = 0;
    while (start < blocks.length) {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      final batch = <int>[];
      var chars = 0;
      while (start < blocks.length) {
        final len = blocks[start].originalText.length + 12;
        if (batch.isNotEmpty && (chars + len > maxBatchChars || batch.length >= 25)) {
          break;
        }
        batch.add(start);
        chars += len;
        start++;
      }

      final payload = StringBuffer();
      for (final idx in batch) {
        final sanitized = blocks[idx].originalText.replaceAll('\n', ' ');
        payload.writeln('[$idx] $sanitized');
      }

      final raw = await _runSingleBatch(
        engine: engine,
        payload: payload.toString().trim(),
        targetCode: targetCode,
        targetName: targetName,
        translationService: translationService,
        aiTranslationService: aiTranslationService,
        aiModel: aiModel,
        apiKey: apiKey,
        cancelToken: cancelToken,
      );

      final parsed = parseIndexedTranslations(raw, batch);
      for (final entry in parsed.entries) {
        outputs[entry.key] = entry.value;
      }
    }
    return outputs;
  }

  static Future<String> _runSingleBatch({
    required TranslationEngine engine,
    required String payload,
    required String targetCode,
    required String targetName,
    required TranslationService translationService,
    AiTranslationService? aiTranslationService,
    ({AiProvider provider, AiModel model})? aiModel,
    String? apiKey,
    required CancelToken cancelToken,
  }) async {
    if (engine == TranslationEngine.ai) {
      if (aiTranslationService == null ||
          aiModel == null ||
          apiKey == null ||
          apiKey.trim().isEmpty) {
        throw const TranslationException(TranslationFailure.unavailable);
      }
      final buffer = StringBuffer();
      await for (final delta in aiTranslationService.translateStream(
        provider: aiModel.provider,
        model: aiModel.model,
        apiKey: apiKey.trim(),
        text:
            '请逐行将下面带编号 [数字] 的图片文本翻译为$targetName，严格保留每行开头的 [数字] 编号，不要合并或遗漏行，不要添加解释：\n\n$payload',
        targetLanguage: targetName,
      )) {
        if (cancelToken.isCancelled) throw cancelToken.cancelError!;
        buffer.write(delta);
      }
      return buffer.toString();
    }

    final buffer = StringBuffer();
    await for (final chunk in translationService.translate(
      engine: engine,
      text: payload,
      targetCode: targetCode,
      targetName: targetName,
      cancelToken: cancelToken,
    )) {
      buffer.write(chunk);
    }
    return buffer.toString();
  }

  /// 解析带 `[index]` 编号的批量译文，兼容全角括号 `【index】` 和行序回退。
  static Map<int, String> parseIndexedTranslations(
    String raw,
    List<int> expectedIndices,
  ) {
    final result = <int, String>{};
    final expectedSet = expectedIndices.toSet();
    final marker = RegExp(r'^\s*[\[【]\s*(\d+)\s*[\]】]\s*(.*)$');
    final lines = raw
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    for (final line in lines) {
      final m = marker.firstMatch(line);
      if (m != null) {
        final idx = int.tryParse(m.group(1)!);
        final text = m.group(2)!.trim();
        if (idx != null && expectedSet.contains(idx) && text.isNotEmpty) {
          result[idx] = text;
        }
      }
    }

    // 若翻译引擎丢掉了编号标记，但返回行数与批次完全一致，按顺序回退对齐。
    if (result.isEmpty && lines.length == expectedIndices.length) {
      for (var i = 0; i < expectedIndices.length; i++) {
        result[expectedIndices[i]] = lines[i];
      }
    }
    return result;
  }

  /// 在任意画布上高清矢量绘制覆盖式译文（实时预览与导出保存共用同一算法）。
  static void paintTranslatedBlocks(
    Canvas canvas, {
    required Rect displayRect,
    required Size imageSize,
    required List<TranslatedTextBlock> blocks,
    double opacity = 1.0,
  }) {
    if (blocks.isEmpty ||
        displayRect.isEmpty ||
        imageSize.isEmpty ||
        opacity <= 0) {
      return;
    }
    final scaleX = displayRect.width / imageSize.width;
    final scaleY = displayRect.height / imageSize.height;

    for (final block in blocks) {
      final raw = Rect.fromLTRB(
        displayRect.left + block.bounds.left * scaleX,
        displayRect.top + block.bounds.top * scaleY,
        displayRect.left + block.bounds.right * scaleX,
        displayRect.top + block.bounds.bottom * scaleY,
      );
      // 轻微扩边覆盖原字边缘抗锯齿毛边，同时保持克制避免盖住邻近图标。
      final padX = math.max(1.0, raw.height * 0.05);
      final padY = math.max(1.0, raw.height * 0.05);
      final fillRect = Rect.fromLTRB(
        math.max(displayRect.left, raw.left - padX),
        math.max(displayRect.top, raw.top - padY),
        math.min(displayRect.right, raw.right + padX),
        math.min(displayRect.bottom, raw.bottom + padY),
      );
      if (fillRect.width < 4 || fillRect.height < 4) continue;

      final radius = math.min(4.0, fillRect.height * 0.16);
      final rrect = RRect.fromRectAndRadius(fillRect, Radius.circular(radius));

      // 1. 以采样到的原图背景色覆盖原文。
      canvas.drawRRect(
        rrect,
        Paint()..color = block.backgroundColor.withValues(alpha: opacity),
      );

      // 2. 二分计算恰好适配区域的最大清晰字号并矢量绘制。
      final availW = math.max(4.0, fillRect.width - 2.0);
      final availH = math.max(4.0, fillRect.height - 1.0);
      final painter = _fitTextPainter(
        text: block.translatedText,
        color: block.foregroundColor.withValues(alpha: opacity),
        maxWidth: availW,
        maxHeight: availH,
        lineCountHint: block.lineCount,
        textAlign: block.textAlign,
      );

      canvas.save();
      canvas.clipRRect(rrect);
      final dx = fillRect.left + 1.0 + math.max(0.0, (availW - painter.width) / 2);
      final dy = fillRect.top + math.max(0.0, (fillRect.height - painter.height) / 2);
      painter.paint(canvas, Offset(block.textAlign == TextAlign.left ? fillRect.left + 2.0 : dx, dy));
      canvas.restore();
    }
  }

  static TextPainter _fitTextPainter({
    required String text,
    required Color color,
    required double maxWidth,
    required double maxHeight,
    required int lineCountHint,
    required TextAlign textAlign,
  }) {
    final minFont = math.min(8.0, maxHeight * 0.7);
    final maxFont = math.max(
      minFont,
      math.min(maxHeight / math.max(1, lineCountHint) * 0.92, 64.0),
    );

    TextPainter build(double fontSize) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: color,
            fontSize: fontSize,
            height: 1.15,
            fontWeight: FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: textAlign,
      )..layout(maxWidth: maxWidth);
      return tp;
    }

    var lo = minFont;
    var hi = maxFont;
    var best = build(lo);
    for (var iter = 0; iter < 9; iter++) {
      final mid = (lo + hi) / 2;
      final candidate = build(mid);
      if (candidate.height <= maxHeight && candidate.width <= maxWidth + 0.5) {
        best = candidate;
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return best;
  }

  /// 将原图与矢量译文层光栅化合成为一张高清 PNG，供「保存译图」使用。
  static Future<Uint8List> renderTranslatedPng(
    ui.Image baseImage,
    List<TranslatedTextBlock> blocks,
  ) async {
    final w = baseImage.width;
    final h = baseImage.height;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final rect = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
    canvas.drawImage(baseImage, Offset.zero, Paint());
    paintTranslatedBlocks(
      canvas,
      displayRect: rect,
      imageSize: Size(w.toDouble(), h.toDouble()),
      blocks: blocks,
    );
    final picture = recorder.endRecording();
    final rendered = await picture.toImage(w, h);
    picture.dispose();
    try {
      final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw const FormatException('无法编码译图 PNG');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      rendered.dispose();
    }
  }
}

class _ColorBucket {
  int rSum = 0;
  int gSum = 0;
  int bSum = 0;
  int weight = 0;

  ({int r, int g, int b}) get average => weight == 0
      ? (r: 255, g: 255, b: 255)
      : (
          r: (rSum ~/ weight).clamp(0, 255),
          g: (gSum ~/ weight).clamp(0, 255),
          b: (bSum ~/ weight).clamp(0, 255),
        );
}
