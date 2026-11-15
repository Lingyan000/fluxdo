import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';

import '../../services/browser_safe_area.dart';

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
    required this.window,
    required this.systemPadding,
    required this.observeGeometry,
    required this.onGeometryChanged,
  });

  final EdgeInsets unsafe;
  final bool edgeToEdge;
  final Color top;
  final Color bottom;
  final Widget child;
  final Rect window;
  final EdgeInsets systemPadding;
  final bool observeGeometry;
  final ValueChanged<BrowserViewportGeometry> onGeometryChanged;

  @override
  Widget build(BuildContext context) => _GeometryObserver(
    window: window,
    padding: systemPadding,
    enabled: observeGeometry,
    onChanged: onGeometryChanged,
    child: TweenAnimationBuilder<Decoration>(
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
    ),
  );
}

/// 在绘制时读取最终位置，能观察仅父级布局或 transform 变化的帧；静止时不轮询。
class _GeometryObserver extends SingleChildRenderObjectWidget {
  const _GeometryObserver({
    required this.window,
    required this.padding,
    required this.enabled,
    required this.onChanged,
    required super.child,
  });

  final Rect window;
  final EdgeInsets padding;
  final bool enabled;
  final ValueChanged<BrowserViewportGeometry> onChanged;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _GeometryRenderBox()..configure(window, padding, enabled, onChanged);

  @override
  void updateRenderObject(
    BuildContext context,
    _GeometryRenderBox renderObject,
  ) => renderObject.configure(window, padding, enabled, onChanged);
}

class _GeometryRenderBox extends RenderProxyBox {
  Rect _window = Rect.zero;
  EdgeInsets _padding = EdgeInsets.zero;
  bool _enabled = false;
  bool _scheduled = false;
  BrowserViewportGeometry? _last;
  late ValueChanged<BrowserViewportGeometry> _onChanged;

  void configure(
    Rect window,
    EdgeInsets padding,
    bool enabled,
    ValueChanged<BrowserViewportGeometry> onChanged,
  ) {
    _onChanged = onChanged;
    if (_window == window && _padding == padding && _enabled == enabled) return;
    _window = window;
    _padding = padding;
    _enabled = enabled;
    _last = null;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (!_enabled) return;
    final geometry = BrowserViewportGeometry(
      viewport: MatrixUtils.transformRect(
        getTransformTo(null),
        Offset.zero & size,
      ),
      window: _window,
      padding: _padding,
    );
    if (geometry == _last) return;
    _last = geometry;
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (attached && _enabled && _last != null) _onChanged(_last!);
    });
  }
}
