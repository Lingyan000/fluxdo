import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 导航入口类型
enum NavEntryKind {
  /// 嵌入 IndexedStack 作为 tab，保留滚动位置 / 状态
  page,

  /// 点击时弹出快速面板（通知、私信 peek 等）—— 阶段 B 使用
  panel,

  /// 点击触发一次性动作（弹对话框、打开外链等）
  action,
}

/// 导航入口描述
///
/// 注册表 [NavEntryRegistry] 统一管理所有候选 entry；
/// 用户偏好 `bottomNavIds` 决定哪些出现在底栏以及顺序。
class NavEntry {
  const NavEntry({
    required this.id,
    required this.kind,
    required this.iconData,
    required this.selectedIconData,
    required this.label,
    this.pageBuilder,
    this.onPanelTap,
    this.onAction,
    this.requiresLogin = false,
    this.locked = false,
    this.defaultInBottomNav = false,
    this.customIconBuilder,
    this.customSelectedIconBuilder,
  });

  /// 稳定 id（home / profile / bookmarks / history / drafts / ...）
  final String id;

  /// 入口类型
  final NavEntryKind kind;

  /// 默认未选中图标
  final IconData iconData;

  /// 默认选中图标
  final IconData selectedIconData;

  /// 标签文案（依赖 l10n 所以通过 BuildContext 取）
  final String Function(BuildContext) label;

  /// [NavEntryKind.page] 使用：构造嵌入到 IndexedStack 的页面内容
  /// - [isActive] 表示这是否为当前活跃 tab，供页面内部按需响应（如懒加载引导）
  final Widget Function(BuildContext context, bool isActive)? pageBuilder;

  /// [NavEntryKind.panel] 使用：点击时弹出快速面板（不切 tab）
  final void Function(BuildContext context, WidgetRef ref)? onPanelTap;

  /// [NavEntryKind.action] 使用：点击后执行的动作
  final void Function(BuildContext context, WidgetRef ref)? onAction;

  /// 需要登录才可见 / 可添加
  final bool requiresLogin;

  /// 不可从底栏移除（home、profile 等必备入口）
  final bool locked;

  /// 首次使用 / 重置时是否自动加入底栏
  final bool defaultInBottomNav;

  /// 可选：自定义未选中图标渲染（如用户头像）。优先于 [iconData]。
  final Widget Function(BuildContext, WidgetRef)? customIconBuilder;

  /// 可选：自定义选中图标渲染
  final Widget Function(BuildContext, WidgetRef)? customSelectedIconBuilder;
}
