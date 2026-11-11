import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 给每个页面提供不透明的页面背景（自定义背景图、主题纹理等），画在路由
/// 转场之内。阅读内容通过 [contentColor] 透出背景，覆盖内容的栏用
/// [PageBackdrop] 遮挡滚动内容，弹层使用自己的表面色。
class PageBackgroundScope extends InheritedWidget {
  const PageBackgroundScope({
    super.key,
    required this.backgroundBuilder,
    required super.child,
  });

  /// 为 null 时不铺背景，切换时不会重建页面内容。
  final WidgetBuilder? backgroundBuilder;

  static PageBackgroundScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PageBackgroundScope>();

  /// 当前是否铺着页面背景（栏、标题栏据此决定透明还是不透明）。
  static bool isActive(BuildContext context) =>
      maybeOf(context)?.backgroundBuilder != null;

  /// 阅读内容的基础填充色。有页面背景时透出背景，否则使用原有颜色。
  /// 选中、高亮等状态色在此基础上叠加，遮挡层通过 [PageBackdrop] 绘制。
  static Color contentColor(BuildContext context, Color fallback) =>
      isActive(context) ? Colors.transparent : fallback;

  @override
  bool updateShouldNotify(PageBackgroundScope oldWidget) =>
      backgroundBuilder != oldWidget.backgroundBuilder;
}

class RoutePageBackground extends StatefulWidget {
  const RoutePageBackground({super.key, required this.child});
  final Widget child;

  @override
  State<RoutePageBackground> createState() => _RoutePageBackgroundState();
}

class _RoutePageBackgroundState extends State<RoutePageBackground> {
  final _pageKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final scope = PageBackgroundScope.maybeOf(context);
    return _PageBackgroundHost(
      pageKey: _pageKey,
      child: Stack(
        key: _pageKey,
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
          widget.child,
        ],
      ),
    );
  }
}

/// 页面背景的坐标原点：[PageBackdrop] 据此把背景副本与整页对齐。
class _PageBackgroundHost extends InheritedWidget {
  const _PageBackgroundHost({required this.pageKey, required super.child});

  final GlobalKey pageKey;

  @override
  bool updateShouldNotify(_PageBackgroundHost oldWidget) =>
      pageKey != oldWidget.pageKey;
}

/// 「页面底」区域：需要遮住下方滚动内容、又应当看起来就是页面本身的
/// 地方（可收起的标题栏、吸顶标签条、窗格底等）。
///
/// 没有页面背景时填页面底色；有页面背景时画一份与整页对齐的背景副本，
/// 纹理和图片与周围连成一片，同时挡住下面的内容。渐隐带可以把它包在
/// `ShaderMask` 里使用。
class PageBackdrop extends StatelessWidget {
  const PageBackdrop({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final builder = PageBackgroundScope.maybeOf(context)?.backgroundBuilder;
    final Widget fill = builder == null
        ? ColoredBox(color: Theme.of(context).scaffoldBackgroundColor)
        : IgnorePointer(
            child: ExcludeSemantics(
              child: _AlignedBackdrop(
                pageKey: context
                    .dependOnInheritedWidgetOfExactType<_PageBackgroundHost>()
                    ?.pageKey,
                pageSize: MediaQuery.sizeOf(context),
                child: Builder(builder: builder),
              ),
            ),
          );
    final content = child;
    if (content == null) return fill;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(child: fill),
        content,
      ],
    );
  }
}

class _AlignedBackdrop extends SingleChildRenderObjectWidget {
  const _AlignedBackdrop({
    required this.pageKey,
    required this.pageSize,
    required super.child,
  });

  final GlobalKey? pageKey;
  final Size pageSize;

  @override
  _RenderAlignedBackdrop createRenderObject(BuildContext context) =>
      _RenderAlignedBackdrop(pageKey, pageSize);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderAlignedBackdrop renderObject,
  ) {
    renderObject
      ..pageKey = pageKey
      ..pageSize = pageSize;
  }
}

/// 子节点（页面背景）按整页尺寸布局，绘制时平移到与页面原点对齐，
/// 再裁剪到自身区域。
class _RenderAlignedBackdrop extends RenderProxyBox {
  _RenderAlignedBackdrop(this.pageKey, this._pageSize);

  GlobalKey? pageKey;

  Size _pageSize;
  set pageSize(Size value) {
    if (value == _pageSize) return;
    _pageSize = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    child?.layout(BoxConstraints.tight(_pageSize));
    size = constraints.biggest;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      false;

  /// 自身原点在页面坐标中的位置；找不到页面时按全局坐标对齐
  Offset _originInPage() {
    final page = pageKey?.currentContext?.findRenderObject();
    if (page is RenderBox && page.attached) {
      return localToGlobal(Offset.zero, ancestor: page);
    }
    return localToGlobal(Offset.zero);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final origin = _originInPage();
    context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (context, offset) => context.paintChild(child, offset - origin),
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
