import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../pages/topics_screen.dart' show PaneContentWidget;
import '../../providers/selected_topic_provider.dart';
import '../../providers/shortcut_provider.dart';
import 'master_detail_layout.dart';
import 'pane_projection_back_scope.dart';

/// "列表 + 详情"页面的双栏宿主标准件。
///
/// 适用于自己就是一整页的列表页（草稿/我的话题/浏览历史……）:宽屏时
/// 左栏列表常驻、右栏显示点开的话题（右栏内部照常支持平行视界压栈）,
/// 窄屏时列表全宽;栈非空则详情在本页体内全宽投影（同一棵树,不 push
/// 合成路由,宽窄切换详情 State 原地保留）。统一承担:
///
/// - 双栏组装（[MasterDetailLayout] + [PaneContentWidget] + onBack 标准语义）
/// - 窄屏投影态（`projectDetailWhenNarrow`,平行视界栈是唯一真相）
/// - 桌面 ESC 两段式:栈非空时不注册 context 层（分发落到 detail scope,
///   关右栏/关投影）;栈空了才注册 maybePop 关整页（底栏 tab 形态是
///   首路由,maybePop 为 no-op）
/// - 进入页面时清空上次残留的选中（[clearOnInit]）
///
/// 调用方职责:列表项点击时按 `MasterDetailLayout.canShowBothPanesFor`
/// 分流——宽屏 `ref.read(stackProvider.notifier).select(...)`,窄屏
/// `Navigator.push` 全屏详情;高亮"正在右栏的那条"自己 watch 栈判断。
/// （窄屏点击走真路由是有意保留:原生转场/侧滑/预测返回;投影态只在
/// "宽屏选中后缩窄"这类宽窄接续场景出现,两者互斥——窄屏点击不写栈。）
class MasterDetailPaneHost extends ConsumerStatefulWidget {
  const MasterDetailPaneHost({
    super.key,
    required this.stackProvider,
    required this.master,
    this.isActive = true,
    this.emptyDetail,
    this.masterWidth = MasterDetailLayout.defaultMasterWidth,
    this.minDetailWidth = MasterDetailLayout.defaultMinDetailWidth,
    this.clearOnInit = true,
    this.maxMasterRatio,
    this.preferredMasterRatio,
    this.masterFloatingActionButton,
  });

  /// 本页专属的平行视界栈（每个宿主页一份,互不干扰）。
  final SelectedTopicProvider stackProvider;

  /// 左栏列表（页面自己的 Scaffold）。
  final Widget master;

  /// 是否为当前活跃的 tab（IndexedStack 嵌入底栏时传入）。
  final bool isActive;

  /// 右栏空态,不传用 [MasterDetailLayout] 内置的。
  final Widget? emptyDetail;

  final double masterWidth;
  final double minDetailWidth;

  /// 进入页面时清空栈:上次打开时选中的话题不带到这次。
  final bool clearOnInit;

  /// 透传 [MasterDetailLayout.maxMasterRatio]（压栈平行视界对半分场景）。
  final double? maxMasterRatio;

  /// 透传 [MasterDetailLayout.preferredMasterRatio]。
  final double? preferredMasterRatio;

  /// 透传 [MasterDetailLayout.masterFloatingActionButton]。
  final Widget? masterFloatingActionButton;

  @override
  ConsumerState<MasterDetailPaneHost> createState() =>
      _MasterDetailPaneHostState();
}

class _MasterDetailPaneHostState extends ConsumerState<MasterDetailPaneHost> {
  /// ESC 两段式标准件(见 [PaneHostEscBinding]):本页可能是 IndexedStack
  /// 常驻 tab(草稿/浏览历史),不活跃时注册失效,否则截胡其他 tab 的 ESC。
  late final PaneHostEscBinding _escBinding = PaneHostEscBinding(
    ref: ref,
    enabled: () => widget.isActive,
  );

  @override
  void initState() {
    super.initState();
    if (widget.clearOnInit) {
      // initState 处在 build 阶段,直接改 provider 会破坏元素树,挪帧后。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(widget.stackProvider.notifier).clear();
      });
    }
  }

  @override
  void dispose() {
    _escBinding.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(widget.stackProvider);

    // ESC 语义:栈非空（宽屏右栏开着 / 窄屏投影着）都让分发落 detail
    // scope（关右栏/关投影,master 无 closeOverlay 注册时分发端有
    // master→detail 回退特例兜住）;栈空才注册 maybePop 关整页。
    _escBinding.sync(context, paneOpen: selected.hasSelection);

    return PaneProjectionBackScope(
      stackProvider: widget.stackProvider,
      isActive: widget.isActive,
      masterWidth: widget.masterWidth,
      minDetailWidth: widget.minDetailWidth,
      child: MasterDetailLayout(
        masterWidth: widget.masterWidth,
        minDetailWidth: widget.minDetailWidth,
        maxMasterRatio:
            widget.maxMasterRatio ?? MasterDetailLayout.defaultMaxMasterRatio,
        preferredMasterRatio: widget.preferredMasterRatio,
        projectDetailWhenNarrow: true,
        // 列表恒驻左栏(pinMaster 默认 true),层带在右格区内滑——
        // 右栏内部压栈(话题里点链接)也是格间滑动,State 恒驻。
        master: widget.master,
        panes: [
          for (var i = 0; i < selected.stack.length; i++)
            KeyedSubtree(
              key: ValueKey(
                'pane_host_${selected.stack[i].kind}_'
                '${selected.stack[i].instanceId ?? selected.stack[i].username ?? selected.stack[i].topicId}',
              ),
              child: PaneContentWidget(
                entry: selected.stack[i],
                stackProvider: widget.stackProvider,
                parentActive: widget.isActive,
                truncateOnPush: i < selected.stack.length - 1,
                onBack: () {
                  final n = ref.read(widget.stackProvider.notifier);
                  if (ref.read(widget.stackProvider).isStacked) {
                    n.pop();
                  } else {
                    n.clear();
                  }
                },
              ),
            ),
        ],
        emptyDetail: widget.emptyDetail,
        masterFloatingActionButton: widget.masterFloatingActionButton,
      ),
    );
  }
}
