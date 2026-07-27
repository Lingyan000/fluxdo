import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxdo_render/editor.dart' show FluxdoEditor;

import '../models/shortcut_binding.dart';
import '../pages/create_topic_page.dart';
import '../pages/search_page.dart';
import '../providers/topic_list/tab_state_provider.dart';
import '../pages/settings_page.dart';
import '../providers/shortcut_provider.dart';
import '../utils/dialog_utils.dart';
import '../utils/platform_utils.dart';
import 'notification/notification_quick_panel.dart';
import 'shortcut_help_overlay.dart';

enum _ShortcutSurfaceDispatch { pass, handled, blocked }

/// 全局键盘快捷键处理器
///
/// 使用 [HardwareKeyboard] 直接监听按键事件，不依赖 Flutter 焦点系统，
/// 确保快捷键在任何交互状态下都能触发。
class KeyboardShortcutHandler extends ConsumerStatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  const KeyboardShortcutHandler({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  @override
  ConsumerState<KeyboardShortcutHandler> createState() =>
      _KeyboardShortcutHandlerState();
}

class _KeyboardShortcutHandlerState
    extends ConsumerState<KeyboardShortcutHandler> {
  @override
  void initState() {
    super.initState();
    if (PlatformUtils.isDesktop) {
      HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    }
  }

  @override
  void dispose() {
    if (PlatformUtils.isDesktop) {
      HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    }
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    final focusInTextInput = _isFocusInTextInput();
    final bindings = ref.read(shortcutProvider);

    for (final binding in bindings) {
      if (!matchKeyEvent(event, binding.activator)) continue;
      // 文本输入期间仍允许单次 Esc 关闭当前页内状态；其余快捷键继续
      // 让给输入法，避免 J/K 等可打印字符被全局动作抢走。
      if (focusInTextInput &&
          (event is! KeyDownEvent ||
              event.logicalKey != LogicalKeyboardKey.escape ||
              binding.action != ShortcutAction.closeOverlay)) {
        continue;
      }

      final surfaceDispatch = _handleSurfaceBeforeDispatch(binding.action);
      if (surfaceDispatch == _ShortcutSurfaceDispatch.handled ||
          surfaceDispatch == _ShortcutSurfaceDispatch.blocked) {
        return true;
      }

      // 先尝试上下文回调（J/K/Enter 等页面级动作）
      final callback = _resolveContextCallback(binding.action);
      if (callback != null) {
        callback();
        return true;
      }

      // 全局动作
      final handled = _handleGlobalAction(binding.action);
      if (handled) return true;
    }

    return false;
  }

  _ShortcutSurfaceDispatch _handleSurfaceBeforeDispatch(ShortcutAction action) {
    final currentRoute = _currentTopRoute();
    if (currentRoute == null) return _ShortcutSurfaceDispatch.pass;

    final registry = ref.read(shortcutSurfaceRegistryProvider);
    final topSurface = resolveTopShortcutSurface(
      registry: registry,
      route: currentRoute,
    );
    if (topSurface != null) {
      if (_isCloseSurfaceAction(action)) {
        _closeSurface(topSurface, fallbackRoute: currentRoute);
        return _ShortcutSurfaceDispatch.handled;
      }

      if (topSurface.matchesAction(action)) {
        switch (topSurface.repeatBehavior) {
          case ShortcutSurfaceRepeatBehavior.toggle:
            _closeSurface(topSurface, fallbackRoute: currentRoute);
            return _ShortcutSurfaceDispatch.handled;
          case ShortcutSurfaceRepeatBehavior.dedupe:
          case ShortcutSurfaceRepeatBehavior.reveal:
            topSurface.onFocus?.call();
            return _ShortcutSurfaceDispatch.handled;
          case ShortcutSurfaceRepeatBehavior.replace:
            _closeSurface(topSurface, fallbackRoute: currentRoute);
            return _ShortcutSurfaceDispatch.pass;
        }
      }

      if (topSurface.allowsPassthrough(action)) {
        return _ShortcutSurfaceDispatch.pass;
      }

      if (topSurface.blocksShortcuts) {
        return _ShortcutSurfaceDispatch.blocked;
      }
    }

    if (currentRoute is PopupRoute && !currentRoute.isFirst) {
      if (_isCloseSurfaceAction(action)) {
        widget.navigatorKey.currentState?.maybePop();
        return _ShortcutSurfaceDispatch.handled;
      }
      return _ShortcutSurfaceDispatch.blocked;
    }

    return _ShortcutSurfaceDispatch.pass;
  }

  bool _isCloseSurfaceAction(ShortcutAction action) {
    return action == ShortcutAction.closeOverlay ||
        action == ShortcutAction.navigateBack ||
        action == ShortcutAction.navigateBackAlt;
  }

  void _closeSurface(
    ShortcutSurfaceRegistration surface, {
    required Route<dynamic> fallbackRoute,
  }) {
    final onClose = surface.onClose;
    if (onClose != null) {
      onClose();
      return;
    }

    if (fallbackRoute is PopupRoute) {
      widget.navigatorKey.currentState?.maybePop();
    }
  }

  /// 根据活跃面板解析上下文回调
  VoidCallback? _resolveContextCallback(ShortcutAction action) {
    final currentRoute = _currentTopRoute();
    if (currentRoute == null) return null;
    final registry = ref.read(shortcutScopeRegistryProvider);

    // 1. 单栏模式的上下文回调（优先级最高，全屏详情页等）
    final singlePane = resolveShortcutScopeCallbacks(
      registry: registry,
      scope: ShortcutScope.context,
      route: currentRoute,
    );
    if (singlePane.containsKey(action)) {
      return singlePane[action];
    }

    // 2. 双栏模式：仅查找活跃面板的回调，不回退到另一面板
    final activePane = ref.read(activePaneProvider);
    final activeCallbacks = resolveShortcutScopeCallbacks(
      registry: registry,
      scope: activePane == ActivePane.master
          ? ShortcutScope.master
          : ShortcutScope.detail,
      route: currentRoute,
    );
    if (activeCallbacks.containsKey(action)) {
      return activeCallbacks[action];
    }

    // 3. 「关闭/返回」再兜另一侧面板:平行视界的层级是**全局**的,不该
    //    取决于用户点没点过右栏。只有点开话题、没点过右栏(activePane
    //    仍是 master)时按 Esc 毫无反应,就是漏了这一步。
    //    只对关闭类动作放开 —— J/K/回复这类必须严格跟随活跃面板。
    if (_isCloseSurfaceAction(action)) {
      final otherCallbacks = resolveShortcutScopeCallbacks(
        registry: registry,
        scope: activePane == ActivePane.master
            ? ShortcutScope.detail
            : ShortcutScope.master,
        route: currentRoute,
      );
      if (otherCallbacks.containsKey(action)) {
        return otherCallbacks[action];
      }
    }

    return null;
  }

  bool _handleGlobalAction(ShortcutAction action) {
    final nav = widget.navigatorKey.currentState;
    if (nav == null) return false;
    final navContext = widget.navigatorKey.currentContext ?? nav.context;

    switch (action) {
      case ShortcutAction.navigateBack:
      case ShortcutAction.navigateBackAlt:
        nav.maybePop();
        return true;
      case ShortcutAction.openSearch:
        return _pushOrRevealRoute(
          context: navContext,
          route: MaterialPageRoute(
            settings: const RouteSettings(name: 'search'),
            builder: (_) => const SearchPage(),
          ),
          shortcutSurface: const ShortcutSurfaceConfig(
            id: ShortcutSurfaceIds.search,
            triggerAction: ShortcutAction.openSearch,
            repeatBehavior: ShortcutSurfaceRepeatBehavior.reveal,
            passthroughActions:
                ShortcutSurfaceActionSets.globalRoutePassthrough,
          ),
        );
      case ShortcutAction.openSettings:
        return _pushOrRevealRoute(
          context: navContext,
          route: MaterialPageRoute(
            settings: const RouteSettings(name: 'settings'),
            builder: (_) => const SettingsPage(),
          ),
          shortcutSurface: const ShortcutSurfaceConfig(
            id: ShortcutSurfaceIds.settings,
            triggerAction: ShortcutAction.openSettings,
            repeatBehavior: ShortcutSurfaceRepeatBehavior.reveal,
            passthroughActions:
                ShortcutSurfaceActionSets.globalRoutePassthrough,
          ),
        );
      case ShortcutAction.refresh:
        final activePane = ref.read(activePaneProvider);
        if (activePane == ActivePane.detail) {
          detailRefreshNotifier.value++;
        } else {
          masterRefreshNotifier.value++;
        }
        desktopRefreshNotifier.value++;
        return true;
      case ShortcutAction.showShortcutHelp:
        if (navContext.mounted) {
          showShortcutHelpOverlay(navContext, ref);
          return true;
        }
        return false;
      case ShortcutAction.switchPane:
        final current = ref.read(activePaneProvider);
        ref
            .read(activePaneProvider.notifier)
            .state = current == ActivePane.master
            ? ActivePane.detail
            : ActivePane.master;
        // 触发 HUD 信号（仅键盘切换时）
        ref.read(paneSwitchSignalProvider.notifier).update((v) => v + 1);
        return true;
      case ShortcutAction.toggleNotifications:
        if (navContext.mounted) {
          NotificationQuickPanel.show(navContext);
        }
        return true;
      case ShortcutAction.switchToTopics:
        ref.read(switchTabProvider.notifier).state = 0;
        return true;
      case ShortcutAction.switchToProfile:
        ref.read(switchTabProvider.notifier).state = 1;
        return true;
      case ShortcutAction.createTopic:
        return _pushOrRevealRoute(
          context: navContext,
          route: MaterialPageRoute(
            builder: (_) => CreateTopicPage(
              initialCategoryId: ref.read(currentTabCategoryIdProvider),
            ),
          ),
          shortcutSurface: const ShortcutSurfaceConfig(
            id: ShortcutSurfaceIds.createTopic,
            triggerAction: ShortcutAction.createTopic,
            repeatBehavior: ShortcutSurfaceRepeatBehavior.reveal,
            passthroughActions:
                ShortcutSurfaceActionSets.globalRoutePassthrough,
          ),
        );
      case ShortcutAction.closeOverlay:
        // ESC 全局兜底:没有更具体的 surface/scope 回调接手时,对根
        // Navigator 栈顶做一次受 canPop 保护的 maybePop。覆盖 drafts/
        // login/设置子页(窄屏全屏态)这类"普通全屏路由没自注册 ESC"
        // 的死角,一处兜底优于逐页补注册(新页漏注册就复发)。
        // 安全边界:
        // - canPop 守卫必不可省 —— home 根路由挂着 PopScope(canPop:false,
        //   双击退出),无脑 maybePop 会让 ESC 弹"再按一次退出"甚至退 App;
        //   home 是 isFirst,canPop()==false,直接跳过;
        // - 嵌入页结构上不可能是"可 pop 的根栈顶"(widget 级嵌入时根栈
        //   顶是 home;嵌套 Navigator 嵌入时 settings 路由带 surface,在
        //   _handleSurfaceBeforeDispatch 已被拦下),不会捅穿;
        // - maybePop 尊重 PopScope,webview 等 canPop:false 页不受影响;
        // - 已自注册 closeOverlay 的页(topic_detail/user_profile/书签)
        //   在派发顺序上先于这里,兜底只兜"没人管"的页。
        final nav = Navigator.maybeOf(navContext, rootNavigator: true);
        if (nav != null && nav.canPop()) {
          nav.maybePop();
          return true;
        }
        return false;
      case ShortcutAction.nextItem:
      case ShortcutAction.previousItem:
      case ShortcutAction.openItem:
      case ShortcutAction.previousTab:
      case ShortcutAction.nextTab:
      case ShortcutAction.jumpToPost:
      case ShortcutAction.goToUnreadPost:
      case ShortcutAction.replyTopic:
      case ShortcutAction.shareTopic:
      case ShortcutAction.bookmarkTopic:
      case ShortcutAction.replyPost:
      case ShortcutAction.quotePost:
      case ShortcutAction.likePost:
      case ShortcutAction.sharePost:
      case ShortcutAction.bookmarkPost:
      case ShortcutAction.editPost:
      case ShortcutAction.flagPost:
      case ShortcutAction.deletePost:
        return false;
      case ShortcutAction.toggleAiPanel:
        toggleAiPanelNotifier.value++;
        return true;
    }
  }

  bool _pushOrRevealRoute({
    required BuildContext context,
    required Route<dynamic> route,
    required ShortcutSurfaceConfig shortcutSurface,
  }) {
    final registry = ref.read(shortcutSurfaceRegistryProvider);
    final existingSurface = findLatestShortcutSurface(
      registry: registry,
      id: shortcutSurface.id,
      kind: ShortcutSurfaceKind.route,
    );

    if (existingSurface != null) {
      existingSurface.onFocus?.call();
      return true;
    }

    pushAppRoute<dynamic>(
      context: context,
      route: route,
      shortcutSurface: shortcutSurface,
    );
    return true;
  }

  Route<dynamic>? _currentTopRoute() {
    final nav = widget.navigatorKey.currentState;
    if (nav == null) return null;

    Route<dynamic>? currentRoute;
    nav.popUntil((route) {
      if (route.isCurrent) {
        currentRoute = route;
      }
      return true;
    });
    return currentRoute;
  }

  /// 检查焦点是否在文本输入框中
  bool _isFocusInTextInput() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus?.context == null) return false;
    var element = focus!.context! as Element;
    var found = false;
    element.visitAncestorElements((ancestor) {
      // FluxdoEditor:自研富文本编辑器(非 EditableText,自己的
      // TextInputClient)—— 不豁免的话 j/k/d/s 等单键快捷键把字母
      // 抢走并标记 handled,嵌入层不再路由给 IME,字母打不出来。
      if (ancestor.widget is EditableText || ancestor.widget is FluxdoEditor) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
