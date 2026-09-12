import 'package:flutter/material.dart';
import 'glass_surface.dart';

export 'glass_edge_painter.dart';

/// 05294df6 导航玻璃的共用外壳：双层柔影、局部裁切和降级方向性边缘光。
/// 导航与编辑器只传尺寸，不各自维护一套阴影或描边参数。
class GlassSurfaceFrame extends StatelessWidget {
  const GlassSurfaceFrame({
    super.key,
    required this.radius,
    required this.child,
    this.enabled = true,
    this.recipe = GlassRecipe.navigation,
  });
  final double radius;
  final Widget child;
  final bool enabled;
  final GlassRecipe recipe;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.052 : 0.068),
            blurRadius: isDark ? 7 : 8,
            spreadRadius: -0.75,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.010 : 0.014),
            blurRadius: isDark ? 3 : 3.5,
            spreadRadius: -0.75,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: GlassSurface(
          recipe: recipe,
          shape: shape,
          enabled: enabled,
          drawFallbackBorder: false,
          fallbackBorderRadius: radius,
          child: child,
        ),
      ),
    );
  }
}
