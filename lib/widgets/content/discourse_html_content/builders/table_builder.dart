import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../l10n/s.dart';
import '../discourse_html_content_widget.dart';
import 'scan_boundary.dart';

/// 行虚拟化阈值：超过此行数启用 ListView.builder
const _kVirtualizeThreshold = 30;

/// 列宽采样行数：用表头 + 前 N 行来预计算列宽
const _kSampleRows = 10;

/// 列宽范围
const _kMinColumnWidth = 60.0;
const _kMaxColumnWidth = 200.0;

/// 单元格内边距
const _kCellPadding = EdgeInsets.all(8);

/// 估算行高（padding*2 + 单行文本高度）
const _kEstimatedRowHeight = 44.0;

/// 检测 HTML 标签的正则
final _htmlTagRegExp = RegExp(r'<[a-zA-Z]');

/// 构建自定义 table widget
Widget? buildTable({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
  List<String>? galleryImages,
  bool screenshotMode = false,
}) {
  // 解析 table 结构
  final rows = <List<_TableCellData>>[];

  final theadElements = element.getElementsByTagName('thead');
  final tbodyElements = element.getElementsByTagName('tbody');
  final directTrElements = element.getElementsByTagName('tr');

  // 解析 thead
  if (theadElements.isNotEmpty) {
    final thead = theadElements.first;
    for (final tr in thead.getElementsByTagName('tr')) {
      rows.add(_parseRow(tr, isHeader: true));
    }
  }

  // 解析 tbody
  if (tbodyElements.isNotEmpty) {
    final tbody = tbodyElements.first;
    for (final tr in tbody.getElementsByTagName('tr')) {
      rows.add(_parseRow(tr, isHeader: false));
    }
  } else if (theadElements.isEmpty) {
    for (final tr in directTrElements) {
      rows.add(_parseRow(tr, isHeader: false));
    }
  }

  if (rows.isEmpty) return null;

  final columnCount =
      rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
  if (columnCount == 0) return null;

  // 截图模式保持原有逻辑（需要完整渲染不裁剪）
  if (screenshotMode) {
    return _buildScreenshotTable(
      context: context,
      theme: theme,
      rows: rows,
      columnCount: columnCount,
      galleryImages: galleryImages,
    );
  }

  // 预计算固定列宽
  final columnWidths = _computeColumnWidths(rows, columnCount, theme);

  // 分离表头和数据行
  List<_TableCellData>? headerRow;
  List<List<_TableCellData>> bodyRows;
  if (rows.isNotEmpty && rows.first.any((c) => c.isHeader)) {
    headerRow = rows.first;
    bodyRows = rows.sublist(1);
  } else {
    bodyRows = rows;
  }

  final borderColor = theme.colorScheme.outlineVariant;
  final totalWidth =
      columnWidths.fold<double>(0, (sum, w) => sum + w) +
      (columnCount - 1); // 列间分隔线 1px
  final totalRowCount = rows.length;

  // 构建数据行区域
  Widget bodyWidget;
  if (bodyRows.length > _kVirtualizeThreshold) {
    // 大表格：行虚拟化
    final maxHeight =
        MediaQuery.of(context).size.height * 0.5;
    final estimatedHeight = bodyRows.length * _kEstimatedRowHeight;
    bodyWidget = SizedBox(
      height: math.min(estimatedHeight, maxHeight),
      child: ListView.builder(
        itemCount: bodyRows.length,
        itemExtent: _kEstimatedRowHeight,
        itemBuilder: (ctx, index) {
          return _buildFixedRow(
            context: ctx,
            theme: theme,
            row: bodyRows[index],
            columnCount: columnCount,
            columnWidths: columnWidths,
            borderColor: borderColor,
            galleryImages: galleryImages,
          );
        },
      ),
    );
  } else {
    // 小表格：一次性构建
    bodyWidget = Column(
      mainAxisSize: MainAxisSize.min,
      children: bodyRows
          .map(
            (row) => _buildFixedRow(
              context: context,
              theme: theme,
              row: row,
              columnCount: columnCount,
              columnWidths: columnWidths,
              borderColor: borderColor,
              galleryImages: galleryImages,
            ),
          )
          .toList(),
    );
  }

  // 组装表格
  final tableContent = Container(
    margin: const EdgeInsets.symmetric(vertical: 8),
    width: totalWidth,
    decoration: BoxDecoration(
      border: Border.all(color: borderColor, width: 1),
      borderRadius: BorderRadius.circular(8),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 表头
          if (headerRow != null)
            _buildFixedRow(
              context: context,
              theme: theme,
              row: headerRow,
              columnCount: columnCount,
              columnWidths: columnWidths,
              borderColor: borderColor,
              galleryImages: galleryImages,
              isHeader: true,
            ),
          // 数据行
          bodyWidget,
          // 大表格显示行数提示
          if (bodyRows.length > _kVirtualizeThreshold)
            _buildInfoBar(
              context: context,
              theme: theme,
              totalRowCount: totalRowCount,
              borderColor: borderColor,
            ),
        ],
      ),
    ),
  );

  return ScanBoundary(
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: tableContent,
    ),
  );
}

/// 截图模式：保持原有逻辑，不限制宽度，用 FittedBox 缩放
Widget _buildScreenshotTable({
  required BuildContext context,
  required ThemeData theme,
  required List<List<_TableCellData>> rows,
  required int columnCount,
  List<String>? galleryImages,
}) {
  final tableWidget = Container(
    margin: const EdgeInsets.symmetric(vertical: 8),
    decoration: BoxDecoration(
      border: Border.all(
        color: theme.colorScheme.outlineVariant,
        width: 1,
      ),
      borderRadius: BorderRadius.circular(8),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder(
          horizontalInside: BorderSide(
            color: theme.colorScheme.outlineVariant,
            width: 1,
          ),
          verticalInside: BorderSide(
            color: theme.colorScheme.outlineVariant,
            width: 1,
          ),
        ),
        children: rows.asMap().entries.map((entry) {
          final rowIndex = entry.key;
          final row = entry.value;
          final isFirstRow = rowIndex == 0;

          return TableRow(
            decoration: isFirstRow && row.any((c) => c.isHeader)
                ? BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                  )
                : null,
            children: List.generate(columnCount, (colIndex) {
              if (colIndex < row.length) {
                return _buildRichCell(
                  context,
                  theme,
                  row[colIndex],
                  galleryImages,
                  screenshotMode: true,
                );
              }
              return const SizedBox.shrink();
            }),
          );
        }).toList(),
      ),
    ),
  );

  return ScanBoundary(
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: tableWidget,
    ),
  );
}

/// 预计算列宽：基于表头 + 前 N 行的文本内容
List<double> _computeColumnWidths(
  List<List<_TableCellData>> rows,
  int columnCount,
  ThemeData theme,
) {
  final widths = List<double>.filled(columnCount, _kMinColumnWidth);
  final sampleCount = math.min(rows.length, _kSampleRows + 1);
  final baseStyle = theme.textTheme.bodyMedium ?? const TextStyle(fontSize: 14);

  for (int i = 0; i < sampleCount; i++) {
    final row = rows[i];
    for (int col = 0; col < math.min(row.length, columnCount); col++) {
      final text = row[col].element.text?.trim() ?? '';
      if (text.isEmpty) continue;

      final style = row[col].isHeader
          ? baseStyle.copyWith(fontWeight: FontWeight.w600)
          : baseStyle;

      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();

      final measuredWidth = painter.width + _kCellPadding.horizontal;
      widths[col] = math.max(widths[col], measuredWidth);
      painter.dispose();
    }
  }

  // Clamp 列宽
  for (int i = 0; i < columnCount; i++) {
    widths[i] = widths[i].clamp(_kMinColumnWidth, _kMaxColumnWidth);
  }

  return widths;
}

/// 构建固定宽度的表格行
Widget _buildFixedRow({
  required BuildContext context,
  required ThemeData theme,
  required List<_TableCellData> row,
  required int columnCount,
  required List<double> columnWidths,
  required Color borderColor,
  List<String>? galleryImages,
  bool isHeader = false,
}) {
  return Container(
    decoration: BoxDecoration(
      color: isHeader ? theme.colorScheme.surfaceContainerHighest : null,
      border: Border(
        bottom: BorderSide(color: borderColor, width: 1),
      ),
    ),
    child: Row(
      children: List.generate(columnCount, (colIndex) {
        final cell = colIndex < row.length ? row[colIndex] : null;
        return Container(
          width: columnWidths[colIndex],
          decoration: colIndex > 0
              ? BoxDecoration(
                  border: Border(
                    left: BorderSide(color: borderColor, width: 1),
                  ),
                )
              : null,
          padding: _kCellPadding,
          child: cell != null
              ? _buildCellContent(
                  context, theme, cell, galleryImages,
                )
              : const SizedBox.shrink(),
        );
      }),
    ),
  );
}

/// 构建单元格内容：纯文本走快速路径，含 HTML 走完整渲染
Widget _buildCellContent(
  BuildContext context,
  ThemeData theme,
  _TableCellData cellData,
  List<String>? galleryImages,
) {
  final innerHtml = cellData.element.innerHtml ?? '';

  // 纯文本快速路径
  if (!_htmlTagRegExp.hasMatch(innerHtml)) {
    final text = cellData.element.text?.trim() ?? '';
    return Text(
      text,
      style: cellData.isHeader
          ? const TextStyle(fontWeight: FontWeight.w600)
          : null,
    );
  }

  // 含 HTML 标签：走完整渲染管线
  return DiscourseHtmlContent(
    html: innerHtml,
    compact: true,
    galleryImages: galleryImages,
  );
}

/// 截图模式下的富文本单元格（保持原有行为）
Widget _buildRichCell(
  BuildContext context,
  ThemeData theme,
  _TableCellData cellData,
  List<String>? galleryImages, {
  bool screenshotMode = false,
}) {
  final innerHtml = cellData.element.innerHtml ?? '';
  return Padding(
    padding: _kCellPadding,
    child: DiscourseHtmlContent(
      html: innerHtml,
      compact: true,
      galleryImages: galleryImages,
      screenshotMode: screenshotMode,
    ),
  );
}

/// 表格底部行数信息栏
Widget _buildInfoBar({
  required BuildContext context,
  required ThemeData theme,
  required int totalRowCount,
  required Color borderColor,
}) {
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
    ),
    child: Text(
      context.l10n.table_rowCount(totalRowCount),
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
      textAlign: TextAlign.center,
    ),
  );
}

/// 解析表格行
List<_TableCellData> _parseRow(dynamic tr, {required bool isHeader}) {
  final cells = <_TableCellData>[];
  for (final child in tr.children) {
    if (child.localName == 'th' || child.localName == 'td') {
      cells.add(_TableCellData(
        element: child,
        isHeader: child.localName == 'th' || isHeader,
      ));
    }
  }
  return cells;
}

/// 表格单元格数据
class _TableCellData {
  final dynamic element;
  final bool isHeader;

  _TableCellData({
    required this.element,
    required this.isHeader,
  });
}
