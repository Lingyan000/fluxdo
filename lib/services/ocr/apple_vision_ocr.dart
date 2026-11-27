import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import '../app_logger.dart';
import 'local_ocr_service.dart';

/// macOS / iOS 系统原生 Vision 文字识别封装。
///
/// 通过 `com.fluxdo/vision_ocr` MethodChannel 调用 `VNRecognizeTextRequest`，
/// 利用系统硬件加速完成检测与识别，免去离线模型下载，并将结果统一归一化为
/// [OcrResult]（含视觉行号 `rowIndex` 与 UTF-16 对齐的逐字包围盒）。
class AppleVisionOcr {
  static const MethodChannel _defaultChannel = MethodChannel(
    'com.fluxdo/vision_ocr',
  );

  static bool? _cachedAvailable;

  /// 当前运行平台是否支持 Apple Vision OCR。
  static bool get isSupportedPlatform => Platform.isMacOS || Platform.isIOS;

  /// 查询原生通道是否可用（默认通道结果缓存，避免反复跨通道查询）。
  static Future<bool> isAvailable({MethodChannel? channel}) async {
    if (channel == null) {
      if (!isSupportedPlatform) return false;
      // flutter test 环境下无原生 Swift Runner，直接返回 false，避免 FakeAsync 阻塞在未注册的平台通道上。
      if (Platform.environment['FLUTTER_TEST'] == 'true') return false;
      final cached = _cachedAvailable;
      if (cached != null) return cached;
    }
    try {
      final available =
          await (channel ?? _defaultChannel).invokeMethod<bool>(
            'isAvailable',
          ) ??
          false;
      if (channel == null) {
        _cachedAvailable = available;
      }
      return available;
    } on MissingPluginException {
      if (channel == null) _cachedAvailable = false;
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 仅供测试重置可用性缓存。
  @visibleForTesting
  static void resetAvailabilityCache() {
    _cachedAvailable = null;
  }

  /// 使用原生 Vision 引擎识别图片字节中的文字。
  static Future<OcrResult> recognize(
    Uint8List imageBytes, {
    MethodChannel? channel,
  }) async {
    final sw = Stopwatch()..start();
    final raw = await (channel ?? _defaultChannel).invokeMethod<Object?>(
      'recognize',
      imageBytes,
    );
    if (raw is! Map) {
      throw const FormatException('系统 OCR 返回数据格式无效');
    }
    final result = parseNativeResult(raw);
    final decodeMs = (raw['decodeMs'] as num?)?.toInt();
    final performMs = (raw['performMs'] as num?)?.toInt();
    final boxesMs = (raw['boxesMs'] as num?)?.toInt();
    final breakdown = decodeMs != null && performMs != null && boxesMs != null
        ? ' decode=${decodeMs}ms perform=${performMs}ms boxes=${boxesMs}ms'
        : '';
    AppLogger.info(
      'OCR 识别完成: engine=vision '
      'total=${sw.elapsedMilliseconds}ms$breakdown '
      'size=${result.imageWidth}x${result.imageHeight} '
      'lines=${result.lines.length}',
      tag: 'OCR',
    );
    return result;
  }

  /// 将原生通道返回的字典解析为结构化 [OcrResult]，并按视觉阅读顺序分配行号。
  @visibleForTesting
  static OcrResult parseNativeResult(Map<Object?, Object?> raw) {
    final imageWidth = (raw['imageWidth'] as num?)?.toInt() ?? 0;
    final imageHeight = (raw['imageHeight'] as num?)?.toInt() ?? 0;
    final rawLines = raw['lines'];
    if (imageWidth <= 0 || imageHeight <= 0 || rawLines is! List) {
      return OcrResult(
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        lines: const [],
      );
    }

    final parsed = <({String text, Rect bounds, List<Rect> charBounds})>[];
    for (final entry in rawLines) {
      if (entry is! Map) continue;
      final text = (entry['text'] as String?)?.trim() ?? '';
      if (text.isEmpty) continue;

      final bounds = _parseRect(entry['bounds']);
      if (bounds == null || bounds.isEmpty) continue;

      final charBounds = _parseCharBounds(
        entry['charBounds'],
        text.length,
        bounds,
      );
      parsed.add((text: text, bounds: bounds, charBounds: charBounds));
    }

    return OcrResult(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      lines: assignReadingOrderRows(parsed),
    );
  }

  /// 按与 LiteRT 一致的视觉行归并规则（从上到下分行、行内从左到右）分配 `rowIndex`。
  @visibleForTesting
  static List<OcrTextLine> assignReadingOrderRows(
    List<({String text, Rect bounds, List<Rect> charBounds})> items,
  ) {
    if (items.isEmpty) return const [];
    final sorted = List.of(items)
      ..sort((a, b) => a.bounds.center.dy.compareTo(b.bounds.center.dy));

    final ordered = <OcrTextLine>[];
    final row = <({String text, Rect bounds, List<Rect> charBounds})>[];
    var rowIndex = 0;

    void finishRow() {
      if (row.isEmpty) return;
      row.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
      for (final item in row) {
        ordered.add(
          OcrTextLine(
            text: item.text,
            bounds: item.bounds,
            charBounds: item.charBounds,
            rowIndex: rowIndex,
          ),
        );
      }
      rowIndex++;
      row.clear();
    }

    for (final item in sorted) {
      if (row.isNotEmpty &&
          item.bounds.center.dy - row.first.bounds.center.dy >
              math.min(item.bounds.height, row.first.bounds.height) / 2) {
        finishRow();
      }
      row.add(item);
    }
    finishRow();
    return ordered;
  }

  static Rect? _parseRect(Object? raw) {
    if (raw is! List || raw.length < 4) return null;
    final l = (raw[0] as num?)?.toDouble();
    final t = (raw[1] as num?)?.toDouble();
    final r = (raw[2] as num?)?.toDouble();
    final b = (raw[3] as num?)?.toDouble();
    if (l == null || t == null || r == null || b == null) return null;
    if (r <= l || b <= t) return null;
    return Rect.fromLTRB(l, t, r, b);
  }

  static List<Rect> _parseCharBounds(
    Object? raw,
    int charCount,
    Rect fallbackBounds,
  ) {
    if (raw is List && raw.length == charCount * 4) {
      final rects = <Rect>[];
      var valid = true;
      for (var i = 0; i < charCount; i++) {
        final l = (raw[i * 4] as num?)?.toDouble();
        final t = (raw[i * 4 + 1] as num?)?.toDouble();
        final r = (raw[i * 4 + 2] as num?)?.toDouble();
        final b = (raw[i * 4 + 3] as num?)?.toDouble();
        if (l == null || t == null || r == null || b == null) {
          valid = false;
          break;
        }
        rects.add(Rect.fromLTRB(l, t, math.max(l, r), math.max(t, b)));
      }
      if (valid) return rects;
    }
    // 兜底：按行宽均匀划分每个 UTF-16 字符框，确保长度严格对齐 text.length。
    final span = fallbackBounds.width / math.max(1, charCount);
    return [
      for (var i = 0; i < charCount; i++)
        Rect.fromLTRB(
          fallbackBounds.left + span * i,
          fallbackBounds.top,
          fallbackBounds.left + span * (i + 1),
          fallbackBounds.bottom,
        ),
    ];
  }
}
