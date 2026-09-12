import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'composer_tools_anchor.dart';

const double kComposerIslandRadius = 20;
const double kComposerIslandInset = 8;
const double kComposerIslandBottomGap = 10;

/// 只负责玻璃与裁切；覆盖正文的布局由 ComposerEditorLayout 提供。
/// 编辑器使用已有的导航玻璃配方，高对比度模式降级为实色。
class ComposerIsland extends StatelessWidget {
  const ComposerIsland({super.key, required this.child, this.toolsAnchor});
  final Widget child;
  final ComposerToolsAnchor? toolsAnchor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        kComposerIslandInset,
        0,
        kComposerIslandInset,
        kComposerIslandBottomGap,
      ),
      child: KeyedSubtree(
        key: toolsAnchor?.surfaceKey,
        child: GlassSurfaceFrame(
          key: const ValueKey('composer-island-surface'),
          radius: kComposerIslandRadius,
          recipe: GlassRecipe.navigation,
          enabled: !MediaQuery.highContrastOf(context),
          child: Material(color: Colors.transparent, child: child),
        ),
      ),
    );
  }
}
