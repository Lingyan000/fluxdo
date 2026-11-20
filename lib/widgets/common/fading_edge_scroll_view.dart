import 'package:material_ui/material_ui.dart';

/// 为可滚动子组件添加边缘渐变遮罩
///
/// 自动监听子组件的滚动位置，在未到达边缘的方向显示渐隐效果。
/// [fadeLeft] 和 [fadeRight] 控制是否启用对应方向的渐变。
class FadingEdgeScrollView extends StatefulWidget {
  final Widget child;

  /// 是否启用左侧渐变（默认关闭）
  final bool fadeLeft;

  /// 是否启用右侧渐变（默认开启）
  final bool fadeRight;

  /// 渐变区域占比（0.0 ~ 1.0），默认 0.15
  final double fadeExtent;

  const FadingEdgeScrollView({
    super.key,
    required this.child,
    this.fadeLeft = false,
    this.fadeRight = true,
    this.fadeExtent = 0.15,
  });

  @override
  State<FadingEdgeScrollView> createState() => _FadingEdgeScrollViewState();
}

class _FadingEdgeScrollViewState extends State<FadingEdgeScrollView> {
  bool _showLeftFade = false;
  bool _showRightFade = true;

  void _updateFadeState(ScrollMetrics metrics) {
    final newShowLeft = metrics.pixels > 1;
    final newShowRight = metrics.pixels < metrics.maxScrollExtent - 1;
    if (newShowLeft != _showLeftFade || newShowRight != _showRightFade) {
      setState(() {
        _showLeftFade = newShowLeft;
        _showRightFade = newShowRight;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final showLeft = widget.fadeLeft && _showLeftFade;
    final showRight = widget.fadeRight && _showRightFade;

    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        _updateFadeState(notification.metrics);
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          _updateFadeState(notification.metrics);
          return false;
        },
        child: ShaderMask(
          shaderCallback: (Rect bounds) {
            if (!showLeft && !showRight) {
              return const LinearGradient(
                colors: [Colors.white, Colors.white],
              ).createShader(bounds);
            }
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                if (showLeft) Colors.white.withValues(alpha: 0),
                Colors.white,
                Colors.white,
                if (showRight) Colors.white.withValues(alpha: 0),
              ],
              stops: [
                if (showLeft) 0.0,
                showLeft ? widget.fadeExtent : 0.0,
                showRight ? 1.0 - widget.fadeExtent : 1.0,
                if (showRight) 1.0,
              ],
            ).createShader(bounds);
          },
          blendMode: BlendMode.dstIn,
          child: widget.child,
        ),
      ),
    );
  }
}
