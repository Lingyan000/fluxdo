import 'package:flutter/widgets.dart';

/// 网页区域：按 [edgeToEdge] 决定是否让出 [unsafe]，让出的部分用页面颜色填充。
///
/// 网页声明了底色时 [top] 与 [bottom] 相同；否则取自截图的上下边缘，
/// 与小程序安全区一样画成纵向渐变。
/// 结构保持不变，切换模式只改边距，不重新挂载原生视图。
class BrowserWebViewport extends StatelessWidget {
  const BrowserWebViewport({
    super.key,
    required this.unsafe,
    required this.edgeToEdge,
    required this.top,
    required this.bottom,
    required this.child,
  });

  final EdgeInsets unsafe;
  final bool edgeToEdge;
  final Color top;
  final Color bottom;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<Decoration>(
    tween: DecorationTween(
      end: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, bottom],
        ),
      ),
    ),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 260),
    builder: (context, decoration, child) =>
        DecoratedBox(decoration: decoration, child: child),
    child: Padding(
      padding: edgeToEdge ? EdgeInsets.zero : unsafe,
      child: child,
    ),
  );
}
