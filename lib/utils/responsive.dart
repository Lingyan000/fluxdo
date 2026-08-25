import 'package:flutter/widgets.dart';
import 'layout_lock.dart';

/// 响应式布局断点
class Breakpoints {
  Breakpoints._();

  /// 手机最大宽度
  static const double mobile = 600;

  /// 平板最大宽度
  static const double tablet = 1200;

  /// 内容最大宽度（用于限制帖子等内容的宽度）
  static const double maxContentWidth = 800;
}

/// 平行视界(双栏)各宿主的栏宽契约,全项目唯一出处。
///
/// 双栏触发阈值 = master + minDetail(再扣 Rail 应占宽,见
/// NavChromeMetrics)。数值是内容驱动的:列表卡片/标题排版决定列表栏
/// 可读宽度,不强行统一成一个数,但必须收口在这里——散落各页的魔数
/// 是「多套断点并存」混乱的根源。
class PaneBreakpoints {
  PaneBreakpoints._();

  /// 默认(首页/私信/草稿/我的话题/浏览历史):380 + 400。
  static const double masterWidth = 380;
  static const double minDetailWidth = 400;

  /// 宽列表宿主(搜索/追觅):结果卡带摘要,440 + 480。
  static const double wideMasterWidth = 440;
  static const double wideMinDetailWidth = 480;

  /// 设置(目录 380 + 内容页 480)。
  static const double settingsMasterWidth = 380;
  static const double settingsMinDetailWidth = 480;
}

/// 用户资料页宽版排版契约(页面与骨架屏共用,两边必须同步分流,
/// 否则 loading 骨架与成品形态对不上、加载完成瞬间跳版式)。
class UserProfileWideLayout {
  UserProfileWideLayout._();

  /// 启用宽版(左资料栏+右内容横排)的最小**实际可用宽度**——按页面
  /// 拿到的约束分流,不按屏宽:嵌入面板/压栈收窄的左栏拿到的是格子
  /// 宽,窄了自动回竖版折叠头图形态。
  static const double minWidth = 760;

  /// 左侧资料栏定宽(与「我的」页左资料卡同宽口径)。
  static const double infoPanelWidth = 360;

  /// 左栏顶部头图横幅高度(头像骑缝叠在横幅下缘,页面与骨架屏共用)。
  static const double bannerHeight = 200;

  /// 骑缝头像半径。
  static const double avatarRadius = 44;
}

/// 设备类型枚举
enum DeviceType { mobile, tablet, desktop }

/// 响应式布局工具类
class Responsive {
  Responsive._();

  static DeviceType? _lastDeviceType;

  /// 根据屏幕宽度获取设备类型
  static DeviceType getDeviceType(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    DeviceType computed;
    if (width < Breakpoints.mobile) {
      computed = DeviceType.mobile;
    } else if (width < Breakpoints.tablet) {
      computed = DeviceType.tablet;
    } else {
      computed = DeviceType.desktop;
    }

    if (LayoutLock.locked && _lastDeviceType != null) {
      return _lastDeviceType!;
    }
    _lastDeviceType = computed;
    return computed;
  }

  /// 是否为手机
  static bool isMobile(BuildContext context) {
    return getDeviceType(context) == DeviceType.mobile;
  }

  /// 是否为平板
  static bool isTablet(BuildContext context) {
    return getDeviceType(context) == DeviceType.tablet;
  }

  /// 是否为桌面
  static bool isDesktop(BuildContext context) {
    return getDeviceType(context) == DeviceType.desktop;
  }

  /// 是否显示侧边导航（平板及以上）
  static bool showNavigationRail(BuildContext context) {
    return !isMobile(context);
  }

  /// 是否显示底部导航（仅手机）
  static bool showBottomNavigation(BuildContext context) {
    return isMobile(context);
  }
}

/// 响应式布局 Builder Widget
class ResponsiveBuilder extends StatelessWidget {
  const ResponsiveBuilder({
    super.key,
    required this.mobile,
    this.tablet,
    this.desktop,
  });

  final Widget mobile;
  final Widget? tablet;
  final Widget? desktop;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= Breakpoints.tablet) {
          return desktop ?? tablet ?? mobile;
        } else if (constraints.maxWidth >= Breakpoints.mobile) {
          return tablet ?? mobile;
        }
        return mobile;
      },
    );
  }
}
