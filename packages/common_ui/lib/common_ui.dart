/// 应用内通用 UI 组件库。
///
/// 目前提供:
/// - 支持滑动关闭、缩放/链式关闭等交互的弹出菜单封装,替代原生
///   [PopupMenuButton] / showMenu,统一全局菜单交互;
/// - [GlassSurface]:柔光玻璃材质(局部背景折射、边缘光与色散),
///   按 [GlassRecipe] 按阅读密度分级的场景配方使用。
/// - [DesktopScrollInteractionBehavior] 与 [DesktopScrollInteractionBinding]:
///   统一桌面滚动期间的控件点击，接入应用入口即可覆盖后代滚动容器。
/// - [KeyboardInsetIsolation]、[RouteMotionHoldMixin]、[AppLoadingSwitcher]:
///   后台键盘隔离、转场期间延后展示更新、短加载防闪烁。
library;

export 'src/app_content_state.dart' show AppEmptyState, AppLoadingSwitcher;
export 'src/app_sheet_scaffold.dart';
export 'src/dismissible_popup_menu.dart';
export 'src/desktop_scroll_interaction.dart';
export 'src/glass_settings.dart';
export 'src/glass_surface.dart';
export 'src/glass_surface_frame.dart';
export 'src/interaction_gate.dart';
export 'src/route_interaction.dart';
export 'src/predictive_back_cupertino_transitions.dart';
export 'src/keyboard_inset_isolation.dart';
export 'src/route_motion_hold.dart';
