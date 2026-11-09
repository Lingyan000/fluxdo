import 'package:flutter/widgets.dart';

/// 常驻侧栏页面自行让主内容避让底栏，根导航器和侧栏保持完整高度。
class BrowserDockContentLayouts extends ChangeNotifier {
  final _regions = <Object, ({Route<dynamic> route, double left})>{};
  bool _disposed = false;
  bool _scheduled = false;

  double? leftFor(Route<dynamic>? route) {
    for (final region in _regions.values) {
      if (region.route == route) return region.left;
    }
    return null;
  }

  void register(Object owner, Route<dynamic>? route, double left) {
    if (_disposed) return;
    final next = route != null && left > 0 ? (route: route, left: left) : null;
    if (_regions[owner] == next) return;
    if (next == null) {
      _regions.remove(owner);
    } else {
      _regions[owner] = next;
    }
    // 页面可能正在 build 或 dispose，不能反向让上层宿主在构建中 setState。
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _regions.clear();
    super.dispose();
  }
}

class BrowserDockContentScope extends InheritedWidget {
  const BrowserDockContentScope({
    super.key,
    required this.layouts,
    required this.route,
    required this.bottomInset,
    required super.child,
  });

  final BrowserDockContentLayouts layouts;
  final Route<dynamic>? route;
  final double bottomInset;

  static BrowserDockContentScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BrowserDockContentScope>();

  @override
  bool updateShouldNotify(BrowserDockContentScope oldWidget) =>
      layouts != oldWidget.layouts ||
      route != oldWidget.route ||
      bottomInset != oldWidget.bottomInset;
}

class BrowserDockContentLayout extends StatefulWidget {
  const BrowserDockContentLayout({
    super.key,
    required this.leftInset,
    required this.builder,
  });

  final double leftInset;
  final Widget Function(BuildContext context, double bottomInset) builder;

  @override
  State<BrowserDockContentLayout> createState() =>
      _BrowserDockContentLayoutState();
}

class _BrowserDockContentLayoutState extends State<BrowserDockContentLayout> {
  BrowserDockContentLayouts? _layouts;

  @override
  Widget build(BuildContext context) {
    final scope = BrowserDockContentScope.maybeOf(context);
    final route = ModalRoute.of(context);
    if (_layouts != scope?.layouts) {
      _layouts?.register(this, null, 0);
      _layouts = scope?.layouts;
    }
    _layouts?.register(this, route, widget.leftInset);
    final inset = widget.leftInset > 0 && scope?.route == route
        ? scope?.bottomInset ?? 0
        : 0.0;
    return widget.builder(context, inset);
  }

  @override
  void dispose() {
    _layouts?.register(this, null, 0);
    super.dispose();
  }
}

MediaQueryData browserDockContentMedia(
  MediaQueryData media,
  double bottomInset,
) => media.copyWith(
  size: Size(
    media.size.width,
    (media.size.height - bottomInset).clamp(0.0, double.infinity),
  ),
  padding: media.padding.copyWith(
    bottom: (media.padding.bottom - bottomInset).clamp(0.0, double.infinity),
  ),
  viewPadding: media.viewPadding.copyWith(
    bottom: (media.viewPadding.bottom - bottomInset).clamp(
      0.0,
      double.infinity,
    ),
  ),
);
