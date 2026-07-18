import 'package:flutter/material.dart';

import '../../utils/relative_time_clock.dart';
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

/// 自动刷新的相对时间 Widget
///
/// 特性：
/// - 长按 Tooltip 显示精确时间
/// - 刷新订阅全局分钟心跳 [RelativeTimeClock] —— 此前每实例自养
///   Timer(15s~30min 自适应)+ 各自 setState,一屏十几个实例就是
///   十几个定时器在随机时刻独立醒来;现在全 app 同一节拍、同帧
///   重建,实例自身零常驻资源。亚分钟档("刚刚"→"1分钟前")的
///   过渡最多迟 1 分钟,属可接受粒度。
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
  bool _subscribed = false;

  void _onTick() {
    if (mounted) setState(() {});
  }

  void _setSubscribed(bool value) {
    if (_subscribed == value) return;
    _subscribed = value;
    if (value) {
      RelativeTimeClock.instance.addListener(_onTick);
    } else {
      RelativeTimeClock.instance.removeListener(_onTick);
    }
  }

  @override
  void dispose() {
    _setSubscribed(false);
    super.dispose();
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
    // 页面不可见(TickerMode off,如被覆盖的路由)时退订,回到可见
    // 时重订 —— 与旧实现的 Timer 暂停语义一致
    _setSubscribed(TickerMode.valuesOf(context).enabled);

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
