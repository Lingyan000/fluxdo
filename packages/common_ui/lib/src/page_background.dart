import 'package:flutter/material.dart';

/// Supplies an opaque wallpaper to each page, inside its route transition.
/// Transparent surfaces may reveal this wallpaper, never the previous page.
class PageBackgroundScope extends InheritedWidget {
  const PageBackgroundScope({
    super.key,
    required this.backgroundBuilder,
    required super.child,
  });

  /// Null disables wallpaper without remounting page content.
  final WidgetBuilder? backgroundBuilder;

  static PageBackgroundScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PageBackgroundScope>();

  /// 当前是否铺着页面背景（栏、标题栏据此决定透明还是不透明）。
  static bool isActive(BuildContext context) =>
      maybeOf(context)?.backgroundBuilder != null;

  /// 阅读内容的基础填充色。有页面背景时透出背景，否则使用原有颜色。
  /// 选中、高亮等状态色在此基础上叠加。
  static Color contentColor(BuildContext context, Color fallback) =>
      isActive(context) ? Colors.transparent : fallback;

  @override
  bool updateShouldNotify(PageBackgroundScope oldWidget) =>
      backgroundBuilder != oldWidget.backgroundBuilder;
}

class RoutePageBackground extends StatelessWidget {
  const RoutePageBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<PageBackgroundScope>();
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: RepaintBoundary(
                child:
                    scope?.backgroundBuilder?.call(context) ??
                    const SizedBox.shrink(),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// PageRouteBuilder bypasses PageTransitionsTheme. Put the wallpaper in its
/// page as well, so custom clipping/motion also moves the wallpaper correctly.
/// Non-opaque viewers and popups intentionally keep showing the underlying page.
mixin PageBackgroundRoute<T> on PageRoute<T> {
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final page = super.buildPage(context, animation, secondaryAnimation);
    return opaque ? RoutePageBackground(child: page) : page;
  }
}
