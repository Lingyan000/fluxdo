import 'package:app_icons/app_icons.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:rfw/rfw.dart';

import '../../../../l10n/s.dart';
import '../../../../services/navigation/app_route_observer.dart';
import '../metaverse_plugin_host.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import 'metaverse_widget_library.dart';

/// 一块插件界面：元宇宙页里的卡片，或一个独立页面。
///
/// 对插件脚本而言是 `ctx.kind`（`card` / `page`）。
enum MetaversePluginSurfaceKind {
  card,
  page;

  static MetaversePluginSurfaceKind? parse(Object? value) => switch (value) {
    'card' => card,
    'page' => page,
    _ => null,
  };
}

/// 渲染插件声明的界面。
///
/// 界面由 rfw 用宿主预置的组件重建（不是 WebView），因此自动跟随主题、圆角
/// 与字体设置；数据与事件经脚本运行时往返。
class MetaversePluginSurfaceView extends StatefulWidget {
  const MetaversePluginSurfaceView({
    super.key,
    required this.host,
    required this.kind,
    this.page,
    this.params = const {},
  });

  final MetaversePluginHost host;
  final MetaversePluginSurfaceKind kind;
  final String? page;
  final Map<String, Object?> params;

  @override
  State<MetaversePluginSurfaceView> createState() =>
      _MetaversePluginSurfaceViewState();
}

class _MetaversePluginSurfaceViewState extends State<MetaversePluginSurfaceView>
    with WidgetsBindingObserver {
  MetaversePluginSurface? _surface;
  Runtime? _widgets;
  Object? _error;
  var _attempt = 0;
  bool _appForeground = true;
  bool _routeCurrent = true;
  ModalRoute<dynamic>? _ancestorRoute;

  void _syncForeground() {
    final surface = _surface;
    if (surface != null) {
      widget.host.setSurfaceForeground(
        surface,
        _appForeground && _routeCurrent && (_ancestorRoute?.isCurrent ?? true),
        appForeground: _appForeground,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null) didChangeAppLifecycleState(state);
    _open();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    _routeCurrent = route?.isCurrent ?? true;
    // 内层 Navigator 的栈顶不反映根层弹框；同时订阅承载它的根路由。
    var outer = route;
    while (outer?.navigator != null) {
      final parent = ModalRoute.of(outer!.navigator!.context);
      if (parent == null) break;
      outer = parent;
    }
    final ancestor = identical(outer, route) ? null : outer;
    if (!identical(ancestor, _ancestorRoute)) {
      appRouteObserver.topRouteRevision.removeListener(_syncForeground);
      _ancestorRoute = ancestor;
      if (ancestor != null) {
        appRouteObserver.topRouteRevision.addListener(_syncForeground);
      }
    }
    _syncForeground();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) return;
    _appForeground = state == AppLifecycleState.resumed;
    _syncForeground();
  }

  @override
  void didUpdateWidget(MetaversePluginSurfaceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.host != widget.host ||
        oldWidget.kind != widget.kind ||
        oldWidget.page != widget.page ||
        !const DeepCollectionEquality().equals(
          oldWidget.params,
          widget.params,
        )) {
      final previous = _surface;
      if (previous != null) oldWidget.host.close(previous);
      _surface = null;
      _open();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    appRouteObserver.topRouteRevision.removeListener(_syncForeground);
    final surface = _surface;
    _surface = null;
    if (surface != null) widget.host.close(surface);
    super.dispose();
  }

  Future<void> _open() async {
    final attempt = ++_attempt;
    final host = widget.host;
    final previous = _surface;
    if (previous != null) widget.host.close(previous);
    if (mounted) {
      setState(() {
        _surface = null;
        _widgets = null;
        _error = null;
      });
    }
    try {
      final surface = await host.open(
        kind: widget.kind.name,
        page: widget.page,
        params: widget.params,
      );
      if (!mounted || attempt != _attempt) {
        host.close(surface);
        return;
      }
      setState(() {
        _surface = surface;
        _widgets = widget.host.widgets;
      });
      _syncForeground();
    } catch (error) {
      if (!mounted || attempt != _attempt) return;
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final surface = _surface;
    final widgets = _widgets;
    final error = _error;
    if (error != null) return MetaversePluginErrorView(message: '$error');
    if (surface == null || widgets == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: LoadingSpinner(size: 28)),
      );
    }
    final manifest = widget.host.manifest;
    final widgetName = widget.kind == MetaversePluginSurfaceKind.card
        ? manifest.cardWidget
        : manifest.page(widget.page ?? '')?.widget;
    if (widgetName == null) {
      return MetaversePluginErrorView(message: '${widget.page}');
    }
    final data = widget.host.attachSurface(surface, context);
    return RemoteWidget(
      runtime: widgets,
      widget: FullyQualifiedWidgetName(metaversePluginLibraryName, widgetName),
      data: data,
      onEvent: (name, arguments) =>
          widget.host.dispatchUserEvent(surface, name, arguments),
    );
  }
}

class MetaversePluginErrorView extends StatelessWidget {
  const MetaversePluginErrorView({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.error_rounded, color: theme.colorScheme.error),
          const SizedBox(height: 8),
          Text(
            context.l10n.metaverse_pluginLoadFailed,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 展示域名列表（安装确认页、权限说明）。
class MetaverseHostList extends StatelessWidget {
  const MetaverseHostList({super.key, required this.hosts});

  final List<String> hosts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final host in hosts)
          DecoratedBox(
            decoration: ShapeDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              shape: const StadiumBorder(),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Text(
                host,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
