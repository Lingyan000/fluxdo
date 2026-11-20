import 'dart:math' as math;

import 'package:app_icons/app_icons.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart' show NumberFormat;
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../models/topic.dart';
import '../../../services/discourse/discourse_service.dart';
import '../../../utils/number_utils.dart';
import '../../../utils/time_utils.dart';
import '../../../widgets/common/app_bottom_sheet.dart';

/// 打开话题浏览量弹层：总浏览量 + 近 30 天每日浏览趋势。
Future<void> showTopicViewStatsSheet(
  BuildContext context, {
  required int topicId,
  required int totalViews,
}) {
  return AppBottomSheet.show(
    context: context,
    title: context.l10n.topicDetail_viewStatsTitle,
    builder: (_) => TopicViewStats(
      load: () => DiscourseService().getTopicViewStats(topicId),
      totalViews: totalViews,
    ),
  );
}

class TopicViewStats extends StatefulWidget {
  const TopicViewStats({
    super.key,
    required this.load,
    required this.totalViews,
  });

  final Future<List<TopicViewStat>> Function() load;
  final int totalViews;

  @override
  State<TopicViewStats> createState() => _TopicViewStatsState();
}

class _TopicViewStatsState extends State<TopicViewStats> {
  /// 少于这么多天时折线没有意义，改为逐日列出
  static const _minChartDays = 3;

  late Future<List<TopicViewStat>> _future = widget.load();

  /// 补齐没有浏览的日子；没有任何记录时以今天承载总浏览量
  List<TopicViewStat> _normalize(List<TopicViewStat> raw) {
    if (raw.isEmpty) {
      final today = _serverToday();
      return [TopicViewStat(day: today, views: widget.totalViews)];
    }
    final sorted = [...raw]..sort((a, b) => a.day.compareTo(b.day));
    final filled = <TopicViewStat>[];
    for (final stat in sorted) {
      if (filled.isNotEmpty) {
        var day = _nextDay(filled.last.day);
        while (day.isBefore(stat.day)) {
          filled.add(TopicViewStat(day: day, views: 0));
          day = _nextDay(day);
        }
      }
      filled.add(stat);
    }
    return filled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;
    return FutureBuilder<List<TopicViewStat>>(
      future: _future,
      builder: (context, snapshot) {
        final Widget body;
        if (snapshot.connectionState != ConnectionState.done) {
          body = const SizedBox(
            height: 200,
            child: Center(child: LoadingSpinner()),
          );
        } else if (snapshot.hasError) {
          body = SizedBox(
            height: 200,
            child: Center(
              child: TextButton.icon(
                icon: const Icon(Symbols.refresh_rounded),
                label: Text(l10n.common_loadFailedTapRetry),
                onPressed: () => setState(() => _future = widget.load()),
              ),
            ),
          );
        } else {
          final stats = _normalize(snapshot.data ?? const []);
          body = stats.length >= _minChartDays
              ? _ViewsChart(stats: stats)
              : _DailyViewList(stats: stats);
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              NumberFormat.decimalPattern(
                Localizations.localeOf(context).toLanguageTag(),
              ).format(widget.totalViews),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              l10n.topicDetail_totalViewsLabel,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            body,
            const SizedBox(height: 12),
            Text(
              l10n.topicDetail_viewExplainer,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 服务端按 UTC 日期汇总浏览量，「今天」也以 UTC 日期为准
DateTime _serverToday() {
  final now = DateTime.now().toUtc();
  return DateTime(now.year, now.month, now.day);
}

DateTime _nextDay(DateTime day) => DateTime(day.year, day.month, day.day + 1);

/// 当天还没过完，数值只是目前为止的部分
bool _isPartialDay(TopicViewStat stat) => stat.day == _serverToday();

String _dayLabel(BuildContext context, TopicViewStat stat) =>
    _isPartialDay(stat)
    ? context.l10n.topicDetail_viewsTodaySoFar
    : TimeUtils.formatShortDate(stat.day);

/// 数据不足以画折线时逐日列出
class _DailyViewList extends StatelessWidget {
  const _DailyViewList({required this.stats});

  final List<TopicViewStat> stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        for (var i = 0; i < stats.length; i++)
          SegmentedCardItem(
            index: i,
            count: stats.length,
            gap: SegmentedCardItem.gapOf(context, 3),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _dayLabel(context, stats[i]),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  Text(
                    context.l10n.topicDetail_dailyViews(stats[i].views),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 每日浏览折线：点按或横向拖动选中某天，上方显示该日数值。
class _ViewsChart extends StatefulWidget {
  const _ViewsChart({required this.stats});

  final List<TopicViewStat> stats;

  @override
  State<_ViewsChart> createState() => _ViewsChartState();
}

class _ViewsChartState extends State<_ViewsChart> {
  static const double _chartHeight = 168;

  /// 用户选中的一天；未选中时上方显示最近一天，图上不画准线
  int? _selected;

  void _selectAt(double dx, double width) {
    final plot = _ChartGeometry.plotRect(Size(width, _chartHeight));
    final t = ((dx - plot.left) / plot.width).clamp(0.0, 1.0);
    final index = (t * (widget.stats.length - 1)).round();
    if (index != _selected) setState(() => _selected = index);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final stat = widget.stats[_selected ?? widget.stats.length - 1];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: context.l10n.topicDetail_dailyViews(stat.views),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const WidgetSpan(child: SizedBox(width: 8)),
              TextSpan(
                text: _dayLabel(context, stat),
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        // 固定高度而非 LayoutBuilder：弹层外壳会做固有尺寸测量
        SizedBox(
          height: _chartHeight,
          width: double.infinity,
          child: Builder(
            builder: (chartContext) {
              void select(Offset position) =>
                  _selectAt(position.dx, chartContext.size!.width);
              return MouseRegion(
                onHover: (event) => select(event.localPosition),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  dragStartBehavior: DragStartBehavior.down,
                  onTapDown: (d) => select(d.localPosition),
                  onHorizontalDragStart: (d) => select(d.localPosition),
                  onHorizontalDragUpdate: (d) => select(d.localPosition),
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _ViewsChartPainter(
                      stats: widget.stats,
                      selected: _selected,
                      partialLast: _isPartialDay(widget.stats.last),
                      lineColor: colorScheme.primary,
                      gridColor: colorScheme.outlineVariant,
                      ringColor: colorScheme.surface,
                      labelStyle: theme.textTheme.labelSmall!.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                      dayLabel: (stat) => TimeUtils.formatShortDate(stat.day),
                      textDirection: Directionality.of(context),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 绘图区与坐标标注的布局
abstract final class _ChartGeometry {
  /// 左侧 Y 轴刻度宽度
  static const double yAxisWidth = 36;

  /// 底部日期标注高度
  static const double xAxisHeight = 20;

  /// 顶部留白，避免最高点与选中圆点被裁
  static const double topInset = 6;

  /// 右侧留白，末端圆点不贴边
  static const double rightInset = 6;

  static Rect plotRect(Size size) => Rect.fromLTRB(
    yAxisWidth,
    topInset,
    size.width - rightInset,
    size.height - xAxisHeight,
  );

  /// 不小于 [value] 的整齐上限，且为偶数，中间刻度也是整数
  static int niceCeil(int value) {
    if (value <= 2) return 2;
    final magnitude = math.pow(10, (math.log(value) / math.ln10).floor());
    for (final step in const [1, 1.5, 2, 3, 4, 5, 6, 8, 10]) {
      final candidate = (step * magnitude).round();
      if (candidate >= value && candidate.isEven) return candidate;
    }
    return (10 * magnitude).round();
  }
}

class _ViewsChartPainter extends CustomPainter {
  _ViewsChartPainter({
    required this.stats,
    required this.selected,
    required this.partialLast,
    required this.lineColor,
    required this.gridColor,
    required this.ringColor,
    required this.labelStyle,
    required this.dayLabel,
    required this.textDirection,
  });

  final List<TopicViewStat> stats;
  final int? selected;
  final bool partialLast;
  final Color lineColor;
  final Color gridColor;
  final Color ringColor;
  final TextStyle labelStyle;
  final String Function(TopicViewStat stat) dayLabel;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = _ChartGeometry.plotRect(size);
    final maxValue = _ChartGeometry.niceCeil(
      stats.map((s) => s.views).fold(0, math.max),
    );
    Offset point(int i) => Offset(
      plot.left + plot.width * i / (stats.length - 1),
      plot.bottom - plot.height * stats[i].views / maxValue,
    );

    // 网格与 Y 轴刻度：0、一半、上限
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final value in [0, maxValue ~/ 2, maxValue]) {
      final y = plot.bottom - plot.height * value / maxValue;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      _drawText(
        canvas,
        NumberUtils.formatCount(value),
        Offset(plot.left - 6, y),
        alignRight: true,
      );
    }

    // X 轴标注：首、中、尾三天
    final ticks = {0, (stats.length - 1) ~/ 2, stats.length - 1};
    for (final i in ticks) {
      final x = point(i).dx;
      _drawText(
        canvas,
        dayLabel(stats[i]),
        Offset(x, plot.bottom + _ChartGeometry.xAxisHeight / 2 + 2),
        center: true,
        clampLeft: plot.left,
        clampRight: size.width,
      );
    }

    // 已过完的日子画实线，今天只是部分数据，最后一段画虚线
    final solidEnd = partialLast ? stats.length - 2 : stats.length - 1;
    final line = Path()..moveTo(point(0).dx, point(0).dy);
    for (var i = 1; i <= solidEnd; i++) {
      line.lineTo(point(i).dx, point(i).dy);
    }
    final area = Path.from(line)
      ..lineTo(point(solidEnd).dx, plot.bottom)
      ..lineTo(point(0).dx, plot.bottom)
      ..close();
    canvas.drawPath(area, Paint()..color = lineColor.withValues(alpha: 0.1));
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(line, linePaint);
    if (partialLast) {
      _drawDashed(
        canvas,
        point(stats.length - 2),
        point(stats.length - 1),
        linePaint,
      );
    }

    // 今天的数据还在累计：末端画空心点
    final last = stats.length - 1;
    if (partialLast && selected != last) {
      _drawDot(canvas, point(last), hollow: true);
    }

    // 选中的一天：竖向准线 + 圆点（今天为空心）
    final index = selected;
    if (index != null) {
      final selectedPoint = point(index);
      canvas.drawLine(
        Offset(selectedPoint.dx, plot.top),
        Offset(selectedPoint.dx, plot.bottom),
        Paint()
          ..color = lineColor.withValues(alpha: 0.4)
          ..strokeWidth = 1,
      );
      _drawDot(canvas, selectedPoint, hollow: partialLast && index == last);
    }
  }

  /// 数据点：外圈用底色描一圈，压在折线上也看得清
  void _drawDot(Canvas canvas, Offset center, {required bool hollow}) {
    canvas.drawCircle(center, 6, Paint()..color = ringColor);
    canvas.drawCircle(
      center,
      hollow ? 3.5 : 4,
      hollow
          ? (Paint()
              ..color = lineColor
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2)
          : (Paint()..color = lineColor),
    );
  }

  void _drawDashed(Canvas canvas, Offset from, Offset to, Paint paint) {
    const dash = 4.0;
    const gap = 4.0;
    final total = (to - from).distance;
    if (total == 0) return;
    final direction = (to - from) / total;
    for (var d = 0.0; d < total; d += dash + gap) {
      final end = math.min(d + dash, total);
      canvas.drawLine(from + direction * d, from + direction * end, paint);
    }
  }

  /// 以 [anchor] 为基准绘制标注：右对齐（Y 轴）或居中（X 轴），纵向居中
  void _drawText(
    Canvas canvas,
    String text,
    Offset anchor, {
    bool alignRight = false,
    bool center = false,
    double? clampLeft,
    double? clampRight,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: labelStyle),
      textDirection: textDirection,
      maxLines: 1,
    )..layout();
    var dx = alignRight
        ? anchor.dx - painter.width
        : center
        ? anchor.dx - painter.width / 2
        : anchor.dx;
    // 首尾日期不超出绘图区左右边界
    if (clampLeft != null) dx = math.max(dx, clampLeft);
    if (clampRight != null) dx = math.min(dx, clampRight - painter.width);
    painter.paint(canvas, Offset(dx, anchor.dy - painter.height / 2));
    painter.dispose();
  }

  @override
  bool shouldRepaint(_ViewsChartPainter old) =>
      old.stats != stats ||
      old.selected != selected ||
      old.partialLast != partialLast ||
      old.lineColor != lineColor ||
      old.gridColor != gridColor ||
      old.ringColor != ringColor ||
      old.labelStyle != labelStyle;
}
