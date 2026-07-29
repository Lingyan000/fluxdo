import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import '../../l10n/s.dart';
import '../../utils/responsive.dart';
import '../../utils/layout_lock.dart';
import 'draggable_divider.dart';

/// Master-Detail 双栏布局
/// 平板/桌面上显示双栏，手机上只显示 master 或 detail
///
/// 使用统一 Row > SizedBox 结构，确保布局切换时 master 不会被卸载重建。
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
///   （参照 TopicDetailPage）；普通全屏路由用 RouteEscCloseBinding；
///   快捷键打开的全局路由用 pushAppRoute + ShortcutSurfaceConfig。
///   不要新增 CallbackShortcuts/KeyboardListener 接 ESC。
class MasterDetailLayout extends StatefulWidget {
  static const double defaultMasterWidth = 380;
  static const double defaultMinDetailWidth = 400;
  static const double desktopMasterWidthRatio = 0.28;
  static const double minMasterWidth = 280;
  static const double maxMasterWidth = 520;

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
    this.emptyDetail,
    this.masterFloatingActionButton,
    this.masterWidth = defaultMasterWidth,
    this.minDetailWidth = defaultMinDetailWidth,
    this.showDivider = true,
    this.minMasterRatio = defaultMinMasterRatio,
    this.maxMasterRatio = defaultMaxMasterRatio,
    this.preferredMasterRatio,
  });

  /// 主列表（左侧）
  final Widget master;

  /// 详情内容（右侧），为 null 时显示 emptyDetail
  final Widget? detail;

  /// 无详情时的占位组件
  final Widget? emptyDetail;

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

  /// 是否显示双栏布局
  static bool canShowBothPanesFor(
    BuildContext context, {
    double masterWidth = defaultMasterWidth,
    double minDetailWidth = defaultMinDetailWidth,
  }) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final computed =
        screenWidth >= masterWidth + minDetailWidth &&
        !Responsive.isMobile(context);
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

        final preferredWidth = _preferredMasterWidth(totalWidth);
        final masterWidth = _clampMasterWidth(preferredWidth, totalWidth);
        final mWidth = showBothPanes ? masterWidth : totalWidth;

        final row = Row(
          children: [
            SizedBox(
              key: const ValueKey('master-pane'),
              width: mWidth,
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
            ),
            if (showBothPanes) ...[
              const VerticalDivider(width: 1, thickness: 1),
              // detail 槽统一铺底：面板本身没有 Scaffold 时（空态、切换过渡帧）
              // 不铺底会透出 MaterialApp 默认 canvasColor / acrylic 的 surface 层，
              // 和左侧 master 的 Scaffold 背景形成色差断层。铺在容器层而非只铺
              // 空态，面板重建的过渡帧也不透底；有内容时被面板自身的同色
              // Scaffold 覆盖，无视觉差异。
              Expanded(
                child: ColoredBox(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child:
                      widget.detail ??
                      widget.emptyDetail ??
                      const _DefaultEmptyState(),
                ),
              ),
            ],
          ],
        );

        if (!showBothPanes) return row;

        return Stack(
          children: [
            row,
            Positioned(
              left: mWidth - 8,
              top: 0,
              bottom: 0,
              width: 16,
              child: DraggableDivider(
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

/// 用于在 Master-Detail 模式下管理选中状态
class MasterDetailController extends ChangeNotifier {
  int? _selectedId;

  int? get selectedId => _selectedId;

  bool get hasSelection => _selectedId != null;

  void select(int id) {
    if (_selectedId != id) {
      _selectedId = id;
      notifyListeners();
    }
  }

  void clear() {
    if (_selectedId != null) {
      _selectedId = null;
      notifyListeners();
    }
  }
}
