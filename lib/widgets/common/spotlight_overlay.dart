import 'package:flutter/material.dart';
import 'package:common_ui/common_ui.dart';
import 'package:app_icons/app_icons.dart';

/// 高亮引导遮罩
///
/// 用法：`SpotlightOverlay.show(context, targetKey: key, message: '...')`
/// 点击任意位置关闭。
class SpotlightOverlay {
  static OverlayEntry? _entry;
  static ValueNotifier<bool>? _input;

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

    final input = ValueNotifier(true);
    _input = input;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _SpotlightWidget(
        input: input,
        targetRect: targetRect,
        borderRadius: borderRadius,
        message: message,
        onDismiss: () {
          if (identical(_entry, entry)) dismiss();
        },
      ),
    );
    _entry = entry;
    Overlay.of(context).insert(entry);
  }

  static void dismiss() {
    _input?.value = false;
    _entry?.remove();
    _entry = null;
    _input?.dispose();
    _input = null;
  }
}

class _SpotlightWidget extends StatefulWidget {
  final ValueNotifier<bool> input;
  final Rect targetRect;
  final double borderRadius;
  final String message;
  final VoidCallback onDismiss;

  const _SpotlightWidget({
    required this.input,
    required this.targetRect,
    required this.borderRadius,
    required this.message,
    required this.onDismiss,
  });

  @override
  State<_SpotlightWidget> createState() => _SpotlightWidgetState();
}

class _SpotlightWidgetState extends State<_SpotlightWidget>
    with SingleTickerProviderStateMixin {
  ValueNotifier<bool> get _acceptsInput => widget.input;
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
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
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    if (!_acceptsInput.value) return;
    _acceptsInput.value = false;
    try {
      await _controller.reverse().orCancel;
      if (mounted) widget.onDismiss();
    } on TickerCanceled {
      // Removed or replaced before the exit animation completed.
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final theme = Theme.of(context);

    // 判断提示文字放在高亮区域上方还是下方
    final spaceBelow = screenSize.height - widget.targetRect.bottom;
    final showBelow = spaceBelow > 120;

    return InteractionGate(
      enabled: _acceptsInput,
      child: FadeTransition(
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
                    targetRect: widget.targetRect,
                    borderRadius: widget.borderRadius,
                  ),
                ),
              ),

              // 高亮边框（呼吸动画）
              Positioned.fromRect(
                rect: widget.targetRect,
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
                top: showBelow ? widget.targetRect.bottom + 16 : null,
                bottom: showBelow
                    ? null
                    : screenSize.height - widget.targetRect.top + 16,
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
                      decoration: ShapeDecoration(
                        color: theme.colorScheme.inverseSurface.withValues(
                          alpha: 0.92,
                        ),
                        shape: RoundedSuperellipseBorder(
                          borderRadius: context.shapes.borderRadius(12),
                        ),
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
      ),
    );
  }
}

/// 高亮镂空遮罩
class _SpotlightPainter extends CustomPainter {
  final Rect targetRect;
  final double borderRadius;

  _SpotlightPainter({required this.targetRect, required this.borderRadius});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withValues(alpha: 0.6);

    // 全屏路径
    final fullPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    // 镂空路径
    final holePath = Path()
      ..addRSuperellipse(
        RSuperellipse.fromRectAndRadius(
          targetRect,
          Radius.circular(borderRadius),
        ),
      );

    // 差集
    final combinedPath = Path.combine(
      PathOperation.difference,
      fullPath,
      holePath,
    );

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

  const _PulsingBorder({required this.borderRadius, required this.color});

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
          decoration: ShapeDecoration(
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              side: BorderSide(
                color: widget.color.withValues(alpha: opacity),
                width: 2,
              ),
            ),
          ),
        );
      },
    );
  }
}
