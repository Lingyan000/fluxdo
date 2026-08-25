import 'package:flutter/material.dart';

import '../../utils/platform_utils.dart';

/// 全局焦点守卫:压掉"关掉浮层后键盘自己弹出来"。
///
/// Flutter 的 ModalRoute 被覆盖时会记住自己那棵子树里的焦点节点,
/// pop 回来原样恢复。移动端上"失焦"和"收键盘"是两件解耦的事——
/// 手势/返回键收键盘并不清焦点,所以"键盘早收了、焦点还挂在输入框
/// 上"是常态。这时长按弹菜单再取消,恢复焦点就等于凭空弹出键盘
/// (用户点名:聊天长按菜单最明显,别处也有)。
///
/// 对策:push 浮层的那一刻,若键盘并没有在显示,就顺手把焦点摘掉,
/// 让 pop 回来时无可恢复。键盘正开着时不动——打字打到一半弹个菜单,
/// 关掉后还回键盘才是对的。
///
/// 桌面端整体跳过:那里焦点还承担 Tab 导航,且没有"焦点=键盘"的绑定。
class KeyboardFocusGuard extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    if (PlatformUtils.isDesktop) return;
    // 首屏入栈:底下没有页面,也就没有"待恢复的焦点"这回事
    if (previousRoute == null) return;
    if (_keyboardVisible) return;
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return;
    // 键盘位表情面板态:输入框 readOnly 持焦点、键盘从未显示。摘掉它
    // 会让 ChatBottomPanelContainer 把"焦点丢失"当"收面板"信号,表情
    // 面板被连带关掉(回归审查发现);而 readOnly 输入框恢复焦点也不弹
    // 键盘——无需摘,跳过
    if (_focusOnReadOnlyInput(focus.context)) return;
    focus.unfocus();
  }

  /// 焦点是否落在只读输入框上(表情面板态)。
  ///
  /// primaryFocus.context 是 TextField 传给 EditableText 的 focusNode 所
  /// 挂的 Focus 节点,**在 EditableText 内部**——EditableText 是它的祖先,
  /// 得向上找。之前向下遍历子树永远找不到,readOnly 保护失效,长按消息
  /// 弹菜单会把表情面板连带关掉(用户点名:图标停在键盘、面板已关)。
  static bool _focusOnReadOnlyInput(BuildContext? context) {
    if (context == null) return false;
    return context.findAncestorWidgetOfExactType<EditableText>()?.readOnly ==
        true;
  }

  /// 键盘是否正占着屏幕。收起动画没走完时 viewInsets 仍 >0,
  /// 会被算作"显示中"——宁可漏摘一次焦点,也别打断真在打字的人。
  static bool get _keyboardVisible {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    return (view?.viewInsets.bottom ?? 0) > 0;
  }
}

/// 全局单例(与 appRouteObserver 同风格):navigatorObservers 是
/// 在 MaterialApp 的 build 里给的,每次重建都 new 一个会让 Navigator
/// 反复 detach/attach observer。
final KeyboardFocusGuard keyboardFocusGuard = KeyboardFocusGuard();
