import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/shortcut_binding.dart';
import '../../l10n/s.dart';
import '../../providers/discourse_providers.dart';
import '../../providers/shortcut_provider.dart';
import '../../providers/preferences_provider.dart';
import '../../pages/notifications_page.dart';
import '../../services/dynamic_content_suspension_service.dart';
import '../../theme/theme_resolver.dart';
import '../../utils/blur_config.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/responsive.dart';
import '../../utils/notification_navigation.dart';
import '../../utils/blocked_user_filter.dart';
import '../common/predictive_back_overlay_handler.dart';
import '../layout/master_detail_layout.dart';
import '../topic/category_drawer.dart' show CategoryDrawerHost;
import 'notification_item.dart';
import 'notification_list_skeleton.dart';

/// 通知快捷面板控制器
/// 侧栏模式：在 widget 树中渲染（低于路由层，新页面自然覆盖）
/// 手机模式：ModalBottomSheetRoute
class NotificationQuickPanel {
  NotificationQuickPanel._();

  /// 侧栏模式面板可见性
  static final ValueNotifier<bool> _visible = ValueNotifier(false);
  static ValueNotifier<bool> get visible => _visible;
  static bool get isVisible => _visible.value;
  static Future<void>? _mobileFuture;
  static bool _mobileDismissPending = false;

  /// 手机 sheet 自身的路由,由 [_MobileNotificationPanelState] 在挂载后
  /// 回填。dismiss 必须锚定这条路由而非「navigator 栈顶」:通知条目的
  /// 点击顺序是「先 push 详情页再关面板」,此刻栈顶是详情页,盲目 pop
  /// 会把刚打开的详情页弹掉。
  static ModalRoute<dynamic>? _mobileRoute;

  /// 弹出或关闭快捷面板(重复触发 = 收起,两种模式同语义)
  static Future<void> show(BuildContext context) {
    if (!Responsive.showNavigationRail(context)) {
      final existing = _mobileFuture;
      if (existing != null) {
        dismiss();
        return existing;
      }

      _mobileDismissPending = false;
      final future = showAppBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        shortcutSurface: const ShortcutSurfaceConfig(
          id: ShortcutSurfaceIds.notifications,
          triggerAction: ShortcutAction.toggleNotifications,
          repeatBehavior: ShortcutSurfaceRepeatBehavior.toggle,
        ),
        builder: (_) => const _MobileNotificationPanel(),
      ).then<void>((_) {});
      _mobileFuture = future;
      future
          .whenComplete(() {
            if (identical(_mobileFuture, future)) {
              _mobileFuture = null;
              _mobileRoute = null;
              _mobileDismissPending = false;
            }
          })
          .ignore();
      return future;
    }

    _visible.value = !_visible.value;
    return Future.value();
  }

  /// 关闭当前通知面板
  static void dismiss() {
    final route = _mobileRoute;
    if (route == null && _mobileFuture != null) {
      // show() 已 push 路由、但 sheet 子树还没挂载。记住这次关闭，
      // 避免首帧前快速二次触发被吞掉。
      _mobileDismissPending = true;
      return;
    }
    if (route != null) {
      final navigator = route.navigator;
      if (navigator != null && route.isActive) {
        if (route.isCurrent) {
          navigator.pop();
        } else {
          // 上面已经盖了别的路由(点通知先 push 详情页):无动画抽掉
          // sheet,详情页保持在原位。
          navigator.removeRoute(route);
        }
      }
      return;
    }
    _visible.value = false;
  }
}

/// 侧栏模式通知面板（嵌入 widget 树，低于路由层）
/// 放在 AdaptiveScaffold 的 body Stack 中
class SidebarNotificationPanel extends ConsumerStatefulWidget {
  const SidebarNotificationPanel({super.key});

  @override
  ConsumerState<SidebarNotificationPanel> createState() =>
      _SidebarNotificationPanelState();
}

class _SidebarNotificationPanelState
    extends ConsumerState<SidebarNotificationPanel>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _animation;
  late final ShortcutSurfaceBinding _shortcutSurfaceBinding;
  late final PredictiveBackOverlayHandler _predictiveBackHandler;
  final ScrollController _scrollController = ScrollController();
  bool _wasVisible = false;
  DynamicContentSuspensionLease? _dynamicContentLease;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _animation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _predictiveBackHandler = PredictiveBackOverlayHandler(
      // 分类抽屉在 Stack 里盖在本面板之上,两者同开时手势归抽屉,
      // 这里让位(见 PredictiveBackOverlayHandler 的互斥说明)。
      isEnabled: () =>
          (ModalRoute.of(context)?.isCurrent ?? false) &&
          NotificationQuickPanel.isVisible &&
          !CategoryDrawerHost.isOpen,
      onStart: _onPredictiveBackStart,
      onUpdate: _onPredictiveBackUpdate,
      onCancel: _onPredictiveBackCancel,
      onCommit: NotificationQuickPanel.dismiss,
    )..attach();
    _shortcutSurfaceBinding = ShortcutSurfaceBinding(
      ref: ref,
      id: ShortcutSurfaceIds.notifications,
      triggerAction: ShortcutAction.toggleNotifications,
      repeatBehavior: ShortcutSurfaceRepeatBehavior.toggle,
    );
    _wasVisible = NotificationQuickPanel._visible.value;
    if (_wasVisible) {
      _acquireDynamicContentSuspension();
      _animController.value = 1;
      _shortcutSurfaceBinding.registerDeferred(
        context,
        onClose: NotificationQuickPanel.dismiss,
      );
    }
    NotificationQuickPanel._visible.addListener(_onVisibilityChanged);
    _animController.addStatusListener(_onAnimationStatusChanged);
  }

  @override
  void dispose() {
    _predictiveBackHandler.dispose();
    NotificationQuickPanel._visible.removeListener(_onVisibilityChanged);
    _animController.removeStatusListener(_onAnimationStatusChanged);
    _shortcutSurfaceBinding.disposeDeferred();
    _releaseDynamicContentSuspension();
    _animController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onPredictiveBackStart() {
    _animController.stop();
    if (_dragOffset != 0) setState(() => _dragOffset = 0);
  }

  void _onPredictiveBackUpdate(double progress) {
    _animController.value = 1.0 - progress;
  }

  void _onPredictiveBackCancel() {
    if (NotificationQuickPanel.isVisible) {
      _animController.animateTo(
        1.0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _onAnimationStatusChanged(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;

    // 反向动画完全结束后再恢复底层动态内容，避免面板仍半透明可见时，
    // SVG/WebView 等重新启动并让背景模糊层再次持续重算。
    _releaseDynamicContentSuspension();
    if (_dragOffset != 0) {
      setState(() => _dragOffset = 0);
    }
  }

  void _acquireDynamicContentSuspension() {
    _dynamicContentLease ??= DynamicContentSuspensionService.instance.acquire(
      reason: 'notification_quick_panel',
    );
  }

  void _releaseDynamicContentSuspension() {
    _dynamicContentLease?.release();
    _dynamicContentLease = null;
  }

  void _onVisibilityChanged() {
    final isVisible = NotificationQuickPanel._visible.value;
    if (isVisible && !_wasVisible) {
      // 在入场动画开始前先暂停底层动态内容，避免首个模糊帧就与帖子动画、
      // WebView 纹理提交争抢 UI/raster 线程。
      _acquireDynamicContentSuspension();
      _animController.forward();
      _shortcutSurfaceBinding.register(
        context,
        onClose: NotificationQuickPanel.dismiss,
      );
    } else if (!isVisible && _wasVisible) {
      _animController.reverse();
      _shortcutSurfaceBinding.clear();
    }
    _wasVisible = isVisible;
  }

  double _dragOffset = 0;
  final _contentKey = GlobalKey();

  void _handleMobileDragUpdate(DragUpdateDetails details) {
    final nextOffset = (_dragOffset + details.delta.dy).clamp(
      0.0,
      double.infinity,
    );
    if (nextOffset == _dragOffset) return;
    setState(() => _dragOffset = nextOffset);
  }

  void _handleMobileDragEnd(DragEndDetails details, double panelHeight) {
    final shouldDismiss =
        _dragOffset > panelHeight * 0.2 || (details.primaryVelocity ?? 0) > 500;
    if (shouldDismiss) {
      NotificationQuickPanel.dismiss();
      return;
    }
    if (_dragOffset != 0) {
      setState(() => _dragOffset = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final showRail = Responsive.showNavigationRail(context);

    // 用 GlobalKey 保持内容子树不重建，滚动位置自然保留
    final content = KeyedSubtree(
      key: _contentKey,
      child: Column(
        children: [
          _NotificationHeader(
            padding: EdgeInsets.fromLTRB(20, showRail ? 16 : 12, 12, 8),
            onClose: NotificationQuickPanel.dismiss,
          ),
          _NotificationBody(scrollController: _scrollController),
        ],
      ),
    );

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        if (_animation.value == 0 && !_animController.isAnimating) {
          return const SizedBox.shrink();
        }

        final dialogBlur = ProviderScope.containerOf(
          context,
          listen: false,
        ).read(preferencesProvider).dialogBlur;
        final barrierColor = dialogBlur
            ? blurBarrierColor(Theme.of(context).brightness)
            : Colors.black26;

        final panel = Material(
          color: Theme.of(context).colorScheme.overlaySurface,
          clipBehavior: Clip.antiAlias,
          elevation: 8,
          borderRadius: showRail
              ? const BorderRadius.only(topRight: Radius.circular(20))
              : const BorderRadius.vertical(top: Radius.circular(20)),
          child: Column(
            children: [
              if (!showRail)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: _handleMobileDragUpdate,
                  onVerticalDragEnd: (details) => _handleMobileDragEnd(
                    details,
                    MediaQuery.sizeOf(context).height * 0.8,
                  ),
                  child: const SizedBox(
                    width: double.infinity,
                    height: 28,
                    child: _DragHandle(),
                  ),
                ),
              Expanded(child: content),
            ],
          ),
        );

        return showRail
            ? _buildSidebarLayout(panel, dialogBlur, barrierColor)
            : _buildMobileLayout(panel, dialogBlur, barrierColor);
      },
    );
  }

  /// 侧栏模式：从左边缘滑出
  Widget _buildSidebarLayout(Widget child, bool blur, Color barrierColor) {
    final screenSize = MediaQuery.sizeOf(context);
    const panelWidth = 420.0;
    final panelHeight = (screenSize.height * 0.9).clamp(0.0, 900.0);
    final actualPanelWidth = panelWidth.clamp(0.0, screenSize.width);

    // 面板可见区域的圆角矩形（排除此区域避免模糊影响面板内容）
    final visiblePanelWidth = actualPanelWidth * _animation.value;
    final panelRRect = RRect.fromRectAndCorners(
      Rect.fromLTWH(
        0,
        screenSize.height - panelHeight,
        visiblePanelWidth,
        panelHeight,
      ),
      topRight: const Radius.circular(20),
    );

    return Stack(
      children: [
        // 模糊层：排除面板圆角矩形，圆角外侧仍可透出模糊
        if (blur)
          Positioned.fill(
            child: ClipPath(
              clipper: _ExcludeRRectClipper(panelRRect),
              child: BackdropFilter(
                filter: createBlurFilter(
                  (blurSigma * _animation.value).clamp(0.01, blurSigma),
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        // 暗色遮罩 + 点击关闭（全屏，面板自身遮盖其下方区域）
        Positioned.fill(
          child: GestureDetector(
            onTap: NotificationQuickPanel.dismiss,
            child: ColoredBox(
              color: barrierColor.withValues(
                alpha: barrierColor.a * _animation.value,
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          bottom: 0,
          width: actualPanelWidth,
          height: panelHeight,
          child: ClipRect(
            child: FractionalTranslation(
              translation: Offset(_animation.value - 1, 0),
              child: child,
            ),
          ),
        ),
      ],
    );
  }

  /// 手机模式：从底部滑出 + 下滑关闭
  Widget _buildMobileLayout(Widget child, bool blur, Color barrierColor) {
    final screenSize = MediaQuery.sizeOf(context);
    final panelHeight = screenSize.height * 0.8;
    final slideOffset = (1 - _animation.value) * panelHeight;
    final dragOffset = _dragOffset.clamp(0.0, panelHeight);

    // 面板可见高度（随动画和拖拽变化）
    final visibleHeight = (panelHeight * _animation.value - dragOffset).clamp(
      0.0,
      panelHeight,
    );
    final panelRRect = RRect.fromRectAndCorners(
      Rect.fromLTWH(
        0,
        screenSize.height - visibleHeight,
        screenSize.width,
        visibleHeight,
      ),
      topLeft: const Radius.circular(20),
      topRight: const Radius.circular(20),
    );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // 模糊层：排除面板圆角矩形
        if (blur)
          Positioned.fill(
            child: ClipPath(
              clipper: _ExcludeRRectClipper(panelRRect),
              child: BackdropFilter(
                filter: createBlurFilter(
                  (blurSigma * _animation.value).clamp(0.01, blurSigma),
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        // 暗色遮罩 + 点击关闭
        Positioned.fill(
          child: GestureDetector(
            onTap: NotificationQuickPanel.dismiss,
            child: ColoredBox(
              color: barrierColor.withValues(
                alpha: barrierColor.a * _animation.value,
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Transform.translate(
            offset: Offset(0, slideOffset + dragOffset),
            child: SizedBox(
              width: double.infinity,
              height: panelHeight,
              child: child,
            ),
          ),
        ),
      ],
    );
  }
}

/// 裁剪路径：全屏减去指定圆角矩形（EvenOdd 填充规则）
///
/// 模糊层使用此 clipper，使模糊覆盖除面板内容区域外的整个屏幕。
/// 面板圆角外侧（弧线与包围盒之间的三角区）仍在模糊范围内，
/// 因此圆角处可自然透出模糊背景。
class _ExcludeRRectClipper extends CustomClipper<Path> {
  final RRect excludeRRect;
  const _ExcludeRRectClipper(this.excludeRRect);

  @override
  Path getClip(Size size) {
    return Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(excludeRRect)
      ..fillType = PathFillType.evenOdd;
  }

  @override
  bool shouldReclip(_ExcludeRRectClipper old) =>
      excludeRRect != old.excludeRRect;
}

/// 手机模式 BottomSheet 面板
/// 拖拽手柄
class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 12),
        width: 32,
        height: 4,
        decoration: BoxDecoration(
          color: colorScheme.outlineVariant.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// 手机端通知面板作为真正的 ModalBottomSheetRoute 渲染，
/// 让系统返回手势可以驱动路由动画并在取消时恢复。
class _MobileNotificationPanel extends StatefulWidget {
  const _MobileNotificationPanel();

  @override
  State<_MobileNotificationPanel> createState() =>
      _MobileNotificationPanelState();
}

class _MobileNotificationPanelState extends State<_MobileNotificationPanel> {
  final ScrollController _scrollController = ScrollController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 回填 sheet 自身路由,供 dismiss 精确锚定(而非盲 pop 栈顶)
    final route = ModalRoute.of(context);
    NotificationQuickPanel._mobileRoute = route;
    if (route != null && NotificationQuickPanel._mobileDismissPending) {
      NotificationQuickPanel._mobileDismissPending = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (identical(NotificationQuickPanel._mobileRoute, route)) {
          NotificationQuickPanel.dismiss();
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _openAllNotifications() {
    final navigator = Navigator.of(context, rootNavigator: true);
    navigator.pop();
    navigator.push(
      MaterialPageRoute(builder: (_) => const NotificationsPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.8;
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            _NotificationHeader(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
              onClose: NotificationQuickPanel.dismiss,
              onViewAll: _openAllNotifications,
            ),
            _NotificationBody(scrollController: _scrollController),
          ],
        ),
      ),
    );
  }
}

/// 共用标题栏
class _NotificationHeader extends ConsumerWidget {
  const _NotificationHeader({
    required this.padding,
    required this.onClose,
    this.onViewAll,
  });

  final EdgeInsets padding;
  final VoidCallback onClose;
  final VoidCallback? onViewAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: padding,
      child: Row(
        children: [
          Text(
            context.l10n.common_notification,
            style: theme.textTheme.titleLarge,
          ),
          const Spacer(),
          IconButton(
            onPressed: () async {
              await ref
                  .read(recentNotificationsProvider.notifier)
                  .markAllAsRead();
            },
            icon: const Icon(Symbols.done_all_rounded, size: 20),
            tooltip: context.l10n.notification_markAllRead,
            style: IconButton.styleFrom(
              foregroundColor: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed:
                onViewAll ??
                () {
                  onClose();
                  Navigator.of(context, rootNavigator: true).push(
                    MaterialPageRoute(
                      builder: (_) => const NotificationsPage(),
                    ),
                  );
                },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.l10n.common_viewAll,
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
                const SizedBox(width: 2),
                Icon(
                  Symbols.chevron_right_rounded,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 共用通知列表
class _NotificationBody extends ConsumerStatefulWidget {
  const _NotificationBody({this.scrollController});

  final ScrollController? scrollController;

  @override
  ConsumerState<_NotificationBody> createState() => _NotificationBodyState();
}

class _NotificationBodyState extends ConsumerState<_NotificationBody> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.invalidate(recentNotificationsProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final notificationsAsync = ref.watch(recentNotificationsProvider);
    final systemAvatarTemplate = ref
        .watch(systemUserAvatarTemplateProvider)
        .value;

    return Expanded(
      child: notificationsAsync.when(
        data: (notifications) {
          final blockedUsernames = ref.watch(
            preferencesProvider.select((p) => p.normalizedBlockedUsernames),
          );
          final visibleNotifications = notifications
              .where(
                (notification) => !BlockedUserFilter.isBlockedNotification(
                  notification,
                  blockedUsernames,
                ),
              )
              .toList(growable: false);
          if (visibleNotifications.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Symbols.notifications_rounded,
                    size: 48,
                    color: Colors.grey,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    context.l10n.notification_empty,
                    style: const TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            );
          }
          return ListView.builder(
            controller: widget.scrollController,
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).padding.bottom,
            ),
            itemCount: visibleNotifications.length,
            itemBuilder: (context, index) {
              final notification = visibleNotifications[index];
              return NotificationItem(
                notification: notification,
                systemAvatarTemplate: systemAvatarTemplate,
                onTap: () {
                  // 先派发跳转再处理面板:跳转在本帧同步读取
                  // context/provider。siblings = 当前可见列表,大屏弹窗
                  // 内可上一条/下一条快速切换。
                  handleNotificationTap(
                    context,
                    ref,
                    notification,
                    siblings: visibleNotifications,
                  );
                  // 大屏(弹窗落点,自带通知列表侧栏)关面板;窄屏推的
                  // 是全屏详情路由,sheet 留在栈里垫底——返回即回到
                  // 面板继续看下一条,不用重新拉开。
                  if (MasterDetailLayout.canShowBothPanesFor(context)) {
                    NotificationQuickPanel.dismiss();
                  }
                },
              );
            },
          );
        },
        loading: () => const NotificationListSkeleton(),
        error: (error, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Symbols.error_rounded, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              Text(
                context.l10n.common_loadFailed,
                style: TextStyle(color: colorScheme.error),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => ref.invalidate(recentNotificationsProvider),
                child: Text(context.l10n.common_retry),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
