import 'package:flutter/widgets.dart';

/// 常驻页面在后台时保留键盘出现前的底部 inset 和布局高度。
///
/// [active] 由 tab/pane 宿主提供；被其他路由覆盖时也自动隔离。
/// 双栏中可启用 [requireFocus]，只让实际输入的栏跟随键盘。
/// 只冻结键盘相关尺寸，窗口大小、方向和其余 MediaQuery 属性仍实时更新。
class KeyboardInsetIsolation extends StatefulWidget {
  const KeyboardInsetIsolation({
    super.key,
    this.active = true,
    this.requireFocus = false,
    required this.child,
  });

  final bool active;
  final bool requireFocus;
  final Widget child;

  @override
  State<KeyboardInsetIsolation> createState() => _KeyboardInsetIsolationState();
}

class _KeyboardInsetIsolationState extends State<KeyboardInsetIsolation>
    with WidgetsBindingObserver {
  bool _hasFocus = false;
  double? _bottomInset;
  double? _bottomPadding;
  double? _height;
  double? _width;
  Size? _viewSize;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() => setState(() {});

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // Scaffold 的 body 可能已消费 viewInsets，仍需识别外层因键盘而缩高。
    final view = View.of(context);
    final keyboardOpen = view.viewInsets.bottom > 0;
    final viewSize = view.physicalSize / view.devicePixelRatio;
    var current = true;
    var routeContext = context;
    final seen = <ModalRoute<dynamic>>{};
    var route = ModalRoute.of(routeContext);
    while (route != null && seen.add(route)) {
      current = current && (ModalRoute.isCurrentOf(routeContext) ?? true);
      final navigator = route.navigator;
      if (navigator == null) break;
      routeContext = navigator.context;
      route = ModalRoute.of(routeContext);
    }
    final followsKeyboard =
        widget.active && current && (!widget.requireFocus || _hasFocus);
    final resized = _viewSize != viewSize;
    _viewSize = viewSize;
    final hold = keyboardOpen && !followsKeyboard && !resized;
    if (!hold || _bottomInset == null) {
      _bottomInset = media.viewInsets.bottom;
      _bottomPadding = media.padding.bottom;
    }
    final isolated = media.copyWith(
      viewInsets: media.viewInsets.copyWith(bottom: _bottomInset),
      padding: media.padding.copyWith(bottom: _bottomPadding),
    );

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (value) {
        if (widget.requireFocus && mounted) {
          setState(() => _hasFocus = value);
        } else {
          _hasFocus = value;
        }
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (!hold || _width != constraints.maxWidth || _height == null) {
            _height = constraints.hasBoundedHeight
                ? constraints.maxHeight
                : null;
          }
          _width = constraints.maxWidth;
          // 外层 Scaffold 已经缩高时，仅覆盖 MediaQuery 不足以阻止后台
          // ListView 重排。保持子树高度，外框仍遵守父约束并裁切溢出。
          return ClipRect(
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minHeight: _height,
              maxHeight: _height,
              child: MediaQuery(data: isolated, child: widget.child),
            ),
          );
        },
      ),
    );
  }
}
