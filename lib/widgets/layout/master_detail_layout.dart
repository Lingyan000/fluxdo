import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import '../../l10n/s.dart';
import '../../utils/nav_chrome_metrics.dart';
import '../../utils/responsive.dart';
import '../../utils/layout_lock.dart';
import 'draggable_divider.dart';
import 'pane_filmstrip.dart';

/// Master-Detail 双栏布局
/// 平板/桌面上显示双栏，手机上只显示 master 或 detail
///
/// 树形恒定：根永远是 Stack > Row[master 槽, 分隔槽, detail 槽]，三个槽
/// 的 widget 链类型/顺序在宽窄切换时不变，只改宽度与 Offstage——这样
/// Element 逐位匹配，master 和 detail 的 State（滚动/视频/输入态）在
/// 宽窄切换时原地保留，不销毁重建。
///
/// ## 窄屏投影态（projectDetailWhenNarrow）
///
/// 传 true 时，窄屏且 detail 非空 = "投影态"：detail 全宽顶替宿主区域
/// （master 收进 Offstage 保状态），不 push 任何合成路由。平行视界栈
/// （provider）是唯一真相，宽窄只是同一状态的两种投影。返回/ESC 语义
/// 由宿主统一走 `isStacked ? pop() : clear()`。
/// 传 false（默认）保持旧语义：窄屏只显示 master，detail 不构建。
///
/// ## 平行视界接入约定（长版见 docs/parallel-view-conventions.md）
///
/// - **背景**：detail 槽由本容器统一铺底（scaffoldBackgroundColor），
///   页面不要自己包 ColoredBox；空态一律用 [MasterDetailEmptyState]，
///   只定制 icon/message。
/// - **onBack**：detail 面板的返回回调标准写法是
///   `isStacked ? pop() : clear()`（回调内重读 provider，不闭包捕获）——
///   基础层 ESC/返回清空右栏回空态，四家宿主行为一致。
/// - **嵌入判定**：判断"我是否处在嵌入面板里"用
///   `EmbeddedStackScope.maybeOf(context)`，**禁止**用屏宽
///   （[canShowBothPanesFor]）推断——独立成屏的页面在宽屏下会被误判。
///   [canShowBothPanesFor] 只用于宿主决定"列表点击进右栏还是全屏 push"。
/// - **ESC 接入**：嵌入面板层以 ShortcutScope.detail 注册 closeOverlay
///   （参照 TopicDetailPage）；普通全屏路由由 EscFallbackObserver 自动
///   兜底（无需显式接入）；快捷键打开的全局路由用 pushAppRoute +
///   ShortcutSurfaceConfig。不要新增 CallbackShortcuts/KeyboardListener
///   接 ESC。
class MasterDetailLayout extends StatefulWidget {
  static const double defaultMasterWidth = PaneBreakpoints.masterWidth;
  static const double defaultMinDetailWidth = PaneBreakpoints.minDetailWidth;

  /// master 栏宽度占比下限——不管 master 里放的是列表还是"平行视界"
  /// 上一层内容，都不能拖到比这更窄。
  static const double defaultMinMasterRatio = 0.2;

  /// master 栏宽度占比上限：默认 0.3，对应 master 是真正的列表（信息流/
  /// 私信列表）场景——列表不需要太宽。平行视界压栈时 master 显示的是
  /// "上一层"内容（不是列表），应该放宽到接近对半分（见
  /// [PaneMasterDetailLayout] 或调用方传更大的 maxMasterRatio，比如 0.8），
  /// 这样才是真正的"平行视界"而不是"列表+详情"。
  static const double defaultMaxMasterRatio = 0.3;

  /// master 栏绝对最小宽度（像素）。窗口整体较窄时按比例算出的宽度可能
  /// 只有一百来像素，头像+徽章这类定宽内容根本塞不下，会撑出 RenderFlex
  /// 溢出条纹——所以下限必须是"比例下限"和"绝对像素下限"取较大值。
  static const double minPaneAbsoluteWidth = 240;

  const MasterDetailLayout({
    super.key,
    required this.master,
    this.detail,
    this.panes,
    this.pinMaster = true,
    this.emptyDetail,
    this.masterFillsWhenEmpty = false,
    this.masterFloatingActionButton,
    this.masterWidth = defaultMasterWidth,
    this.minDetailWidth = defaultMinDetailWidth,
    this.showDivider = true,
    this.minMasterRatio = defaultMinMasterRatio,
    this.maxMasterRatio = defaultMaxMasterRatio,
    this.preferredMasterRatio,
    this.resizableMaster = true,
    this.projectDetailWhenNarrow = false,
    this.animatePanes = true,
  }) : assert(
         detail == null || panes == null,
         'detail(单格兼容)与 panes(胶片带)二选一',
       );

  /// 主列表（左侧）
  final Widget master;

  /// 详情内容(单格兼容口:等价于 panes=[detail]),为 null 时显示
  /// emptyDetail。新宿主用 [panes]。
  final Widget? detail;

  /// 平行视界层格(胶片带):每层一格、**每格必须有稳定 key**,压/退栈
  /// = 视口沿带平移,格子 Element 恒驻(State 全保)。见 [PaneFilmstrip]。
  final List<Widget>? panes;

  /// true(默认)= master 恒驻左栏,层带只在右格区滑(列表+详情形态);
  /// false = master 也在带上,压栈时被顶出左侧,倒二层格顶上左栏
  /// (首页平行视界"上一层预览"形态)。
  final bool pinMaster;

  /// 无详情时的占位组件
  final Widget? emptyDetail;

  /// true = 栈空时 master 撑满整个内容区(页面自己排版宽屏,无右栏
  /// 空态);压栈才收窄成左栏、层格从右滑入。适合"页面本身是内容、
  /// 点开条目才分栏"的宿主(用户资料页)。仅 pinMaster: false 生效。
  final bool masterFillsWhenEmpty;

  /// 主列表区域的 FAB
  final Widget? masterFloatingActionButton;

  /// 主列表初始宽度
  final double masterWidth;

  /// 详情区最小宽度
  final double minDetailWidth;

  /// 是否显示分隔线
  final bool showDivider;

  /// master 栏宽度占比下限（默认 20%）
  final double minMasterRatio;

  /// master 栏宽度占比上限：master 是列表时默认 30%；平行视界压栈、
  /// master 显示"上一层"内容时调用方应传更大的值（如 0.8），允许两栏
  /// 接近对半分。
  final double maxMasterRatio;

  /// master 栏默认宽度占比：不传时退回 [minMasterRatio]（列表场景，20%）。
  /// 平行视界压栈、两侧都不是"列表"时调用方应传 0.5，让两栏默认对半分
  /// （而不是只把 [maxMasterRatio] 放宽到 0.8——那只是允许用户拖到多宽，
  /// 不代表默认就该那么宽，两者是分开的语义）。
  final double? preferredMasterRatio;

  /// master 栏是否可拖拽调宽。false = 固定 [masterWidth]（不渲染拖拽
  /// 分隔柄,比例参数全部不生效）——适合「我的」页这类左栏是定宽资料
  /// 卡、不存在"列表想看宽点"诉求的宿主。
  final bool resizableMaster;

  /// 窄屏投影态开关：true 时窄屏且层格非空 = 栈顶格全宽顶替宿主区域
  /// （master 收进带外保状态），不 push 合成路由。
  /// false（默认）保持旧语义：窄屏只显示 master，层格不渲染。
  final bool projectDetailWhenNarrow;

  /// 层间过渡动画开关(逃生口:false 一律瞬切,结构不变)。
  final bool animatePanes;

  /// 是否显示双栏布局
  ///
  /// 判定轴与分配轴同轴:宽屏内容区 = 窗宽 − Rail 应占宽,比阈值前先
  /// 扣掉([NavChromeMetrics])。曾按整窗宽判定,窗宽 780~852 区间
  /// 「判定能双栏、实际空间不够」,左栏被压到 240px 挤压带。
  static bool canShowBothPanesFor(
    BuildContext context, {
    double masterWidth = defaultMasterWidth,
    double minDetailWidth = defaultMinDetailWidth,
  }) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isMobile = Responsive.isMobile(context);
    final contentWidth =
        screenWidth -
        NavChromeMetrics.reservedWidth(showRailByBreakpoint: !isMobile);
    final computed = contentWidth >= masterWidth + minDetailWidth && !isMobile;
    return LayoutLock.resolveCanShowBoth(computed: computed);
  }

  /// 是否显示双栏布局
  bool canShowBothPanes(BuildContext context) {
    return canShowBothPanesFor(
      context,
      masterWidth: masterWidth,
      minDetailWidth: minDetailWidth,
    );
  }

  @override
  State<MasterDetailLayout> createState() => _MasterDetailLayoutState();
}

class _MasterDetailLayoutState extends State<MasterDetailLayout> {
  late double _currentMasterWidth;
  double? _dragStartWidth;
  bool _hasUserResized = false;

  @override
  void didUpdateWidget(covariant MasterDetailLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    // master 复用同一个 State（见类注释），列表态<->压栈态切换时
    // preferredMasterRatio 会变（0.25 <-> 0.5）。如果之前手动拖拽过一次，
    // _hasUserResized 会一直锁定旧宽度，导致新模式的默认比例永远生效不了
    // ——切模式时重置，让新默认值重新起作用；同一模式内的手动拖拽不受影响。
    if (oldWidget.preferredMasterRatio != widget.preferredMasterRatio) {
      _hasUserResized = false;
    }
  }

  @override
  void initState() {
    super.initState();
    _currentMasterWidth = widget.masterWidth;
  }

  double _preferredMasterWidth(double totalWidth) {
    if (_hasUserResized) return _currentMasterWidth;
    // 比例给"大窗口按比例放宽"，masterWidth 像素值兜"小窗口别挤成一条"
    // ——取较大者。列表栏的可读宽度是内容决定的（卡片/标题排版），
    // 中等窗口 0.2~0.25 的比例算出来只有两三百像素：早先只按比例，
    // "所有双栏初始都特别窄"就是这么来的。
    final ratio = widget.preferredMasterRatio ?? widget.minMasterRatio;
    final byRatio = totalWidth * ratio;
    return byRatio < widget.masterWidth ? widget.masterWidth : byRatio;
  }

  double _clampMasterWidth(double width, double totalWidth) {
    final ratioLower = totalWidth * widget.minMasterRatio;
    final lowerBound = ratioLower < MasterDetailLayout.minPaneAbsoluteWidth
        ? MasterDetailLayout.minPaneAbsoluteWidth
        : ratioLower;
    final ratioUpper = totalWidth * widget.maxMasterRatio;
    final spaceUpper = totalWidth - widget.minDetailWidth;
    var upperBound = ratioUpper < spaceUpper ? ratioUpper : spaceUpper;
    if (upperBound < lowerBound) upperBound = lowerBound;
    return width.clamp(lowerBound, upperBound);
  }

  @override
  Widget build(BuildContext context) {
    // FAB 锚定在系统安全区基线（viewPadding，不含 extendBody 注入的
    // 底栏槽高）：底栏是滑出式的，槽高恒定但可见性随滚动变化，锚在
    // padding.bottom 会让 FAB 在底栏滑走后仍悬在半空。跟随底栏升降
    // 由 FAB 自身按 barVisibility 平移（见 _TopicsFab）。
    final bottomPadding = MediaQuery.viewPaddingOf(context).bottom;

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final showBothPanes = widget.canShowBothPanes(context);
        // 单格兼容口(detail)与胶片带(panes)归一成格子列表。
        final panes = widget.panes ??
            (widget.detail != null ? <Widget>[widget.detail!] : const <Widget>[]);
        // 投影态:窄屏 + 栈非空,栈顶格全宽盖住 master。
        final projecting =
            !showBothPanes && widget.projectDetailWhenNarrow && panes.isNotEmpty;
        // masterFillsWhenEmpty 且栈空:master 独占视口(内容页自排版),
        // 此刻不存在"两栏"——空态与拖拽柄都不该出现。
        final masterFillsNow =
            widget.masterFillsWhenEmpty && !widget.pinMaster && panes.isEmpty;

        final preferredWidth = _preferredMasterWidth(totalWidth);
        // 固定栏宽宿主(resizableMaster: false)不走比例/clamp,始终取
        // 调用方指定的 masterWidth——与旧手写 Row 的定宽语义一致。
        final masterWidth = widget.resizableMaster
            ? _clampMasterWidth(preferredWidth, totalWidth)
            : widget.masterWidth;

        // master 格:FAB 挂在格内(压栈/投影时随格滑出视口,自然消失)。
        // 'master-pane' key 保留(测试与外部丈量契约)。
        final Widget masterCell = KeyedSubtree(
          key: const ValueKey('master-pane'),
          child: Stack(
            children: [
              widget.master,
              if (widget.masterFloatingActionButton != null)
                Positioned(
                  right: 16,
                  bottom: 16 + bottomPadding,
                  child: widget.masterFloatingActionButton!,
                ),
            ],
          ),
        );

        // 层格统一铺底(scaffoldBackgroundColor):面板没有 Scaffold 时
        // (切换过渡帧等)不铺底会透出 canvasColor/acrylic surface,与
        // master 背景形成色差断层。格子身份 key 派生自内容 key(不直接
        // 复用——同 key 双挂载会让 find.byKey/语义查找命中两个)。
        final theme = Theme.of(context);
        final wrappedPanes = <Widget>[
          for (var i = 0; i < panes.length; i++)
            KeyedSubtree(
              key: ValueKey(('pane-cell', panes[i].key ?? i)),
              child: ColoredBox(
                color: theme.scaffoldBackgroundColor,
                child: panes[i],
              ),
            ),
        ];

        // 窄屏非投影(纯单栏):只渲染 master,层格不构建(旧语义,
        // 窄屏点列表走真路由,栈恒空)。
        final narrowPlain = !showBothPanes && !projecting;

        Widget strip = PaneFilmstrip(
          master: masterCell,
          panes: narrowPlain ? const <Widget>[] : wrappedPanes,
          emptyPane: showBothPanes
              ? ColoredBox(
                  color: theme.scaffoldBackgroundColor,
                  child: widget.emptyDetail ?? const _DefaultEmptyState(),
                )
              : null,
          masterFillsWhenEmpty: widget.masterFillsWhenEmpty,
          pinMaster: widget.pinMaster,
          viewportPanes: showBothPanes ? 2 : 1,
          masterWidth: showBothPanes ? masterWidth : totalWidth,
          // 分隔线画在格子左缘(随带平移,动画期淡出结束淡入),样式
          // 对齐项目竖线口径(page_dialog/profile 同款 outlineVariant
          // 40%)——theme.dividerColor 更重,双栏接缝显突兀。
          dividerColor: showBothPanes && widget.showDivider
              ? theme.colorScheme.outlineVariant.withValues(alpha: 0.4)
              : null,
          animate: widget.animatePanes,
          bandDrag: PaneProjectionBack.progress,
        );

        return Stack(
          children: [
            Positioned.fill(child: strip),
            if (showBothPanes && widget.resizableMaster && !masterFillsNow)
              Positioned(
                left: masterWidth - 8,
                top: 0,
                bottom: 0,
                width: 16,
                child: DraggableDivider(
                  // 静止细线由胶片带按格子实时位置画在接缝上;本柄挂在
                  // 终态栏宽处,动画期它的静止线会劈在飞行画面中间。
                  showIdleLine: false,
                  onResizeStart: () => _dragStartWidth = masterWidth,
                  onResizeUpdate: (globalX, startX) {
                    final desired = _dragStartWidth! + (globalX - startX);
                    final clamped = _clampMasterWidth(desired, totalWidth);
                    // 拖拽事件频率很高（鼠标高轮询率下每秒上百次），每次都
                    // setState 会让内容区（图片等按可用宽度算尺寸的东西）
                    // 跟着抖动式反复重算——量化到 8px 网格，拖拽视觉上无感，
                    // 但大幅减少宽度变化次数，避免图片频繁按新尺寸重新请求
                    // （有 429 风险）。
                    const snapGrid = 8.0;
                    final snapped = (clamped / snapGrid).round() * snapGrid;
                    if (snapped == _currentMasterWidth && _hasUserResized) {
                      return;
                    }
                    setState(() {
                      _currentMasterWidth = snapped;
                      _hasUserResized = true;
                    });
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

/// detail 区未选中内容时的默认空态（“选择一个话题查看详情”）。
class _DefaultEmptyState extends StatelessWidget {
  const _DefaultEmptyState();

  @override
  Widget build(BuildContext context) {
    return MasterDetailEmptyState(
      icon: Symbols.article_rounded,
      message: context.l10n.layout_selectTopicHint,
    );
  }
}

/// 平行视界 detail 区空状态的统一样式。
///
/// 各页面自定义空态（emptyDetail）时应使用本组件、只定制 icon/message，
/// 不要自己拼 Center/Column，也不要自己包 ColoredBox 铺底——背景由
/// [MasterDetailLayout] 的 detail 槽统一负责。
class MasterDetailEmptyState extends StatelessWidget {
  const MasterDetailEmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.iconSize = 64,
  });

  final IconData icon;
  final String message;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: iconSize, color: theme.colorScheme.outlineVariant),
          const SizedBox(height: 16),
          Text(
            message,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

