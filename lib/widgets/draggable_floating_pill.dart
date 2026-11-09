import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:m3e_ui/m3e_ui.dart';

import 'floating_widget_mixin.dart';

class DraggableFloatingPill extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final double initialTop;
  final bool initiallyExpanded;
  final bool tapToExpand;

  /// 前导图标。
  final IconData icon;

  /// 自带颜色的标志（如品牌 logo），提供时取代 [icon]，不跟随内容色。
  final Widget? mark;

  /// 进行中：图标外套一圈不确定进度环。
  final bool busy;

  /// 需要用户处理：改用 primary 色底，与进行中态区分。
  final bool emphasized;

  const DraggableFloatingPill({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    this.initialTop = 100,
    this.initiallyExpanded = false,
    this.tapToExpand = true,
    this.icon = Symbols.gpp_maybe_rounded,
    this.mark,
    this.busy = false,
    this.emphasized = false,
  });

  @override
  State<DraggableFloatingPill> createState() => _DraggableFloatingPillState();
}

/// 进度环直径。比普通图标（20）大一圈：M3E 波浪环会向内起伏，
/// 留出余量免得贴住内部标志。
const double _busyRingSize = 24;

/// 普通图标尺寸。
const double _iconSize = 20;

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
    final backgroundColor = widget.emphasized
        ? colorScheme.primary
        : colorScheme.inverseSurface;
    final contentColor = widget.emphasized
        ? colorScheme.onPrimary
        : colorScheme.onInverseSurface;

    // Padding 动画：吸附时增加 padding 防止内容被埋在 offscreen 区域
    // 进度环比图标高出的部分从上下内边距里扣回，各状态胶囊等高
    final ringExtra = widget.busy ? (_busyRingSize - _iconSize) / 2 : 0.0;
    final basePadding = widget.padding.copyWith(
      top: widget.padding.top - ringExtra,
      bottom: widget.padding.bottom - ringExtra,
    );
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
                decoration: ShapeDecoration(
                  shadows: [
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
                  shape: RoundedSuperellipseBorder(borderRadius: borderRadius),
                ),
                child: child,
              );
            },
            child: Material(
              color: Colors.transparent,
              elevation: 0,
              shape: RoundedSuperellipseBorder(borderRadius: borderRadius),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                decoration: ShapeDecoration(
                  color: backgroundColor.withValues(alpha: 0.9),
                  shape: RoundedSuperellipseBorder(
                    borderRadius: borderRadius,
                    side: BorderSide(
                      color: colorScheme.outline.withValues(alpha: 0.1),
                      width: 1.0,
                    ),
                  ),
                ),
                padding: targetPadding,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.busy)
                      // 进度环包住标志；M3E 开关关闭时组件内部回退为经典转圈
                      SizedBox.square(
                        dimension: _busyRingSize,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            M3eCircularProgress(
                              size: _busyRingSize,
                              strokeWidth: 1.5,
                              color: contentColor,
                              trackColor: contentColor.withValues(alpha: 0.2),
                            ),
                            widget.mark ??
                                Icon(
                                  widget.icon,
                                  fill: 1,
                                  size: 12,
                                  color: contentColor,
                                ),
                          ],
                        ),
                      )
                    else
                      widget.mark ??
                          Icon(
                            widget.icon,
                            fill: _isExpanded ? 1 : 0,
                            size: _iconSize,
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
                          Symbols.chevron_right_rounded,
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
