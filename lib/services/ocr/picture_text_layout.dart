import 'dart:math' as math;
import 'dart:ui' show Rect, TextAlign;

import 'local_ocr_service.dart';

/// OCR 文本行排版方向。
enum OcrTextDirection { horizontal, vertical }

/// OCR 文本输出排版模式（0ms 本地即时切换，无需重新识字）。
enum OcrTextLayoutMode {
  /// 智能分段（line2para 视觉归并 + XY-Cut 阅读顺序）。
  smartParagraph,

  /// 保留换行（按视觉行逐行换行，不合并段落，适合代码、日志、清单与诗歌）。
  preserveLines,

  /// 合并为单段（全部文字拼成一整段，自动补英文与中英间距并修复软连字符）。
  singleParagraph,
}

/// 智能排版归并后的逻辑段落（由一个或多个视觉连续行组成）。
class OcrParagraph {
  const OcrParagraph({
    required this.lines,
    required this.lineIndices,
    required this.bounds,
    required this.direction,
    required this.alignment,
    required this.text,
  });

  final List<OcrTextLine> lines;
  final List<int> lineIndices;
  final Rect bounds;
  final OcrTextDirection direction;
  final TextAlign alignment;
  final String text;
}

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

/// 面向原图实况选字、全文复制与覆盖译图的统一智能排版模型：
/// - 递归 XY-Cut 区域划分：识别多栏文档、侧边栏与聊天双侧气泡，防止跨栏串行，
///   同时识别紧凑表格/带徽章菜单以保持逐行阅读顺序；
/// - 段落智能归并：识别中文首行缩进、列表/编号项、居中/右对齐多行段落与竖排文字列，
///   自动修复英文行尾连字符断词并在中日文与英文数字间补空格；
/// - 构造相邻字符无缝衔接的字符格，提供命中查询、最近字符查询与逐行高亮选区计算。
class PictureTextLayout {
  PictureTextLayout._({
    required this.imageWidth,
    required this.imageHeight,
    required this.lines,
    required this.lineDirections,
    required this.paragraphs,
    required this.glyphs,
    required this.joins,
    required this.stripHyphenAfterLine,
  });

  factory PictureTextLayout.fromOcr(OcrResult ocr) {
    final valid = ocr.lines.where((l) => l.text.trim().isNotEmpty).toList();
    if (valid.isEmpty) {
      return PictureTextLayout._(
        imageWidth: ocr.imageWidth,
        imageHeight: ocr.imageHeight,
        lines: const [],
        lineDirections: const [],
        paragraphs: const [],
        glyphs: const [],
        joins: const [],
        stripHyphenAfterLine: const [],
      );
    }

    final externalGroups = ocr.paragraphGroups;
    if (externalGroups != null && externalGroups.isNotEmpty) {
      final fromModel = _buildFromParagraphGroups(ocr, externalGroups);
      if (fromModel != null) return fromModel;
    }

    final items = <_LayoutItem>[
      for (final line in valid)
        _LayoutItem(line: line, direction: detectLineDirection(line)),
    ];

    final orderedRegions = _orderRegionsByXyCut(items);
    final ordered = <OcrTextLine>[];
    final directions = <OcrTextDirection>[];
    final regionIds = <int>[];
    final regionBounds = <Rect>[];

    for (var r = 0; r < orderedRegions.length; r++) {
      final region = orderedRegions[r];
      if (region.isEmpty) continue;
      var bounds = region.first.bounds;
      for (final item in region) {
        bounds = bounds.expandToInclude(item.bounds);
        ordered.add(item.line);
        directions.add(item.direction);
        regionIds.add(r);
      }
      regionBounds.add(bounds);
    }

    final glyphs = <PictureGlyph>[];
    for (var lineIdx = 0; lineIdx < ordered.length; lineIdx++) {
      glyphs.addAll(_buildGlyphs(ordered[lineIdx], lineIdx, directions[lineIdx]));
    }

    final joins = List<String>.filled(
      math.max(0, ordered.length - 1),
      '\n',
    );
    final stripHyphen = List<bool>.filled(ordered.length, false);
    final paragraphs = <OcrParagraph>[];

    var idx = 0;
    while (idx < ordered.length) {
      final start = idx;
      final regionId = regionIds[start];
      final regionRect = regionBounds[regionId];
      final direction = directions[start];

      var end = start;
      while (end + 1 < ordered.length) {
        final next = end + 1;
        if (regionIds[next] != regionId || directions[next] != direction) {
          joins[end] = '\n';
          break;
        }
        final prevLine = ordered[end];
        final nextLine = ordered[next];
        final firstLine = ordered[start];
        final merge = _decideLineJoin(
          prev: prevLine,
          next: nextLine,
          paragraphFirst: firstLine,
          direction: direction,
          regionRect: regionRect,
        );
        if (!merge.sameParagraph) {
          joins[end] = '\n';
          break;
        }
        joins[end] = merge.joiner;
        stripHyphen[end] = merge.stripTrailingHyphen;
        end = next;
      }

      final paraLines = ordered.sublist(start, end + 1);
      final paraIndices = [for (var i = start; i <= end; i++) i];
      var paraBounds = paraLines.first.bounds;
      for (var i = 1; i < paraLines.length; i++) {
        paraBounds = paraBounds.expandToInclude(paraLines[i].bounds);
      }
      final alignment = detectParagraphAlignment(
        paraLines,
        regionLeft: regionRect.left,
        regionRight: regionRect.right,
      );
      final text = _composeLinesText(
        paraLines,
        joins,
        stripHyphen,
        start,
      );
      paragraphs.add(
        OcrParagraph(
          lines: paraLines,
          lineIndices: paraIndices,
          bounds: paraBounds,
          direction: direction,
          alignment: alignment,
          text: text,
        ),
      );
      idx = end + 1;
    }

    return PictureTextLayout._(
      imageWidth: ocr.imageWidth,
      imageHeight: ocr.imageHeight,
      lines: ordered,
      lineDirections: directions,
      paragraphs: paragraphs,
      glyphs: glyphs,
      joins: joins,
      stripHyphenAfterLine: stripHyphen,
    );
  }

  final int imageWidth;
  final int imageHeight;
  final List<OcrTextLine> lines;
  final List<OcrTextDirection> lineDirections;
  final List<OcrParagraph> paragraphs;
  final List<PictureGlyph> glyphs;
  final List<String> joins;
  final List<bool> stripHyphenAfterLine;

  bool get isEmpty => glyphs.isEmpty;

  String get fullText => isEmpty ? '' : extractText(0, glyphs.length - 1);

  /// 按指定 [OcrTextLayoutMode] 输出完整文本（0ms 即时重排，无需重新识字）。
  String formatText(OcrTextLayoutMode mode) {
    if (isEmpty) return '';
    switch (mode) {
      case OcrTextLayoutMode.smartParagraph:
        return fullText;
      case OcrTextLayoutMode.preserveLines:
        return _formatPreserveLines();
      case OcrTextLayoutMode.singleParagraph:
        return _formatSingleParagraph();
    }
  }

  String _formatPreserveLines() {
    final out = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      final text = lines[i].text.trim();
      if (text.isEmpty) continue;
      if (out.isNotEmpty) {
        final prev = lines[i - 1];
        final sameVisualRow =
            lineDirections[i - 1] == OcrTextDirection.horizontal &&
            lineDirections[i] == OcrTextDirection.horizontal &&
            _sharesRow(prev, lines[i]);
        out.write(sameVisualRow ? ' ' : '\n');
      }
      out.write(text);
    }
    return out.toString();
  }

  String _formatSingleParagraph() {
    final out = StringBuffer();
    int? prevCodeUnit;
    for (var i = 0; i < lines.length; i++) {
      var text = lines[i].text.trim();
      if (text.isEmpty) continue;
      if (out.isNotEmpty && i > 0) {
        final prevLine = lines[i - 1];
        final prevTrim = prevLine.text.trimRight();
        final isSoftHyphen =
            prevTrim.length >= 2 &&
            prevTrim.endsWith('-') &&
            !prevTrim.endsWith('--') &&
            _isAsciiAlpha(prevTrim.codeUnitAt(prevTrim.length - 2)) &&
            _isAsciiLower(text.codeUnitAt(0));
        if (!isSoftHyphen && prevTrim.isNotEmpty) {
          final endUnit = prevTrim.codeUnitAt(prevTrim.length - 1);
          final startUnit = text.codeUnitAt(0);
          if (_isLatin(endUnit) && _isLatin(startUnit)) {
            out.write(' ');
            prevCodeUnit = 0x20;
          }
        }
      }
      if (i + 1 < lines.length) {
        final nextTrim = lines[i + 1].text.trimLeft();
        if (text.length >= 2 &&
            text.endsWith('-') &&
            !text.endsWith('--') &&
            _isAsciiAlpha(text.codeUnitAt(text.length - 2)) &&
            nextTrim.isNotEmpty &&
            _isAsciiLower(nextTrim.codeUnitAt(0))) {
          text = text.substring(0, text.length - 1);
        }
      }
      for (var c = 0; c < text.length; c++) {
        final unit = text.codeUnitAt(c);
        if (prevCodeUnit != null &&
            ((_isHanOrKana(prevCodeUnit) && _isAsciiWord(unit)) ||
                (_isAsciiWord(prevCodeUnit) && _isHanOrKana(unit)))) {
          out.write(' ');
        }
        out.writeCharCode(unit);
        prevCodeUnit = unit;
      }
    }
    return out.toString();
  }

  /// 判断单条 OCR 文本行是横排还是竖排。
  static OcrTextDirection detectLineDirection(OcrTextLine line) {
    final trimmed = line.text.trim();
    if (trimmed.length < 2) return OcrTextDirection.horizontal;
    final b = line.bounds;
    if (b.width <= 0 || b.height <= 0) return OcrTextDirection.horizontal;
    if (b.height <= b.width * 1.65) return OcrTextDirection.horizontal;
    if (b.height / trimmed.length < b.width * 0.48) {
      return OcrTextDirection.horizontal;
    }
    if (line.charBounds.length == line.text.length &&
        line.charBounds.length >= 2) {
      final dy =
          (line.charBounds.last.center.dy - line.charBounds.first.center.dy)
              .abs();
      final dx =
          (line.charBounds.last.center.dx - line.charBounds.first.center.dx)
              .abs();
      if (dy <= dx * 1.2) return OcrTextDirection.horizontal;
    }
    return OcrTextDirection.vertical;
  }

  /// 供译图等上层服务复用：按递归 XY-Cut 返回分区与阅读顺序排列后的文本行分组。
  static List<List<OcrTextLine>> orderRegions(List<OcrTextLine> lines) {
    final valid = lines.where((l) => l.text.trim().isNotEmpty).toList();
    if (valid.isEmpty) return const [];
    final items = <_LayoutItem>[
      for (final line in valid)
        _LayoutItem(line: line, direction: detectLineDirection(line)),
    ];
    return [
      for (final region in _orderRegionsByXyCut(items))
        [for (final item in region) item.line],
    ];
  }

  /// 推断一组连续行的水平对齐方式（左对齐 / 居中 / 右对齐）。
  static TextAlign detectParagraphAlignment(
    List<OcrTextLine> lines, {
    required double regionLeft,
    required double regionRight,
  }) {
    if (lines.isEmpty) return TextAlign.left;
    final avgH =
        lines.fold<double>(0, (s, l) => s + l.bounds.height) / lines.length;
    if (lines.length == 1) {
      final b = lines.first.bounds;
      final regionW = regionRight - regionLeft;
      if (regionW > b.width + avgH * 2.5) {
        final leftMargin = b.left - regionLeft;
        final rightMargin = regionRight - b.right;
        if ((leftMargin - rightMargin).abs() <= math.max(avgH * 0.9, regionW * 0.08) &&
            leftMargin > avgH * 1.2) {
          return TextAlign.center;
        }
        if (leftMargin > avgH * 2.5 && rightMargin <= avgH * 0.9) {
          return TextAlign.right;
        }
      }
      return TextAlign.left;
    }

    var leftSpread = 0.0;
    var centerSpread = 0.0;
    var rightSpread = 0.0;
    final refLeft = lines.first.bounds.left;
    final refCenter = lines.first.bounds.center.dx;
    final refRight = lines.first.bounds.right;
    // 若首行有明显中文缩进，左对齐离散度以第 2..N 行为准。
    final hasFirstIndent =
        lines.length >= 2 &&
        (lines[0].bounds.left - lines[1].bounds.left) > avgH * 1.0 &&
        (lines[0].bounds.left - lines[1].bounds.left) <= avgH * 3.4;
    if (hasFirstIndent) return TextAlign.left;

    for (var i = 1; i < lines.length; i++) {
      leftSpread = math.max(leftSpread, (lines[i].bounds.left - refLeft).abs());
      centerSpread = math.max(
        centerSpread,
        (lines[i].bounds.center.dx - refCenter).abs(),
      );
      rightSpread = math.max(
        rightSpread,
        (lines[i].bounds.right - refRight).abs(),
      );
    }
    if (leftSpread <= avgH * 0.85) return TextAlign.left;
    if (centerSpread <= avgH * 0.85 && centerSpread < leftSpread * 0.65) {
      return TextAlign.center;
    }
    if (rightSpread <= avgH * 0.85 && rightSpread < leftSpread * 0.65) {
      return TextAlign.right;
    }
    return TextAlign.left;
  }

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
        final prevLineIdx = glyphs[i - 1].lineIndex;
        final joiner = joins[prevLineIdx];
        out.write(joiner);
        prevCodeUnit = joiner.isEmpty
            ? prevCodeUnit
            : joiner.codeUnitAt(joiner.length - 1);
      }
      // 若当前字符是软换行连字符（下一字符属于合并后的下一行），在连词时自动去掉 `-`。
      if (i < end &&
          glyph.text == '-' &&
          stripHyphenAfterLine[glyph.lineIndex] &&
          glyphs[i + 1].lineIndex != glyph.lineIndex) {
        continue;
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
    return _nearestGlyphInLine(bestLine, x, y);
  }

  /// 拖动手柄时使用：无论手指拖到画面何处，总能找到最合理的最近字符。
  int? nearestGlyph(double x, double y) {
    if (lines.isEmpty || glyphs.isEmpty) return null;
    var bestLine = 0;
    var bestScore = double.infinity;
    for (var i = 0; i < lines.length; i++) {
      final b = lines[i].bounds;
      final isVert = lineDirections[i] == OcrTextDirection.vertical;
      final double score;
      if (isVert) {
        final dx = (b.center.dx - x).abs();
        final dy = math.max(0.0, math.max(b.top - y, y - b.bottom));
        score = dx + dy * 0.25;
      } else {
        final dy = (b.center.dy - y).abs();
        final dx = math.max(0.0, math.max(b.left - x, x - b.right));
        score = dy + dx * 0.25;
      }
      if (score < bestScore) {
        bestScore = score;
        bestLine = i;
      }
    }
    return _nearestGlyphInLine(bestLine, x, y);
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

  int? _nearestGlyphInLine(int lineIndex, double x, double y) {
    final isVert = lineDirections[lineIndex] == OcrTextDirection.vertical;
    int? best;
    var bestDist = double.infinity;
    for (var i = 0; i < glyphs.length; i++) {
      if (glyphs[i].lineIndex != lineIndex) continue;
      final dist = isVert
          ? (glyphs[i].centerY - y).abs()
          : (glyphs[i].centerX - x).abs();
      if (dist < bestDist) {
        bestDist = dist;
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

  static bool _sharesColumn(OcrTextLine a, OcrTextLine b) {
    final overlap =
        math.min(a.bounds.right, b.bounds.right) -
        math.max(a.bounds.left, b.bounds.left);
    final minW = math.min(a.bounds.width, b.bounds.width);
    return minW > 0 && overlap >= 0.5 * minW;
  }

  // ---------------------------------------------------------------------------
  // 递归 XY-Cut 区域划分与阅读顺序排序
  // ---------------------------------------------------------------------------

  static List<List<_LayoutItem>> _orderRegionsByXyCut(List<_LayoutItem> items) {
    if (items.length <= 1) return [items];

    final sizes = [
      for (final item in items)
        item.direction == OcrTextDirection.vertical
            ? item.bounds.width
            : item.bounds.height,
    ]..sort();
    final medianSize = math.max(8.0, sizes[sizes.length ~/ 2]);

    List<List<_LayoutItem>> recurse(List<_LayoutItem> subset, int depth) {
      if (subset.length <= 1 || depth >= 8) {
        return [_orderLeafRegion(subset)];
      }

      // 1. 优先尝试水平切分（将顶部标题、横幅、独立上下块分开，避免跨栏标题挡住下方分栏）。
      final ySplit = _findBestHorizontalCut(subset, medianSize);
      if (ySplit != null) {
        return [
          ...recurse(ySplit.first, depth + 1),
          ...recurse(ySplit.second, depth + 1),
        ];
      }

      // 2. 尝试垂直分栏切分（双栏文章、侧边栏+正文、左右聊天气泡）。
      final xSplit = _findBestVerticalCut(subset, medianSize);
      if (xSplit != null) {
        final isPredominantlyVertical =
            subset.where((e) => e.direction == OcrTextDirection.vertical).length >
            subset.length / 2;
        if (isPredominantlyVertical) {
          // 竖排区域按传统从右到左阅读列顺序。
          return [
            ...recurse(xSplit.second, depth + 1),
            ...recurse(xSplit.first, depth + 1),
          ];
        }
        return [
          ...recurse(xSplit.first, depth + 1),
          ...recurse(xSplit.second, depth + 1),
        ];
      }

      return [_orderLeafRegion(subset)];
    }

    return recurse(items, 0);
  }

  static ({List<_LayoutItem> first, List<_LayoutItem> second})?
  _findBestHorizontalCut(List<_LayoutItem> items, double medianSize) {
    if (items.length < 2) return null;
    final sorted = List<_LayoutItem>.of(items)
      ..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));

    var maxBottom = sorted.first.bounds.bottom;
    var bestGap = 0.0;
    var bestCutY = 0.0;

    for (var i = 1; i < sorted.length; i++) {
      final top = sorted[i].bounds.top;
      final gap = top - maxBottom;
      if (gap > bestGap) {
        bestGap = gap;
        bestCutY = (maxBottom + top) / 2;
      }
      if (sorted[i].bounds.bottom > maxBottom) {
        maxBottom = sorted[i].bounds.bottom;
      }
    }

    final threshold = math.max(medianSize * 1.45, 16.0);
    if (bestGap < threshold) return null;

    final topGroup = <_LayoutItem>[];
    final bottomGroup = <_LayoutItem>[];
    for (final item in items) {
      if (item.bounds.center.dy < bestCutY) {
        topGroup.add(item);
      } else {
        bottomGroup.add(item);
      }
    }
    if (topGroup.isEmpty || bottomGroup.isEmpty) return null;
    return (first: topGroup, second: bottomGroup);
  }

  static ({List<_LayoutItem> first, List<_LayoutItem> second})?
  _findBestVerticalCut(List<_LayoutItem> items, double medianSize) {
    if (items.length < 3) return null;
    final sorted = List<_LayoutItem>.of(items)
      ..sort((a, b) => a.bounds.left.compareTo(b.bounds.left));

    var maxRight = sorted.first.bounds.right;
    var bestGap = 0.0;
    var bestCutX = 0.0;

    for (var i = 1; i < sorted.length; i++) {
      final left = sorted[i].bounds.left;
      final gap = left - maxRight;
      if (gap > bestGap) {
        bestGap = gap;
        bestCutX = (maxRight + left) / 2;
      }
      if (sorted[i].bounds.right > maxRight) {
        maxRight = sorted[i].bounds.right;
      }
    }

    final minGap = math.max(medianSize * 1.6, 28.0);
    if (bestGap < minGap) return null;

    final leftGroup = <_LayoutItem>[];
    final rightGroup = <_LayoutItem>[];
    for (final item in items) {
      if (item.bounds.center.dx < bestCutX) {
        leftGroup.add(item);
      } else {
        rightGroup.add(item);
      }
    }
    if (leftGroup.isEmpty || rightGroup.isEmpty) return null;

    // 两侧均需存在垂直堆叠的多行才视为真多栏（避免单行导航或仅一侧有单个孤立字段/值时被拆成两栏）。
    final leftStacked = _countVisualRows(leftGroup);
    final rightStacked = _countVisualRows(rightGroup);
    if (math.min(leftStacked, rightStacked) < 2) return null;

    // 保护紧凑双列表格 / 带徽章菜单（例如左侧选项 + 右侧标签且间距偏小且严格 1:1 对齐）：
    // 这类结构应保持逐行阅读，不强行拆成两栏。
    if (bestGap < medianSize * 2.5 &&
        _looksLikePairedTable(leftGroup, rightGroup)) {
      return null;
    }

    return (first: leftGroup, second: rightGroup);
  }

  static int _countVisualRows(List<_LayoutItem> items) {
    if (items.isEmpty) return 0;
    final sorted = List<_LayoutItem>.of(items)
      ..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
    var rows = 1;
    var anchor = sorted.first.line;
    for (var i = 1; i < sorted.length; i++) {
      if (!_sharesRow(anchor, sorted[i].line)) {
        rows++;
        anchor = sorted[i].line;
      }
    }
    return rows;
  }

  static bool _looksLikePairedTable(
    List<_LayoutItem> left,
    List<_LayoutItem> right,
  ) {
    final smaller = left.length <= right.length ? left : right;
    final larger = identical(smaller, left) ? right : left;
    if (smaller.isEmpty) return false;
    var paired = 0;
    for (final item in smaller) {
      if (larger.any((other) => _sharesRow(item.line, other.line))) {
        paired++;
      }
    }
    return paired == smaller.length && left.length == right.length;
  }

  static List<_LayoutItem> _orderLeafRegion(List<_LayoutItem> input) {
    if (input.length <= 1) return List<_LayoutItem>.of(input);
    final verticalCount = input
        .where((e) => e.direction == OcrTextDirection.vertical)
        .length;
    if (verticalCount > input.length / 2) {
      // 竖排区域：按列分组，列从右到左，列内从上到下。
      final sorted = List<_LayoutItem>.of(input)
        ..sort((a, b) => b.bounds.right.compareTo(a.bounds.right));
      final cols = <List<_LayoutItem>>[];
      for (final item in sorted) {
        if (cols.isNotEmpty &&
            cols.last.any((other) => _sharesColumn(other.line, item.line))) {
          cols.last.add(item);
        } else {
          cols.add([item]);
        }
      }
      final ordered = <_LayoutItem>[];
      for (final col in cols) {
        col.sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
        ordered.addAll(col);
      }
      return ordered;
    }

    final sorted = List<_LayoutItem>.of(input)
      ..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
    final rows = <List<_LayoutItem>>[];
    for (final item in sorted) {
      if (rows.isNotEmpty &&
          rows.last.any((other) => _sharesRow(other.line, item.line))) {
        rows.last.add(item);
      } else {
        rows.add([item]);
      }
    }
    final ordered = <_LayoutItem>[];
    for (final row in rows) {
      row.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
      ordered.addAll(row);
    }
    return ordered;
  }

  // ---------------------------------------------------------------------------
  // 智能段落判定与行间连接
  // ---------------------------------------------------------------------------

  static final _listStartPattern = RegExp(
    r'^(?:[•·▪▸►◆◇●○\-–—\*]\s+|\d{1,3}[.)、．]\s*|[(（][0-9a-zA-Z一二三四五六七八九十]+[)）]\s*|[一二三四五六七八九十]+、\s*|#{1,6}\s+)',
  );
  static final _terminalPunctPattern = RegExp(r'[。！？.!?…]$');

  static ({bool sameParagraph, String joiner, bool stripTrailingHyphen})
  _decideLineJoin({
    required OcrTextLine prev,
    required OcrTextLine next,
    required OcrTextLine paragraphFirst,
    required OcrTextDirection direction,
    required Rect regionRect,
  }) {
    if (direction == OcrTextDirection.vertical) {
      // 竖排：同一列上下接续，或紧邻左侧下一列继续同一段落。
      if (_sharesColumn(prev, next)) {
        return (sameParagraph: true, joiner: '', stripTrailingHyphen: false);
      }
      final minW = math.min(prev.bounds.width, next.bounds.width);
      final hGap = prev.bounds.left - next.bounds.right;
      final topAligned = (next.bounds.top - prev.bounds.top).abs() <= minW * 1.5;
      if (hGap >= -minW * 0.25 && hGap <= minW * 1.1 && topAligned) {
        return (sameParagraph: true, joiner: '', stripTrailingHyphen: false);
      }
      return (sameParagraph: false, joiner: '\n', stripTrailingHyphen: false);
    }

    if (_sharesRow(prev, next)) {
      return (sameParagraph: true, joiner: ' ', stripTrailingHyphen: false);
    }

    final minH = math.min(prev.bounds.height, next.bounds.height);
    if (minH <= 0) {
      return (sameParagraph: false, joiner: '\n', stripTrailingHyphen: false);
    }

    final verticalGap = next.bounds.top - prev.bounds.bottom;
    if (verticalGap < -minH * 0.25 ||
        verticalGap > minH * 0.85 ||
        next.bounds.top < prev.bounds.top) {
      return (sameParagraph: false, joiner: '\n', stripTrailingHyphen: false);
    }

    // 标题与正文字号差异较大时不合并。
    final heightRatio = prev.bounds.height / next.bounds.height;
    if (heightRatio < 0.72 || heightRatio > 1.38) {
      return (sameParagraph: false, joiner: '\n', stripTrailingHyphen: false);
    }

    final prevTrim = prev.text.trimRight();
    final nextTrim = next.text.trimLeft();
    if (prevTrim.isEmpty || nextTrim.isEmpty) {
      return (sameParagraph: false, joiner: '\n', stripTrailingHyphen: false);
    }

    // 列表项 / 编号项 / Markdown 标题行独立成段。
    if (_listStartPattern.hasMatch(nextTrim)) {
      return (sameParagraph: false, joiner: '\n', stripTrailingHyphen: false);
    }

    // 上一行以句末标点结尾且右侧显著留白，说明上一段已自然结束。
    final refRight = math.max(
      regionRect.right,
      math.max(paragraphFirst.bounds.right, next.bounds.right),
    );
    if (_terminalPunctPattern.hasMatch(prevTrim) &&
        prev.bounds.right < refRight - minH * 2.2 &&
        prev.bounds.width < (refRight - regionRect.left) * 0.82) {
      return (sameParagraph: false, joiner: '\n', stripTrailingHyphen: false);
    }

    // 检查水平对齐与中文首行缩进：
    final leftDiff = (next.bounds.left - prev.bounds.left).abs();
    final isLeftAligned = leftDiff <= minH * 1.1;

    // 经典中文段首缩进（首行比次行缩进 1~3.4 倍字高，且右侧延伸到段宽大部分）。
    final firstIndent = prev.bounds.left - next.bounds.left;
    final isFirstLineIndent =
        identical(prev, paragraphFirst) &&
        firstIndent > minH * 1.0 &&
        firstIndent <= minH * 3.4 &&
        prev.bounds.right >= next.bounds.left + next.bounds.width * 0.5;

    // 居中或右对齐多行段落。
    final isCentered =
        (prev.bounds.center.dx - next.bounds.center.dx).abs() <= minH * 0.85 &&
        prev.bounds.right > next.bounds.left &&
        next.bounds.right > prev.bounds.left;
    final isRightAligned =
        (prev.bounds.right - next.bounds.right).abs() <= minH * 0.85 &&
        prev.bounds.right > next.bounds.left &&
        next.bounds.right > prev.bounds.left;

    if (!isLeftAligned && !isFirstLineIndent && !isCentered && !isRightAligned) {
      return (sameParagraph: false, joiner: '\n', stripTrailingHyphen: false);
    }

    // 英文软换行连字符修复（如 `implemen-` + `tation` → `implementation`）。
    if (prevTrim.length >= 2 &&
        prevTrim.endsWith('-') &&
        !prevTrim.endsWith('--') &&
        _isAsciiAlpha(prevTrim.codeUnitAt(prevTrim.length - 2)) &&
        _isAsciiLower(nextTrim.codeUnitAt(0))) {
      return (sameParagraph: true, joiner: '', stripTrailingHyphen: true);
    }

    final endUnit = prevTrim.codeUnitAt(prevTrim.length - 1);
    final startUnit = nextTrim.codeUnitAt(0);
    final joiner = _isLatin(endUnit) && _isLatin(startUnit) ? ' ' : '';
    return (sameParagraph: true, joiner: joiner, stripTrailingHyphen: false);
  }

  /// 基于 line2para 段落分组构建排版：
  /// - 保留模型判定的段落归属与段内行序；
  /// - 对段落块叠加递归 XY-Cut 分栏阅读顺序，避免双栏场景下按块中心 Y 误把短右栏排到长左栏前面；
  /// - 复用英文软连字符修复、中英自动间距与对齐推断。
  static PictureTextLayout? _buildFromParagraphGroups(
    OcrResult ocr,
    List<List<int>> rawGroups,
  ) {
    final total = ocr.lines.length;
    final seen = <int>{};
    final groups = <_ParagraphGroup>[];

    void addGroup(List<int> rawIndices) {
      final lines = <OcrTextLine>[];
      final dirs = <OcrTextDirection>[];
      for (final idx in rawIndices) {
        if (idx < 0 || idx >= total || !seen.add(idx)) continue;
        final line = ocr.lines[idx];
        if (line.text.trim().isEmpty) continue;
        lines.add(line);
        dirs.add(detectLineDirection(line));
      }
      if (lines.isEmpty) return;
      var bounds = lines.first.bounds;
      var verticalCount = 0;
      for (var i = 0; i < lines.length; i++) {
        bounds = bounds.expandToInclude(lines[i].bounds);
        if (dirs[i] == OcrTextDirection.vertical) verticalCount++;
      }
      final dir = verticalCount > lines.length / 2
          ? OcrTextDirection.vertical
          : OcrTextDirection.horizontal;
      groups.add(
        _ParagraphGroup(
          lines: lines,
          directions: dirs,
          direction: dir,
          bounds: bounds,
        ),
      );
    }

    for (final g in rawGroups) {
      addGroup(g);
    }
    if (groups.isEmpty) return null;
    // 兜底补齐未被分组引用的有效非空行。
    for (var i = 0; i < total; i++) {
      if (!seen.contains(i) && ocr.lines[i].text.trim().isNotEmpty) {
        addGroup([i]);
      }
    }

    final orderedRegions = _orderGroupsByXyCut(groups);
    final ordered = <OcrTextLine>[];
    final directions = <OcrTextDirection>[];
    final groupSpans = <({int start, int end, OcrTextDirection dir, Rect regionRect})>[];

    for (final region in orderedRegions) {
      if (region.isEmpty) continue;
      var regionRect = region.first.bounds;
      for (var i = 1; i < region.length; i++) {
        regionRect = regionRect.expandToInclude(region[i].bounds);
      }
      for (final group in region) {
        final start = ordered.length;
        ordered.addAll(group.lines);
        directions.addAll(group.directions);
        groupSpans.add((
          start: start,
          end: ordered.length - 1,
          dir: group.direction,
          regionRect: regionRect,
        ));
      }
    }

    final glyphs = <PictureGlyph>[];
    for (var lineIdx = 0; lineIdx < ordered.length; lineIdx++) {
      glyphs.addAll(_buildGlyphs(ordered[lineIdx], lineIdx, directions[lineIdx]));
    }

    final joins = List<String>.filled(
      math.max(0, ordered.length - 1),
      '\n',
    );
    final stripHyphen = List<bool>.filled(ordered.length, false);
    final paragraphs = <OcrParagraph>[];

    for (final span in groupSpans) {
      for (var i = span.start; i < span.end; i++) {
        final j = _decideIntraParagraphJoin(
          ordered[i],
          ordered[i + 1],
          span.dir,
        );
        joins[i] = j.joiner;
        stripHyphen[i] = j.stripTrailingHyphen;
      }
      if (span.end < joins.length) {
        joins[span.end] = '\n';
      }

      final paraLines = ordered.sublist(span.start, span.end + 1);
      final paraIndices = [for (var i = span.start; i <= span.end; i++) i];
      var paraBounds = paraLines.first.bounds;
      for (var i = 1; i < paraLines.length; i++) {
        paraBounds = paraBounds.expandToInclude(paraLines[i].bounds);
      }
      final alignment = detectParagraphAlignment(
        paraLines,
        regionLeft: span.regionRect.left,
        regionRight: span.regionRect.right,
      );
      final text = _composeLinesText(
        paraLines,
        joins,
        stripHyphen,
        span.start,
      );
      paragraphs.add(
        OcrParagraph(
          lines: paraLines,
          lineIndices: paraIndices,
          bounds: paraBounds,
          direction: span.dir,
          alignment: alignment,
          text: text,
        ),
      );
    }

    return PictureTextLayout._(
      imageWidth: ocr.imageWidth,
      imageHeight: ocr.imageHeight,
      lines: ordered,
      lineDirections: directions,
      paragraphs: paragraphs,
      glyphs: glyphs,
      joins: joins,
      stripHyphenAfterLine: stripHyphen,
    );
  }

  static ({String joiner, bool stripTrailingHyphen}) _decideIntraParagraphJoin(
    OcrTextLine prev,
    OcrTextLine next,
    OcrTextDirection direction,
  ) {
    if (direction == OcrTextDirection.vertical) {
      return (joiner: '', stripTrailingHyphen: false);
    }
    if (_sharesRow(prev, next)) {
      return (joiner: ' ', stripTrailingHyphen: false);
    }
    final prevTrim = prev.text.trimRight();
    final nextTrim = next.text.trimLeft();
    if (prevTrim.isEmpty || nextTrim.isEmpty) {
      return (joiner: '', stripTrailingHyphen: false);
    }
    if (prevTrim.length >= 2 &&
        prevTrim.endsWith('-') &&
        !prevTrim.endsWith('--') &&
        _isAsciiAlpha(prevTrim.codeUnitAt(prevTrim.length - 2)) &&
        _isAsciiLower(nextTrim.codeUnitAt(0))) {
      return (joiner: '', stripTrailingHyphen: true);
    }
    final endUnit = prevTrim.codeUnitAt(prevTrim.length - 1);
    final startUnit = nextTrim.codeUnitAt(0);
    final joiner = _isLatin(endUnit) && _isLatin(startUnit) ? ' ' : '';
    return (joiner: joiner, stripTrailingHyphen: false);
  }

  static List<List<_ParagraphGroup>> _orderGroupsByXyCut(
    List<_ParagraphGroup> groups,
  ) {
    if (groups.length <= 1) return [groups];

    final sizes = <double>[
      for (final g in groups)
        for (var i = 0; i < g.lines.length; i++)
          g.directions[i] == OcrTextDirection.vertical
              ? g.lines[i].bounds.width
              : g.lines[i].bounds.height,
    ]..sort();
    final medianSize = sizes.isEmpty
        ? 16.0
        : math.max(8.0, sizes[sizes.length ~/ 2]);

    List<List<_ParagraphGroup>> recurse(
      List<_ParagraphGroup> subset,
      int depth,
    ) {
      if (subset.length <= 1 || depth >= 8) {
        return [_orderLeafGroups(subset)];
      }

      // 优先检查贯穿全高的垂直分栏切分：全宽标题/页脚会自然阻断垂直切分而先走水平切分，
      // 一旦进入多栏正文区则先分栏再排栏内各段，避免栏内段落空隙先触发水平切分。
      final xSplit = _findGroupVerticalCut(subset, medianSize);
      if (xSplit != null) {
        final isPredominantlyVertical =
            subset.where((e) => e.direction == OcrTextDirection.vertical).length >
            subset.length / 2;
        if (isPredominantlyVertical) {
          return [
            ...recurse(xSplit.second, depth + 1),
            ...recurse(xSplit.first, depth + 1),
          ];
        }
        return [
          ...recurse(xSplit.first, depth + 1),
          ...recurse(xSplit.second, depth + 1),
        ];
      }

      final ySplit = _findGroupHorizontalCut(subset, medianSize);
      if (ySplit != null) {
        return [
          ...recurse(ySplit.first, depth + 1),
          ...recurse(ySplit.second, depth + 1),
        ];
      }

      return [_orderLeafGroups(subset)];
    }

    return recurse(groups, 0);
  }

  static ({List<_ParagraphGroup> first, List<_ParagraphGroup> second})?
  _findGroupHorizontalCut(List<_ParagraphGroup> groups, double medianSize) {
    if (groups.length < 2) return null;
    final sorted = List<_ParagraphGroup>.of(groups)
      ..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
    var maxBottom = sorted.first.bounds.bottom;
    var bestGap = 0.0;
    var bestCutY = 0.0;
    for (var i = 1; i < sorted.length; i++) {
      final gap = sorted[i].bounds.top - maxBottom;
      if (gap > bestGap) {
        bestGap = gap;
        bestCutY = (maxBottom + sorted[i].bounds.top) / 2;
      }
      if (sorted[i].bounds.bottom > maxBottom) {
        maxBottom = sorted[i].bounds.bottom;
      }
    }
    final threshold = math.max(medianSize * 1.35, 14.0);
    if (bestGap < threshold) return null;
    final top = <_ParagraphGroup>[];
    final bottom = <_ParagraphGroup>[];
    for (final g in groups) {
      if (g.bounds.center.dy < bestCutY) {
        top.add(g);
      } else {
        bottom.add(g);
      }
    }
    if (top.isEmpty || bottom.isEmpty) return null;
    return (first: top, second: bottom);
  }

  static ({List<_ParagraphGroup> first, List<_ParagraphGroup> second})?
  _findGroupVerticalCut(List<_ParagraphGroup> groups, double medianSize) {
    if (groups.length < 2) return null;
    final sorted = List<_ParagraphGroup>.of(groups)
      ..sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
    var maxRight = sorted.first.bounds.right;
    var bestGap = 0.0;
    var bestCutX = 0.0;
    for (var i = 1; i < sorted.length; i++) {
      final gap = sorted[i].bounds.left - maxRight;
      if (gap > bestGap) {
        bestGap = gap;
        bestCutX = (maxRight + sorted[i].bounds.left) / 2;
      }
      if (sorted[i].bounds.right > maxRight) {
        maxRight = sorted[i].bounds.right;
      }
    }
    final minGap = math.max(medianSize * 1.4, 24.0);
    if (bestGap < minGap) return null;
    final left = <_ParagraphGroup>[];
    final right = <_ParagraphGroup>[];
    for (final g in groups) {
      if (g.bounds.center.dx < bestCutX) {
        left.add(g);
      } else {
        right.add(g);
      }
    }
    if (left.isEmpty || right.isEmpty) return null;

    final leftItems = <_LayoutItem>[
      for (final g in left)
        for (var i = 0; i < g.lines.length; i++)
          _LayoutItem(line: g.lines[i], direction: g.directions[i]),
    ];
    final rightItems = <_LayoutItem>[
      for (final g in right)
        for (var i = 0; i < g.lines.length; i++)
          _LayoutItem(line: g.lines[i], direction: g.directions[i]),
    ];
    if (math.min(_countVisualRows(leftItems), _countVisualRows(rightItems)) <
        2) {
      return null;
    }
    if (bestGap < medianSize * 2.5 &&
        _looksLikePairedTable(leftItems, rightItems)) {
      return null;
    }
    return (first: left, second: right);
  }

  static List<_ParagraphGroup> _orderLeafGroups(List<_ParagraphGroup> input) {
    if (input.length <= 1) return List<_ParagraphGroup>.of(input);
    final verticalCount = input
        .where((g) => g.direction == OcrTextDirection.vertical)
        .length;
    if (verticalCount > input.length / 2) {
      final sorted = List<_ParagraphGroup>.of(input)
        ..sort((a, b) {
          final dx = b.bounds.right.compareTo(a.bounds.right);
          return dx != 0 ? dx : a.bounds.top.compareTo(b.bounds.top);
        });
      return sorted;
    }
    final sorted = List<_ParagraphGroup>.of(input)
      ..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
    final rows = <List<_ParagraphGroup>>[];
    for (final g in sorted) {
      if (rows.isNotEmpty &&
          rows.last.any((other) {
            final ov =
                math.min(other.bounds.bottom, g.bounds.bottom) -
                math.max(other.bounds.top, g.bounds.top);
            final minH = math.min(other.bounds.height, g.bounds.height);
            return minH > 0 && ov >= 0.5 * minH;
          })) {
        rows.last.add(g);
      } else {
        rows.add([g]);
      }
    }
    final ordered = <_ParagraphGroup>[];
    for (final row in rows) {
      row.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
      ordered.addAll(row);
    }
    return ordered;
  }

  static String _composeLinesText(
    List<OcrTextLine> paraLines,
    List<String> joins,
    List<bool> stripHyphen,
    int baseIndex,
  ) {
    final out = StringBuffer();
    int? prevCodeUnit;
    for (var i = 0; i < paraLines.length; i++) {
      var text = paraLines[i].text.trim();
      if (text.isEmpty) continue;
      if (i > 0) {
        final joiner = joins[baseIndex + i - 1];
        out.write(joiner);
        prevCodeUnit = joiner.isEmpty
            ? prevCodeUnit
            : joiner.codeUnitAt(joiner.length - 1);
      }
      if (i + 1 < paraLines.length &&
          stripHyphen[baseIndex + i] &&
          text.endsWith('-')) {
        text = text.substring(0, text.length - 1);
      }
      for (var c = 0; c < text.length; c++) {
        final unit = text.codeUnitAt(c);
        if (prevCodeUnit != null &&
            ((_isHanOrKana(prevCodeUnit) && _isAsciiWord(unit)) ||
                (_isAsciiWord(prevCodeUnit) && _isHanOrKana(unit)))) {
          out.write(' ');
        }
        out.writeCharCode(unit);
        prevCodeUnit = unit;
      }
    }
    return out.toString();
  }

  static List<PictureGlyph> _buildGlyphs(
    OcrTextLine line,
    int lineIndex,
    OcrTextDirection direction,
  ) {
    final text = line.text;
    final len = text.length;
    if (len == 0) return const [];
    final bounds = line.bounds;
    final hasExact = line.charBounds.length == len;

    if (direction == OcrTextDirection.vertical) {
      final raw = hasExact
          ? line.charBounds
          : [
              for (var i = 0; i < len; i++)
                Rect.fromLTRB(
                  bounds.left,
                  bounds.top + bounds.height * (i / len),
                  bounds.right,
                  bounds.top + bounds.height * ((i + 1) / len),
                ),
            ];
      return [
        for (var i = 0; i < len; i++)
          PictureGlyph(
            text: text[i],
            lineIndex: lineIndex,
            bounds: Rect.fromLTRB(
              bounds.left,
              i == 0 ? bounds.top : (raw[i - 1].bottom + raw[i].top) / 2,
              bounds.right,
              math.max(
                i == 0 ? bounds.top : (raw[i - 1].bottom + raw[i].top) / 2,
                i == len - 1
                    ? bounds.bottom
                    : (raw[i].bottom + raw[i + 1].top) / 2,
              ),
            ),
          ),
      ];
    }

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

  static bool _isAsciiAlpha(int u) =>
      (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A);

  static bool _isAsciiLower(int u) => u >= 0x61 && u <= 0x7A;

  static bool _isAsciiWord(int u) =>
      (u >= 0x30 && u <= 0x39) || _isAsciiAlpha(u);

  static bool _isLatin(int u) =>
      u < 0x2E80 && (_isAsciiWord(u) || ',.;:!?)'.codeUnits.contains(u));
}

class _LayoutItem {
  const _LayoutItem({required this.line, required this.direction});

  final OcrTextLine line;
  final OcrTextDirection direction;

  Rect get bounds => line.bounds;
}

class _ParagraphGroup {
  const _ParagraphGroup({
    required this.lines,
    required this.directions,
    required this.direction,
    required this.bounds,
  });

  final List<OcrTextLine> lines;
  final List<OcrTextDirection> directions;
  final OcrTextDirection direction;
  final Rect bounds;
}
