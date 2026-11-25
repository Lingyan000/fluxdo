import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'local_ocr_service.dart';

/// 原图坐标系下的单个无缝字符格。
class PictureGlyph {
  const PictureGlyph({
    required this.text,
    required this.lineIndex,
    required this.bounds,
  });

  final String text;
  final int lineIndex;
  final Rect bounds;

  double get centerX => bounds.center.dx;
  double get centerY => bounds.center.dy;
}

/// 面向原图实况选字的排版模型：
/// - 将识别行按阅读顺序排列，构造相邻字符无缝衔接的字符格；
/// - 智能拼合同一段落的连续换行，并在中文/假名与英文数字间自动补空格；
/// - 提供命中查询、最近字符查询和逐行高亮选区计算。
class PictureTextLayout {
  PictureTextLayout._({
    required this.imageWidth,
    required this.imageHeight,
    required this.lines,
    required this.glyphs,
    required this.joins,
  });

  factory PictureTextLayout.fromOcr(OcrResult ocr) {
    final valid = ocr.lines.where((l) => l.text.trim().isNotEmpty).toList();
    final ordered = _orderLines(valid);
    final glyphs = <PictureGlyph>[];
    for (var lineIdx = 0; lineIdx < ordered.length; lineIdx++) {
      glyphs.addAll(_buildGlyphs(ordered[lineIdx], lineIdx));
    }
    final joins = <String>[
      for (var i = 0; i + 1 < ordered.length; i++)
        _joinBetween(ordered[i], ordered[i + 1]),
    ];
    return PictureTextLayout._(
      imageWidth: ocr.imageWidth,
      imageHeight: ocr.imageHeight,
      lines: ordered,
      glyphs: glyphs,
      joins: joins,
    );
  }

  final int imageWidth;
  final int imageHeight;
  final List<OcrTextLine> lines;
  final List<PictureGlyph> glyphs;
  final List<String> joins;

  bool get isEmpty => glyphs.isEmpty;

  String get fullText => isEmpty ? '' : extractText(0, glyphs.length - 1);

  /// 提取 `[from, to]`（闭区间）字符对应的自然排版文本。
  String extractText(int from, int to) {
    if (glyphs.isEmpty) return '';
    final start = from.clamp(0, glyphs.length - 1);
    final end = to.clamp(0, glyphs.length - 1);
    if (start > end) return '';

    final out = StringBuffer();
    int? prevCodeUnit;
    for (var i = start; i <= end; i++) {
      final glyph = glyphs[i];
      if (i > start && glyph.lineIndex != glyphs[i - 1].lineIndex) {
        final joiner = joins[glyphs[i - 1].lineIndex];
        out.write(joiner);
        prevCodeUnit = joiner.isEmpty
            ? prevCodeUnit
            : joiner.codeUnitAt(joiner.length - 1);
      }
      final ch = glyph.text;
      if (ch.isNotEmpty) {
        final firstUnit = ch.codeUnitAt(0);
        if (prevCodeUnit != null &&
            ((_isHanOrKana(prevCodeUnit) && _isAsciiWord(firstUnit)) ||
                (_isAsciiWord(prevCodeUnit) && _isHanOrKana(firstUnit)))) {
          out.write(' ');
        }
        out.write(ch);
        prevCodeUnit = ch.codeUnitAt(ch.length - 1);
      }
    }
    return out.toString();
  }

  /// 在容差 [reach]（原图像素）内命中坐标 `(x, y)` 最近的字符索引；未命中返回 null。
  int? glyphAt(double x, double y, {double reach = 0}) {
    if (lines.isEmpty || glyphs.isEmpty) return null;
    int? bestLine;
    var bestGap = double.infinity;
    for (var i = 0; i < lines.length; i++) {
      final g = _gapToRect(lines[i].bounds, x, y);
      if (g < bestGap) {
        bestGap = g;
        bestLine = i;
      }
    }
    if (bestLine == null || bestGap > reach) return null;
    return _nearestGlyphInLine(bestLine, x);
  }

  /// 拖动手柄时使用：无论手指拖到画面何处，总能找到最合理的最近字符。
  int? nearestGlyph(double x, double y) {
    if (lines.isEmpty || glyphs.isEmpty) return null;
    var bestLine = 0;
    var bestScore = double.infinity;
    for (var i = 0; i < lines.length; i++) {
      final b = lines[i].bounds;
      final dy = (b.center.dy - y).abs();
      final dx = math.max(0.0, math.max(b.left - x, x - b.right));
      final score = dy + dx * 0.25;
      if (score < bestScore) {
        bestScore = score;
        bestLine = i;
      }
    }
    return _nearestGlyphInLine(bestLine, x);
  }

  /// 返回 [glyphIndex] 所在行的闭区间 `(start, end)`。
  ({int start, int end}) lineRangeOf(int glyphIndex) {
    final targetLine = glyphs[glyphIndex].lineIndex;
    var start = glyphIndex;
    while (start > 0 && glyphs[start - 1].lineIndex == targetLine) {
      start--;
    }
    var end = glyphIndex;
    while (end + 1 < glyphs.length &&
        glyphs[end + 1].lineIndex == targetLine) {
      end++;
    }
    return (start: start, end: end);
  }

  /// 计算闭区间 `[from, to]` 覆盖的逐行连续高亮矩形（原图坐标系）。
  List<Rect> selectionRects(int from, int to) {
    if (glyphs.isEmpty) return const [];
    final start = from.clamp(0, glyphs.length - 1);
    final end = to.clamp(0, glyphs.length - 1);
    if (start > end) return const [];

    final rects = <Rect>[];
    var i = start;
    while (i <= end) {
      final line = glyphs[i].lineIndex;
      var j = i;
      while (j + 1 <= end && glyphs[j + 1].lineIndex == line) {
        j++;
      }
      final a = glyphs[i].bounds;
      final b = glyphs[j].bounds;
      rects.add(
        Rect.fromLTRB(
          math.min(a.left, b.left),
          math.min(a.top, b.top),
          math.max(a.right, b.right),
          math.max(a.bottom, b.bottom),
        ),
      );
      i = j + 1;
    }
    return rects;
  }

  /// 计算闭区间 `[from, to]` 的整体外接矩形（原图坐标系）。
  Rect? selectionBounds(int from, int to) {
    final rects = selectionRects(from, to);
    if (rects.isEmpty) return null;
    var merged = rects.first;
    for (var i = 1; i < rects.length; i++) {
      merged = merged.expandToInclude(rects[i]);
    }
    return merged;
  }

  int? _nearestGlyphInLine(int lineIndex, double x) {
    int? best;
    var bestDx = double.infinity;
    for (var i = 0; i < glyphs.length; i++) {
      if (glyphs[i].lineIndex != lineIndex) continue;
      final dx = (glyphs[i].centerX - x).abs();
      if (dx < bestDx) {
        bestDx = dx;
        best = i;
      }
    }
    return best;
  }

  static double _gapToRect(Rect r, double x, double y) =>
      math.max(math.max(r.left - x, 0.0), x - r.right) +
      math.max(math.max(r.top - y, 0.0), y - r.bottom);

  static bool _sharesRow(OcrTextLine a, OcrTextLine b) {
    final overlap =
        math.min(a.bounds.bottom, b.bounds.bottom) -
        math.max(a.bounds.top, b.bounds.top);
    final minH = math.min(a.bounds.height, b.bounds.height);
    return minH > 0 && overlap >= 0.5 * minH;
  }

  static List<OcrTextLine> _orderLines(List<OcrTextLine> input) {
    final sorted = List<OcrTextLine>.of(input)
      ..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
    final rows = <List<OcrTextLine>>[];
    for (final line in sorted) {
      if (rows.isNotEmpty && rows.last.any((other) => _sharesRow(other, line))) {
        rows.last.add(line);
      } else {
        rows.add([line]);
      }
    }
    final ordered = <OcrTextLine>[];
    for (final row in rows) {
      row.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
      ordered.addAll(row);
    }
    return ordered;
  }

  static String _joinBetween(OcrTextLine a, OcrTextLine b) {
    if (_sharesRow(a, b)) return ' ';
    final minH = math.min(a.bounds.height, b.bounds.height);
    final verticalGap = b.bounds.top - a.bounds.bottom;
    final aligned = (b.bounds.left - a.bounds.left).abs() <= minH;
    final continues = verticalGap <= 0.8 * minH && b.bounds.top >= a.bounds.top;
    if (!continues || !aligned) return '\n';
    final endText = a.text.trimRight();
    final startText = b.text.trimLeft();
    if (endText.isEmpty || startText.isEmpty) return '';
    final endUnit = endText.codeUnitAt(endText.length - 1);
    final startUnit = startText.codeUnitAt(0);
    return _isLatin(endUnit) && _isLatin(startUnit) ? ' ' : '';
  }

  static List<PictureGlyph> _buildGlyphs(OcrTextLine line, int lineIndex) {
    final text = line.text;
    final len = text.length;
    if (len == 0) return const [];
    final bounds = line.bounds;
    final hasExact = line.charBounds.length == len;
    final raw = hasExact
        ? line.charBounds
        : [
            for (var i = 0; i < len; i++)
              Rect.fromLTRB(
                bounds.left + bounds.width * (i / len),
                bounds.top,
                bounds.left + bounds.width * ((i + 1) / len),
                bounds.bottom,
              ),
          ];

    // 将相邻字符框在中点处无缝拼接，首尾贴齐行边界，高亮选区连贯无竖缝。
    return [
      for (var i = 0; i < len; i++)
        PictureGlyph(
          text: text[i],
          lineIndex: lineIndex,
          bounds: Rect.fromLTRB(
            i == 0 ? bounds.left : (raw[i - 1].right + raw[i].left) / 2,
            bounds.top,
            math.max(
              i == 0 ? bounds.left : (raw[i - 1].right + raw[i].left) / 2,
              i == len - 1
                  ? bounds.right
                  : (raw[i].right + raw[i + 1].left) / 2,
            ),
            bounds.bottom,
          ),
        ),
    ];
  }

  static bool _isHanOrKana(int u) =>
      (u >= 0x4E00 && u <= 0x9FFF) ||
      (u >= 0x3400 && u <= 0x4DBF) ||
      (u >= 0x3040 && u <= 0x30FF);

  static bool _isAsciiWord(int u) =>
      (u >= 0x30 && u <= 0x39) ||
      (u >= 0x41 && u <= 0x5A) ||
      (u >= 0x61 && u <= 0x7A);

  static bool _isLatin(int u) =>
      u < 0x2E80 && (_isAsciiWord(u) || ',.;:!?)'.codeUnits.contains(u));
}
