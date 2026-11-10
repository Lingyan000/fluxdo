import 'package:common_ui/common_ui.dart' show UiShapesContext;
import 'package:flutter/material.dart';

/// 骨架屏容器
///
/// 使用方式：
/// ```dart
/// Skeleton(
///   child: Column(
///     children: [
///       SkeletonBox(width: 100, height: 20),
///       SkeletonBox(width: 200, height: 16),
///     ],
///   ),
/// )
/// ```
class Skeleton extends StatefulWidget {
  final Widget child;

  const Skeleton({required this.child, super.key});

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 使用更明显的渐变效果
    // 注意：不能使用 Colors.transparent（它是透明黑色 0x00000000），
    // 否则在浅色模式下与 surface 背景色混合时会产生黑色扫描效果
    final transparentSurface = theme.colorScheme.surface.withAlpha(0);
    final shimmerGradient = LinearGradient(
      colors: [
        transparentSurface,
        theme.colorScheme.surface.withAlpha(80),
        theme.colorScheme.surface.withAlpha(80),
        transparentSurface,
      ],
      stops: const [0.1, 0.3, 0.5, 0.7],
      begin: const Alignment(-1.0, -0.3),
      end: const Alignment(1.0, 0.3),
      tileMode: TileMode.clamp,
    );

    // RepaintBoundary 隔离 60fps shimmer 重绘,避免连累 Skeleton 外的 page。
    return RepaintBoundary(
      child: _Shimmer(
        linearGradient: shimmerGradient,
        child: _ShimmerLoading(isLoading: true, child: widget.child),
      ),
    );
  }
}

/// 内部 Shimmer 动画管理器
class _Shimmer extends StatefulWidget {
  static _ShimmerState? of(BuildContext context) {
    return context.findAncestorStateOfType<_ShimmerState>();
  }

  const _Shimmer({required this.linearGradient, this.child});

  final LinearGradient linearGradient;
  final Widget? child;

  @override
  _ShimmerState createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late AnimationController _shimmerController;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController.unbounded(vsync: this)
      ..repeat(min: -0.5, max: 1.5, period: const Duration(milliseconds: 1200));
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  LinearGradient get gradient => LinearGradient(
    colors: widget.linearGradient.colors,
    stops: widget.linearGradient.stops,
    begin: widget.linearGradient.begin,
    end: widget.linearGradient.end,
    transform: _SlidingGradientTransform(
      slidePercent: _shimmerController.value,
    ),
  );

  bool get isSized =>
      (context.findRenderObject() as RenderBox?)?.hasSize ?? false;

  Size get size => (context.findRenderObject() as RenderBox).size;

  Offset getDescendantOffset({
    required RenderBox descendant,
    Offset offset = Offset.zero,
  }) {
    final shimmerBox = context.findRenderObject() as RenderBox;
    return descendant.localToGlobal(offset, ancestor: shimmerBox);
  }

  Listenable get shimmerChanges => _shimmerController;

  @override
  Widget build(BuildContext context) {
    return widget.child ?? const SizedBox();
  }
}

/// 渐变平移变换
class _SlidingGradientTransform extends GradientTransform {
  const _SlidingGradientTransform({required this.slidePercent});

  final double slidePercent;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * slidePercent, 0.0, 0.0);
  }
}

/// ShimmerLoading 包装器
class _ShimmerLoading extends StatefulWidget {
  const _ShimmerLoading({required this.isLoading, required this.child});

  final bool isLoading;
  final Widget child;

  @override
  State<_ShimmerLoading> createState() => _ShimmerLoadingState();
}

class _ShimmerLoadingState extends State<_ShimmerLoading> {
  Listenable? _shimmerChanges;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_shimmerChanges != null) {
      _shimmerChanges!.removeListener(_onShimmerChange);
    }
    _shimmerChanges = _Shimmer.of(context)?.shimmerChanges;
    if (_shimmerChanges != null) {
      _shimmerChanges!.addListener(_onShimmerChange);
    }
  }

  @override
  void dispose() {
    _shimmerChanges?.removeListener(_onShimmerChange);
    super.dispose();
  }

  void _onShimmerChange() {
    if (widget.isLoading) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isLoading) {
      return widget.child;
    }

    final shimmer = _Shimmer.of(context);

    // 布局未完成时，先显示静态内容（无动画）
    if (shimmer == null || !shimmer.isSized) {
      return widget.child;
    }

    // 自身也需要已布局才能计算偏移
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) {
      return widget.child;
    }

    final shimmerSize = shimmer.size;
    final gradient = shimmer.gradient;
    final offsetWithinShimmer = shimmer.getDescendantOffset(
      descendant: renderBox,
    );

    return ShaderMask(
      blendMode: BlendMode.srcATop,
      shaderCallback: (bounds) {
        return gradient.createShader(
          Rect.fromLTWH(
            -offsetWithinShimmer.dx,
            -offsetWithinShimmer.dy,
            shimmerSize.width,
            shimmerSize.height,
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// 骨架屏占位框
///
/// 这是一个简单的占位框，需要配合 [Skeleton] 使用
class SkeletonBox extends StatelessWidget {
  final double? width;
  final double height;
  final double borderRadius;

  const SkeletonBox({
    super.key,
    this.width,
    required this.height,
    this.borderRadius = 4,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: width,
      height: height,
      decoration: ShapeDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withAlpha(100),
        shape: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(borderRadius),
        ),
      ),
    );
  }
}

/// 圆形骨架屏占位框
class SkeletonCircle extends StatelessWidget {
  final double size;

  const SkeletonCircle({super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withAlpha(100),
        shape: BoxShape.circle,
      ),
    );
  }
}
