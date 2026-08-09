import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';

import '../l10n/s.dart';

/// 底栏导航快捷动作总线
///
/// 底栏点击已选中的 tab 时，由底栏组件按用户偏好派发动作到总线。
/// 目标页面（TopicsScreen / ProfilePage）按 id 监听 [navActionBusProvider] 执行实际动作。
///
/// 分层原因：页面各自维护自己的 ScrollController / 刷新逻辑，底栏不关心细节；
/// 总线保证底栏和页面解耦。

/// 派发到页面的实际动作
enum NavAction {
  scrollToTop,
  refresh,
}

/// 用户可为单击 / 双击配置的动作（含"无"选项）
///
/// 比 [NavAction] 多出 [none]——用户主动把某个手势关掉时使用。
/// 未来扩展通知 / 搜索 / 发帖等面板型动作时加到这里。
enum NavTapAction {
  none,
  scrollToTop,
  refresh,
}

extension NavTapActionX on NavTapAction {
  /// 转换为实际派发的 [NavAction]；[none] 返回 null 表示不派发。
  NavAction? toNavAction() {
    switch (this) {
      case NavTapAction.none:
        return null;
      case NavTapAction.scrollToTop:
        return NavAction.scrollToTop;
      case NavTapAction.refresh:
        return NavAction.refresh;
    }
  }

  /// 对应的反馈图标。用于底栏已选中 tab 滚离顶部时做图标替换。
  /// [none] 没有图标，因为不会切换。
  IconData? get icon {
    switch (this) {
      case NavTapAction.none:
        return null;
      case NavTapAction.scrollToTop:
        return Symbols.keyboard_double_arrow_up_rounded;
      case NavTapAction.refresh:
        return Symbols.refresh_rounded;
    }
  }

  /// 本地化标签。用于设置页 picker 和副标题。
  /// 不依赖 BuildContext，方便在 defs 中通过 `S.current` 访问。
  String get label {
    final l10n = S.current;
    switch (this) {
      case NavTapAction.none:
        return l10n.navTapAction_none;
      case NavTapAction.scrollToTop:
        return l10n.navTapAction_scrollToTop;
      case NavTapAction.refresh:
        return l10n.navTapAction_refresh;
    }
  }

  /// 持久化的稳定字符串（enum.name 会随 refactor 改变，显式 switch 更稳）
  String toStorageKey() {
    switch (this) {
      case NavTapAction.none:
        return 'none';
      case NavTapAction.scrollToTop:
        return 'scroll_to_top';
      case NavTapAction.refresh:
        return 'refresh';
    }
  }

  static NavTapAction fromStorageKey(
    String? key, {
    NavTapAction fallback = NavTapAction.scrollToTop,
  }) {
    switch (key) {
      case 'none':
        return NavTapAction.none;
      case 'scroll_to_top':
        return NavTapAction.scrollToTop;
      case 'refresh':
        return NavTapAction.refresh;
      default:
        return fallback;
    }
  }
}

/// 一次派发的动作事件
///
/// [nonce] 单调递增，保证连续两次相同事件也能被 Riverpod 监听捕获
/// （StateProvider 会对 == 相等的新旧值去重，nonce 让事件永远不等）。
class NavActionEvent {
  final String targetId;
  final NavAction action;
  final int nonce;

  const NavActionEvent({
    required this.targetId,
    required this.action,
    required this.nonce,
  });
}

/// 内部递增计数器
final _navActionNonceProvider = StateProvider<int>((ref) => 0);

/// 动作事件总线。页面通过 `ref.listen(navActionBusProvider, ...)` 订阅。
final navActionBusProvider = StateProvider<NavActionEvent?>((ref) => null);

/// 外部入口请求切换到某个稳定导航项。
///
/// 不能复用按数字下标切换的 [switchTabProvider]：底栏允许用户重排，首页
/// 并不永远是第 0 个 page。通知、深链等入口应按 [NavEntryIds] 请求。
class NavDestinationRequest {
  const NavDestinationRequest({required this.targetId, required this.nonce});

  final String targetId;
  final int nonce;
}

final navDestinationRequestProvider =
    StateProvider<NavDestinationRequest?>((ref) => null);

/// 派发入口
extension NavActionDispatch on WidgetRef {
  void dispatchNavAction(String targetId, NavAction action) {
    final next = read(_navActionNonceProvider) + 1;
    read(_navActionNonceProvider.notifier).state = next;
    read(navActionBusProvider.notifier).state = NavActionEvent(
      targetId: targetId,
      action: action,
      nonce: next,
    );
  }

  void requestNavDestination(String targetId) {
    final next = read(_navActionNonceProvider) + 1;
    read(_navActionNonceProvider.notifier).state = next;
    read(navDestinationRequestProvider.notifier).state = NavDestinationRequest(
      targetId: targetId,
      nonce: next,
    );
  }
}

/// 每个 tab 的"距顶距离"（单位：像素）。页面按 id 更新，底栏 watch 用来切换图标。
///
/// 原始像素数而非归一化 0-1，便于统一阈值在 [navScrollIconThreshold]。
final navScrollProgressProvider =
    StateProvider.family<double, String>((ref, id) => 0.0);

/// 底栏已选中 tab 的图标切换阈值（像素）
///
/// 滚动距顶 ≥ 此值时显示单击动作图标（↑ / ⟳），否则保持原 selectedIcon。
/// 选 1000 让用户必须滚得比较深才会看到反馈，避免短滚动就抖动切换。
const double navScrollIconThreshold = 1000.0;

/// 显式重置某个 entry 的滚动进度为 0
///
/// 用于 refresh 动作后：刷新会替换 ListView 数据，内部 `correctPixels`
/// 不会 fire ScrollNotification，[navScrollProgressProvider] 拿不到
/// 实际已经 0 的事实，底栏图标会错误地停在"动作态"。
extension NavScrollProgressReset on WidgetRef {
  void resetNavScrollProgress(String id) {
    final current = read(navScrollProgressProvider(id));
    if (current == 0) return;
    read(navScrollProgressProvider(id).notifier).state = 0.0;
  }
}

/// 已注册的 entry id。未来扩展时加到这里。
class NavEntryIds {
  NavEntryIds._();

  static const String home = 'home';
  static const String profile = 'profile';
  static const String bookmarks = 'bookmarks';
  static const String history = 'history';
  static const String drafts = 'drafts';
  static const String notifications = 'notifications';
  static const String messages = 'messages';
  static const String chat = 'chat';
  static const String seeking = 'seeking';
}
