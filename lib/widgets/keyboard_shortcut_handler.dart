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
      // IME 组字中（拼音候选未上屏）Esc 的语义是"取消候选"，必须放行
      // 给输入法，绝不能当 closeOverlay 消费。
      if (focusInTextInput &&
          (event is! KeyDownEvent ||
              event.logicalKey != LogicalKeyboardKey.escape ||
              binding.action != ShortcutAction.closeOverlay ||
              _isImeComposingAtFocus())) {
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

    // 2. 双栏模式：仅查找活跃面板的回调（closeOverlay 的回退例外见下）
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

    // 3. 例外：closeOverlay 在 master 侧回退到 detail。master 列表只注册
    //    J/K/Enter 之类导航动作,没有 closeOverlay——焦点在左栏时按 Esc
    //    落空会显得"失灵",用户直觉是关掉右侧详情。仅 closeOverlay 回退,
    //    导航动作仍严格按活跃面板分发,不越界。右栏无选中时 detail 无
    //    注册,回退落空,维持原空操作。
    if (action == ShortcutAction.closeOverlay &&
        activePane == ActivePane.master) {
      final detailCallbacks = resolveShortcutScopeCallbacks(
        registry: registry,
        scope: ShortcutScope.detail,
        route: currentRoute,
      );
      if (detailCallbacks.containsKey(action)) {
        return detailCallbacks[action];
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
  /// 焦点编辑器是否正处于 IME 组字（候选词未上屏）。
  ///
  /// Windows 引擎会把合规 IME 组字期间消费的按键标成 VK_PROCESSKEY 并
  /// 直接吞掉（engine keyboard_key_embedder_handler.cc），这类 Esc 根本
  /// 到不了框架层；这里兜的是不合规输入法把组字中的 Esc 原样放行的
  /// 场景。组字取消后（composing 区间清空）下一次 Esc 才恢复关闭语义。
  bool _isImeComposingAtFocus() {
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    if (context == null) return false;
    var composing = false;
    (context as Element).visitAncestorElements((ancestor) {
      final w = ancestor.widget;
      if (w is EditableText) {
        final range = w.controller.value.composing;
        composing = range.isValid && !range.isCollapsed;
        return false;
      }
      if (w is FluxdoEditor) {
        composing = w.state.hasComposing;
        return false;
      }
      return true;
    });
    return composing;
  }

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
