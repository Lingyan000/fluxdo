import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' as ui show lerpDouble;

import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' show SpringDescription, SpringSimulation;
import 'package:app_icons/app_icons.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../models/topic.dart';
import '../models/category.dart';
import '../providers/discourse_providers.dart';
import '../providers/message_bus_providers.dart';
import '../providers/selected_topic_provider.dart';
import '../providers/pinned_categories_provider.dart';
import 'login_page.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'search_page.dart';
import '../models/search_filter.dart';
import '../widgets/common/notification_icon_button.dart';
import '../widgets/common/anchor_guard_sliver.dart';
import '../widgets/topic/topic_list_skeleton.dart';
import '../widgets/topic/keyword_filter_hint_bar.dart';
import '../widgets/topic/topic_filter_menu.dart';
import '../widgets/common/topic_badges.dart';
import '../widgets/common/search_capsule.dart';
import '../widgets/topic/category_drawer.dart';
import '../widgets/topic/topic_item_builder.dart';
import '../widgets/common/tag_selection_sheet.dart';
import '../widgets/common/paged_list_footer.dart';
import '../navigation/nav_action_bus.dart';
import '../providers/app_state_refresher.dart';
import '../providers/preferences_provider.dart';
import '../utils/load_more_coordinator.dart';
import '../utils/motion_springs.dart';
import '../utils/topic_keyword_filter.dart';
import '../utils/frame_jank_monitor.dart';
import '../utils/responsive.dart';
import '../widgets/layout/master_detail_layout.dart';
import '../widgets/common/error_view.dart';
import '../widgets/common/loading_dialog.dart';
import '../widgets/common/fading_edge_scroll_view.dart';
import '../widgets/offline_indicator.dart';
import '../l10n/s.dart';
import '../models/shortcut_binding.dart';
import '../providers/shortcut_provider.dart';
import '../widgets/desktop_refresh_indicator.dart';
import '../services/toast_service.dart';
import '../utils/dialog_utils.dart';
import '../utils/platform_utils.dart';

class ScrollToTopNotifier extends StateNotifier<int> {
  ScrollToTopNotifier() : super(0);

  void trigger() => state++;
}

final scrollToTopProvider = StateNotifierProvider<ScrollToTopNotifier, int>((
  ref,
) {
  return ScrollToTopNotifier();
});

/// 顶栏/底栏可见性进度（0.0 = 完全隐藏, 1.0 = 完全显示）
final barVisibilityProvider = StateProvider<double>((ref) => 1.0);

/// FAB 是否处于刷新模式（用户正在向上滚动时为 true）
final fabRefreshModeProvider = StateProvider<bool>((ref) => false);

/// FAB 触发刷新信号
final fabRefreshSignalProvider =
    StateNotifierProvider<ScrollToTopNotifier, int>((ref) {
      return ScrollToTopNotifier();
    });

/// Header 区域常量。
///
/// 顶部 = 常驻工具栏 48px（☰ + 聚合筛选菜单标题「最新 ▾」+ 右簇
/// 🔕(条件)·搜索落位·🔔）。可折叠段三段式：搜索胶囊行 48（折叠时
/// 胶囊 Rect.lerp 连续 morph 缩进常驻行右簇的落位格 —— 头部内
/// "一镜到底"）→ 分类 chips 行 40 → 条件标签行 36。
const _toolbarRowHeight = 48.0;
const _capsuleRowHeight = 48.0;
const _navRowHeight = 40.0;
const _tagsRowHeight = 36.0;

/// 首页运动系统统一弹簧,定义与说明见 [kHeaderMotionSpring]。
final SpringDescription _kHeaderSpring = kHeaderSpringDescription;

/// 顶栏收放控制器。两种收放语义分治（iOS/Telegram 搜索栏范式）：
///
/// - **胶囊段 = 位置驱动**：`capsuleOffset = pixels.clamp(0, 48)`，是
///   滚动位置的纯函数 —— 搜索胶囊只在列表顶部 48px 内擦洗展开/收起，
///   深处上滑不会冒出来（搜索是"内容的一部分"，随内容离场回场）。
/// - **工具段（chips 行 + 底栏联动）= enterAlways 增量驱动**：深处
///   上滑即回、下滑即走（chips/底栏是"工具"）;近顶被位置钳制强制
///   全展开，与胶囊段无缝衔接。
///
/// snap/展开只动本 controller 或驱动列表，头部是 overlay 层自行收放。
class _HeaderCollapseController extends ChangeNotifier {
  _HeaderCollapseController({
    required TickerProvider vsync,
    required this.onVisibilityChanged,
    required bool locked,
    required double extent,
  }) : _vsync = vsync,
       _locked = locked {
    _applyExtent(extent);
  }

  final TickerProvider _vsync;

  /// 可见性联动（1 - barOffset/barExtent），供底栏滑出等外部消费。
  /// 通知发生在滚动回调/动画 tick（build 之外），可同步写 provider。
  final ValueChanged<double> onVisibilityChanged;

  AnimationController? _snapAnim;
  double _capsuleOffset = 0.0;
  double _barOffset = 0.0;
  double _barExtent = _capsuleRowHeight;
  double _extent = _capsuleRowHeight;
  bool _locked;
  double _lastReportedVisibility = 1.0;

  /// 本次手势/滚轮会话起点的列表位置与工具段收起量（ScrollStart
  /// (drag)/滚轮会话首事件写入）。顶带吸附按起点分治迟滞;工具段
  /// 回滚判定需要起点收起量（区分"收起态被蹭开"与"展开态收到一半"，
  /// 见 _settleBarAfterScroll）。
  double gestureStartPixels = 0.0;
  double gestureStartBarOffset = 0.0;

  void noteGestureStart(double pixels) {
    gestureStartPixels = pixels;
    gestureStartBarOffset = _barOffset;
  }

  // —— 胶囊 morph 弹簧跟随器 ——
  // morph 若被滚动 1:1 擦洗，整段飞行只映射在头 48px 滚动距离里：快甩
  // 两三帧滚完 = 胶囊瞬移进角落;方向微抖 = 整段横飞反复。跟随器让
  // 滚动只改目标值，morph 以临界阻尼弹簧趋近 —— 带速度状态，目标
  // 反向时运动连续无折角（一阶指数滤波在反向瞬间有可感的"折"）。
  Ticker? _morphTicker;
  double _morph = 0.0;
  double _morphVelocity = 0.0;
  Duration? _lastMorphTick;

  /// 平滑后的胶囊 morph 进度（0=整行胶囊，1=落位图标）。
  /// **只驱动胶囊 rect 飞行与落位 spacer**（快甩不瞬移）;布局占位
  /// 用 [rowProgress]。
  double get morphProgress => _morph;

  /// 胶囊行**布局**进度：收起方向跟随滚动位置 1:1（raw），展开方向
  /// 跟随 morph 弹簧（平滑）。收起时行高与内容严格同步 —— 内容顶边
  /// 全程贴着头部下缘 8px 呼吸位滑行，首卡圆角"顶上去"清晰可见
  /// （行高若吃 morph 平滑值，快收时行还没让开、内容已到，被下缘
  /// 直线拦腰斩 = "动画开始就是直角线"）;展开时内容在远离下缘，
  /// 平滑无副作用。
  double get rowProgress {
    final raw = (_capsuleOffset / _capsuleRowHeight).clamp(0.0, 1.0);
    return raw > _morph ? raw : _morph;
  }

  double get _morphTarget =>
      (_capsuleOffset / _capsuleRowHeight).clamp(0.0, 1.0);

  void _syncMorph() {
    if ((_morphTarget - _morph).abs() < 0.001) return;
    final ticker = _morphTicker ??= _vsync.createTicker(_onMorphTick);
    if (!ticker.isActive) {
      _lastMorphTick = null;
      ticker.start();
    }
  }

  void _onMorphTick(Duration elapsed) {
    final last = _lastMorphTick;
    _lastMorphTick = elapsed;
    final dt =
        ((last == null ? 16.7 : (elapsed - last).inMicroseconds / 1000.0) /
                1000.0)
            .clamp(0.0, 0.05);
    final target = _morphTarget;
    // 临界阻尼弹簧半隐式积分（ω=√(stiffness/mass)，与全局弹簧
    // _kHeaderSpring 同参 kHeaderMotionSpring）：a = ω²·(target-x) − 2ω·v
    const omega = 22.4; // sqrt(kHeaderMotionSpring.stiffness / 1)
    final accel =
        omega * omega * (target - _morph) - 2 * omega * _morphVelocity;
    _morphVelocity += accel * dt;
    _morph = (_morph + _morphVelocity * dt).clamp(0.0, 1.0);
    if ((target - _morph).abs() < 0.003 && _morphVelocity.abs() < 0.05) {
      _morph = target;
      _morphVelocity = 0.0;
      _morphTicker?.stop();
      _lastMorphTick = null;
    }
    notifyListeners();
  }

  /// 胶囊段收起量（位置驱动，0 = 全展开胶囊，48 = 已 morph 成图标）
  double get capsuleOffset => _capsuleOffset;

  /// 工具段收起量（enterAlways 累计，0 = chips/底栏全显）
  double get barOffset => _barOffset;

  /// 工具段总量（chips+标签行高;无 chips 时退化为 48，保证底栏联动
  /// 仍有收放行程）
  double get barExtent => _barExtent;

  /// 工具段收起进度 0..1（chips 行 heightFactor 与底栏可见性共用）
  double get barProgress =>
      _barExtent <= 0 ? 0.0 : (_barOffset / _barExtent).clamp(0.0, 1.0);

  /// chip→标题飞行进度（barProgress 的语义别名：单列出来方便日后
  /// 独立调曲线而不牵动布局口径）
  double get chipFlightProgress => barProgress;

  /// 可折叠总高（胶囊 48 + chips/标签行;列表 topInset 同源）
  double get extent => _extent;

  set extent(double value) {
    if (_extent == value) return;
    // setter 在 build 期被调（_syncTabsIfNeeded 路径），不能同步
    // notify/写 provider;夹紧与可见性重报推迟到帧末。
    _applyExtent(value);
    stopSnap();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setBarOffset(_barOffset.clamp(0.0, _barExtent), force: true);
    });
  }

  void _applyExtent(double value) {
    _extent = value;
    final rest = value - _capsuleRowHeight;
    _barExtent = rest > 0 ? rest : _capsuleRowHeight;
  }

  bool get isSnapping => _snapAnim?.isAnimating ?? false;

  /// hideBarOnScroll 关闭时锁定全展开
  set locked(bool value) {
    if (_locked == value) return;
    _locked = value;
    if (value) {
      stopSnap();
      _setCapsuleOffset(0.0, instantMorph: true);
      _setBarOffset(0.0);
    }
  }

  /// 消化一次列表滚动：胶囊段位置驱动 + **单向粘滞**——收起方向随
  /// 位置立即走;展开方向仅在用户上滑（delta<0）进入顶部区时随位置。
  /// tab 切换遗留的"胶囊已折叠、列表在顶部"失配不会被下滑/惯性误
  /// 展开（折叠状态跨 tab 粘滞），上滑到顶自然长回。
  /// 工具段按增量累计（[accumulateBar] false = 越界回弹段不喂）;
  /// 近顶钳制：pixels < 48 时工具段强制全展开。
  void handleScroll(double delta, double pixels, {bool accumulateBar = true}) {
    if (_locked) return;
    stopSnap();
    final posOffset = pixels.clamp(0.0, _capsuleRowHeight);
    if (posOffset > _capsuleOffset || delta < 0) {
      _setCapsuleOffset(posOffset);
    }
    final cap = (pixels - _capsuleRowHeight).clamp(0.0, _barExtent);
    final next = accumulateBar
        ? (_barOffset + delta).clamp(0.0, cap)
        : _barOffset.clamp(0.0, cap);
    _setBarOffset(next);
  }

  /// 工具段 snap 到全显(0)或全隐([barExtent])。只动 overlay 的 chips
  /// 行与底栏，列表内容不动。统一弹簧 + 继承 [velocity]（px/s，
  /// barOffset 增大方向为正）——快甩快收、慢松缓归，跟手段与动画段
  /// 速度连续。[duration] Duration.zero = 立即跳变（外部状态同步用）。
  void snapBar(double target, {double velocity = 0, Duration? duration}) {
    if (_locked) return;
    stopSnap();
    if (duration == Duration.zero) {
      _setBarOffset(target);
      return;
    }
    if (_barOffset == target && velocity == 0) return;
    final controller = AnimationController.unbounded(vsync: _vsync);
    _snapAnim = controller;
    controller.addListener(() {
      _setBarOffset(controller.value.clamp(0.0, _barExtent));
    });
    controller
        .animateWith(
          SpringSimulation(_kHeaderSpring, _barOffset, target, velocity),
        )
        .whenComplete(() {
          if (identical(_snapAnim, controller)) {
            _snapAnim = null;
            _setBarOffset(target);
          }
          controller.dispose();
        });
  }

  /// 工具段兜底吸附（正常路径下物理层耦合收尾已把工具段送到边，
  /// 这里恒 no-op;只兜 extent 突变/短列表滚不动等物理层覆盖不到的
  /// 残余半开）。规则从简：过半收、不过半开;[listPixels] 提供收起
  /// 可达性门禁——内容没滚过锚位时强收会在头部下缘与内容顶边间
  /// 凭空造出空白带，一律反转为回开。
  void snapBarToNearest({double velocity = 0, double? listPixels}) {
    if (_locked) return;
    if (_barOffset <= 0 || _barOffset >= _barExtent) return;
    double target = _barOffset > _barExtent / 2 ? _barExtent : 0.0;
    if (target >= _barExtent && listPixels != null) {
      final cap = (listPixels - _capsuleRowHeight).clamp(0.0, _barExtent);
      if (cap < _barExtent) target = 0.0;
    }
    snapBar(target, velocity: velocity);
  }

  /// 可折叠段当前**可见高度**（tab 自己的折叠总量 [tabExtent] 口径）：
  /// 骨架屏/错误页等非滚动态的顶部让位用 —— 它们没有滚动位置可与
  /// 头部互动，让位必须实时贴着头部下缘（胶囊折叠时少让 48px，
  /// 否则头部与内容之间露空洞）。与头部布局同源：胶囊段吃
  /// rowProgress（收起 1:1/展开平滑，与胶囊行占位一致）、工具段吃
  /// barProgress，收放/吸附全程贴合。
  double visibleExtentFor(double tabExtent) {
    final capsuleVisible = _capsuleRowHeight * (1.0 - rowProgress);
    final rest = tabExtent - _capsuleRowHeight;
    final barVisible = rest > 0 ? rest * (1.0 - barProgress) : 0.0;
    return capsuleVisible + barVisible;
  }

  /// 折叠锚位：内容顶边不露空洞所需的最小滚动位置 = 头部收起总量
  /// （胶囊段 + 工具段，按 tab 自己的 [tabExtent] 折算）。列表 attach
  /// /切 tab 适配用 —— 只对齐 capsuleOffset 会漏工具段收起量
  /// （chips 折叠时 pill 上方露 40px，截图实锤）。
  double collapsedAnchorFor(double tabExtent) {
    final rest = tabExtent - _capsuleRowHeight;
    final barCollapsed = rest > 0 ? rest * barProgress : 0.0;
    return _capsuleOffset + barCollapsed;
  }

  /// 展开头部（切 tab 横滑起步、scrollToTop、关闭折叠偏好时调用）。
  /// 胶囊一并展开：位置驱动下一旦列表滚动会立即重新对齐，仅作为
  /// 过渡期的视觉兜底（避免相邻贴顶 tab 在横滑中露出 48px 空隙）。
  void expand({bool animate = true}) {
    if (_locked) {
      _setCapsuleOffset(0.0, instantMorph: true);
      _setBarOffset(0.0);
      return;
    }
    _setCapsuleOffset(0.0, instantMorph: !animate);
    if (animate) {
      snapBar(0.0);
    } else {
      stopSnap();
      _setBarOffset(0.0);
    }
  }

  void stopSnap() {
    final anim = _snapAnim;
    if (anim == null) return;
    _snapAnim = null;
    anim.stop();
    anim.dispose();
  }

  void _setCapsuleOffset(double value, {bool instantMorph = false}) {
    if (_capsuleOffset != value) {
      _capsuleOffset = value;
      if (instantMorph) {
        _morphTicker?.stop();
        _lastMorphTick = null;
        _morph = _morphTarget;
      } else {
        _syncMorph();
      }
      notifyListeners();
    } else if (instantMorph && _morph != _morphTarget) {
      _morphTicker?.stop();
      _lastMorphTick = null;
      _morph = _morphTarget;
      notifyListeners();
    }
  }

  void _setBarOffset(double value, {bool force = false}) {
    if (_barOffset == value && !force) return;
    _barOffset = value;
    notifyListeners();
    final visibility = (1.0 - barProgress).clamp(0.0, 1.0);
    // 0.01 节流；端点必须精确送达（底栏全隐/全显判定依赖 0.0/1.0）
    if (visibility != _lastReportedVisibility &&
        ((visibility - _lastReportedVisibility).abs() > 0.01 ||
            visibility == 0.0 ||
            visibility == 1.0)) {
      _lastReportedVisibility = visibility;
      onVisibilityChanged(visibility);
    }
  }

  @override
  void dispose() {
    stopSnap();
    _morphTicker?.dispose();
    super.dispose();
  }
}

// ─── TopicsPage ───

/// 顶带 + 深区工具段的吸附物理（**耦合收尾**定案）。
///
/// 两个战场，一个原则：**settle 期间栏与内容一体移动**——位移要么
/// 顺着手势方向补完（≤剩余行程），要么整段撤销（净位移归零），
/// 永不出现"栏自己动、内容留在原地"的错位。
///
/// 1. **胶囊带**：弹道落点停进 (0, 48) 时按手势起点分治迟滞——
///    顶部起手落点 > 36 才 commit 收起，否则回滚展开;深处起手落点
///    < 12 才 assist 全开，否则回滚收起锚位。胶囊是位置纯函数，
///    驱动列表即一体。
/// 2. **深区工具段**：chips/底栏 half-open 且弹道自己送不到边时，
///    弹簧把**列表**滚到"工具段恰好到边"的位置——增量经 enterAlways
///    记账自然驱动工具段同步，栏沿与内容行相对静止（此前 ScrollEnd
///    → snapBar 是 overlay-only：栏收回去、列表下滑位移留在原地，
///    每次短滑内容凭空多出栏漏出的高度 —— 本次翻车实锤）。同一套
///    起手锚定迟滞（75% 行程才换状态，不足全撤）。
///
/// 越界（下拉刷新）走平台物理。
class _TopSnapScrollPhysics extends ScrollPhysics {
  const _TopSnapScrollPhysics({required this.controller, super.parent});

  /// 读手势起点快照与工具段状态（noteGestureStart 维护）
  final _HeaderCollapseController controller;

  @override
  _TopSnapScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _TopSnapScrollPhysics(
      controller: controller,
      parent: buildParent(ancestor),
    );
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final base = super.createBallisticSimulation(position, velocity);
    // 越界（下拉刷新回弹等）交给平台物理
    if (position.outOfRange) return base;

    // 弹道落点（取大有限时刻：所有模拟均已收敛;不用 infinity ——
    // spring 解析解含 t·e^{-ωt} 项，无穷时刻是 inf·0 = NaN）
    final endPixels = base?.x(100.0) ?? position.pixels;
    if (!endPixels.isFinite) return base;
    const band = _capsuleRowHeight;

    // —— 胶囊带：落点停进 (0, 48) ——
    if (endPixels > 0 && endPixels < band) {
      final fromDeep = controller.gestureStartPixels >= band;
      double target;
      if (fromDeep) {
        target = endPixels < band / 4 ? 0.0 : band;
      } else {
        target = endPixels > band * 3 / 4 ? band : 0.0;
      }
      if (target > position.maxScrollExtent) target = 0.0;
      if (target == position.pixels &&
          velocity.abs() < toleranceFor(position).velocity) {
        return null;
      }
      return ScrollSpringSimulation(
        _kHeaderSpring,
        position.pixels,
        target,
        velocity,
        tolerance: toleranceFor(position),
      );
    }

    // —— 深区工具段耦合收尾 ——
    final barExtent = controller.barExtent;
    final barOffset = controller.barOffset;
    if (position.pixels >= band &&
        barExtent > 0 &&
        barOffset > 0.5 &&
        barOffset < barExtent - 0.5) {
      // 弹道行程足以把工具段送到边（记账器吃满 delta）则不干预
      final predicted = (barOffset + (endPixels - position.pixels)).clamp(
        0.0,
        barExtent,
      );
      if (predicted <= 0.5 || predicted >= barExtent - 0.5) return base;

      // 起手锚定迟滞：从收起态起手要拉出 75% 才 commit 展开;从
      // 展开态起手要推进 75% 才 commit 收起;不足一律原路撤销
      final startBar = controller.gestureStartBarOffset;
      double targetBar;
      if (startBar >= barExtent - 0.5) {
        targetBar = barOffset <= barExtent * 0.25 ? 0.0 : barExtent;
      } else if (startBar <= 0.5) {
        targetBar = barOffset >= barExtent * 0.75 ? barExtent : 0.0;
      } else {
        targetBar = barOffset > barExtent / 2 ? barExtent : 0.0;
      }
      var listTarget = position.pixels + (targetBar - barOffset);
      // 收起可达性：滚动余量不足则反转为展开（防底部强收露空白）
      if (targetBar > barOffset && listTarget > position.maxScrollExtent) {
        listTarget = position.pixels - barOffset;
      }
      // 不越入胶囊带：expand-commit 压到 48 为止（缺口由近顶钳制
      // cap = pixels-48 收编，工具段照样到边），否则弹簧停进带内
      // 会触发二次 goBallistic 的反向修正 = 可感的二段抖
      listTarget = listTarget.clamp(band, position.maxScrollExtent);
      if (listTarget == position.pixels &&
          velocity.abs() < toleranceFor(position).velocity) {
        return null;
      }
      return ScrollSpringSimulation(
        _kHeaderSpring,
        position.pixels,
        listTarget,
        velocity,
        tolerance: toleranceFor(position),
      );
    }

    return base;
  }
}

/// 抽屉拖拽桥：TabBarView 的 physics（随 build 重建、不可变）与
/// State 间的可变状态通道。
class _DrawerPullBridge {
  /// 手指按下的拖拽会话中（ScrollStart.dragDetails != null 维护;
  /// 挡住 ballistic 越界误触发抽屉）
  bool dragging = false;

  /// 本次手势已进入"拉抽屉"模式（首缘越界触发，手势结束前锁存：
  /// 期间全部水平位移归抽屉，含往回滑 —— 否则回滑会被 PageView
  /// 接手直接切 tab）
  bool pulling = false;
}

/// 首页 TabBarView 常驻 physics：首缘（"全部"页再向右拖）把越界量
/// 转交抽屉跟手拖出，PageView 自身**永不越界**（首缘表现为 clamping，
/// iOS 无橡皮筋残留）;进入拉抽屉模式后本次手势位移全量归抽屉。
/// 其余方向/页面完全走平台默认物理。
class _DrawerPullPagerPhysics extends ScrollPhysics {
  const _DrawerPullPagerPhysics({
    required this.bridge,
    required this.onPull,
    required this.onPullEnd,
    super.parent,
  });

  final _DrawerPullBridge bridge;

  /// 位移增量（正 = 手指向右 = 抽屉拉出方向）
  final ValueChanged<double> onPull;

  /// 手势结束（velocityDx 正 = 向右甩）
  final ValueChanged<double> onPullEnd;

  @override
  _DrawerPullPagerPhysics applyTo(ScrollPhysics? ancestor) {
    return _DrawerPullPagerPhysics(
      bridge: bridge,
      onPull: onPull,
      onPullEnd: onPullEnd,
      parent: buildParent(ancestor),
    );
  }

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) {
    // 无收藏分类时 TabBarView 只有"全部"一页（min==max），默认物理
    // 拒绝手势 → 拖拽会话不建立，首缘桥永远无法介入（"没有分类栏
    // 就不能右滑"）。始终收下手势：单页下所有位移都走首缘越界分支
    // 转给抽屉。
    return true;
  }

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    // 拉抽屉模式：手势位移全量转交（offset 正 = 手指向右）
    if (bridge.pulling) {
      onPull(offset);
      return 0;
    }
    return super.applyPhysicsToUserOffset(position, offset);
  }

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    // 首缘越界（已在第一页仍向右拖）→ 进入拉抽屉模式：越界量转交
    // 抽屉，PageView 钉在 minScrollExtent（不产生 iOS 橡皮筋）
    if (bridge.dragging &&
        value < position.minScrollExtent &&
        position.pixels <= position.minScrollExtent + precisionErrorTolerance) {
      if (!bridge.pulling) bridge.pulling = true;
      onPull(position.minScrollExtent - value);
      return value - position.minScrollExtent;
    }
    if (bridge.pulling) {
      // 模式中冻结页面（含往回滑）
      return value - position.pixels;
    }
    return super.applyBoundaryConditions(position, value);
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (bridge.pulling) {
      bridge.pulling = false;
      // scroll velocity 正 = pixels 增大 = 手指向左;抽屉口径取反
      onPullEnd(-velocity);
      return null;
    }
    return super.createBallisticSimulation(position, velocity);
  }
}

/// tab 列表滚动控制器：初始滚动位置动态跟随胶囊折叠态。
///
/// 骨架屏 ↔ 数据列表切换会销毁/重建 Scrollable（position detach 后
/// 重新 attach），`initialScrollOffset` 是构造期快照满足不了"attach
/// 那一刻的胶囊态"——用 resolver 每次 attach 现取;attach 回调再做
/// 帧末校验兜底（PageStorage 恢复陈旧位置等杂例）。
class _TabListScrollController extends ScrollController {
  _TabListScrollController({
    required this.initialOffsetResolver,
    required this.onAttachPosition,
  });

  final double Function() initialOffsetResolver;
  final void Function(ScrollPosition position) onAttachPosition;

  @override
  double get initialScrollOffset => initialOffsetResolver();

  @override
  void attach(ScrollPosition position) {
    super.attach(position);
    onAttachPosition(position);
  }
}

/// 帖子列表页面 - 分类 Tab + 排序下拉 + 标签 Chips
class TopicsPage extends ConsumerStatefulWidget {
  const TopicsPage({super.key});

  @override
  ConsumerState<TopicsPage> createState() => _TopicsPageState();
}

class _TopicsPageState extends ConsumerState<TopicsPage>
    with TickerProviderStateMixin {
  late TabController _tabController;

  // chip→标题一镜到底的三个测位 key：选中 chip 文字（起点）、标题
  // 前缀零尺寸锚（终点）、头部根（参考系）
  final GlobalKey _selectedChipKey = GlobalKey();
  final GlobalKey _titlePrefixAnchorKey = GlobalKey();
  final GlobalKey _headerRootKey = GlobalKey();
  late final ShortcutScopeBinding _tabShortcutBinding = ShortcutScopeBinding(
    ref: ref,
    scope: ShortcutScope.master,
  );
  int _tabLength = 1; // 初始只有"全部"
  int _currentTabIndex = 0;
  List<int> _visiblePinnedIds = []; // 过滤后的可见分类 ID

  late final _HeaderCollapseController _headerController;
  bool _invalidateScheduled = false;
  Timer? _pointerScrollIdleTimer;
  bool _pointerScrolling = false;

  /// TabBarView 横滑进行中（ScrollStart..ScrollEnd）：期间冻结垂直
  /// 滚动对收放的驱动（两个 tab 列表同时在场，事件源混杂）
  bool _pageTransitioning = false;

  /// 首页整块区域右滑拖出侧栏：物理层桥（见 _DrawerPullPagerPhysics）
  final _DrawerPullBridge _drawerPullBridge = _DrawerPullBridge();
  late final _DrawerPullPagerPhysics _pagerPhysics = _DrawerPullPagerPhysics(
    bridge: _drawerPullBridge,
    onPull: CategoryDrawerHost.dragBy,
    onPullEnd: CategoryDrawerHost.settle,
    // 与 TabBarView 无 physics 时的默认对齐（clamping 边界）
    parent: const ClampingScrollPhysics(),
  );

  /// 各 tab 列表的滚动控制器。页面持有：snap 通过驱动当前列表实现
  /// 头部+内容一体回弹。
  final Map<int?, ScrollController> _listControllers = {};

  /// 不变量收口：胶囊折叠（跨 tab 粘滞）时，列表任何一次 attach 都
  /// 必须从 ≥capsuleOffset 起步 —— 否则"胶囊折叠 + 列表贴顶"= 头部
  /// 下缘与内容顶边之间露 48px 空洞。逐处补跳不可靠（骨架屏重挂时
  /// ScrollEnd 已错过、首建/刷新各有路径），在控制器层统一兜底：
  /// 初始位置跟随胶囊态 + attach 帧末校验。
  ScrollController _listControllerFor(int? categoryId) {
    double anchor() => _headerController.collapsedAnchorFor(
      _collapsibleExtentFor(
        _visiblePinnedIds,
        ref.read(tabTagsProvider(categoryId)),
      ),
    );
    return _listControllers.putIfAbsent(
      categoryId,
      () => _TabListScrollController(
        initialOffsetResolver: anchor,
        onAttachPosition: (position) {
          // attach 时布局未完成，帧末校验（覆盖 PageStorage 恢复出
          // 小于折叠锚位的陈旧位置等杂例）
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final target = anchor();
            if (target <= 0) return;
            if (!position.hasPixels || !position.hasContentDimensions) {
              return;
            }
            if (position.pixels < target) {
              position.jumpTo(target.clamp(0.0, position.maxScrollExtent));
            }
          });
        },
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _visiblePinnedIds = ref.read(pinnedCategoriesProvider);
    _tabLength = 1 + _visiblePinnedIds.length;
    _tabController = TabController(length: _tabLength, vsync: this);
    _tabController.addListener(_handleTabChange);
    _headerController = _HeaderCollapseController(
      vsync: this,
      locked: !ref.read(preferencesProvider).hideBarOnScroll,
      extent: _collapsibleExtentFor(
        _visiblePinnedIds,
        ref.read(tabTagsProvider(null)),
      ),
      // 同步写入（通知源是滚动回调/动画 tick，不在 build 期），
      // 底栏与头部同帧联动，消除旧架构 postFrameCallback 的滞后一帧
      onVisibilityChanged: (v) =>
          ref.read(barVisibilityProvider.notifier).state = v,
    );
  }

  /// 可折叠量：胶囊行恒在；chips 导航行仅有收藏分类时存在（无收藏时
  /// 只有"全部"+"＋"是空壳，不值得占一行）；标签行仅选了标签时存在
  static double _collapsibleExtentFor(List<int> pinnedIds, List<String> tags) =>
      _capsuleRowHeight +
      (pinnedIds.isEmpty ? 0.0 : _navRowHeight) +
      (tags.isEmpty ? 0.0 : _tagsRowHeight);

  void _registerTabShortcuts() {
    if (!mounted) return;
    _tabShortcutBinding.register(context, {
      ShortcutAction.previousTab: () {
        if (_tabController.index > 0) {
          _tabController.animateTo(_tabController.index - 1);
        }
      },
      ShortcutAction.nextTab: () {
        if (_tabController.index < _tabController.length - 1) {
          _tabController.animateTo(_tabController.index + 1);
        }
      },
    });
  }

  @override
  void dispose() {
    _headerController.dispose();
    _pointerScrollIdleTimer?.cancel();
    for (final controller in _listControllers.values) {
      controller.dispose();
    }
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    if (PlatformUtils.isDesktop) {
      _tabShortcutBinding.disposeDeferred();
    }
    super.dispose();
  }

  /// 全局筛选/排序变化时：刷新当前 tab，非活跃 tab 标记 stale
  /// 使用微任务去抖，避免多个参数连续变化时重复请求（如登出时重置筛选+排序+方向）
  void _invalidateTopicTabs(List<int> pinnedIds) {
    if (_invalidateScheduled) return;
    _invalidateScheduled = true;
    Future.microtask(() {
      _invalidateScheduled = false;
      if (!mounted) return;
      final currentCategoryId = _currentCategoryId(pinnedIds);
      // 当前活跃 tab：调用 refresh() 显式设置纯 loading 状态，确保骨架屏显示
      ref.read(topicListProvider(currentCategoryId).notifier).refresh();
      // 非活跃 tab：标记 stale，切换时再刷新
      final staleTabs = <int?>{};
      for (final categoryId in [null, ...pinnedIds]) {
        if (categoryId == currentCategoryId) continue;
        staleTabs.add(categoryId);
      }
      final existing = ref.read(staleTabsProvider);
      ref.read(staleTabsProvider.notifier).state = {...existing, ...staleTabs};
    });
  }

  void _handleTabChange() {
    if (_tabController.indexIsChanging) return;
    if (_currentTabIndex == _tabController.index) return;
    setState(() {
      _currentTabIndex = _tabController.index;
    });
    final categoryId = _currentCategoryId();
    // 胶囊对齐不在这里做：本回调在横滑过半瞬间就触发（手指未松），
    // 此刻动胶囊会出现"先展开再收起";对齐挂在 PageMetrics 的
    // ScrollEnd（见 _handleScrollNotification）。

    // 先处理 stale：在设置 currentTab 之前调用 refresh()，
    // 这样 widget rebuild 时 provider 已处于 loading 状态，不会闪旧数据
    final staleTabs = ref.read(staleTabsProvider);
    if (staleTabs.contains(categoryId)) {
      ref.read(topicListProvider(categoryId).notifier).refresh();
      ref.read(staleTabsProvider.notifier).state = staleTabs.difference({
        categoryId,
      });
    }

    ref.read(currentTabCategoryIdProvider.notifier).state = categoryId;
    ref.read(activeSidebarCategoryIdProvider.notifier).state = categoryId;
  }

  /// 检测 pinnedCategories 变化，重建 TabController
  void _syncTabsIfNeeded(List<int> pinnedIds) {
    final desiredLength = 1 + pinnedIds.length;
    _visiblePinnedIds = pinnedIds;
    if (desiredLength == _tabLength) return;

    final oldIndex = _tabController.index;
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    _tabLength = desiredLength;
    _tabController = TabController(length: _tabLength, vsync: this);
    _tabController.addListener(_handleTabChange);
    _currentTabIndex = oldIndex < _tabLength ? oldIndex : 0;
    _tabController.index = _currentTabIndex;
  }

  Future<void> _goToLogin() async {
    final result = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const LoginPage()));
    if (result == true && mounted) {
      final loading = LoadingDialog.show(
        context,
        message: context.l10n.common_loadingData,
      );
      try {
        // 等加载弹框完成首帧构建后再刷新 Riverpod provider，避免在
        // OverlayEntry build 过程中触发 ProviderScope markNeedsBuild。
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;

        AppStateRefresher.refreshAll(
          ProviderScope.containerOf(context, listen: false),
        );

        await Future.wait([
          ref.read(currentUserProvider.future),
          ref.read(topicListProvider(null).future),
        ]).timeout(const Duration(seconds: 10));
      } catch (e) {
        debugPrint('[TopicsPage] 登录后刷新失败/超时: $e');
      } finally {
        loading.hide();
      }
    }
  }

  void _showTopicIdDialog(BuildContext context) {
    final controller = TextEditingController();
    showAppDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.topics_jumpToTopic),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            labelText: context.l10n.topics_topicId,
            hintText: context.l10n.topics_topicIdHint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () {
              final id = int.tryParse(controller.text.trim());
              Navigator.pop(context);
              if (id != null) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TopicDetailPage(
                      topicId: id,
                      autoSwitchToMasterDetail: true,
                    ),
                  ),
                );
              }
            },
            child: Text(context.l10n.topics_jump),
          ),
        ],
      ),
    );
  }

  /// 打开分类侧栏（☰ / chips 行 ＋）。宿主 DrawerController 挂在
  /// AdaptiveScaffold 顶层（全局手势），这里只发开启指令。
  void _openCategoryDrawer() {
    CategoryDrawerHost.open();
  }

  Future<void> _openTagSelection() async {
    final categoryId = _currentCategoryId();
    final currentTags = ref.read(tabTagsProvider(categoryId));
    final tagsAsync = ref.read(tagsProvider);
    final availableTags = tagsAsync.when(
      data: (tags) => tags,
      loading: () => <String>[],
      error: (e, s) => <String>[],
    );

    final result = await showAppBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => TagSelectionSheet(
        categoryId: categoryId,
        availableTags: availableTags,
        selectedTags: currentTags,
        maxTags: 99,
      ),
    );

    if (result != null && mounted) {
      ref.read(tabTagsProvider(categoryId).notifier).state = result;
    }
  }

  /// 获取当前选中分类 Tab 对应的 Category（仅非"全部"时返回）
  Category? _getCurrentCategory(
    List<int> pinnedIds,
    Map<int, Category>? categoryMap,
  ) {
    if (_currentTabIndex == 0 || categoryMap == null) return null;
    if (_currentTabIndex - 1 >= pinnedIds.length) return null;
    final categoryId = pinnedIds[_currentTabIndex - 1];
    return categoryMap[categoryId];
  }

  /// 获取当前 tab 对应的 categoryId
  int? _currentCategoryId([List<int>? pinnedIds]) {
    if (_currentTabIndex == 0) return null;
    final List<int> ids = pinnedIds ?? _visiblePinnedIds;
    if (_currentTabIndex - 1 < ids.length) {
      return ids[_currentTabIndex - 1];
    }
    return null;
  }

  void _showDismissConfirmDialog(TopicListFilter currentFilter) {
    final label = _dismissLabel(currentFilter);
    showAppDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.topics_dismissConfirmTitle),
        content: Text(context.l10n.topics_dismissConfirmContent(label)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _doDismiss();
            },
            child: Text(context.l10n.common_confirm),
          ),
        ],
      ),
    );
  }

  String _dismissLabel(TopicListFilter filter) {
    if (filter == TopicListFilter.newTopics) {
      final subset = ref.read(topicNewSubsetProvider);
      switch (subset) {
        case NewSubset.topics:
          return context.l10n.topic_filterNewTopicsShort;
        case NewSubset.replies:
          return context.l10n.topic_filterNewRepliesShort;
        case NewSubset.all:
          return context.l10n.topic_filterNewAllShort;
      }
    }
    return context.l10n.topics_unreadTopics;
  }

  Future<void> _doDismiss() async {
    final categoryId = _currentCategoryId();
    try {
      await ref.read(topicListProvider(categoryId).notifier).dismissAll();
    } catch (e) {
      if (mounted) {
        ToastService.showError(S.current.common_operationFailed(e.toString()));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 帧内构建归因:首页整页 rebuild 直接现形(监控关闭零开销)
    FrameJankMonitor.noteBuild('home:page');
    // 桌面端：注册分类 Tab 切换快捷键（在 build 中确保每次重建都刷新）
    if (PlatformUtils.isDesktop) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _registerTabShortcuts();
      });
    }

    final topPadding = MediaQuery.of(context).padding.top;
    final isLoggedIn = ref.watch(currentUserProvider).value != null;
    final allPinnedIds = ref.watch(pinnedCategoriesProvider);
    final categoryMapAsync = ref.watch(categoryMapProvider);
    final categoryMap = categoryMapAsync.value;
    // 首页卡片统一复用页面层的分类快照，避免每张 TopicCard 单独订阅
    // categoryMapProvider。加载期也传空 Map，防止卡片回退为逐卡 watch。
    final topicCategoryMap = categoryMap ?? const <int, Category>{};
    // 过滤掉当前用户无权限访问的分类（不在可见分类集合中的）
    final visibleIds = ref.watch(visibleCategoryIdsProvider);
    final pinnedIds = visibleIds != null
        ? allPinnedIds.where((id) => visibleIds.contains(id)).toList()
        : allPinnedIds;
    final currentFilter = ref.watch(topicFilterProvider);
    _syncTabsIfNeeded(pinnedIds);

    // 监听侧栏分类选中变化，同步切换 tab
    ref.listen(activeSidebarCategoryIdProvider, (prev, next) {
      if (next == null && _tabController.index != 0) {
        _tabController.animateTo(0);
      } else if (next != null) {
        final latestVisibleIds = ref.read(visibleCategoryIdsProvider);
        final latestPinnedIds = ref.read(pinnedCategoriesProvider);
        final effectivePinnedIds = latestVisibleIds != null
            ? latestPinnedIds
                  .where((id) => latestVisibleIds.contains(id))
                  .toList()
            : latestPinnedIds;
        final targetIndex = effectivePinnedIds.indexOf(next);
        if (targetIndex >= 0 && _tabController.index != targetIndex + 1) {
          _tabController.animateTo(targetIndex + 1);
        }
      }
    });

    final currentCategoryId = _currentCategoryId(pinnedIds);
    final currentTags = ref.watch(tabTagsProvider(currentCategoryId));

    // 监听全局筛选/排序变化：刷新当前 tab，清除非活跃 tab 数据
    // 所有全局参数统一聚合在 topicListGlobalParamsSignal 中，
    // 未来新增参数只需在信号 provider 中添加 ref.watch
    ref.listen(topicListGlobalParamsSignal, (_, _) {
      _invalidateTopicTabs(pinnedIds);
    });

    // 关闭滚动折叠时，锁定头部全展开
    ref.listen(preferencesProvider.select((p) => p.hideBarOnScroll), (
      prev,
      next,
    ) {
      _headerController.locked = !next;
    });

    // 监听滚动到顶部的通知：动画展开头部；列表回顶由 _TopicListState
    // 各自监听同一信号处理（overlay 头部与列表滚动已解耦）
    ref.listen(scrollToTopProvider, (previous, next) {
      ref.read(fabRefreshModeProvider.notifier).state = false;
      _headerController.expand();
    });

    // 外部写 barVisibility=1.0（main.dart 切底部 tab、书签工作台退出等）
    // 时同步展开工具段，避免"底栏已显示、回到首页 chips 却还收着"的
    // 错位。页面此时通常在 IndexedStack 后台，直接跳变不做动画。
    // 胶囊是位置纯函数不受影响（深处回来仍是图标态，正确语义）。
    ref.listen(barVisibilityProvider, (prev, next) {
      if (next == 1.0 && _headerController.barOffset > 0) {
        _headerController.snapBar(0.0, duration: Duration.zero);
      }
    });

    // chips 行随有无收藏、标签行随有无标签动态存在，可折叠量跟着变
    // （setter 的副作用推迟帧末，build 期调用安全）
    _headerController.extent = _collapsibleExtentFor(pinnedIds, currentTags);

    // 聚合筛选菜单（筛选/子过滤/排序/标签/忽略五合一）;折叠态标题
    // 前缀承接 chips 收起后的"你在哪"信息（「水源 · 最新」）
    String? tabNameOf(int index) {
      if (index <= 0 || index - 1 >= pinnedIds.length) return null;
      return categoryMap?[pinnedIds[index - 1]]?.name;
    }

    final titlePrefix = _TitleTabPrefix(
      headerController: _headerController,
      tabController: _tabController,
      nameResolver: tabNameOf,
      anchorKey: _titlePrefixAnchorKey,
    );
    final filterMenu = _buildFilterMenu(isLoggedIn, currentFilter, titlePrefix);

    return Listener(
      onPointerDown: (_) => _cancelSnap(cancelPointerScrollSession: true),
      onPointerSignal: (event) {
        if (event is PointerScrollEvent && _shouldHandlePointerScroll(event)) {
          _onPointerScroll(event);
        }
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: ScrollConfiguration(
          // 禁用自动 Scrollbar（TabBarView 多 ScrollPosition 下 Scrollbar
          // 会报错）与 overscroll indicator，保持既有视觉行为
          behavior: ScrollConfiguration.of(
            context,
          ).copyWith(scrollbars: false, overscroll: false),
          child: Stack(
            children: [
              // 列表区全屏，顶部让出常驻区（状态栏 + 紧凑工具栏）的恒定
              // 高度;可折叠段（chips 导航行/标签行）悬浮在列表上方，
              // 收放只动 overlay 自身，不牵动列表布局
              Positioned.fill(
                top: topPadding + _toolbarRowHeight,
                child: TabBarView(
                  controller: _tabController,
                  // 首缘越界转交抽屉跟手拖出（拉抽屉模式中 PageView
                  // 冻结，回滑不切 tab）;其余走 clamping 默认
                  physics: _pagerPhysics,
                  children: [
                    _buildTabPage(null, topicCategoryMap),
                    for (final id in pinnedIds)
                      _buildTabPage(id, topicCategoryMap),
                  ],
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _CollapsibleHeader(
                  key: _headerRootKey,
                  controller: _headerController,
                  statusBarHeight: topPadding,
                  toolbarChild: _buildToolbar(isLoggedIn, filterMenu),
                  onSearchTap: _openSearch,
                  bellVisible:
                      isLoggedIn && !Responsive.showNavigationRail(context),
                  flightLabel: _ChipFlightLabel(
                    headerController: _headerController,
                    tabController: _tabController,
                    nameResolver: tabNameOf,
                    chipKey: _selectedChipKey,
                    anchorKey: _titlePrefixAnchorKey,
                    headerKey: _headerRootKey,
                  ),
                  collapsibleChild: Column(
                    children: [
                      // 无收藏分类时不显示 chips 行（只有"全部"+"＋"
                      // 是空壳）;分类主入口在 ☰ 侧栏
                      if (pinnedIds.isNotEmpty)
                        _buildNavRow(pinnedIds, categoryMap),
                      if (currentTags.isNotEmpty) _buildTagsRow(currentTags),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 常驻工具栏（48px，永不折叠）。左=☰ 分类侧栏 + 聚合筛选菜单标题
  /// 「最新 ▾」（Reddit `Home ▾` 模式），右=搜索落位格（折叠时张开
  /// 迎接胶囊 morph 成的图标）+ 🔔。图标 glyph 统一默认 24（与全 app
  /// AppBar 一致），compact 密度只收触控目标不缩 glyph;左右缘 8 +
  /// compact 按钮内边 8 = glyph 距屏 16（M3 基线）。
  Widget _buildToolbar(bool isLoggedIn, Widget filterMenu) {
    return SizedBox(
      height: _toolbarRowHeight,
      child: Row(
        children: [
          const SizedBox(width: 8),
          // ☰ 全平台常显：分类侧栏的显性入口（侧栏走根 Navigator
          // 路由，rail/底栏任何布局形态下都可用）
          IconButton(
            icon: const Icon(Symbols.menu_rounded),
            onPressed: _openCategoryDrawer,
            tooltip: context.l10n.topics_browseCategories,
            visualDensity: VisualDensity.compact,
          ),
          // 标题区弹性化：窄面板（桌面 master-detail 列表栏）空间不足
          // 时标题内部自行让步（前缀先缩，见 _TitleTabPrefix），刚性
          // Row + Spacer 版在窄面板直接撑破右簇
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: filterMenu),
          ),
          // 搜索落位格：展开态零宽（右簇紧凑无空洞），折叠时随 morph
          // 同曲线张开迎接胶囊缩成的图标（胶囊本体在
          // _CollapsibleHeader 的 overlay 层绘制，这里只占位）
          _SearchSlotSpacer(controller: _headerController),
          if (isLoggedIn && !Responsive.showNavigationRail(context))
            const NotificationIconButton(compact: true),
          if (kDebugMode)
            IconButton(
              icon: const Icon(Symbols.bug_report_rounded),
              visualDensity: VisualDensity.compact,
              onPressed: () => _showTopicIdDialog(context),
              tooltip: context.l10n.topics_debugJump,
            ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  void _openSearch() {
    final pinnedIds = _visiblePinnedIds;
    final categoryMap = ref.read(categoryMapProvider).value;
    final currentCategory = _getCurrentCategory(pinnedIds, categoryMap);
    SearchFilter? filter;
    if (currentCategory != null) {
      String? parentSlug;
      if (currentCategory.parentCategoryId != null) {
        parentSlug = categoryMap?[currentCategory.parentCategoryId]?.slug;
      }
      filter = SearchFilter(
        categoryId: currentCategory.id,
        categorySlug: currentCategory.slug,
        categoryName: currentCategory.name,
        parentCategorySlug: parentSlug,
      );
    }
    // fade 路由：全局 Cupertino 滑动转场会带着整页横移，毁掉胶囊 →
    // 搜索框的 Hero morph（一镜到底）;搜索页单独用淡入配合 Hero 飞行
    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 280),
        pageBuilder: (_, _, _) =>
            SearchPage(initialFilter: filter, heroCapsule: true),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  /// 分类 chips 导航行（可折叠段，40px，仅有收藏分类时存在）：
  /// 全部 + 收藏分类 + ＋。TabBar 降为 chips（YouTube 首页同款），
  /// 与 TabBarView 仍由 _tabController 双向同步；＋ 打开分类侧栏
  /// （分类主入口，订阅设置也在侧栏分类行上）。
  Widget _buildNavRow(List<int> pinnedIds, Map<int, Category>? categoryMap) {
    return SizedBox(
      height: _navRowHeight,
      child: FadingEdgeScrollView(
        child: _CategoryChipsRow(
          tabController: _tabController,
          pinnedIds: pinnedIds,
          categoryMap: categoryMap,
          onReselect: () => ref.read(scrollToTopProvider.notifier).trigger(),
          onManageCategories: _openCategoryDrawer,
          headerController: _headerController,
          selectedChipKey: _selectedChipKey,
        ),
      ),
    );
  }

  /// 已选标签行（可折叠段，仅选了标签时存在）：chips + 紧凑 ＋
  Widget _buildTagsRow(List<String> currentTags) {
    final colorScheme = Theme.of(context).colorScheme;
    final currentCategoryId = _currentCategoryId();
    return SizedBox(
      height: _tagsRowHeight,
      child: Align(
        alignment: Alignment.topLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              for (final tag in currentTags)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: RemovableTagBadge(
                    name: tag,
                    onDeleted: () {
                      final tags = ref.read(tabTagsProvider(currentCategoryId));
                      ref
                          .read(tabTagsProvider(currentCategoryId).notifier)
                          .state = tags
                          .where((t) => t != tag)
                          .toList();
                    },
                    size: const BadgeSize(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      radius: 6,
                      iconSize: 12,
                      fontSize: 12,
                    ),
                  ),
                ),
              InkWell(
                onTap: _openTagSelection,
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    Symbols.add_rounded,
                    size: 14,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 聚合筛选菜单按钮。用 Consumer 局部订阅排序/子过滤状态，收放轻壳
  /// 与 State 整树都不因排序变化而重建。
  Widget _buildFilterMenu(
    bool isLoggedIn,
    TopicListFilter currentFilter,
    Widget titlePrefix,
  ) {
    final showDismiss =
        isLoggedIn &&
        (currentFilter == TopicListFilter.newTopics ||
            currentFilter == TopicListFilter.unread);
    return Consumer(
      builder: (context, ref, _) {
        final order = ref.watch(topicSortOrderProvider);
        final ascending = ref.watch(topicSortAscendingProvider);
        final subset = ref.watch(topicNewSubsetProvider);
        final tagCount = ref
            .watch(tabTagsProvider(_currentCategoryId()))
            .length;
        return TopicFilterMenuButton(
          currentFilter: currentFilter,
          isLoggedIn: isLoggedIn,
          titleStyle: true,
          titlePrefix: titlePrefix,
          onFilterChanged: (filter) {
            ref.read(topicFilterProvider.notifier).setFilter(filter);
          },
          currentSubset: subset,
          onSubsetChanged: (s) =>
              ref.read(topicNewSubsetProvider.notifier).setSubset(s),
          currentOrder: order,
          ascending: ascending,
          onOrderChanged: (o) =>
              ref.read(topicSortOrderProvider.notifier).setOrder(o),
          onToggleAscending: () =>
              ref.read(topicSortAscendingProvider.notifier).toggle(),
          onSelectTags: _openTagSelection,
          selectedTagCount: tagCount,
          onDismissAll: showDismiss
              ? () => _showDismissConfirmDialog(currentFilter)
              : null,
        );
      },
    );
  }

  bool _shouldHandlePointerScroll(PointerScrollEvent event) {
    if (kIsWeb) return false;
    if (!Platform.isMacOS) return false;
    final dx = event.scrollDelta.dx.abs();
    final dy = event.scrollDelta.dy.abs();
    return dy > dx;
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    // 只关心列表的垂直滚动；TabBarView 横滑/TabBar/标签条横向滚动
    // （axis horizontal）全部排除
    if (notification.metrics.axis != Axis.vertical) {
      // TabBarView 横滑：胶囊全程冻结，仅在横滑 settle 完成
      // （ScrollEnd）后按落定 tab 的列表位置对齐一次（morph 跟随器
      // 补平滑过渡）。落定 tab **必须从 PageMetrics.page 推导**：
      // _currentTabIndex 由 TabController 监听器更新，与本通知存在
      // 竞态（chip 点击在动画结束才更新、横滑在过半就更新）——
      // 竞态输了就会按旧 tab 位置对齐，胶囊错误展开，随后又被
      // 收回 = "先显示再自动收起"。
      if (notification.metrics is PageMetrics) {
        if (notification is ScrollStartNotification) {
          _pageTransitioning = true;
          // 抽屉首缘桥只认真手势（dragDetails 非空;挡 ballistic 越界）
          _drawerPullBridge.dragging = notification.dragDetails != null;
          // 横滑起步即校准**所有**已挂载列表到折叠锚位：落定(ScrollEnd)
          // 才适配的话，整个滑动过程邻页都露"头部下缘与内容顶边"之间
          // 的空白带（折叠带内 jump 零视觉跳变，起步做安全）
          _alignAttachedListsToAnchor();
        }
        if (notification is ScrollEndNotification) {
          _pageTransitioning = false;
          _drawerPullBridge.dragging = false;
          // settle 兜底：向右甩/静止松手走 physics 弹道路径（Page
          // ScrollPhysics 在 velocity≤0 且贴 minScrollExtent 时委派
          // parent），拉抽屉中**向左甩**它不委派、自跑 spring——被
          // 冻结物理第一帧掐死后到达这里，按指针速度收尾（dx 负 =
          // 向左 = 关）。两路经 pulling 标志互斥不重复。
          if (_drawerPullBridge.pulling) {
            _drawerPullBridge.pulling = false;
            CategoryDrawerHost.settle(
              notification.dragDetails?.velocity.pixelsPerSecond.dx ?? 0,
            );
          }
          // 折叠状态跨 tab 粘滞：头部纹丝不动，**列表适配头部**。
          // 起步已对齐一轮（_alignAttachedListsToAnchor），这里兜
          // 横滑过程中新挂载的邻页。
          _alignAttachedListsToAnchor();
        }
      }
      return false;
    }

    // 横滑过渡期只滤**非用户事件**：两个 tab 列表同时在场，弹道残留
    // /挂载修正(jumpTo)等无 dragDetails 的位移不该驱动收放;真实的
    // 用户垂直拖拽必须放行（手势仲裁保证与横滑拖拽互斥）—— 曾整段
    // 冻结：横滑 settle 未完就开始滚列表时头部不跟手，settle 一结束
    // 才补折叠动画（"延迟折叠"）。
    if (_pageTransitioning) {
      final userDriven =
          notification is UserScrollNotification ||
          (notification is ScrollStartNotification &&
              notification.dragDetails != null) ||
          (notification is ScrollUpdateNotification &&
              notification.dragDetails != null) ||
          (notification is ScrollEndNotification &&
              notification.dragDetails != null);
      if (!userDriven) return false;
    }

    if (notification is ScrollUpdateNotification) {
      final delta = notification.scrollDelta;
      final metrics = notification.metrics;
      // 底部越界回弹免疫：滚过 maxScrollExtent（iOS 弹性 + 触底加载
      // 的 overscroll）后弹簧回弹是一串负向 delta，会被误读成"用户
      // 向上滚"→ 工具段无故展开。回弹段不喂 enterAlways 累计器;
      // 胶囊段是位置纯函数，天然免疫（深处恒为图标态）。
      final beyondBottom =
          metrics.pixels > metrics.maxScrollExtent ||
          (delta != null && metrics.pixels - delta > metrics.maxScrollExtent);
      if (delta != null && delta != 0) {
        _headerController.handleScroll(
          delta,
          metrics.pixels,
          accumulateBar: !beyondBottom,
        );
      }
      // 发布"距顶进度"到 NavActionBus，底栏据此做动态图标切换
      _publishHomeScrollProgress(metrics.pixels);

      // 列表到达顶部时恢复创建模式
      if (metrics.pixels <= 0 && ref.read(fabRefreshModeProvider)) {
        ref.read(fabRefreshModeProvider.notifier).state = false;
      }
    }

    // 用 UserScrollNotification 追踪用户主动滚动方向（FAB 刷新/创建
    // 模式切换;回弹/惯性不误触发）
    if (notification is UserScrollNotification) {
      if (notification.direction == ScrollDirection.forward) {
        // 向上滚动（朝顶部方向）→ 刷新模式
        if (!ref.read(fabRefreshModeProvider)) {
          ref.read(fabRefreshModeProvider.notifier).state = true;
        }
      } else if (notification.direction == ScrollDirection.reverse) {
        // 向下滚动（深入列表）→ 创建模式
        if (ref.read(fabRefreshModeProvider)) {
          ref.read(fabRefreshModeProvider.notifier).state = false;
        }
      }
    }

    // 拖拽滚动开始时，清理 pointer scroll 的状态，避免影响松手吸附;
    // 并快照手势起点（列表位置 + 工具段收起量：顶带/工具段吸附的
    // 起手锚定迟滞判据）
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _pointerScrollIdleTimer?.cancel();
      _pointerScrolling = false;
      _headerController.noteGestureStart(notification.metrics.pixels);
    }

    if (notification is ScrollEndNotification) {
      // 顶带与深区工具段的吸附都已下沉到 _TopSnapScrollPhysics
      // （弹道级耦合收尾：驱动列表、栏随记账复位，栏与内容一体）。
      // 这里只剩兜底：物理层覆盖不到的残余半开（如 extent 突变、
      // 短列表滚不动）——guard 在 snapBarToNearest 内，正常路径下
      // 恒 no-op。macOS 滚轮的离散 ScrollEnd 由 idle 定时器收口。
      if (_pointerScrolling) return false;
      _headerController.snapBarToNearest(
        velocity: -(notification.dragDetails?.velocity.pixelsPerSecond.dy ?? 0),
        listPixels: notification.metrics.pixels,
      );
    }

    return false;
  }

  void _onPointerScroll(PointerScrollEvent event) {
    _headerController.stopSnap();
    // 滚轮会话（一串离散事件）首帧快照起点：与触摸手势同一套起手
    // 锚定迟滞判据
    if (!_pointerScrolling) {
      final c = _listControllers[_currentCategoryId()];
      if (c != null && c.hasClients && c.positions.length == 1) {
        _headerController.noteGestureStart(c.position.pixels);
      }
    }
    _pointerScrolling = true;
    _pointerScrollIdleTimer?.cancel();
    final delay = event.kind == PointerDeviceKind.mouse
        ? const Duration(milliseconds: 450)
        : const Duration(milliseconds: 250);
    _pointerScrollIdleTimer = Timer(delay, () {
      _pointerScrolling = false;
      if (!mounted) return;
      _snapAfterPointerScroll();
    });
  }

  /// 取消正在进行的 snap
  void _cancelSnap({bool cancelPointerScrollSession = false}) {
    if (cancelPointerScrollSession) {
      _pointerScrollIdleTimer?.cancel();
      _pointerScrolling = false;
    }
    _headerController.stopSnap();
  }

  /// 把所有已挂载的 tab 列表校准到折叠锚位（列表适配头部：比锚位
  /// "浅"时 jump 上去;折叠带内任何位置视觉相同 = 零跳变）。横滑
  /// 起步/落定各跑一轮：起步保证滑动全程邻页不露空白带，落定兜
  /// 滑动中途新挂载的页。
  void _alignAttachedListsToAnchor() {
    for (final entry in _listControllers.entries) {
      final c = entry.value;
      if (!c.hasClients) continue;
      final anchor = _headerController.collapsedAnchorFor(
        _collapsibleExtentFor(
          _visiblePinnedIds,
          ref.read(tabTagsProvider(entry.key)),
        ),
      );
      if (anchor <= 0) continue;
      final position = c.position;
      if (!position.hasPixels || !position.hasContentDimensions) continue;
      if (position.pixels < anchor) {
        position.jumpTo(anchor.clamp(0.0, position.maxScrollExtent));
      }
    }
  }

  /// macOS 滚轮/触控板的 idle 收口：滚轮驱动没有弹道（每个事件都是
  /// 离散 jump），_TopSnapScrollPhysics 拦不到 —— 顶带停在半开时由
  /// 这里驱动列表吸附;深区兜工具段。带内规则与触摸路径同一套起手
  /// 分治迟滞（gestureStartPixels 由滚轮会话首事件写入）。
  void _snapAfterPointerScroll() {
    if (_headerController.isSnapping) return;

    final controller = _listControllers[_currentCategoryId()];
    final hasList =
        controller != null &&
        controller.hasClients &&
        controller.positions.length == 1;

    if (hasList) {
      final position = controller.position;
      final pixels = position.pixels;
      if (pixels > 0 && pixels < _capsuleRowHeight) {
        // 胶囊带：起手分治迟滞（与触摸物理层同规则）
        final fromDeep =
            _headerController.gestureStartPixels >= _capsuleRowHeight;
        double target;
        if (fromDeep) {
          target = pixels < _capsuleRowHeight / 4 ? 0.0 : _capsuleRowHeight;
        } else {
          target = pixels > _capsuleRowHeight * 3 / 4 ? _capsuleRowHeight : 0.0;
        }
        if (target > position.maxScrollExtent) target = 0.0;
        if (target != pixels) {
          position.animateTo(
            target,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          );
        }
        return;
      }
      // 深区工具段半开：耦合收尾——滚列表送工具段到边（增量经
      // enterAlways 记账驱动栏同步，栏与内容一体;overlay-only 的
      // snapBar 会让内容留在原地 = 净位移凭空多出栏高）
      final barExtent = _headerController.barExtent;
      final barOffset = _headerController.barOffset;
      if (pixels >= _capsuleRowHeight &&
          barExtent > 0 &&
          barOffset > 0.5 &&
          barOffset < barExtent - 0.5) {
        final startBar = _headerController.gestureStartBarOffset;
        double targetBar;
        if (startBar >= barExtent - 0.5) {
          targetBar = barOffset <= barExtent * 0.25 ? 0.0 : barExtent;
        } else if (startBar <= 0.5) {
          targetBar = barOffset >= barExtent * 0.75 ? barExtent : 0.0;
        } else {
          targetBar = barOffset > barExtent / 2 ? barExtent : 0.0;
        }
        var listTarget = pixels + (targetBar - barOffset);
        if (targetBar > barOffset && listTarget > position.maxScrollExtent) {
          listTarget = pixels - barOffset;
        }
        listTarget = listTarget.clamp(
          _capsuleRowHeight,
          position.maxScrollExtent,
        );
        if (listTarget != pixels) {
          position.animateTo(
            listTarget,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          );
          return;
        }
      }
    }

    _headerController.snapBarToNearest(
      listPixels: hasList ? controller.position.pixels : null,
    );
  }

  void _publishHomeScrollProgress(double pixels) {
    final progress = pixels < 0 ? 0.0 : pixels;
    final current = ref.read(navScrollProgressProvider(NavEntryIds.home));
    // 节流：变化 >= 4 像素 才更新；或跨越"回顶"阈值 / 过 0 时立即同步
    final atZero = progress == 0 && current != 0;
    final crossed =
        (progress >= navScrollIconThreshold) !=
        (current >= navScrollIconThreshold);
    if (!atZero && !crossed && (progress - current).abs() < 4.0) return;
    ref.read(navScrollProgressProvider(NavEntryIds.home).notifier).state =
        progress;
  }

  /// 构建单个 tab 页面（带水平间距，圆角裁剪在列表内部处理）
  Widget _buildTabPage(int? categoryId, Map<int, Category> categoryMap) {
    // 每个 tab 的顶部 inset 跟随各自的标签行有无（与头部可折叠量的
    // 计算同源，该 tab 激活时两者必然一致）
    final tags = ref.watch(tabTagsProvider(categoryId));
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 12),
      child: _TopicList(
        key: ValueKey(categoryId),
        categoryId: categoryId,
        categoryMap: categoryMap,
        scrollController: _listControllerFor(categoryId),
        topInset: _collapsibleExtentFor(_visiblePinnedIds, tags),
        headerController: _headerController,
        onLoginRequired: _goToLogin,
      ),
    );
  }
}

// ─── Collapsible Header ───

/// overlay 顶栏：状态栏 + 常驻工具栏（☰ + 筛选标题 + 🔕·搜索落位·🔔）
/// + 可折叠段（搜索胶囊行 → 分类 chips 行 → 条件标签行）。
///
/// ## 胶囊 morph（头部内一镜到底）
///
/// 胶囊不放在 Column 流里，而是 Stack overlay 层用 [Rect.lerp] 连续
/// 定位：展开态 = 胶囊行内整行胶囊（40 高、圆角 20），折叠第一段
/// (p1: 0→1) 中收缩宽度、上移，最终停进工具栏右簇的 40×40 落位格 ——
/// 圆角恒定 20，宽度收到 40 时自然成圆形图标；hint 文字随 p1 淡出。
/// Column 里只放一个高度随 p1 收缩的占位，chips/标签段在其下方
/// 正常折叠（p2/p3）。
///
/// 两端 rect 全由行高/边距常量推算（不做运行时测量）：
/// - 起点：left 12, top 状态栏+工具栏+4, size (W-24)×40
/// - 终点：工具栏右簇落位格。从右往左：8(右缘) + [debug 40] +
///   [🔔 40] + 4(间隔) → 落位格右缘；top = 状态栏+(48-40)/2。
///   落位格是否有 🔔/debug 由 [bellVisible] 传入。
///
/// 收放由 [_HeaderCollapseController] 驱动，ListenableBuilder 每帧只
/// 重组轻壳与 rect；工具栏/chips 等重 child 由 State.build 预构建，
/// identical 短路。
class _CollapsibleHeader extends StatelessWidget {
  const _CollapsibleHeader({
    super.key,
    required this.controller,
    required this.statusBarHeight,
    required this.toolbarChild,
    required this.collapsibleChild,
    required this.onSearchTap,
    required this.bellVisible,
    this.flightLabel,
  });

  final _HeaderCollapseController controller;
  final double statusBarHeight;

  /// 常驻工具栏（含 40×40 搜索落位空格）
  final Widget toolbarChild;

  /// 可折叠段（chips 导航行 + 条件标签行；胶囊行由本组件负责）
  final Widget collapsibleChild;

  final VoidCallback onSearchTap;

  /// 工具栏右簇是否有 🔔（决定落位格的横向位置）
  final bool bellVisible;

  /// chip→标题的飞行标签层（覆盖整头部，见 _ChipFlightLabel）
  final Widget? flightLabel;

  @override
  Widget build(BuildContext context) {
    final bgColor = Theme.of(context).scaffoldBackgroundColor;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        // 收放/回弹期间每帧重组 —— 埋点验证它是否落在 jank 帧
        FrameJankMonitor.noteBuild('home:headerFrame');
        // 三路进度（语义分治）：
        // - 胶囊飞行 p1 = 低通平滑的 morph（rect 插值，快甩不瞬移）
        // - 胶囊行占位 pRow = 收起 1:1/展开平滑（布局与内容严格同
        //   步，快收时行先让开，内容顶边贴下缘滑行不被斩）
        // - chips/标签段 pRest = enterAlways 工具段进度
        final p1 = controller.morphProgress;
        final pRow = controller.rowProgress;
        final pRest = controller.barProgress;

        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            // morph 两端 rect（常量推算，见类文档）
            final expandedRect = Rect.fromLTWH(
              12,
              statusBarHeight + _toolbarRowHeight + 4,
              width - 24,
              40,
            );
            // 右簇（从右缘往左）：8 边距 + [debug 40] + [🔔 40]（compact
            // IconButton 触控目标 40，glyph 24）；再往左是落位 spacer
            // （满宽 44 = 40 图标格 + 4 呼吸位），图标格贴住 🔔 左缘
            final debugW = kDebugMode ? 40.0 : 0.0;
            final bellW = bellVisible ? 40.0 : 0.0;
            final slotRight = width - 8 - debugW - bellW;
            final collapsedRect = Rect.fromLTWH(
              slotRight - 40,
              statusBarHeight + (_toolbarRowHeight - 40) / 2,
              40,
              40,
            );
            final t = Curves.easeInOutCubic.transform(p1);
            final capsuleRect = Rect.lerp(expandedRect, collapsedRect, t)!;

            return Stack(
              children: [
                Column(
                  children: [
                    // 背景色只垫到头部实体（窗檐在其下方，需要中间透出
                    // 列表内容，不能被整块背景垫死）
                    ColoredBox(
                      color: bgColor,
                      child: Column(
                        children: [
                          SizedBox(height: statusBarHeight),
                          // 常驻工具栏（搜索落位格在其右簇内空置）
                          toolbarChild,
                          // 胶囊行占位：高度随 pRow 收缩（胶囊本体在
                          // overlay 层随 p1 飞行）
                          SizedBox(height: _capsuleRowHeight * (1.0 - pRow)),
                          // chips/标签段（完全折叠后跳过子树构建）：
                          // **滑入式折叠**——窗口收缩时内容锚定底部，
                          // 顶端被上方 bar 覆盖裁掉，读作"chips 滑入
                          // bar 下方"（原 topCenter+Opacity = 原地压扁
                          // 淡出，与谁都不衔接）。实色滑入不做透明度：
                          // 被不透明 bar 覆盖本身就是消失语义;chips
                          // 的上行与标题前缀的升入连成一条运动线
                          // （分类名"迁入 bar"一镜到底）
                          if (pRest < 1.0)
                            ClipRect(
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                heightFactor: 1.0 - pRest,
                                child: Opacity(
                                  opacity: 1.0 - pRest,
                                  child: collapsibleChild,
                                ),
                              ),
                            ),
                          // 离线提示条：并入头部下缘，在线时零高
                          const OfflineIndicator(),
                        ],
                      ),
                    ),
                  ],
                ),
                // 胶囊 morph 层（Hero 起点：跨页一镜到底的另一段）
                Positioned.fromRect(
                  rect: capsuleRect,
                  child: Hero(
                    tag: kSearchCapsuleHeroTag,
                    flightShuttleBuilder: searchCapsuleFlightShuttle,
                    child: SearchCapsule(
                      onTap: onSearchTap,
                      hintOpacity: (1.0 - t * 1.6).clamp(0.0, 1.0),
                      // 落位后 glyph 24（与 🔔 等同大）;左内边同步收
                      // 使图标在 40 格内居中 (40-24)/2=8
                      iconSize: 20 + 4 * t,
                      iconLeftPadding: 16 - 8 * t,
                      // 收尾阶段灰底渐隐：落位后是纯图标，与 🔔 等
                      // 裸图标按钮同族（带色块停在图标簇里很突兀）
                      backgroundOpacity: (1.0 - (t - 0.55) / 0.4).clamp(
                        0.0,
                        1.0,
                      ),
                    ),
                  ),
                ),
                // chip→标题飞行标签（最上层，覆盖 chips 行与工具栏）
                if (flightLabel != null) Positioned.fill(child: flightLabel!),
              ],
            );
          },
        );
      },
    );
  }
}

/// chip→标题的飞行标签：折叠时选中分类名从 chip 文字位**实测 rect**
/// 连续插值到标题前缀落位（搜索胶囊 morph 同构的第二条一镜到底）。
///
/// 两端 GlobalKey 逐帧测位（chips 行横向可滚、标题宽度随筛选名变化，
/// 静态推算必错位）;字号 13→17、字重 w500→w700、颜色 chip 前景→
/// onSurface 全程 lerp。起点 rect 随 chips 行滑入 bar 同步上移（测
/// 位天然带上），终点由 _TitleTabPrefix 的零尺寸锚提供。落位窗口
/// [0.86, 0.98] 与前缀真名字交叉淡入交棒（rect 已重合，交接不可见）。
/// 「全部」tab（index 0）无前缀不飞。
class _ChipFlightLabel extends StatelessWidget {
  const _ChipFlightLabel({
    required this.headerController,
    required this.tabController,
    required this.nameResolver,
    required this.chipKey,
    required this.anchorKey,
    required this.headerKey,
  });

  final _HeaderCollapseController headerController;
  final TabController tabController;
  final String? Function(int index) nameResolver;

  /// 起点：选中 chip 的文字
  final GlobalKey chipKey;

  /// 终点：标题前缀的零尺寸锚
  final GlobalKey anchorKey;

  /// 参考系：头部根 RenderBox（飞行层与其重合，全局坐标转局部）
  final GlobalKey headerKey;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([
        headerController,
        tabController.animation ?? tabController,
      ]),
      builder: (context, _) {
        final p = headerController.chipFlightProgress;
        if (p <= 0.001 || p >= 0.98) return const SizedBox.shrink();

        final index =
            (tabController.animation?.value ?? tabController.index.toDouble())
                .round()
                .clamp(0, tabController.length - 1);
        final name = nameResolver(index);
        if (name == null) return const SizedBox.shrink();

        // 逐帧实测两端（任一端未挂载/不可见则本帧不画，下一帧自愈）
        final headerBox =
            headerKey.currentContext?.findRenderObject() as RenderBox?;
        final chipBox =
            chipKey.currentContext?.findRenderObject() as RenderBox?;
        final anchorBox =
            anchorKey.currentContext?.findRenderObject() as RenderBox?;
        if (headerBox == null ||
            !headerBox.attached ||
            chipBox == null ||
            !chipBox.attached ||
            anchorBox == null ||
            !anchorBox.attached) {
          return const SizedBox.shrink();
        }
        final chipTopLeft = chipBox.localToGlobal(
          Offset.zero,
          ancestor: headerBox,
        );
        final anchorTopLeft = anchorBox.localToGlobal(
          Offset.zero,
          ancestor: headerBox,
        );

        final t = Curves.easeInOutCubic.transform(p);
        // 透明度包络：起飞段 [0,0.10] 淡入（与 chip 文字渐隐交叉，
        // 避免两份文字瞬时叠亮）→ 飞行段全显 → 落位段 [0.86,0.98]
        // 淡出（与前缀真名字淡入互补交棒）
        final appear = (p / 0.10).clamp(0.0, 1.0);
        final handoff = 1.0 - ((p - 0.86) / 0.12).clamp(0.0, 1.0);
        final opacity = appear * handoff;
        // 字排版两端参数（与 chip 文字/前缀文字样式严格同参）——
        // 字号/字重/颜色随行程连续变深（13→17、w500→w700、chip
        // 前景→onSurface）
        final fontSize = ui.lerpDouble(13.0, 17.0, t)!;
        final weight = FontWeight.lerp(FontWeight.w500, FontWeight.w700, t)!;
        final color = Color.lerp(
          colorScheme.onSecondaryContainer,
          colorScheme.onSurface,
          t,
        )!;
        // 终点基线对齐：锚是零尺寸点（挂在前缀 Row 的 centerLeft
        // 侧），飞行文字以自身高度对 center 对齐;起点直接用 chip
        // 文字 topLeft（同为文字框原点）
        final endTop = anchorTopLeft.dy - fontSize * 1.2 / 2;
        final pos = Offset(
          ui.lerpDouble(chipTopLeft.dx, anchorTopLeft.dx, t)!,
          ui.lerpDouble(chipTopLeft.dy, endTop, t)!,
        );

        return IgnorePointer(
          child: Stack(
            children: [
              Positioned(
                left: pos.dx,
                top: pos.dy,
                child: Opacity(
                  opacity: opacity,
                  child: Text(
                    name,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: fontSize,
                      height: 1.2,
                      fontWeight: weight,
                      color: color,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 列表顶部消隐纱：画在每个 tab 列表自身的 ClipRRect 内 —— 随横滑
/// 一起移动（header 固定层版本在收起态罩住列表顶端 = 横滑"冻结带"
/// + 糊掉包裹圆角，已废）。
///
/// 位置钉在头部下缘（seam = visibleExtentFor，逐帧跟随收放），
/// 强度 = 本列表内容顶边越过 seam 的深度（8px 呼吸位内 0→1）：
/// - 展开态静止在顶：内容顶边在 seam 下方呼吸位里，强度 0，首卡
///   无纱（"顶部不应该有羽化"）
/// - 收放 1:1 擦洗：内容顶边贴呼吸位滑行不被裁，强度 0，首卡圆角
///   "顶上去"全程清晰;窗檐已删，chips 半高时不再有独立圆角弧在
///   卡片上咬出豁口（"缺一块"）
/// - 正常浏览（任意态深滚，内容真被 seam 裁切）：满强度 bg→透明
///   消散，无硬切直角 —— composer 顶栏同款消散语言
class _TopEdgeFade extends StatelessWidget {
  const _TopEdgeFade({
    required this.headerController,
    required this.scrollController,
    required this.topInset,
  });

  final _HeaderCollapseController headerController;
  final ScrollController scrollController;
  final double topInset;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).scaffoldBackgroundColor;
    return ListenableBuilder(
      listenable: Listenable.merge([headerController, scrollController]),
      builder: (context, _) {
        final seam = headerController.visibleExtentFor(topInset);
        final collapsed = topInset - seam;
        final pixels =
            scrollController.hasClients &&
                scrollController.positions.length == 1
            ? scrollController.position.pixels
            : 0.0;
        final cut = ((pixels - collapsed) / 8.0).clamp(0.0, 1.0);
        if (cut <= 0.004) return const SizedBox.shrink();
        return Positioned(
          top: seam,
          left: 0,
          right: 0,
          height: 24,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  // 多停靠点近似 smoothstep（线性两点在梯度尾部有
                  // 可感的"边"），整体强度随 cut
                  colors: [
                    color.withValues(alpha: cut),
                    color.withValues(alpha: 0.85 * cut),
                    color.withValues(alpha: 0.5 * cut),
                    color.withValues(alpha: 0.15 * cut),
                    color.withValues(alpha: 0.0),
                  ],
                  stops: const [0.0, 0.25, 0.5, 0.75, 1.0],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 折叠态标题前缀：chips 收起后「你在哪个分类」迁入标题——
/// 「水源 · 最新 ▾」。与 chips 淡出共用同一进度源（barProgress），
/// 宽度 ClipRect+widthFactor 连续显隐，读作信息在两处间"交接"，
/// 零新增常驻元素。折叠中横滑切 tab：名字快速淡切（与 chips 高亮
/// 同款 round 判定;文字真跟手交叉会叠影）+ AnimatedSize 平滑宽差。
/// 「全部」tab 无前缀（全部=无分类，前缀出现即有信息量），宽度
/// 收敛到 0 而非跳没。
class _TitleTabPrefix extends StatelessWidget {
  const _TitleTabPrefix({
    required this.headerController,
    required this.tabController,
    required this.nameResolver,
    required this.anchorKey,
  });

  final _HeaderCollapseController headerController;
  final TabController tabController;

  /// tab index → 分类名（0/越界 = null，无前缀）
  final String? Function(int index) nameResolver;

  /// 落位锚（零尺寸，常驻挂载）：chip→标题的飞行标签以此为终点
  /// 测位（见 _CollapsibleHeader 飞行层）
  final GlobalKey anchorKey;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 锚点必须常驻（p=0 时飞行层也可能在测终点——展开方向起飞点）
    final anchor = SizedBox(key: anchorKey, width: 0, height: 0);
    return ListenableBuilder(
      listenable: Listenable.merge([
        headerController,
        tabController.animation ?? tabController,
      ]),
      builder: (context, _) {
        final pRaw = headerController.barProgress;
        final p = Curves.easeInOutCubic.transform(pRaw);
        // 展开态（chips 在场）标题只管筛选，前缀零存在
        if (p <= 0.001) {
          return Row(mainAxisSize: MainAxisSize.min, children: [anchor]);
        }

        final index =
            (tabController.animation?.value ?? tabController.index.toDouble())
                .round()
                .clamp(0, tabController.length - 1);
        final name = nameResolver(index);

        // 名字交棒：飞行标签（_CollapsibleHeader 层）承担 0.86 之前
        // 的呈现，真名字在落位窗口 [0.86, 0.98] 淡入接棒 —— 两者
        // rect 已重合，交接不可见
        final nameOpacity = ((pRaw - 0.86) / 0.12).clamp(0.0, 1.0);
        final label = name == null
            ? const SizedBox.shrink(key: ValueKey('none'))
            : Row(
                key: ValueKey(name),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: ConstrainedBox(
                      // 长分类名截断：上限 110，窄面板下随外层 Flexible
                      // 进一步收缩（省略号），空间永远先由前缀让出
                      constraints: const BoxConstraints(maxWidth: 110),
                      child: Opacity(
                        opacity: nameOpacity,
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    child: Text(
                      '·',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.55,
                        ),
                      ),
                    ),
                  ),
                ],
              );

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            anchor,
            Transform.translate(
              // 「·」等余部轻微升入（12px）;名字本体的运动由飞行
              // 标签承担（translate 在 ClipRect 外，途中不被裁）
              offset: Offset(0, (1.0 - p) * 12),
              child: ClipRect(
                child: Align(
                  alignment: Alignment.centerLeft,
                  widthFactor: p,
                  child: Opacity(
                    opacity: p,
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.centerLeft,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 160),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeIn,
                        // 默认 layout 居中叠放，名字宽差时会左右晃;
                        // 钉左缘
                        layoutBuilder: (currentChild, previousChildren) =>
                            Stack(
                              alignment: Alignment.centerLeft,
                              children: [...previousChildren, ?currentChild],
                            ),
                        child: label,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 工具栏搜索落位 spacer：展开态零宽（右簇紧凑无空洞），随折叠进度
/// 张开到 44px（40 图标格 + 4 间隔），与胶囊 morph 同曲线 —— 🔔 等
/// 右侧成员不动（Spacer 吸收），左侧的分类铃铛被自然推开。
class _SearchSlotSpacer extends StatelessWidget {
  const _SearchSlotSpacer({required this.controller});

  final _HeaderCollapseController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final t = Curves.easeInOutCubic.transform(controller.morphProgress);
        return SizedBox(width: 44 * t);
      },
    );
  }
}

/// 分类 chips 导航行：全部 + 已 pin 分类 + ＋（管理入口）。
///
/// 与 [TabBarView] 共用同一个 [TabController]：点 chip →
/// animateTo(index)；横滑列表 → 监听 controller.animation 高亮跟手
/// 迁移（用四舍五入的 index 判定，滑过半即切换选中态，无需等
/// settle）。选中 chip 重复点击触发 [onReselect]（回顶）。
///
/// chip 内不挂任何随选中态增减的附件（曾试过选中 chip 尾部长订阅
/// 铃铛：宽度随选中迁移变化，整行弹宽必抖，已废）——分类的操作
/// （订阅/收藏）统一在 ☰ 侧栏的分类行上。
class _CategoryChipsRow extends StatelessWidget {
  const _CategoryChipsRow({
    required this.tabController,
    required this.pinnedIds,
    required this.categoryMap,
    required this.onReselect,
    required this.onManageCategories,
    required this.headerController,
    required this.selectedChipKey,
  });

  final TabController tabController;
  final List<int> pinnedIds;
  final Map<int, Category>? categoryMap;
  final VoidCallback onReselect;
  final VoidCallback onManageCategories;
  final _HeaderCollapseController headerController;

  /// 选中 chip 的文字测位 key：chip→标题飞行标签的起点
  final GlobalKey selectedChipKey;

  @override
  Widget build(BuildContext context) {
    final labels = <String>[
      S.current.common_all,
      for (final id in pinnedIds) categoryMap?[id]?.name ?? '...',
    ];

    return AnimatedBuilder(
      animation: Listenable.merge([
        tabController.animation ?? tabController,
        headerController,
      ]),
      builder: (context, _) {
        final selected = (tabController.animation?.value ?? 0).round().clamp(
          0,
          labels.length - 1,
        );
        // 折叠中选中 chip 的名字交给飞行标签代言（本体文字渐隐，
        // 药丸底随行滑入 bar 下）;「全部」tab 无前缀不飞，本体保留
        final flying =
            selected > 0 && headerController.chipFlightProgress > 0.001;
        return ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: [
            for (var i = 0; i < labels.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _CategoryChip(
                  label: labels[i],
                  selected: i == selected,
                  labelKey: i == selected ? selectedChipKey : null,
                  // 前 40% 行程线性渐隐把呈现让给飞行标签（两者起点
                  // rect 重合，交叉淡化不可见）
                  labelOpacity: i == selected && flying
                      ? (1.0 - headerController.chipFlightProgress / 0.4).clamp(
                          0.0,
                          1.0,
                        )
                      : 1.0,
                  onTap: () {
                    if (i == tabController.index) {
                      onReselect();
                    } else {
                      tabController.animateTo(i);
                    }
                  },
                ),
              ),
            // ＋：分类管理入口（pin/调序/订阅都在侧栏里）
            _CategoryChip(
              label: '＋',
              selected: false,
              isAction: true,
              tooltip: S.current.topics_browseCategories,
              onTap: onManageCategories,
            ),
          ],
        );
      },
    );
  }
}

/// 单个分类 chip：药丸形（YouTube 首页同款）——选中 = onSurface 反色
/// 填充 + 加粗，未选中 = surfaceContainerHigh 灰底；[isAction] 的 ＋
/// 入口用更淡的底色与次级前景，视觉上是"操作"不是"分类"
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.isAction = false,
    this.tooltip,
    this.labelKey,
    this.labelOpacity = 1.0,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool isAction;
  final String? tooltip;

  /// 文字测位 key（选中 chip：飞行标签起点）
  final Key? labelKey;

  /// 文字透明度（折叠中选中 chip 的名字交飞行标签代言时渐隐）
  final double labelOpacity;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final Color bg;
    final Color fg;
    if (selected) {
      // 主题色系（曾用 onSurface 黑白反色，用户点名要主题色）：
      // secondaryContainer = M3 filter chip 选中态标准用色
      bg = colorScheme.secondaryContainer;
      fg = colorScheme.onSecondaryContainer;
    } else if (isAction) {
      bg = colorScheme.surfaceContainerHighest.withValues(alpha: 0.35);
      fg = colorScheme.onSurfaceVariant.withValues(alpha: 0.8);
    } else {
      bg = colorScheme.surfaceContainerHigh;
      fg = colorScheme.onSurface.withValues(alpha: 0.85);
    }
    final chip = Material(
      color: bg,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          child: Opacity(
            opacity: labelOpacity,
            child: Text(
              label,
              key: labelKey,
              style: TextStyle(
                fontSize: 13,
                height: 1.0,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
    final sized = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: chip,
    );
    return tooltip == null ? sized : Tooltip(message: tooltip!, child: sized);
  }
}

// ─── TopicList ───

/// 话题列表（每个 tab 一个实例，根据 categoryId + topicFilterProvider 获取数据）
class _TopicList extends ConsumerStatefulWidget {
  final VoidCallback onLoginRequired;
  final int? categoryId;
  final Map<int, Category> categoryMap;

  /// 页面持有的滚动控制器（snap 需要从页面驱动当前列表）
  final ScrollController scrollController;

  /// 顶部恒定 inset（悬浮可折叠段的高度，随有无自定义 tab 变化）
  final double topInset;

  /// 头部收放控制器：骨架屏/错误页等非滚动态的顶部让位需实时贴着
  /// 头部下缘（visibleExtentFor），否则胶囊折叠时露 48px 空洞
  final _HeaderCollapseController headerController;

  const _TopicList({
    super.key,
    required this.onLoginRequired,
    required this.scrollController,
    required this.topInset,
    required this.headerController,
    required this.categoryMap,
    this.categoryId,
  });

  @override
  ConsumerState<_TopicList> createState() => _TopicListState();
}

class _TopicListState extends ConsumerState<_TopicList>
    with AutomaticKeepAliveClientMixin {
  final _refreshIndicatorKey = GlobalKey<M3eRefreshIndicatorState>();

  /// overlay 头部架构下无 NestedScrollView 注入的 PrimaryScrollController，
  /// 回顶/键盘导航都走页面下发的控制器
  ScrollController get _scrollController => widget.scrollController;
  late final ShortcutScopeBinding _listShortcutBinding = ShortcutScopeBinding(
    ref: ref,
    scope: ShortcutScope.master,
  );
  bool _isLoadingNewTopics = false;

  /// 需要高亮的话题 IDs（loadBefore 插入后设置，渐变消失后清除）
  final Set<int> _highlightedTopicIds = {};

  /// 话题卡片实例缓存(key: topic.id):返回本页(pop)或任意 provider
  /// 更新引发的整列表 rebuild 中,输入未变的卡片直接复用实例,框架在
  /// Element.updateChild 处整棵短路(诊断数据:pop 返回列表后整页
  /// rebuild 单次 35~45ms,大头是可见卡片全量重建)。Topic 为不可变
  /// 数据,引用同即内容同;卡片外观偏好由 TopicCard 内部 Consumer
  /// 自行订阅,复用实例不影响其响应。theme/断点变化时整体失效。
  final Map<int, ({Object signature, Widget widget})> _topicItemCache = {};
  static const _topicItemCacheCapacity = 64;

  /// keyed reconcile 的行 key 常量(pill/提示条/footer 三个固定行)
  static const _pillKeyValue = 'topics-pill';
  static const _filterHintKeyValue = 'topics-filter-hint';
  static const _footerKeyValue = 'topics-footer';

  /// topic.id → 可见列表 index,供 findChildIndexCallback O(1) 反查。
  /// 行 key 化 + 该回调是列表版"锚定"的身份基础:顶部插入新话题 / pill
  /// 出现导致全列表 index 平移时,Element/RenderObject 跟随 topic.id
  /// 迁移而不是按 index 换内容(无 key 时视口内每行会"换脸"成上一条),
  /// 迁移残留的布局位移再由列表尾部的 AnchorGuardSliver 同帧修正。
  List<Topic>? _visibleIndexSource;
  Map<int, int> _topicIdToVisibleIndex = const {};

  /// 上次 build 的列表头部行数(pill/过滤提示),变化 = 行 index 平移
  int? _lastHeaderOffset;

  Map<int, int> _visibleIndexMapFor(List<Topic> topics) {
    if (!identical(_visibleIndexSource, topics)) {
      final hadPrevious = _visibleIndexSource != null;
      _visibleIndexSource = topics;
      _topicIdToVisibleIndex = <int, int>{
        for (var i = 0; i < topics.length; i++) topics[i].id: i,
      };
      // 只保留仍存在的数据，并限制缓存规模。缓存的是 Widget 配置而非
      // RenderObject；64 条足够覆盖数屏父层 rebuild，同时避免数据越多
      // TopicCard 配置和闭包永久累积、放大 GC 压力。
      _topicItemCache.removeWhere(
        (topicId, _) => !_topicIdToVisibleIndex.containsKey(topicId),
      );
      // 列表数据换代(顶部插入/全量替换/单行刷新):静默结构变化落地帧,
      // 武装锚定哨兵补偿 keyed 迁移产生的位移。首建不武装。
      if (hadPrevious) {
        AnchorGuardSliver.arm();
      }
    }
    return _topicIdToVisibleIndex;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _topicItemCache.clear();
  }

  /// 本地缓存的话题数据，非当前 tab 时使用此缓存渲染，不订阅 provider
  AsyncValue<List<Topic>>? _cachedTopicsAsync;

  /// 键盘焦点索引（J/K 导航用）
  int _keyboardFocusIndex = -1;

  /// J/K 防抖：上次触发时间
  DateTime _lastKeyNavTime = DateTime(0);

  final TopicLoadMoreCoordinator _loadMoreCoordinator =
      TopicLoadMoreCoordinator();
  List<String> _lastAutoLoadKeywords = const [];
  Set<String> _lastAutoLoadBlockedUsernames = const <String>{};
  bool? _lastAutoLoadWholeWord;

  @override
  bool get wantKeepAlive => true;

  /// 列表区域顶部圆角
  static const _topBorderRadius = BorderRadius.only(
    topLeft: Radius.circular(12),
    topRight: Radius.circular(12),
  );

  /// overlay 头部可折叠段悬浮在列表上方，列表内容顶部让出的恒定 inset
  double get _headerInset => widget.topInset;

  void scrollToTop() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  /// 清除当前 tab 的高亮和"新话题"计数
  void _clearIncomingState() {
    _highlightedTopicIds.clear();
    ref
        .read(latestChannelProvider.notifier)
        .clearNewTopicsForCategory(widget.categoryId);
  }

  /// J/K 键盘导航：移动焦点（含 150ms 防抖）
  void _moveKeyboardFocus(int delta, AsyncValue<List<Topic>> topicsAsync) {
    final now = DateTime.now();
    if (now.difference(_lastKeyNavTime).inMilliseconds < 150) return;
    _lastKeyNavTime = now;

    final topics = topicsAsync.asData?.value;
    if (topics == null || topics.isEmpty) return;

    final anchorIndex = _resolveKeyboardAnchorIndex(topics);
    final newIndex = (anchorIndex + delta).clamp(0, topics.length - 1);
    if (newIndex == _keyboardFocusIndex) return;

    setState(() => _keyboardFocusIndex = newIndex);

    final topic = topics[newIndex];
    _openTopic(topic);

    // 滚动到可见区域
    if (_scrollController.hasClients) {
      // 估算位置（顶部 inset + 每个 item 约 80px 高度）
      final estimatedPosition = _headerInset + newIndex * 80.0;
      final viewport = _scrollController.position.viewportDimension;
      final current = _scrollController.position.pixels;

      if (estimatedPosition < current ||
          estimatedPosition > current + viewport - 80) {
        _scrollController.animateTo(
          estimatedPosition.clamp(
            0.0,
            _scrollController.position.maxScrollExtent,
          ),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    }
  }

  /// Enter 键打开当前焦点话题
  void _openFocusedTopic(AsyncValue<List<Topic>> topicsAsync) {
    final topics = topicsAsync.asData?.value;
    if (topics == null || topics.isEmpty) return;
    final focusIndex = _resolveKeyboardAnchorIndex(topics);
    if (focusIndex < 0 || focusIndex >= topics.length) return;

    final topic = topics[focusIndex];
    // 强制用 Navigator push 打开（而非 Master-Detail 内选中）
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topic.id,
          initialTitle: topic.title,
          scrollToPostNumber: topic.lastReadPostNumber,
        ),
      ),
    );
  }

  int _resolveKeyboardAnchorIndex(List<Topic> topics) {
    final selectedTopicId = ref.read(selectedTopicProvider).topicId;
    final selectedIndex = selectedTopicId == null
        ? -1
        : topics.indexWhere((topic) => topic.id == selectedTopicId);

    if (_keyboardFocusIndex >= 0 && _keyboardFocusIndex < topics.length) {
      if (selectedIndex != -1 &&
          topics[_keyboardFocusIndex].id != selectedTopicId) {
        return selectedIndex;
      }
      return _keyboardFocusIndex;
    }

    if (selectedIndex != -1) {
      return selectedIndex;
    }

    return -1;
  }

  void _syncKeyboardFocusToIndex(int index) {
    if (_keyboardFocusIndex == index) return;
    setState(() => _keyboardFocusIndex = index);
  }

  void _syncKeyboardFocusToTopicId(int topicId) {
    final index = _topicIdToVisibleIndex[topicId];
    if (index != null) _syncKeyboardFocusToIndex(index);
  }

  Object? _categorySignatureFor(Topic topic) {
    final categoryId = int.tryParse(topic.categoryId);
    final category = widget.categoryMap[categoryId];
    if (category == null) return null;
    if (!topic.pinned) {
      return (name: category.name, color: category.color);
    }
    final parent = widget.categoryMap[category.parentCategoryId];
    return (
      color: category.color,
      icon: category.icon,
      logo: category.uploadedLogo,
      parentIcon: parent?.icon,
      parentLogo: parent?.uploadedLogo,
    );
  }

  /// 触发 loadMore，并在关键词命中率高、可见增量不足时自动续加载，
  /// 避免用户在话题列表里看到「滑到底但只多了 1-2 条」。
  Future<void> _triggerLoadMore(int? providerKey) async {
    final notifier = ref.read(topicListProvider(providerKey).notifier);

    final prefs = ref.read(preferencesProvider);
    final keywords = prefs.normalizedFilterKeywords;
    final wholeWord = prefs.topicFilterWholeWord;
    final blockedUsernames = prefs.normalizedBlockedUsernames;

    int itemCount() {
      return ref.read(topicListProvider(providerKey)).value?.length ?? 0;
    }

    int visibleItemCount() {
      final raw =
          ref.read(topicListProvider(providerKey)).value ?? const <Topic>[];
      final (visible, _, _) = TopicKeywordFilter.apply(
        raw,
        normalizedKeywords: keywords,
        wholeWord: wholeWord,
        blockedUsernames: blockedUsernames,
      );
      return visible.length;
    }

    await _loadMoreCoordinator.loadTopicPage(
      loadMore: notifier.loadMore,
      hasMore: () => notifier.hasMore,
      isActive: () => mounted,
      itemCount: itemCount,
      visibleItemCount: visibleItemCount,
      hasKeywordFilter: keywords.isNotEmpty || blockedUsernames.isNotEmpty,
    );
  }

  void _syncAutoLoadFilter(
    List<String> keywords,
    bool wholeWord,
    Set<String> blockedUsernames,
  ) {
    if (listEquals(_lastAutoLoadKeywords, keywords) &&
        _lastAutoLoadWholeWord == wholeWord &&
        setEquals(_lastAutoLoadBlockedUsernames, blockedUsernames)) {
      return;
    }
    _lastAutoLoadKeywords = List.unmodifiable(keywords);
    _lastAutoLoadWholeWord = wholeWord;
    _lastAutoLoadBlockedUsernames = Set.unmodifiable(blockedUsernames);
    _loadMoreCoordinator.resetCooldown();
  }

  void _openTopic(Topic topic) {
    final canShowDetailPane = MasterDetailLayout.canShowBothPanesFor(context);

    if (canShowDetailPane) {
      ref
          .read(selectedTopicProvider.notifier)
          .select(
            topicId: topic.id,
            initialTitle: topic.title,
            scrollToPostNumber: topic.lastReadPostNumber,
          );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topic.id,
          initialTitle: topic.title,
          scrollToPostNumber: topic.lastReadPostNumber,
          autoSwitchToMasterDetail: true,
        ),
      ),
    );
  }

  @override
  void dispose() {
    if (PlatformUtils.isDesktop) {
      _listShortcutBinding.disposeDeferred();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 需要

    final providerKey = widget.categoryId;
    // 本页外层固定有 12px 左右留白；TopicCard 内部再扣 24px padding、
    // 32px 头像和 8px 间距，因此移动端元信息区宽度 = 屏宽 - 88。
    // 由列表层一次计算并传入，避开 Sliver 布局阶段的逐卡 LayoutBuilder。
    final double? statsAvailableWidth = Responsive.isMobile(context)
        ? MediaQuery.sizeOf(context).width - 88
        : null;
    final statsWidthTier = statsAvailableWidth == null
        ? null
        : (
            showLikes: statsAvailableWidth >= 300,
            showViews: statsAvailableWidth >= 460,
          );
    final isCurrentTab =
        ref.watch(currentTabCategoryIdProvider) == widget.categoryId;

    // 当前 tab：watch provider 建立订阅，并缓存到本地
    // 非当前 tab：stale 显示 loading，否则显示缓存数据；均不订阅 provider
    final AsyncValue<List<Topic>> topicsAsync;
    if (isCurrentTab) {
      topicsAsync = ref.watch(topicListProvider(providerKey));
      _cachedTopicsAsync = topicsAsync;

      // 以下 listener 仅当前 tab 需要
      ref.listen(fabRefreshSignalProvider, (_, _) {
        _refreshIndicatorKey.currentState?.show();
      });
      // 回顶信号：头部展开由 _TopicsPageState 处理，列表回滚在这里
      ref.listen(scrollToTopProvider, (_, _) {
        scrollToTop();
      });
      ref.listen(tabTagsProvider(widget.categoryId), (prev, next) {
        if (prev != next) {
          _loadMoreCoordinator.resetCooldown();
          ref.read(topicListProvider(widget.categoryId).notifier).refresh();
          _clearIncomingState();
        }
      });
      ref.listen(topicListGlobalParamsSignal, (_, _) {
        _loadMoreCoordinator.resetCooldown();
        _clearIncomingState();
      });
    } else {
      // stale 时直接显示 loading，滑动动画中就能看到骨架屏
      final isStale = ref.watch(staleTabsProvider).contains(widget.categoryId);
      topicsAsync = isStale
          ? const AsyncValue.loading()
          : (_cachedTopicsAsync ?? const AsyncValue.loading());
    }

    final keywords = ref.watch(
      preferencesProvider.select((p) => p.normalizedFilterKeywords),
    );
    final wholeWord = ref.watch(
      preferencesProvider.select((p) => p.topicFilterWholeWord),
    );
    final blockedUsernames = ref.watch(
      preferencesProvider.select((p) => p.normalizedBlockedUsernames),
    );
    _syncAutoLoadFilter(keywords, wholeWord, blockedUsernames);
    var hiddenCount = 0;
    var hiddenByBlocked = 0;
    final visibleTopicsAsync = topicsAsync.whenData((topics) {
      final (visible, hidden, byBlocked) = TopicKeywordFilter.apply(
        topics,
        normalizedKeywords: keywords,
        wholeWord: wholeWord,
        blockedUsernames: blockedUsernames,
      );
      hiddenCount = hidden;
      hiddenByBlocked = byBlocked;
      return visible;
    });
    final selectedTopicId = ref.watch(selectedTopicProvider).topicId;
    // 列表层读取一次；itemBuilder 冷挂载每张卡时直接复用结果。
    final enableLongPress = ref.watch(
      preferencesProvider.select((p) => p.longPressPreview),
    );
    // 话题卡自定义样式:改设置触发列表 rebuild(排版层直读全局快照),
    // 并进 widget 缓存签名防命中旧卡
    final topicCardStyle = ref.watch(
      preferencesProvider.select((p) => p.topicCardStyle),
    );

    // 桌面端：注册 J/K/Enter 导航到主面板快捷键
    if (PlatformUtils.isDesktop && isCurrentTab) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _listShortcutBinding.register(context, {
          ShortcutAction.nextItem: () =>
              _moveKeyboardFocus(1, visibleTopicsAsync),
          ShortcutAction.previousItem: () =>
              _moveKeyboardFocus(-1, visibleTopicsAsync),
          ShortcutAction.openItem: () => _openFocusedTopic(visibleTopicsAsync),
        });
      });
    } else if (PlatformUtils.isDesktop) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _listShortcutBinding.clear();
      });
    }

    return visibleTopicsAsync.when(
      data: (topics) {
        if (topics.isEmpty) {
          // 空态列表滚动范围 ~0，与头部无位置互动，让位同骨架屏走
          // 实时口径（静态 _headerInset 在折叠态下露空洞）
          return ListenableBuilder(
            listenable: widget.headerController,
            builder: (context, _) {
              final visible = widget.headerController.visibleExtentFor(
                widget.topInset,
              );
              return M3eRefreshIndicator(
                edgeOffset: visible,
                onRefresh: () async {
                  _loadMoreCoordinator.resetCooldown();
                  try {
                    // ignore: unused_result
                    await ref.refresh(topicListProvider(providerKey).future);
                  } catch (_) {}
                },
                child: ClipRRect(
                  borderRadius: _topBorderRadius,
                  child: ListView(
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.only(top: visible),
                    children: [
                      const SizedBox(height: 100),
                      Center(child: Text(context.l10n.topics_noTopics)),
                    ],
                  ),
                ),
              );
            },
          );
        }

        final incomingState = ref.watch(latestChannelProvider);
        final currentFilter = ref.read(topicFilterProvider);
        final hasNewTopics =
            currentFilter == TopicListFilter.latest &&
            incomingState.hasIncomingForCategory(widget.categoryId);
        final newTopicCount = incomingState.incomingCountForCategory(
          widget.categoryId,
        );
        final newTopicOffset = hasNewTopics ? 1 : 0;
        final hintOffset = hiddenCount > 0 ? 1 : 0;
        final headerOffset = newTopicOffset + hintOffset;
        final idToIndex = _visibleIndexMapFor(topics);
        // pill/过滤提示行出现或消失 = 全列表行 index 平移(数据身份未变,
        // _visibleIndexMapFor 检测不到),同样属于静默结构变化,武装哨兵
        if (_lastHeaderOffset != null && _lastHeaderOffset != headerOffset) {
          AnchorGuardSliver.arm();
        }
        _lastHeaderOffset = headerOffset;

        return DesktopRefreshIndicator(
          refreshIndicatorKey: _refreshIndicatorKey,
          refreshNotifier: masterRefreshNotifier,
          // 头部可折叠段悬浮在列表上方;列表贴顶时头部必然全展开
          // （见 _HeaderCollapseController.handleScrollDelta 的上限规则），
          // spinner 固定从展开头部下缘冒出
          edgeOffset: _headerInset,
          shouldRefresh: () =>
              ref.read(currentTabCategoryIdProvider) == widget.categoryId,
          onRefresh: () async {
            _loadMoreCoordinator.resetCooldown();
            try {
              // ignore: unused_result
              await ref.refresh(topicListProvider(providerKey).future);
            } catch (_) {}
            if (ref.read(topicFilterProvider) == TopicListFilter.latest) {
              ref
                  .read(latestChannelProvider.notifier)
                  .clearNewTopicsForCategory(widget.categoryId);
            }
          },
          child: ClipRRect(
            borderRadius: _topBorderRadius,
            child: Stack(
              children: [
                NotificationListener<ScrollUpdateNotification>(
                  onNotification: (notification) {
                    if (notification.depth == 0) {
                      final distance =
                          notification.metrics.maxScrollExtent -
                          notification.metrics.pixels;
                      if (_loadMoreCoordinator.shouldTriggerForDistance(
                        distance,
                      )) {
                        _triggerLoadMore(providerKey);
                      }
                    }
                    return false;
                  },
                  child: CustomScrollView(
                    controller: _scrollController,
                    // 顶带吸附下沉在弹道层（继承惯性速度的弹簧 + 起手
                    // 分治迟滞，见 _TopSnapScrollPhysics）
                    physics: _TopSnapScrollPhysics(
                      controller: widget.headerController,
                      parent: const AlwaysScrollableScrollPhysics(),
                    ),
                    slivers: [
                      SliverPadding(
                        // 底部让出 extendBody 注入的底栏高度（底栏滑出式后
                        // 内容延伸到底栏后面）
                        padding: EdgeInsets.only(
                          top: _headerInset + 8,
                          bottom: 12 + MediaQuery.paddingOf(context).bottom,
                        ),
                        sliver: SliverList.builder(
                          itemCount: topics.length + headerOffset + 1,
                          // 卡片无 keepalive 需求(无视频/表单/KeepAliveNotification
                          // 使用者),默认的 AutomaticKeepAlive+_SelectionKeepAlive
                          // 两层 State 对快滚单卡首建是纯税,关掉
                          addAutomaticKeepAlives: false,
                          // keyed reconcile:pill 出现/新话题插入/全量替换导致
                          // index 平移时,已有行的 Element/RenderObject 按 key
                          // 迁移,而不是按 index 复用"换脸"(无 key 时视口内
                          // 每行会瞬间变成相邻一条的内容)。迁移残留的布局
                          // 位移由列表尾部的 AnchorGuardSliver 同帧修正。
                          findChildIndexCallback: (key) {
                            if (key is! ValueKey<String>) return null;
                            final value = key.value;
                            if (value == _pillKeyValue) {
                              return hasNewTopics ? 0 : null;
                            }
                            if (value == _filterHintKeyValue) {
                              return hintOffset > 0 ? newTopicOffset : null;
                            }
                            if (value == _footerKeyValue) {
                              return topics.length + headerOffset;
                            }
                            if (value.startsWith('topic-')) {
                              final id = int.tryParse(value.substring(6));
                              final topicIndex = id == null
                                  ? null
                                  : idToIndex[id];
                              if (topicIndex != null) {
                                return topicIndex + headerOffset;
                              }
                            }
                            return null;
                          },
                          itemBuilder: (context, index) {
                            if (hasNewTopics && index == 0) {
                              FrameJankMonitor.noteBuild('home:pill');
                              return KeyedSubtree(
                                key: const ValueKey(_pillKeyValue),
                                child: _buildNewTopicIndicator(
                                  context,
                                  newTopicCount,
                                  providerKey,
                                ),
                              );
                            }
                            if (hintOffset > 0 && index == newTopicOffset) {
                              return KeyedSubtree(
                                key: const ValueKey(_filterHintKeyValue),
                                child: KeywordFilterHintBar(
                                  hiddenCount: hiddenCount,
                                  hiddenByBlocked: hiddenByBlocked,
                                ),
                              );
                            }
                            final topicIndex = index - headerOffset;
                            if (topicIndex >= topics.length) {
                              final notifier = ref.watch(
                                topicListProvider(providerKey).notifier,
                              );
                              return KeyedSubtree(
                                key: const ValueKey(_footerKeyValue),
                                child: PagedListFooter(
                                  hasMore: notifier.hasMore,
                                  isLoadingMore: notifier.isLoadingMore,
                                  isLoadMoreFailed: notifier.isLoadMoreFailed,
                                  onRetry: notifier.retryLoadMore,
                                ),
                              );
                            }

                            final topic = topics[topicIndex];
                            final rowKey = ValueKey('topic-${topic.id}');
                            final shouldHighlight = _highlightedTopicIds
                                .contains(topic.id);

                            if (shouldHighlight) {
                              final theme = Theme.of(context);
                              // 卡片正常背景色（需与 TopicCard / CompactTopicCard 的默认 color 一致）
                              final normalColor = topic.pinned
                                  ? theme.colorScheme.surfaceContainerLow
                                        .withValues(alpha: 0.5)
                                  : theme.cardTheme.color ??
                                        theme
                                            .colorScheme
                                            .surfaceContainerHighest;
                              final highlightColor = theme
                                  .colorScheme
                                  .primaryContainer
                                  .withValues(alpha: 0.3);
                              return KeyedSubtree(
                                key: rowKey,
                                child: TweenAnimationBuilder<Color?>(
                                  tween: ColorTween(
                                    begin: highlightColor,
                                    end: normalColor,
                                  ),
                                  duration: const Duration(milliseconds: 2000),
                                  curve: const Interval(
                                    0.2,
                                    1.0,
                                    curve: Curves.easeOut,
                                  ),
                                  onEnd: () =>
                                      _highlightedTopicIds.remove(topic.id),
                                  builder: (context, color, _) {
                                    return buildTopicItem(
                                      context: context,
                                      topic: topic,
                                      isSelected: topic.id == selectedTopicId,
                                      onTap: () {
                                        _syncKeyboardFocusToTopicId(topic.id);
                                        _openTopic(topic);
                                      },
                                      enableLongPress: enableLongPress,
                                      highlightColor: color,
                                      categoryMap: widget.categoryMap,
                                      statsAvailableWidth: statsAvailableWidth,
                                    );
                                  },
                                ),
                              );
                            }

                            final signature = (
                              topic: topic,
                              isSelected: topic.id == selectedTopicId,
                              enableLongPress: enableLongPress,
                              category: _categorySignatureFor(topic),
                              statsWidthTier: statsWidthTier,
                              cardStyle: topicCardStyle,
                              // 主题恒等进签名:自绘卡的文字颜色在排版期
                              // 烤死,obtain 发生在缓存短路点之外 —— 不换
                              // 代则深浅色切换后旧排版继续画(底色由
                              // PaintedTopicCard 自身 Theme 依赖刷新,文字
                              // 停留旧主题)。didChangeDependencies 清缓存
                              // 兜不住:State 自身 context 未注册 Theme 依赖
                              themeId: identityHashCode(Theme.of(context)),
                            );
                            final cached = _topicItemCache[topic.id];
                            if (cached != null &&
                                cached.signature == signature) {
                              // Map 保持插入顺序，命中后移到尾部作为轻量 LRU。
                              _topicItemCache.remove(topic.id);
                              _topicItemCache[topic.id] = cached;
                              return KeyedSubtree(
                                key: rowKey,
                                child: cached.widget,
                              );
                            }
                            final item = buildTopicItem(
                              context: context,
                              topic: topic,
                              isSelected: topic.id == selectedTopicId,
                              onTap: () {
                                _syncKeyboardFocusToTopicId(topic.id);
                                _openTopic(topic);
                              },
                              enableLongPress: enableLongPress,
                              categoryMap: widget.categoryMap,
                              statsAvailableWidth: statsAvailableWidth,
                            );
                            _topicItemCache[topic.id] = (
                              signature: signature,
                              widget: item,
                            );
                            while (_topicItemCache.length >
                                _topicItemCacheCapacity) {
                              _topicItemCache.remove(
                                _topicItemCache.keys.first,
                              );
                            }
                            return KeyedSubtree(key: rowKey, child: item);
                          },
                        ),
                      ),
                      // 滚动锚定哨兵:keyed 迁移会把"index 格子的旧账"分给新
                      // 住户(framework 按 index 搬 layoutOffset),整窗因此
                      // 平移约一行高 —— 在这里被同帧修正;贴顶时哨兵自带
                      // 顶部抑制,pill/新话题自然推入视野(浏览器同款语义)。
                      const AnchorGuardSliver(),
                    ],
                  ),
                ),
                // 顶部消隐纱：钉在头部下缘，内容被裁切时 bg→透明
                // 消散（在 ClipRRect 内 = 随本 tab 横滑一起走）
                _TopEdgeFade(
                  headerController: widget.headerController,
                  scrollController: _scrollController,
                  topInset: widget.topInset,
                ),
              ],
            ),
          ),
        );
      },
      loading: () => ClipRRect(
        borderRadius: _topBorderRadius,
        // 骨架屏无滚动位置可与头部互动，顶部让位实时贴头部下缘
        // （visibleExtentFor）——按恒定 inset 让位会在胶囊折叠时
        // 露 48px 空洞（切 tab 到 stale 分类 = 折叠态遇 loading）
        child: ListenableBuilder(
          listenable: widget.headerController,
          builder: (context, _) => TopicListSkeleton(
            padding: EdgeInsets.only(
              top:
                  widget.headerController.visibleExtentFor(widget.topInset) + 8,
              bottom: 12,
            ),
          ),
        ),
      ),
      error: (error, stack) => ClipRRect(
        borderRadius: _topBorderRadius,
        child: ListenableBuilder(
          listenable: widget.headerController,
          builder: (context, _) => Padding(
            padding: EdgeInsets.only(
              top: widget.headerController.visibleExtentFor(widget.topInset),
            ),
            child: ErrorView(
              error: error,
              stackTrace: stack,
              onRetry: () => ref.refresh(topicListProvider(providerKey)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNewTopicIndicator(
    BuildContext context,
    int count,
    int? providerKey,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Theme.of(
          context,
        ).colorScheme.primaryContainer.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _isLoadingNewTopics
              ? null
              : () async {
                  setState(() {
                    _isLoadingNewTopics = true;
                  });
                  try {
                    // 对齐网页版 showInserted：按 topic_ids 增量加载并插入顶部
                    final incomingState = ref.read(latestChannelProvider);
                    final topicIds = incomingState.incomingTopicIdsForCategory(
                      providerKey,
                    );
                    final insertedIds = await ref
                        .read(topicListProvider(providerKey).notifier)
                        .loadBefore(topicIds);
                    ref
                        .read(latestChannelProvider.notifier)
                        .clearIncoming(topicIds);

                    if (mounted && insertedIds.isNotEmpty) {
                      // 标记插入的话题以显示高亮动画
                      _highlightedTopicIds.addAll(insertedIds);
                      // 定时清除高亮，避免不可见卡片的动画无法触发 onEnd
                      final idsToRemove = insertedIds.toSet();
                      Future.delayed(const Duration(milliseconds: 2500), () {
                        if (!mounted) return;
                        final hadHighlights = _highlightedTopicIds
                            .intersection(idsToRemove)
                            .isNotEmpty;
                        _highlightedTopicIds.removeAll(idsToRemove);
                        if (hadHighlights) setState(() {});
                      });
                      scrollToTop();
                    }
                  } finally {
                    if (mounted) {
                      setState(() {
                        _isLoadingNewTopics = false;
                      });
                    }
                  }
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: _isLoadingNewTopics
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Symbols.arrow_upward_rounded,
                          size: 14,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          context.l10n.topics_viewNewTopics(count),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
