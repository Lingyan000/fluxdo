import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/shortcut_binding.dart';
import '../../l10n/s.dart';
import '../../providers/discourse_providers.dart';
import '../../providers/shortcut_provider.dart';
import '../../providers/preferences_provider.dart';
import '../../pages/notifications_page.dart';
import '../../utils/blur_config.dart';
import '../../utils/responsive.dart';
import '../../utils/notification_navigation.dart';
import 'notification_item.dart';
import 'notification_list_skeleton.dart';

/// 通知快捷面板控制器
/// 侧栏模式：在 widget 树中渲染（低于路由层，新页面自然覆盖）
/// 手机模式：showModalBottomSheet
class NotificationQuickPanel {
  NotificationQuickPanel._();

  /// 侧栏模式面板可见性
  static final ValueNotifier<bool> _visible = ValueNotifier(false);
  static ValueNotifier<bool> get visible => _visible;
  static bool get isVisible => _visible.value;

  /// 弹出或关闭快捷面板
  static Future<void> show(BuildContext context) {
    _visible.value = !_visible.value;
    return Future.value();
  }

  /// 关闭侧栏面板
  static void dismiss() {
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
  final ScrollController _scrollController = ScrollController();
  bool _wasVisible = false;

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
    _shortcutSurfaceBinding = ShortcutSurfaceBinding(
      ref: ref,
      id: ShortcutSurfaceIds.notifications,
      triggerAction: ShortcutAction.toggleNotifications,
      repeatBehavior: ShortcutSurfaceRepeatBehavior.toggle,
    );
    _wasVisible = NotificationQuickPanel._visible.value;
    if (_wasVisible) {
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
    NotificationQuickPanel._visible.removeListener(_onVisibilityChanged);
    _animController.removeStatusListener(_onAnimationStatusChanged);
    _shortcutSurfaceBinding.disposeDeferred();
    _animController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onAnimationStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _dragOffset != 0) {
      setState(() => _dragOffset = 0);
    }
  }

  void _onVisibilityChanged() {
    final isVisible = NotificationQuickPanel._visible.value;
    if (isVisible && !_wasVisible) {
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
          color: Theme.of(context).colorScheme.surface,
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

/// 共用标题栏
class _NotificationHeader extends ConsumerWidget {
  const _NotificationHeader({required this.padding});

  final EdgeInsets padding;

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
            icon: const Icon(Icons.done_all, size: 20),
            tooltip: context.l10n.notification_markAllRead,
            style: IconButton.styleFrom(
              foregroundColor: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: () {
              NotificationQuickPanel.dismiss();
              Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute(builder: (_) => const NotificationsPage()),
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
                  Icons.chevron_right,
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
          if (notifications.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.notifications_none,
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
            itemCount: notifications.length,
            itemBuilder: (context, index) {
              final notification = notifications[index];
              return NotificationItem(
                notification: notification,
                systemAvatarTemplate: systemAvatarTemplate,
                onTap: () {
                  handleNotificationTap(context, ref, notification);
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
              const Icon(Icons.error_outline, size: 48, color: Colors.grey),
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
