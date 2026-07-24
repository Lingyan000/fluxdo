/// Material 3 Expressive 组件库。
///
/// 收口应用内所有 M3E 风格控件与运动规格:
/// - [M3eFlags]:全局开关(ThemeExtension),关闭时组件回退经典形态;
/// - [M3eMotion]:M3E motion scheme 的六档弹簧 token 与解析解曲线工具;
/// - [LoadingSpinner]:LoadingIndicator(不定态)的 1:1 复刻;
/// - [M3eLinearProgress]:wavy 线性进度条(确定态 + 不定态);
/// - [M3eCircularProgress]:wavy 圆形进度环(确定态);
/// - [M3eRefreshIndicator]:M3E 下拉刷新(LoadingSpinner 表现层);
/// - [M3eButtonGroup]:联排按钮组(按压展宽/邻项挤压);
/// - [M3eFabMenu]:FAB 菜单(stagger 入场 + FAB 收圆变形);
/// - [SegmentedCardGroup]:M3E 分段卡片列表。
library;

export 'src/loading_spinner.dart';
export 'src/m3e_button_group.dart';
export 'src/m3e_circular_progress.dart';
export 'src/m3e_fab_menu.dart';
export 'src/m3e_flags.dart';
export 'src/m3e_linear_progress.dart';
export 'src/m3e_motion.dart';
export 'src/m3e_navigation_bar.dart';
export 'src/m3e_refresh_indicator.dart';
export 'src/segmented_card_group.dart';
