import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';

/// 所有对象工具条与菜单共享同一材质，统一跟随玻璃、明暗与高对比度设置。
class ComposerObjectSurface extends StatelessWidget {
  const ComposerObjectSurface({
    super.key,
    required this.child,
    this.radius = 24,
    this.compact = false,
  });
  final Widget child;
  final double radius;
  final bool compact;
  @override
  Widget build(BuildContext context) => GlassSurfaceFrame(
    radius: radius,
    recipe: compact ? GlassRecipe.toolbar : GlassRecipe.menu,
    child: Material(color: Colors.transparent, child: child),
  );
}
