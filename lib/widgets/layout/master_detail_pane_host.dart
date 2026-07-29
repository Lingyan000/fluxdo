import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../pages/settings_page.dart';
import '../../pages/topic_detail_page/topic_detail_page.dart';
import '../../pages/topics_screen.dart' show PaneContentWidget;
import '../../pages/user_profile_page.dart';
import '../../providers/selected_topic_provider.dart';
import '../../providers/shortcut_provider.dart';
import 'auto_restore_master_detail_route.dart';
import 'master_detail_layout.dart';

/// "列表 + 详情"页面的双栏宿主标准件。
///
/// 适用于自己就是一整页的列表页（草稿/我的话题/浏览历史……）:宽屏时
/// 左栏列表常驻、右栏显示点开的话题（右栏内部照常支持平行视界压栈）,
/// 窄屏时只渲染列表本身（点开走全屏 push,由调用方分流）。统一承担:
///
/// - 双栏组装（[MasterDetailLayout] + [PaneContentWidget] + onBack 标准语义）
/// - 桌面 ESC 两段式:右栏开着时不注册 context 层（分发落到 detail scope,
///   关右栏）;右栏空了才注册 maybePop 关整页（底栏 tab 形态是首路由,
///   maybePop 为 no-op）
/// - 宽→窄把右栏顶成全屏、回宽屏自动还原（`_maybePushDetail` 模式）
/// - 进入页面时清空上次残留的选中（[clearOnInit]）
///
/// 调用方职责:列表项点击时按 `MasterDetailLayout.canShowBothPanesFor`
/// 分流——宽屏 `ref.read(stackProvider.notifier).select(...)`,窄屏
/// `Navigator.push` 全屏详情;高亮"正在右栏的那条"自己 watch 栈判断。
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

  bool? _lastCanShowDetailPane;
  bool _isAutoSwitching = false;

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

  /// 双栏→单栏（窗口缩小）时把当前栈顶层 push 成全屏页,回宽屏自动还原
  /// —— 与私信页 `_maybePushDetail` 同一套模式。
  void _maybePushDetail(SelectedTopicState selected, bool canShowDetailPane) {
    if (_isAutoSwitching) return;
    if (!widget.isActive) {
      _lastCanShowDetailPane = canShowDetailPane;
      return;
    }

    final previous = _lastCanShowDetailPane;
    _lastCanShowDetailPane = canShowDetailPane;

    if (!canShowDetailPane &&
        selected.hasSelection &&
        (previous == null || previous == true)) {
      final topicId = selected.topicId;
      if (topicId == null) {
        final username = selected.username;
        final isSettings = selected.kind == PaneKind.settings;
        if (username == null && !isSettings) return;
        _isAutoSwitching = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Navigator.of(context)
              .push(MaterialPageRoute(
                builder: (_) => AutoRestoreMasterDetailRoute(
                  child: isSettings
                      ? const SettingsPage()
                      : UserProfilePage(username: username!),
                ),
              ))
              .whenComplete(() {
            if (mounted) setState(() => _isAutoSwitching = false);
          });
        });
        return;
      }

      _isAutoSwitching = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context)
            .push(MaterialPageRoute(
              builder: (_) => TopicDetailPage(
                topicId: topicId,
                initialTitle: selected.initialTitle,
                scrollToPostNumber: selected.scrollToPostNumber,
                autoSwitchToMasterDetail: true,
                restoreExistingPaneStack: true,
                stackProvider: widget.stackProvider,
              ),
            ))
            .whenComplete(() {
          if (mounted) setState(() => _isAutoSwitching = false);
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(widget.stackProvider);
    final canShowBothPanes = MasterDetailLayout.canShowBothPanesFor(
      context,
      masterWidth: widget.masterWidth,
      minDetailWidth: widget.minDetailWidth,
    );
    _maybePushDetail(selected, canShowBothPanes);

    final paneOpen = canShowBothPanes && selected.hasSelection;
    _escBinding.sync(context, paneOpen: paneOpen);

    if (!canShowBothPanes) return widget.master;

    return MasterDetailLayout(
      masterWidth: widget.masterWidth,
      minDetailWidth: widget.minDetailWidth,
      master: widget.master,
      detail: selected.hasSelection
          ? PaneContentWidget(
              key: ValueKey(
                'pane_host_${selected.kind}_'
                '${selected.instanceId ?? selected.username ?? selected.topicId}',
              ),
              entry: selected.topEntry!,
              stackProvider: widget.stackProvider,
              parentActive: widget.isActive,
              onBack: () {
                final n = ref.read(widget.stackProvider.notifier);
                if (ref.read(widget.stackProvider).isStacked) {
                  n.pop();
                } else {
                  n.clear();
                }
              },
            )
          : null,
      emptyDetail: widget.emptyDetail,
    );
  }
}
