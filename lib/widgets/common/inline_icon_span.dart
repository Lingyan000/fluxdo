import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 图标中心距文字基线的高度（以字号为单位）。
///
/// 做法同 Web 图标库的 `vertical-align: -0.125em`：以基线为锚、按字号
/// 固定偏移，按主字体与图标集校准一次。数值在 macOS 真机上实测校准：
/// 系统字体 12px 数字中心约在基线上 0.315em，Material Symbols 字形在
/// 方框里又普遍偏上约 0.3px，合起来取 0.28em 时图标与数字视觉居中。
/// 数字更高的字体（如 Roboto）下图标会略低，偏差约 0.5px。
const double _iconCenterAboveBaseline = 0.28;

/// 与数字同行的行内图标，图标中心落在基线以上固定比例处。
///
/// 不用 [PlaceholderAlignment.middle]：它按字体上下伸部算中线，与数字的
/// 视觉中心无关，macOS 上实测图标偏高约 1px。
///
/// [textStyle] 传所在文字的样式（未经系统缩放；WidgetSpan 会整体随字号缩放）。
InlineSpan inlineIconSpan(
  IconData icon, {
  required double size,
  Color? color,
  double? fill,
  required TextStyle textStyle,
}) {
  final fontSize = textStyle.fontSize ?? 14;
  return WidgetSpan(
    alignment: PlaceholderAlignment.baseline,
    baseline: TextBaseline.alphabetic,
    child: _BaselineAt(
      baseline: size / 2 + fontSize * _iconCenterAboveBaseline,
      child: Icon(icon, size: size, color: color, fill: fill),
    ),
  );
}

/// 向父级报告指定的基线位置（自顶部起算），子组件照常布局与绘制。
class _BaselineAt extends SingleChildRenderObjectWidget {
  const _BaselineAt({required this.baseline, super.child});

  final double baseline;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBaselineAt(baseline);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderBaselineAt renderObject,
  ) {
    renderObject.baseline = baseline;
  }
}

class _RenderBaselineAt extends RenderProxyBox {
  _RenderBaselineAt(this._baseline);

  double _baseline;
  set baseline(double value) {
    if (value == _baseline) return;
    _baseline = value;
    markNeedsLayout();
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => _baseline;

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => _baseline;
}
