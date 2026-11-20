import '../../../../pages/app_logs_page.dart';
import 'metaverse_plugin_management_page.dart';
import 'package:common_ui/common_ui.dart';
import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:rfw/rfw.dart';
import '../../../../navigation/nav_action_bus.dart';

import '../../../../l10n/s.dart';
import '../../../../navigation/navigation_activity_scope.dart';
import '../../../../services/navigation/app_route_observer.dart';
import '../metaverse_plugin_host.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import 'metaverse_widget_library.dart';
import '../../../../widgets/common/error_view.dart';

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
    this.navigationId,
    this.builder,
    this.params = const {},
  });

  final MetaversePluginHost host;
  final MetaversePluginSurfaceKind kind;
  final String? page;
  final String? navigationId;
  final Map<String, Object?> params;
  /// 外壳与内容共用一个 surface，标题栏不会重复启动脚本或派发 page.open。
  final Widget Function(BuildContext context, Widget content, Widget Function(String name)? render)? builder;

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
  bool _tabActive = true;
  bool _opening = false;
  int? _navigationNonce;
  ModalRoute<dynamic>? _ancestorRoute;

  void _syncForeground() {
    final visible = _tabActive && _appForeground && _routeCurrent && (_ancestorRoute?.isCurrent ?? true);
    final surface = _surface;
    if (surface == null && visible && !_opening && _error == null) _open();
    if (surface != null) {
      widget.host.setSurfaceForeground(
        surface,
        visible,
        appForeground: _appForeground,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _appForeground = state == null || state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tabActive = NavigationActivityScope.isActive(context);
    final event = NavigationActivityScope.actionOf(context);
    if (_surface case final surface?) {
      if (event != null && event.nonce != _navigationNonce && event.targetId == widget.navigationId && _tabActive && surface.foreground) {
        _navigationNonce = event.nonce;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !identical(surface, _surface) || !surface.foreground) return;
          if (event.action == NavAction.refresh) {
            widget.host.dispatchUserEvent(surface, 'page.refresh', const {});
          } else {
            for (final position in PrimaryScrollController.maybeOf(context)?.positions.toList() ?? <ScrollPosition>[]) {
              position.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
            }
          }
        });
      }
    }
    _navigationNonce = event?.nonce;
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
      _attempt++;
      _surface = null;
      _widgets = null;
      _error = null;
      _opening = false;
      _syncForeground();
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
    _opening = true;
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
        isVisible: () => mounted && attempt == _attempt && _tabActive && _appForeground && _routeCurrent && (_ancestorRoute?.isCurrent ?? true),
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
      if (error is! MetaversePluginCallException || error.message != 'surface_not_visible') {
        setState(() => _error = error);
      }
    } finally {
      if (attempt == _attempt) {
        _opening = false;
        // 启动被隐藏取消后，标签可能已再次可见；不能一直停留在加载状态。
        if (mounted && _surface == null && _error == null) _syncForeground();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget wrap(Widget content, [Widget Function(String name)? render]) =>
        widget.builder?.call(context, content, render) ?? content;
    final surface = _surface;
    final widgets = _widgets;
    final error = _error;
    if (error != null) { return wrap(MetaversePluginErrorView(message: '$error', pluginId: widget.host.id, onRetry: () {
      setState(() => _error = null);
      _syncForeground();
    })); }
    if (surface == null || widgets == null) {
      return wrap(const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: LoadingSpinner(size: 28)),
      ));
    }
    final manifest = widget.host.manifest;
    final widgetName = widget.kind == MetaversePluginSurfaceKind.card
        ? manifest.cardWidget
        : manifest.page(widget.page ?? '')?.widget;
    if (widgetName == null) {
      return wrap(MetaversePluginErrorView(message: '${widget.page}'));
    }
    final data = widget.host.attachSurface(surface, context);
    Widget render(String name) => RemoteWidget(
      runtime: widgets,
      widget: FullyQualifiedWidgetName(metaversePluginLibraryName, name),
      data: data,
      onEvent: (name, arguments) =>
          widget.host.dispatchUserEvent(surface, name, arguments),
    );
    return wrap(render(widgetName), render);
  }
}

class MetaversePluginErrorView extends StatelessWidget {
  const MetaversePluginErrorView({super.key, required this.message, this.onRetry, this.pluginId});

  final String message;
  final String? pluginId;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      ErrorView(error: message, title: context.l10n.metaverse_runtimeFailed, onRetry: onRetry),
      if (pluginId != null) TextButton(onPressed: () => Navigator.of(context).push(InteractionPageRoute(builder: (_) => AppLogsPage(pluginId: pluginId))),
        child: Text(context.l10n.metaverse_diagnostics)),
      if (pluginId != null) TextButton(onPressed: () => Navigator.of(context).push(InteractionPageRoute(builder: (_) => MetaversePluginSettingsPage(pluginId: pluginId!))),
        child: Text(context.l10n.metaverse_pluginManage)),
    ]);
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
