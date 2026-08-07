import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/selected_topic_provider.dart';
import '../common/predictive_back_overlay_handler.dart';
import '../notification/notification_quick_panel.dart';
import '../topic/category_drawer.dart';
import 'master_detail_layout.dart';
import 'pane_filmstrip.dart';

/// 平行视界宿主的「窄屏投影态返回链」标准件。
///
/// 包在宿主的 [MasterDetailLayout]（projectDetailWhenNarrow: true）外层,
/// 统一承担投影态的三条关闭路径:
///
/// 1. **系统返回**(Android 返回键/手势 commit、桌面窗口返回):PopScope
///    拦截,`isStacked ? pop() : clear()`——与宽屏 onBack 同一语义。
/// 2. **Android 预测返回跟手**:认领手势,进度写入
///    [PaneProjectionBack.progress],正在投影的布局平移露出 master;
///    cancel 弹回,commit 滑出后清栈。
/// 3. **与 main 层协调**:通过 [hasActiveProjection] 向根 PopScope 报告
///    "当前有投影在消费返回",避免双击退出的 toast 抢跑。
///
/// 宿主可能是 IndexedStack 常驻 tab(共享根路由):PopScope 的 canPop
/// 只在 `isActive && 投影开` 时为 false,非活跃 tab 不拦截;onPopInvoked
/// 也按同谓词过滤(共享路由上所有 PopEntry 都会被回调)。
class PaneProjectionBackScope extends ConsumerStatefulWidget {
  const PaneProjectionBackScope({
    super.key,
    required this.stackProvider,
    required this.child,
    this.isActive = true,
    this.masterWidth = MasterDetailLayout.defaultMasterWidth,
    this.minDetailWidth = MasterDetailLayout.defaultMinDetailWidth,
  });

  final SelectedTopicProvider stackProvider;
  final Widget child;
  final bool isActive;
  final double masterWidth;
  final double minDetailWidth;

  /// 当前是否有活跃宿主处于投影态(供根 PopScope / 底栏显隐读取)。
  /// 计数式:多宿主并存(tab 页+压栈全屏页各自的宿主)时互不覆盖。
  static final ValueNotifier<bool> hasActiveProjection = ValueNotifier(false);

  static int _activeCount = 0;

  static void _report(bool active) {
    _activeCount += active ? 1 : -1;
    hasActiveProjection.value = _activeCount > 0;
  }

  @override
  ConsumerState<PaneProjectionBackScope> createState() =>
      _PaneProjectionBackScopeState();
}

class _PaneProjectionBackScopeState
    extends ConsumerState<PaneProjectionBackScope>
    with SingleTickerProviderStateMixin {
  // 不能 late final 惰性建:从未播过动画时首次实例化会落在 dispose(),
  // AnimationController 构造要向上查 TickerMode,unmount 期间祖先查找
  // 直接抛 "Looking up a deactivated widget's ancestor is unsafe"。
  late final AnimationController _settle;
  PredictiveBackOverlayHandler? _predictiveBack;
  bool _desiredReport = false;
  bool _appliedReport = false;
  bool _reportSyncScheduled = false;

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    // 预测返回是 Android 专属管线,其他平台不挂 observer。
    if (!kIsWeb && Platform.isAndroid) {
      _predictiveBack = PredictiveBackOverlayHandler(
        // 互斥:z 序更高的浮层(分类抽屉/通知面板)开着时让位,
        // 被其他路由盖住时让位(路由自己的预测返回接管)。
        isEnabled: () =>
            _projectionOpen &&
            (ModalRoute.of(context)?.isCurrent ?? false) &&
            !CategoryDrawerHost.isOpen &&
            !NotificationQuickPanel.isVisible,
        onStart: () => _settle.stop(),
        onUpdate: (progress) {
          _settle.stop();
          PaneProjectionBack.progress.value = progress;
        },
        onCancel: () => _animateProgressTo(0),
        onCommit: _commitClose,
      )..attach();
    }
  }

  bool get _projectionOpen =>
      widget.isActive &&
      ref.read(widget.stackProvider).hasSelection &&
      !MasterDetailLayout.canShowBothPanesFor(
        context,
        masterWidth: widget.masterWidth,
        minDetailWidth: widget.minDetailWidth,
      );

  void _animateProgressTo(double target) {
    final from = PaneProjectionBack.progress.value;
    if (from == target) return;
    _settle.stop();
    final animation = _settle.drive(
      Tween(begin: from, end: target).chain(CurveTween(curve: Curves.easeOut)),
    );
    void tick() => PaneProjectionBack.progress.value = animation.value;
    _settle.addListener(tick);
    _settle.forward(from: 0).whenComplete(() {
      _settle.removeListener(tick);
      PaneProjectionBack.progress.value = target;
    });
  }

  /// 关闭投影层(ESC/系统返回/onBack):直接退层/清栈——胶片带容器
  /// 对结构变化自己演滑出(退栈=顶格右滑出、下层格/列表跟进),这里
  /// 不再手工播 progress 滑出(旧机制,带模型下会双动)。
  void _closeProjection() {
    final notifier = ref.read(widget.stackProvider.notifier);
    if (ref.read(widget.stackProvider).isStacked) {
      notifier.pop();
    } else {
      notifier.clear();
    }
  }

  /// 预测返回 commit:手势已把顶格拖出一段(bandDrag),先把 progress
  /// 补到 1(顶格完全滑出),再清栈——清栈瞬间置 suppress,胶片带对
  /// 这次结构变化瞬切(滑出已由手势+补间演过,再演一遍会跳回重滑)。
  void _commitClose() {
    final from = PaneProjectionBack.progress.value;
    _settle.stop();
    final animation = _settle.drive(
      Tween(begin: from, end: 1.0).chain(CurveTween(curve: Curves.easeOut)),
    );
    void tick() => PaneProjectionBack.progress.value = animation.value;
    _settle.addListener(tick);
    _settle.forward(from: 0).whenComplete(() {
      _settle.removeListener(tick);
      if (!mounted) return;
      PaneProjectionBack.suppressNextPaneSwitch();
      final notifier = ref.read(widget.stackProvider.notifier);
      if (ref.read(widget.stackProvider).isStacked) {
        notifier.pop();
      } else {
        notifier.clear();
      }
      PaneProjectionBack.progress.value = 0;
    });
  }

  void _syncReport(bool active) {
    if (_desiredReport == active) return;
    _desiredReport = active;
    _scheduleReportSync();
  }

  /// 期望态与已上报态挂帧对账:build/dispose 期间都不能直接 notify
  /// (会撞依赖方 setState-during-build),统一挪帧;多次翻转合并成
  /// 最终态一次上报。
  void _scheduleReportSync() {
    if (_reportSyncScheduled) return;
    _reportSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reportSyncScheduled = false;
      if (_appliedReport == _desiredReport) return;
      _appliedReport = _desiredReport;
      PaneProjectionBackScope._report(_appliedReport);
    });
  }

  @override
  void dispose() {
    _syncReport(false);
    _predictiveBack?.dispose();
    _settle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(widget.stackProvider);
    final projecting =
        widget.isActive &&
        selected.hasSelection &&
        !MasterDetailLayout.canShowBothPanesFor(
          context,
          masterWidth: widget.masterWidth,
          minDetailWidth: widget.minDetailWidth,
        );
    _syncReport(projecting);

    return PopScope(
      canPop: !projecting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 共享根路由上所有 PopEntry 都会被回调,只有真正投影中的宿主
        // 消费这次返回。
        if (!_projectionOpen) return;
        _closeProjection();
      },
      child: widget.child,
    );
  }
}
