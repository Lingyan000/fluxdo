import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

/// 高亮引导遮罩
///
/// 用法：`SpotlightOverlay.show(context, targetKey: key, message: '...')`
/// 点击任意位置关闭。
class SpotlightOverlay {
  static OverlayEntry? _entry;

  /// 显示高亮引导
  /// [targetKey] 需要高亮的组件的 GlobalKey
  /// [message] 引导文案
  /// [borderRadius] 高亮区域圆角
  /// [padding] 高亮区域向外扩展的边距
  static void show(
    BuildContext context, {
    required GlobalKey targetKey,
    required String message,
    double borderRadius = 16,
    EdgeInsets padding = const EdgeInsets.all(4),
  }) {
    dismiss();

    final renderBox =
        targetKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return;

    final position = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;

    final targetRect = Rect.fromLTWH(
      position.dx - padding.left,
      position.dy - padding.top,
      size.width + padding.left + padding.right,
      size.height + padding.top + padding.bottom,
    );

    _entry = OverlayEntry(
      builder: (context) => _SpotlightWidget(
        targetRect: targetRect,
        targetKey: targetKey,
        padding: padding,
        borderRadius: borderRadius,
        message: message,
        onDismiss: dismiss,
      ),
    );

    Overlay.of(context).insert(_entry!);
  }

  static void dismiss() {
    _entry?.remove();
    _entry = null;
  }
}

class _SpotlightWidget extends StatefulWidget {
  final Rect targetRect;
  final GlobalKey targetKey;
  final EdgeInsets padding;
  final double borderRadius;
  final String message;
  final VoidCallback onDismiss;

  const _SpotlightWidget({
    required this.targetRect,
    required this.targetKey,
    required this.padding,
    required this.borderRadius,
    required this.message,
    required this.onDismiss,
  });

  @override
  State<_SpotlightWidget> createState() => _SpotlightWidgetState();
}

class _SpotlightWidgetState extends State<_SpotlightWidget>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;

  /// 当前镂空位置。初值是 show() 时算好的;窗口尺寸剧变(折叠屏折叠/
  /// 展开、拖动窗口)时经 [didChangeMetrics] 按 targetKey 重算 ——
  /// 之前是一次性算死,折叠后高亮框停在旧坐标框到空白。
  late Rect _rect = widget.targetRect;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );
    _controller.forward();
  }

  @override
  void didChangeMetrics() {
    // 等一帧:metrics 变化时目标还没完成新布局,立刻取是旧坐标
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final renderBox =
          widget.targetKey.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox == null || !renderBox.hasSize || !renderBox.attached) {
        // 目标随布局切换消失(如折叠后组件不在树上)→ 引导直接收场
        widget.onDismiss();
        return;
      }
      final position = renderBox.localToGlobal(Offset.zero);
      setState(() {
        _rect = Rect.fromLTWH(
          position.dx - widget.padding.left,
          position.dy - widget.padding.top,
          renderBox.size.width + widget.padding.horizontal,
          renderBox.size.height + widget.padding.vertical,
        );
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    await _controller.reverse();
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final theme = Theme.of(context);

    // 判断提示文字放在高亮区域上方还是下方
    final spaceBelow = screenSize.height - _rect.bottom;
    final showBelow = spaceBelow > 120;

    return FadeTransition(
      opacity: _fadeAnimation,
      child: GestureDetector(
        onTap: _dismiss,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          children: [
            // 半透明遮罩（中间镂空）
            Positioned.fill(
              child: CustomPaint(
                painter: _SpotlightPainter(
                  targetRect: _rect,
                  borderRadius: widget.borderRadius,
                ),
              ),
            ),

            // 高亮边框（呼吸动画）
            Positioned.fromRect(
              rect: _rect,
              child: IgnorePointer(
                child: _PulsingBorder(
                  borderRadius: widget.borderRadius,
                  color: theme.colorScheme.primary.withValues(alpha: 0.6),
                ),
              ),
            ),

            // 提示文案
            Positioned(
              left: 24,
              right: 24,
              top: showBelow ? _rect.bottom + 16 : null,
              bottom: showBelow
                  ? null
                  : screenSize.height - _rect.top + 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!showBelow)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Icon(
                        Symbols.arrow_downward_rounded,
                        color: Colors.white.withValues(alpha: 0.8),
                        size: 20,
                      ),
                    ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.inverseSurface
                          .withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      widget.message,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onInverseSurface,
                        fontWeight: FontWeight.w500,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 高亮镂空遮罩
class _SpotlightPainter extends CustomPainter {
  final Rect targetRect;
  final double borderRadius;

  _SpotlightPainter({
    required this.targetRect,
    required this.borderRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withValues(alpha: 0.6);

    // 全屏路径
    final fullPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    // 镂空路径
    final holePath = Path()
      ..addRRect(
        RRect.fromRectAndRadius(targetRect, Radius.circular(borderRadius)),
      );

    // 差集
    final combinedPath =
        Path.combine(PathOperation.difference, fullPath, holePath);

    canvas.drawPath(combinedPath, paint);
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) =>
      old.targetRect != targetRect || old.borderRadius != borderRadius;
}

/// 呼吸边框动画
class _PulsingBorder extends StatefulWidget {
  final double borderRadius;
  final Color color;

  const _PulsingBorder({
    required this.borderRadius,
    required this.color,
  });

  @override
  State<_PulsingBorder> createState() => _PulsingBorderState();
}

class _PulsingBorderState extends State<_PulsingBorder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final opacity = 0.3 + 0.5 * _controller.value;
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            border: Border.all(
              color: widget.color.withValues(alpha: opacity),
              width: 2,
            ),
          ),
        );
      },
    );
  }
}
