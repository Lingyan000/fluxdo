/// 全局导航底盘(Rail)的「应占宽」记账。
///
/// 平行视界的双栏判定([MasterDetailLayout.canShowBothPanesFor])早年按
/// **整窗宽**比阈值,但宽屏实际内容区 = 窗宽 − Rail 宽:窗宽 780~852
/// 区间「判定说能双栏、实际空间不够」,左栏被压到 240px 挤压带。判定轴
/// 必须与分配轴同轴——比阈值前先扣掉 Rail 应占宽。
///
/// 取「应占宽」而非「当前可见宽」:hideNavigationRail(深层平行视界临时
/// 隐藏)依赖 isStacked,若判定读它会成环——pop 一层→Rail 回来→宽度
/// 不够→塌成投影→isStacked 变化→Rail 又走,模式翻转振荡。应占宽只由
/// 窗宽断点(Responsive.showNavigationRail)与 Rail 形态决定,与栈状态
/// 无关,判定稳定。
///
/// 由 AdaptiveScaffold 每次 build 写入(仿 LayoutLock 的静态记账先例);
/// canShowBothPanesFor 是 static(context) 签名、部分调用方无 ref
/// (notification_navigation / main.dart 剪贴板),走静态类而非 provider。
class NavChromeMetrics {
  NavChromeMetrics._();

  /// Rail 当前形态的宽度(展开 180 / 常规 72),由 AdaptiveScaffold 维护。
  static double railWidth = 72.0;

  /// 「应占宽」:窗宽达到 Rail 断点(非 mobile)即认为 Rail 占位,
  /// 无论它此刻是否被 hideNavigationRail 临时藏起。
  /// 全屏路由上下文里同样扣(语义=「回到 tab 形态能否双栏」),判定
  /// 口径全局唯一无分支。
  static double reservedWidth({required bool showRailByBreakpoint}) {
    return showRailByBreakpoint ? railWidth : 0.0;
  }
}
