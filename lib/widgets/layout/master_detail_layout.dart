import 'package:flutter/material.dart';
import '../../l10n/s.dart';
import '../../utils/responsive.dart';
import '../../utils/layout_lock.dart';
import 'draggable_divider.dart';

/// Master-Detail 双栏布局
/// 平板/桌面上显示双栏，手机上只显示 master 或 detail
///
/// 使用统一 Row > SizedBox 结构，确保布局切换时 master 不会被卸载重建。
class MasterDetailLayout extends StatefulWidget {
  static const double defaultMasterWidth = 380;
  static const double defaultMinDetailWidth = 400;
  static const double desktopMasterWidthRatio = 0.28;
  static const double minMasterWidth = 280;
  static const double maxMasterWidth = 520;

  const MasterDetailLayout({
    super.key,
    required this.master,
    this.detail,
    this.emptyDetail,
    this.masterFloatingActionButton,
    this.masterWidth = defaultMasterWidth,
    this.minDetailWidth = defaultMinDetailWidth,
    this.showDivider = true,
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
  void initState() {
    super.initState();
    _currentMasterWidth = widget.masterWidth;
  }

  double _preferredMasterWidth(double totalWidth) {
    if (_hasUserResized) return _currentMasterWidth;

    final proportionalWidth =
        totalWidth * MasterDetailLayout.desktopMasterWidthRatio;
    return proportionalWidth.clamp(
      widget.masterWidth,
      MasterDetailLayout.maxMasterWidth,
    );
  }

  double _clampMasterWidth(double width, double totalWidth) {
    final maxAllowed = totalWidth - widget.minDetailWidth;
    final upperBound = maxAllowed.clamp(
      MasterDetailLayout.minMasterWidth,
      MasterDetailLayout.maxMasterWidth,
    );
    return width.clamp(MasterDetailLayout.minMasterWidth, upperBound);
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;

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
              Expanded(
                child:
                    widget.detail ??
                    widget.emptyDetail ??
                    _buildEmptyState(context),
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
                  setState(() {
                    final desired = _dragStartWidth! + (globalX - startX);
                    _currentMasterWidth = _clampMasterWidth(
                      desired,
                      totalWidth,
                    );
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

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.article_outlined,
            size: 64,
            color: theme.colorScheme.outlineVariant,
          ),
          const SizedBox(height: 16),
          Text(
            context.l10n.layout_selectTopicHint,
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
