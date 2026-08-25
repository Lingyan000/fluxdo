import 'dart:convert';

// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/flutter_riverpod.dart' show WidgetRef;
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/shortcut_binding.dart';
import '../utils/platform_utils.dart';
import 'theme_provider.dart'; // sharedPreferencesProvider

/// 快捷键状态管理
class ShortcutNotifier extends StateNotifier<List<ShortcutBinding>> {
  static const _prefsKey = 'shortcuts_custom';

  ShortcutNotifier(this._prefs) : super(buildDefaultBindings()) {
    _loadCustomBindings();
  }

  final SharedPreferences _prefs;

  /// 从 SharedPreferences 加载用户自定义绑定
  void _loadCustomBindings() {
    final jsonStr = _prefs.getString(_prefsKey);
    if (jsonStr == null) return;

    try {
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      state = state.map((binding) {
        final data = map[binding.action.name] as Map<String, dynamic>?;
        final custom = ShortcutBinding.activatorFromJson(data);
        if (custom != null) {
          return binding.copyWith(customActivator: custom);
        }
        return binding;
      }).toList();
    } catch (_) {
      // JSON 损坏，忽略
    }
  }

  /// 持久化所有自定义绑定
  Future<void> _saveCustomBindings() async {
    final map = <String, dynamic>{};
    for (final binding in state) {
      if (binding.isCustomized) {
        map[binding.action.name] = ShortcutBinding.activatorToJson(
          binding.customActivator!,
        );
      }
    }
    if (map.isEmpty) {
      await _prefs.remove(_prefsKey);
    } else {
      await _prefs.setString(_prefsKey, jsonEncode(map));
    }
  }

  /// 更新某个动作的快捷键绑定
  Future<void> updateBinding(
    ShortcutAction action,
    SingleActivator activator,
  ) async {
    state = state.map((b) {
      if (b.action == action) {
        return b.copyWith(customActivator: activator);
      }
      return b;
    }).toList();
    await _saveCustomBindings();
  }

  /// 重置单个动作为默认
  Future<void> resetBinding(ShortcutAction action) async {
    state = state.map((b) {
      if (b.action == action) {
        return b.copyWith(clearCustom: true);
      }
      return b;
    }).toList();
    await _saveCustomBindings();
  }

  /// 重置全部为默认
  Future<void> resetAll() async {
    state = buildDefaultBindings();
    await _prefs.remove(_prefsKey);
  }

  /// 查找与指定激活器冲突的动作，排除 excludeAction
  ShortcutAction? findConflict(
    SingleActivator activator, {
    ShortcutAction? excludeAction,
  }) {
    for (final binding in state) {
      if (binding.action == excludeAction) continue;
      if (_activatorsEqual(binding.activator, activator)) {
        return binding.action;
      }
    }
    return null;
  }

  /// 获取指定动作的绑定
  ShortcutBinding? getBinding(ShortcutAction action) {
    for (final binding in state) {
      if (binding.action == action) return binding;
    }
    return null;
  }

  /// 构建用于 CallbackShortcuts 的 bindings map
  Map<ShortcutActivator, VoidCallback> buildBindingsMap(
    Map<ShortcutAction, VoidCallback> callbacks,
  ) {
    final result = <ShortcutActivator, VoidCallback>{};
    for (final binding in state) {
      final callback = callbacks[binding.action];
      if (callback != null) {
        result[binding.activator] = callback;
      }
    }
    return result;
  }

  static bool _activatorsEqual(SingleActivator a, SingleActivator b) {
    return a.trigger == b.trigger &&
        a.control == b.control &&
        a.shift == b.shift &&
        a.alt == b.alt &&
        a.meta == b.meta;
  }
}

final shortcutProvider =
    StateNotifierProvider<ShortcutNotifier, List<ShortcutBinding>>((ref) {
      final prefs = ref.watch(sharedPreferencesProvider);
      return ShortcutNotifier(prefs);
    });

/// 双栏活跃面板
enum ActivePane { master, detail }

/// 快捷键作用域
enum ShortcutScope { master, detail, context }

class ShortcutScopeRegistration {
  const ShortcutScopeRegistration({
    required this.owner,
    required this.route,
    required this.callbacks,
    required this.order,
    this.enabled,
  });

  final Object owner;
  final Route<dynamic>? route;
  final Map<ShortcutAction, VoidCallback> callbacks;
  final int order;

  /// 分发时的活跃谓词。底栏 tab 页全部挂在同一个 IndexedStack、共享
  /// 同一个根路由——按路由过滤区分不出"哪个 tab 活跃",不活跃 tab 的
  /// 注册会吞掉/抢走活跃 tab 的按键(实测:草稿 tab 的 maybePop 注册
  /// 吞掉私信页的 ESC)。IndexedStack 常驻页面注册时必须传
  /// `() => widget.isActive` 这类谓词;独立路由页可不传(路由过滤够用)。
  final bool Function()? enabled;

  bool get isEnabled => enabled?.call() ?? true;
}

class ShortcutScopeRegistryState {
  const ShortcutScopeRegistryState({
    this.master = const {},
    this.detail = const {},
    this.context = const {},
  });

  final Map<Object, ShortcutScopeRegistration> master;
  final Map<Object, ShortcutScopeRegistration> detail;
  final Map<Object, ShortcutScopeRegistration> context;

  Map<Object, ShortcutScopeRegistration> registrationsFor(ShortcutScope scope) {
    return switch (scope) {
      ShortcutScope.master => master,
      ShortcutScope.detail => detail,
      ShortcutScope.context => context,
    };
  }

  ShortcutScopeRegistryState copyWithScope(
    ShortcutScope scope,
    Map<Object, ShortcutScopeRegistration> registrations,
  ) {
    return switch (scope) {
      ShortcutScope.master => ShortcutScopeRegistryState(
        master: registrations,
        detail: detail,
        context: context,
      ),
      ShortcutScope.detail => ShortcutScopeRegistryState(
        master: master,
        detail: registrations,
        context: context,
      ),
      ShortcutScope.context => ShortcutScopeRegistryState(
        master: master,
        detail: detail,
        context: registrations,
      ),
    };
  }
}

class ShortcutScopeRegistryNotifier
    extends StateNotifier<ShortcutScopeRegistryState> {
  ShortcutScopeRegistryNotifier() : super(const ShortcutScopeRegistryState());

  int _registrationOrder = 0;

  void register({
    required ShortcutScope scope,
    required Object owner,
    required Route<dynamic>? route,
    required Map<ShortcutAction, VoidCallback> callbacks,
    bool Function()? enabled,
  }) {
    final next = Map<Object, ShortcutScopeRegistration>.from(
      state.registrationsFor(scope),
    );

    if (callbacks.isEmpty) {
      next.remove(owner);
    } else {
      next[owner] = ShortcutScopeRegistration(
        owner: owner,
        route: route,
        callbacks: Map.unmodifiable(Map.of(callbacks)),
        enabled: enabled,
        order: ++_registrationOrder,
      );
    }

    state = state.copyWithScope(scope, Map.unmodifiable(next));
  }

  void unregister({required ShortcutScope scope, required Object owner}) {
    final next = Map<Object, ShortcutScopeRegistration>.from(
      state.registrationsFor(scope),
    );
    if (next.remove(owner) == null) return;
    state = state.copyWithScope(scope, Map.unmodifiable(next));
  }
}

final shortcutScopeRegistryProvider =
    StateNotifierProvider<
      ShortcutScopeRegistryNotifier,
      ShortcutScopeRegistryState
    >((ref) {
      return ShortcutScopeRegistryNotifier();
    });

Map<ShortcutAction, VoidCallback> _mergeShortcutRegistrations(
  Iterable<ShortcutScopeRegistration> registrations,
) {
  final sorted = registrations.toList()
    ..sort((a, b) => a.order.compareTo(b.order));
  final callbacks = <ShortcutAction, VoidCallback>{};
  for (final registration in sorted) {
    callbacks.addAll(registration.callbacks);
  }
  return callbacks;
}

Map<ShortcutAction, VoidCallback> resolveShortcutScopeCallbacks({
  required ShortcutScopeRegistryState registry,
  required ShortcutScope scope,
  required Route<dynamic>? route,
}) {
  // isEnabled 过滤:IndexedStack 常驻 tab 页共享根路由,路由过滤分不出
  // 活跃 tab,靠注册方传入的谓词把非活跃 tab 的注册排除在分发之外。
  final registrations = registry
      .registrationsFor(scope)
      .values
      .where((registration) => registration.isEnabled)
      .toList();
  if (registrations.isEmpty) return const {};

  if (route != null) {
    final exactMatches = registrations
        .where((registration) => identical(registration.route, route))
        .toList();
    if (exactMatches.isNotEmpty) {
      return _mergeShortcutRegistrations(exactMatches);
    }
  }

  final currentRouteGroups =
      <Route<dynamic>, List<ShortcutScopeRegistration>>{};
  for (final registration in registrations) {
    final registrationRoute = registration.route;
    if (registrationRoute == null || !registrationRoute.isCurrent) continue;
    currentRouteGroups
        .putIfAbsent(registrationRoute, () => [])
        .add(registration);
  }

  if (currentRouteGroups.isEmpty) return const {};

  Route<dynamic>? preferredRoute;
  var preferredOrder = -1;
  for (final entry in currentRouteGroups.entries) {
    final groupOrder = entry.value
        .map((registration) => registration.order)
        .reduce((a, b) => a > b ? a : b);
    if (groupOrder > preferredOrder) {
      preferredOrder = groupOrder;
      preferredRoute = entry.key;
    }
  }

  if (preferredRoute == null) return const {};
  return _mergeShortcutRegistrations(currentRouteGroups[preferredRoute]!);
}

class ShortcutScopeBinding {
  ShortcutScopeBinding({
    required WidgetRef ref,
    required this.scope,
    this.enabled,
  }) : _registry = ref.read(shortcutScopeRegistryProvider.notifier);

  final ShortcutScope scope;

  /// 分发时的活跃谓词(见 [ShortcutScopeRegistration.enabled])。
  /// IndexedStack 常驻 tab 页必须传 `() => widget.isActive` 之类,
  /// 否则非活跃 tab 的注册会截胡活跃 tab 的按键。
  final bool Function()? enabled;

  final ShortcutScopeRegistryNotifier _registry;
  final Object _owner = Object();
  bool _disposed = false;

  void register(
    BuildContext context,
    Map<ShortcutAction, VoidCallback> callbacks,
  ) {
    registerForRoute(ModalRoute.of(context), callbacks);
  }

  void registerForRoute(
    Route<dynamic>? route,
    Map<ShortcutAction, VoidCallback> callbacks,
  ) {
    if (_disposed) return;
    _registry.register(
      scope: scope,
      owner: _owner,
      route: route,
      callbacks: callbacks,
      enabled: enabled,
    );
  }

  void clear() {
    if (_disposed) return;
    _registry.unregister(scope: scope, owner: _owner);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _registry.unregister(scope: scope, owner: _owner);
  }

  void disposeDeferred() {
    if (_disposed) return;
    final disposeNow = dispose;
    Future(disposeNow);
  }
}

// 「普通全屏路由 ESC 可关」不再需要页面显式接入:全屏 PageRoute 由
// EscFallbackObserver(widgets/esc_fallback_observer.dart)在 push 时自动
// 登记,分发端在 context 回调之后兜底 maybePop。原 RouteEscCloseBinding
// 标准件(定义至今零使用,正是「逐页显式接入」约定腐烂的证据)已删除。

/// 双栏宿主页的「ESC 两段式」标准件:右栏开着时不注册 context 层
/// (让分发落到 detail scope——TopicDetailPage 等注册的关闭回调,先退
/// 页内搜索/AI,再 pop/clear 右栏);右栏空了才注册 maybePop 关整页。
/// 底栏 tab 形态页面是首路由,maybePop 为 no-op,注册无害。
///
/// 用法(State 内):
/// ```dart
/// late final _esc = PaneHostEscBinding(ref: ref, enabled: () => widget.isActive);
/// build:    _esc.sync(context, paneOpen: canShowBothPanes && selected.hasSelection);
/// dispose:  _esc.dispose();
/// ```
class PaneHostEscBinding {
  PaneHostEscBinding({required WidgetRef ref, bool Function()? enabled})
    : _binding = ShortcutScopeBinding(
        ref: ref,
        scope: ShortcutScope.context,
        enabled: enabled,
      );

  final ShortcutScopeBinding _binding;
  bool? _pageCloseRegistered;

  /// 每次 build 调用,按右栏开合同步注册状态。内部挂帧后,可在 build
  /// 期间安全调用。
  void sync(BuildContext context, {required bool paneOpen}) {
    if (!PlatformUtils.isDesktop) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      final wantPageClose = !paneOpen;
      if (_pageCloseRegistered == wantPageClose) return;
      _pageCloseRegistered = wantPageClose;
      if (wantPageClose) {
        _binding.register(context, {
          ShortcutAction.closeOverlay: () {
            if (context.mounted) Navigator.of(context).maybePop();
          },
        });
      } else {
        _binding.clear();
      }
    });
  }

  void dispose() => _binding.dispose();
}

enum ShortcutSurfaceKind { route, panel, overlay }

enum ShortcutSurfaceRepeatBehavior { toggle, dedupe, reveal, replace }

abstract final class ShortcutSurfaceIds {
  static const notifications = 'global.notifications';
  static const shortcutHelp = 'global.shortcutHelp';
  static const search = 'global.search';
  static const settings = 'global.settings';
  static const createTopic = 'global.createTopic';
  static const topicAiAssistant = 'topic.aiAssistant';
  static const topicJumpToPost = 'topic.jumpToPost';
  static const replyComposer = 'composer.reply';
  static const editComposer = 'composer.edit';
  static const postFlag = 'post.flag';
  static const postDeleteConfirm = 'post.deleteConfirm';
  static const imageLiftMenu = 'image.imageLiftMenu';
}

abstract final class ShortcutSurfaceActionSets {
  static const replyComposerTriggers = <ShortcutAction>{
    ShortcutAction.replyTopic,
    ShortcutAction.replyPost,
    ShortcutAction.quotePost,
  };

  static const globalRoutePassthrough = <ShortcutAction>{
    ShortcutAction.openSearch,
    ShortcutAction.openSettings,
    ShortcutAction.createTopic,
    ShortcutAction.showShortcutHelp,
  };
}

class ShortcutSurfaceConfig {
  const ShortcutSurfaceConfig({
    required this.id,
    required this.triggerAction,
    this.repeatActions = const <ShortcutAction>{},
    this.kind = ShortcutSurfaceKind.route,
    this.repeatBehavior = ShortcutSurfaceRepeatBehavior.dedupe,
    this.blocksShortcuts = true,
    this.passthroughActions = const <ShortcutAction>{},
  });

  final String id;
  final ShortcutAction triggerAction;
  final Set<ShortcutAction> repeatActions;
  final ShortcutSurfaceKind kind;
  final ShortcutSurfaceRepeatBehavior repeatBehavior;
  final bool blocksShortcuts;
  final Set<ShortcutAction> passthroughActions;
}

class ShortcutSurfaceRegistration {
  const ShortcutSurfaceRegistration({
    required this.owner,
    required this.id,
    required this.triggerAction,
    required this.repeatActions,
    required this.kind,
    required this.repeatBehavior,
    required this.blocksShortcuts,
    required this.passthroughActions,
    required this.order,
    this.route,
    this.onClose,
    this.onFocus,
    this.enabled,
  });

  final Object owner;
  final String id;
  final ShortcutAction triggerAction;
  final Set<ShortcutAction> repeatActions;
  final ShortcutSurfaceKind kind;
  final ShortcutSurfaceRepeatBehavior repeatBehavior;
  final bool blocksShortcuts;
  final Set<ShortcutAction> passthroughActions;
  final int order;
  final Route<dynamic>? route;
  final VoidCallback? onClose;
  final VoidCallback? onFocus;

  /// 活跃谓词,语义同 [ShortcutScopeRegistration.enabled]:IndexedStack
  /// 常驻 tab 页里的 surface(嵌入设置/嵌入搜索)共享根路由,切走 tab 后
  /// 不过滤会拦截活跃 tab 的按键。
  final bool Function()? enabled;

  bool get isEnabled => enabled?.call() ?? true;

  bool matchesAction(ShortcutAction action) {
    return triggerAction == action || repeatActions.contains(action);
  }

  bool allowsPassthrough(ShortcutAction action) {
    return passthroughActions.contains(action);
  }
}

class ShortcutSurfaceRegistryState {
  const ShortcutSurfaceRegistryState({this.registrations = const {}});

  final Map<Object, ShortcutSurfaceRegistration> registrations;
}

class ShortcutSurfaceRegistryNotifier
    extends StateNotifier<ShortcutSurfaceRegistryState> {
  ShortcutSurfaceRegistryNotifier()
    : super(const ShortcutSurfaceRegistryState());

  int _registrationOrder = 0;

  void register({
    required Object owner,
    required String id,
    required ShortcutAction triggerAction,
    Set<ShortcutAction> repeatActions = const <ShortcutAction>{},
    required ShortcutSurfaceKind kind,
    required ShortcutSurfaceRepeatBehavior repeatBehavior,
    required bool blocksShortcuts,
    Set<ShortcutAction> passthroughActions = const <ShortcutAction>{},
    Route<dynamic>? route,
    VoidCallback? onClose,
    VoidCallback? onFocus,
    bool Function()? enabled,
  }) {
    final next = Map<Object, ShortcutSurfaceRegistration>.from(
      state.registrations,
    );
    next.removeWhere(
      (existingOwner, registration) =>
          !identical(existingOwner, owner) &&
          registration.id == id &&
          identical(registration.route, route),
    );
    next[owner] = ShortcutSurfaceRegistration(
      owner: owner,
      id: id,
      triggerAction: triggerAction,
      repeatActions: Set.unmodifiable(repeatActions),
      kind: kind,
      repeatBehavior: repeatBehavior,
      blocksShortcuts: blocksShortcuts,
      passthroughActions: Set.unmodifiable(passthroughActions),
      route: route,
      onClose: onClose,
      onFocus: onFocus,
      enabled: enabled,
      order: ++_registrationOrder,
    );
    state = ShortcutSurfaceRegistryState(registrations: Map.unmodifiable(next));
  }

  void unregister({required Object owner}) {
    final next = Map<Object, ShortcutSurfaceRegistration>.from(
      state.registrations,
    );
    if (next.remove(owner) == null) return;
    state = ShortcutSurfaceRegistryState(registrations: Map.unmodifiable(next));
  }
}

final shortcutSurfaceRegistryProvider =
    StateNotifierProvider<
      ShortcutSurfaceRegistryNotifier,
      ShortcutSurfaceRegistryState
    >((ref) {
      return ShortcutSurfaceRegistryNotifier();
    });

ShortcutSurfaceRegistration? resolveTopShortcutSurface({
  required ShortcutSurfaceRegistryState registry,
  required Route<dynamic>? route,
}) {
  // isEnabled 过滤:非活跃 tab 里的 surface 不参与分发(见字段注释)。
  final registrations = registry.registrations.values
      .where((registration) => registration.isEnabled)
      .toList();
  if (registrations.isEmpty) return null;

  if (route != null) {
    final exactMatches = registrations
        .where((registration) => identical(registration.route, route))
        .toList();
    if (exactMatches.isNotEmpty) {
      exactMatches.sort((a, b) => a.order.compareTo(b.order));
      return exactMatches.last;
    }
  }

  final currentRouteMatches = registrations.where((registration) {
    final registrationRoute = registration.route;
    return registrationRoute != null && registrationRoute.isCurrent;
  }).toList();
  if (currentRouteMatches.isNotEmpty) {
    currentRouteMatches.sort((a, b) => a.order.compareTo(b.order));
    return currentRouteMatches.last;
  }

  final pendingRouteMatches = registrations.where((registration) {
    final registrationRoute = registration.route;
    return registrationRoute != null && registrationRoute.navigator == null;
  }).toList();
  if (pendingRouteMatches.isEmpty) return null;

  pendingRouteMatches.sort((a, b) => a.order.compareTo(b.order));
  return pendingRouteMatches.last;
}

ShortcutSurfaceRegistration? findLatestShortcutSurface({
  required ShortcutSurfaceRegistryState registry,
  required String id,
  ShortcutSurfaceKind? kind,
}) {
  final matches = registry.registrations.values.where((registration) {
    if (registration.id != id) return false;
    if (kind != null && registration.kind != kind) return false;
    // 非活跃 tab 里的 surface 不算"已存在":否则 Ctrl+, 之类的
    // push-or-reveal 会去 reveal 一个看不见的嵌入实例,表现为按了没反应。
    if (!registration.isEnabled) return false;

    final registrationRoute = registration.route;
    if (registrationRoute == null) return true;
    return registrationRoute.isActive || registrationRoute.navigator == null;
  }).toList();

  if (matches.isEmpty) return null;

  matches.sort((a, b) => a.order.compareTo(b.order));
  return matches.last;
}

class ShortcutSurfaceBinding {
  ShortcutSurfaceBinding({
    required WidgetRef ref,
    required this.id,
    required this.triggerAction,
    this.repeatActions = const <ShortcutAction>{},
    this.kind = ShortcutSurfaceKind.panel,
    this.repeatBehavior = ShortcutSurfaceRepeatBehavior.toggle,
    this.blocksShortcuts = true,
    this.passthroughActions = const <ShortcutAction>{},
    this.enabled,
  }) : _registry = ref.read(shortcutSurfaceRegistryProvider.notifier);

  final String id;
  final ShortcutAction triggerAction;
  final Set<ShortcutAction> repeatActions;
  final ShortcutSurfaceKind kind;
  final ShortcutSurfaceRepeatBehavior repeatBehavior;
  final bool blocksShortcuts;
  final Set<ShortcutAction> passthroughActions;

  /// 活跃谓词(见 [ShortcutSurfaceRegistration.enabled])。
  final bool Function()? enabled;

  final ShortcutSurfaceRegistryNotifier _registry;
  final Object _owner = Object();
  bool _disposed = false;
  bool _registered = false;
  int _deferredToken = 0;

  void _registerWithResolvedRoute(
    Route<dynamic>? route, {
    VoidCallback? onClose,
    VoidCallback? onFocus,
  }) {
    _registered = true;
    _registry.register(
      owner: _owner,
      id: id,
      triggerAction: triggerAction,
      repeatActions: repeatActions,
      kind: kind,
      repeatBehavior: repeatBehavior,
      blocksShortcuts: blocksShortcuts,
      passthroughActions: passthroughActions,
      route: route,
      onClose: onClose,
      onFocus: onFocus,
      enabled: enabled,
    );
  }

  void register(
    BuildContext context, {
    VoidCallback? onClose,
    VoidCallback? onFocus,
  }) {
    if (_disposed) return;
    _deferredToken++;
    _registerWithResolvedRoute(
      ModalRoute.of(context),
      onClose: onClose,
      onFocus: onFocus,
    );
  }

  void registerDeferred(
    BuildContext context, {
    VoidCallback? onClose,
    VoidCallback? onFocus,
  }) {
    if (_disposed) return;
    final token = ++_deferredToken;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || token != _deferredToken || !context.mounted) return;
      _registerWithResolvedRoute(
        ModalRoute.of(context),
        onClose: onClose,
        onFocus: onFocus,
      );
    });
  }

  void clear() {
    _deferredToken++;
    if (_disposed || !_registered) return;
    _registered = false;
    _registry.unregister(owner: _owner);
  }

  void clearDeferred() {
    if (_disposed) return;
    final token = ++_deferredToken;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || token != _deferredToken || !_registered) return;
      _registered = false;
      _registry.unregister(owner: _owner);
    });
  }

  void dispose() {
    if (_disposed) return;
    _deferredToken++;
    _disposed = true;
    if (_registered) {
      _registered = false;
      _registry.unregister(owner: _owner);
    }
  }

  void disposeDeferred() {
    if (_disposed) return;
    final token = ++_deferredToken;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || token != _deferredToken) return;
      dispose();
    });
  }
}

/// 当前活跃面板（决定 J/K 控制哪一侧）
final activePaneProvider = StateProvider<ActivePane>(
  (ref) => ActivePane.master,
);

/// 桌面端刷新信号（ValueNotifier，不依赖 Riverpod）
/// 页面在 initState/dispose 中 addListener/removeListener
final desktopRefreshNotifier = ValueNotifier<int>(0);

/// 桌面端主面板刷新信号
final masterRefreshNotifier = ValueNotifier<int>(0);

/// 桌面端详情面板刷新信号
final detailRefreshNotifier = ValueNotifier<int>(0);

/// 外部切换首页 tab 的信号（-1 表示无操作）
final switchTabProvider = StateProvider<int>((ref) => -1);

/// AI 面板切换信号
final toggleAiPanelNotifier = ValueNotifier<int>(0);

/// 键盘触发的面板切换信号（自增计数，HUD 监听变化来显示）
final paneSwitchSignalProvider = StateProvider<int>((ref) => 0);

/// Shift 组合键映射表：基础键 → Shift 后的键
final _shiftKeyMap = <LogicalKeyboardKey, LogicalKeyboardKey>{
  LogicalKeyboardKey.slash: LogicalKeyboardKey.question,
  LogicalKeyboardKey.digit1: LogicalKeyboardKey.exclamation,
  LogicalKeyboardKey.digit2: LogicalKeyboardKey.at,
  LogicalKeyboardKey.digit3: LogicalKeyboardKey.numberSign,
  LogicalKeyboardKey.semicolon: LogicalKeyboardKey.colon,
  LogicalKeyboardKey.equal: LogicalKeyboardKey.add,
  LogicalKeyboardKey.minus: LogicalKeyboardKey.underscore,
  LogicalKeyboardKey.bracketLeft: LogicalKeyboardKey.braceLeft,
  LogicalKeyboardKey.bracketRight: LogicalKeyboardKey.braceRight,
  LogicalKeyboardKey.backslash: LogicalKeyboardKey.bar,
  LogicalKeyboardKey.quote: LogicalKeyboardKey.quoteSingle,
  LogicalKeyboardKey.comma: LogicalKeyboardKey.less,
  LogicalKeyboardKey.period: LogicalKeyboardKey.greater,
  LogicalKeyboardKey.backquote: LogicalKeyboardKey.tilde,
};

/// 基础键 → Shift 后的字符（用于 character 级别匹配）
const _shiftCharMap = <String, String>{
  '/': '?',
  '1': '!',
  '2': '@',
  '3': '#',
  ';': ':',
  '=': '+',
  '-': '_',
  '[': '{',
  ']': '}',
  '\\': '|',
  ',': '<',
  '.': '>',
  '`': '~',
};

/// 将 KeyEvent 与 SingleActivator 进行匹配
bool matchKeyEvent(KeyEvent event, SingleActivator activator) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

  final eventKey = event.logicalKey;
  final triggerKey = activator.trigger;
  final keyboard = HardwareKeyboard.instance;

  // 非 shift 修饰键必须严格匹配
  if (activator.control != keyboard.isControlPressed) return false;
  if (activator.alt != keyboard.isAltPressed) return false;
  if (activator.meta != keyboard.isMetaPressed) return false;

  // 情况 1：逻辑键直接匹配 → shift 也必须严格匹配
  if (eventKey == triggerKey) {
    return activator.shift == keyboard.isShiftPressed;
  }

  // 情况 2：Shift 变体——通过 LogicalKeyboardKey 映射匹配（仅 binding 要求 shift）
  if (activator.shift) {
    if (_shiftKeyMap[triggerKey] == eventKey) return true;
    if (_shiftKeyMap[eventKey] == triggerKey && keyboard.isShiftPressed) {
      return true;
    }
  }

  // 情况 3：最终兜底——用事件的实际字符匹配
  // 解决各平台对 Shift+键 报告的 logicalKey 不一致的问题
  if (event is KeyDownEvent && event.character != null) {
    final char = event.character!;
    final triggerLabel = triggerKey.keyLabel;

    if (activator.shift) {
      // binding 要求 shift：检查字符是否是 trigger 的 shifted 版本
      final shiftedChar = _shiftCharMap[triggerLabel.toLowerCase()];
      if (shiftedChar != null && shiftedChar == char) return true;
    } else {
      // binding 不要求 shift：字符必须精确匹配且 shift 未按下
      if (triggerLabel.toLowerCase() == char.toLowerCase() &&
          !keyboard.isShiftPressed) {
        return true;
      }
    }
  }

  return false;
}
