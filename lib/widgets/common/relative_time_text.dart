import 'dart:async';

import 'package:flutter/material.dart';

import '../../utils/time_utils.dart';

/// 时间显示样式
enum TimeDisplayStyle {
  /// 纯相对时间："3小时前"
  relative,

  /// 前缀模式："创建于 3小时前"
  prefixed,

  /// 后缀模式："3小时前 获得"
  suffixed,
}

/// 可自动刷新的相对时间 Widget
///
/// 特性：
/// - 长按 Tooltip 显示精确时间
/// - Timer 根据时间差动态调整刷新频率
/// - 页面不可见时自动暂停 Timer
class RelativeTimeText extends StatefulWidget {
  const RelativeTimeText({
    super.key,
    required this.dateTime,
    this.style,
    this.displayStyle = TimeDisplayStyle.relative,
    this.prefix,
    this.suffix,
  });

  /// 要显示的时间
  final DateTime? dateTime;

  /// 文本样式
  final TextStyle? style;

  /// 显示样式
  final TimeDisplayStyle displayStyle;

  /// 前缀文本，displayStyle 为 prefixed 时使用
  final String? prefix;

  /// 后缀文本，displayStyle 为 suffixed 时使用
  final String? suffix;

  @override
  State<RelativeTimeText> createState() => _RelativeTimeTextState();
}

class _RelativeTimeTextState extends State<RelativeTimeText> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _scheduleTimer();
  }

  @override
  void didUpdateWidget(RelativeTimeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dateTime != widget.dateTime) {
      _timer?.cancel();
      _scheduleTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 根据时间差动态调整刷新频率
  Duration _getRefreshInterval() {
    if (widget.dateTime == null) return const Duration(minutes: 30);

    final diff = DateTime.now().difference(widget.dateTime!);
    if (diff.inMinutes < 1) return const Duration(seconds: 15);
    if (diff.inHours < 1) return const Duration(seconds: 30);
    if (diff.inHours < 24) return const Duration(minutes: 5);
    return const Duration(minutes: 30);
  }

  void _scheduleTimer() {
    // 通过 TickerMode 检查页面是否可见
    _timer = Timer(_getRefreshInterval(), () {
      if (mounted) {
        setState(() {});
        _scheduleTimer();
      }
    });
  }

  String _buildDisplayText() {
    final relativeText = TimeUtils.formatRelativeTime(widget.dateTime);

    switch (widget.displayStyle) {
      case TimeDisplayStyle.relative:
        return relativeText;
      case TimeDisplayStyle.prefixed:
        return '${widget.prefix ?? ''}$relativeText';
      case TimeDisplayStyle.suffixed:
        return '$relativeText${widget.suffix ?? ''}';
    }
  }

  @override
  Widget build(BuildContext context) {
    // TickerMode 为 false 时暂停 Timer
    if (!TickerMode.valuesOf(context).enabled) {
      _timer?.cancel();
    } else if (_timer == null || !_timer!.isActive) {
      _scheduleTimer();
    }

    final displayText = _buildDisplayText();
    final tooltipText = TimeUtils.formatTooltipTime(widget.dateTime);

    if (tooltipText.isEmpty) {
      return Text(displayText, style: widget.style);
    }

    return Tooltip(
      message: tooltipText,
      preferBelow: true,
      child: Text(displayText, style: widget.style),
    );
  }
}
