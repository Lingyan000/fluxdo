import 'package:flutter/material.dart';

import 'floating_widget_mixin.dart';

class DraggableFloatingPill extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final double initialTop;
  final bool initiallyExpanded;
  final bool tapToExpand;

  const DraggableFloatingPill({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    this.initialTop = 100,
    this.initiallyExpanded = false,
    this.tapToExpand = true,
  });

  @override
  State<DraggableFloatingPill> createState() => _DraggableFloatingPillState();
}

class _DraggableFloatingPillState extends State<DraggableFloatingPill>
    with TickerProviderStateMixin, FloatingWidgetMixin {
  // 呼吸动画控制器
  late AnimationController _breathingController;
  late Animation<double> _breathingAnimation;

  late bool _isExpanded;

  @override
  double get floatingOverlap => 20.0;

  @override
  double get floatingTopMargin => 50.0;

  @override
  double get floatingBottomMargin => 50.0;

  @override
  void initState() {
    super.initState();
    initFloating();
    _isExpanded = widget.initiallyExpanded;

    // 初始化呼吸动画
    _breathingController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _breathingAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _breathingController, curve: Curves.easeInOut),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    updateFloatingDependencies();
  }

  @override
  void dispose() {
    _breathingController.dispose();
    disposeFloating();
    super.dispose();
  }

  void _onPanStart(DragStartDetails details) {
    onFloatingPanStart(details);
    if (widget.tapToExpand) {
      setState(() {
        _isExpanded = false; // 拖拽时自动收起
      });
    }
  }

  void _handleTap() {
    if (!widget.tapToExpand) {
      widget.onTap?.call();
      return;
    }

    if (_isExpanded) {
      widget.onTap?.call();
    } else {
      setState(() {
        _isExpanded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(999);
    final pos = floatingPosition();
    final colorScheme = Theme.of(context).colorScheme;
    final backgroundColor = colorScheme.inverseSurface;
    final contentColor = colorScheme.onInverseSurface;

    // Padding 动画：吸附时增加 padding 防止内容被埋在 offscreen 区域
    final basePadding = widget.padding;
    final overlap = floatingOverlap;
    final isRight = floatingIsRight;
    final targetPadding = floatingIsAdsorbed
        ? basePadding.copyWith(
            left: isRight ? basePadding.left : basePadding.left + overlap,
            right: isRight ? basePadding.right + overlap : basePadding.right,
          )
        : basePadding;

    return Positioned(
      left: pos.left,
      top: pos.top,
      right: pos.right,
      child: Opacity(
        opacity: floatingIsInitialized ? 1.0 : 0.0,
        child: GestureDetector(
          onPanStart: _onPanStart,
          onPanUpdate: onFloatingPanUpdate,
          onPanEnd: onFloatingPanEnd,
          onTap: _handleTap,
          child: AnimatedBuilder(
            animation: _breathingAnimation,
            builder: (context, child) {
              return Container(
                decoration: BoxDecoration(
                  borderRadius: borderRadius,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 6,
                      spreadRadius: 1,
                      offset: const Offset(0, 2),
                    ),
                    BoxShadow(
                      color: colorScheme.primary.withValues(
                        alpha: 0.1 + 0.3 * _breathingAnimation.value,
                      ),
                      blurRadius: 12 + 8 * _breathingAnimation.value,
                      spreadRadius: 2 + 4 * _breathingAnimation.value,
                    ),
                  ],
                ),
                child: child,
              );
            },
            child: Material(
              color: Colors.transparent,
              elevation: 0,
              borderRadius: borderRadius,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  color: backgroundColor.withValues(alpha: 0.9),
                  borderRadius: borderRadius,
                  border: Border.all(
                    color: colorScheme.outline.withValues(alpha: 0.1),
                    width: 1.0,
                  ),
                ),
                padding: targetPadding,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isExpanded ? Icons.gpp_maybe : Icons.gpp_maybe_outlined,
                      size: 20,
                      color: contentColor,
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      child: SizedBox(
                        width: _isExpanded ? null : 0,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: DefaultTextStyle(
                              style: Theme.of(context).textTheme.labelLarge!
                                  .copyWith(
                                    color: contentColor,
                                    fontWeight: FontWeight.w600,
                                  ),
                              child: widget.child,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_isExpanded)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: contentColor.withValues(alpha: 0.7),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
