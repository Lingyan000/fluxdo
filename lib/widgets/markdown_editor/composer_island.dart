import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';

import 'composer_tools_anchor.dart';

const double kComposerIslandRadius = 20;
const double kComposerIslandInset = 8;
const double kComposerIslandBottomGap = 10;

/// 只负责玻璃与裁切；覆盖正文的布局由 ComposerEditorLayout 提供。
/// 材质遵循全局玻璃开关和档位，高对比度实色策略由 GlassSurface 统一处理。
class ComposerIsland extends StatelessWidget {
  const ComposerIsland({
    super.key,
    required this.child,
    this.toolsAnchor,
    this.padding = const EdgeInsets.fromLTRB(
      kComposerIslandInset,
      0,
      kComposerIslandInset,
      kComposerIslandBottomGap,
    ),
    this.radius = kComposerIslandRadius,
    this.expanded = false,
  });
  final Widget child;
  final ComposerToolsAnchor? toolsAnchor;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: KeyedSubtree(
        key: toolsAnchor?.surfaceKey,
        child: GlassSurfaceFrame(
          key: const ValueKey('composer-island-surface'),
          radius: radius,
          recipe: expanded ? GlassRecipe.sheet : GlassRecipe.toolbar,
          child: Material(color: Colors.transparent, child: child),
        ),
      ),
    );
  }
}
