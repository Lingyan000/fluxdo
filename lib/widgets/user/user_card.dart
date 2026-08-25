import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../models/user.dart';
import '../../pages/chat/channel/chat_channel_page.dart';
import '../../providers/discourse_providers.dart';
import '../../providers/selected_topic_provider.dart';
import '../../services/app_error_handler.dart';
import '../../services/discourse_cache_manager.dart';
import '../../services/preloaded_data_service.dart';
import '../../services/toast_service.dart';
import '../../theme/theme_resolver.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/number_utils.dart';
import '../../utils/platform_utils.dart';
import '../../utils/time_utils.dart';
import '../common/flair_badge.dart';
import 'package:common_ui/common_ui.dart';
import '../common/skeleton.dart';
import '../common/smart_avatar.dart';
import '../../utils/fluxdo_render_callbacks.dart';
import 'avatar_action_menu.dart';
import 'ignore_duration_picker.dart';

/// 卡片与锚点之间的间隙
const double _kGap = 10.0;

/// 距屏幕边缘的最小留白
const double _kScreenMargin = 12.0;

/// 桌面端浮层宽度（比移动端更宽，对齐网页版桌面卡片）
const double _kFloatingWidth = 420.0;

/// 移动端停靠卡最大宽度
const double _kDockedMaxWidth = 480.0;

/// 头像半径（戳出卡片顶边的大头像）
const double _kAvatarRadius = 38.0;

/// 头像戳出卡片顶边的高度
const double _kAvatarOverflow = 24.0;

/// 是否允许展示用户卡片（站点隐藏公开资料时要求已登录）。
bool canShowUserCardPreview(BuildContext context) {
  final preloaded = PreloadedDataService();
  final hideProfilesFromPublic =
      preloaded.siteSettingsSync?['hide_user_profiles_from_public'] == true;
  if (!hideProfilesFromPublic) return true;

  final currentUser = ProviderScope.containerOf(context, listen: false)
      .read(currentUserProvider)
      .value;
  return currentUser != null || preloaded.currentUserSync != null;
}

/// 显示用户卡片。两种形态对齐 Discourse 网页版：
/// - 桌面端：锚定在头像旁的浮层（优先右侧，其次左/下/上）。
/// - 移动端：顶部全宽停靠卡（docked），背景模糊作遮罩。
///
/// [anchorRect] 头像在屏幕坐标系中的矩形（桌面端浮层定位用）。
/// [topicId]/[postNumber] 话题上下文，用于「基于话题的私信」（正文携带帖子链接）。
/// [avatarFallbackUrl]/[nameFallback]/flair* 来自 Post，用于在网络返回前秒显头部。
void showUserCard({
  required BuildContext context,
  required Rect anchorRect,
  required String username,
  LayerLink? layerLink,
  int? topicId,
  String? topicTitle,
  int? postNumber,
  String? avatarFallbackUrl,
  String? nameFallback,
  String? flairUrl,
  String? flairName,
  String? flairBgColor,
  String? flairColor,
}) {
  if (!canShowUserCardPreview(context)) return;

  final anchorContext = context;
  final menuNavigatorKey =
      PlatformUtils.isDesktop ? GlobalKey<NavigatorState>() : null;

  Widget buildCard(VoidCallback onClose) => _UserCardContent(
        username: username,
        topicId: topicId,
        topicTitle: topicTitle,
        postNumber: postNumber,
        avatarFallbackUrl: avatarFallbackUrl,
        nameFallback: nameFallback,
        flairUrl: flairUrl,
        flairName: flairName,
        flairBgColor: flairBgColor,
        flairColor: flairColor,
        anchorContext: anchorContext,
        menuNavigatorKey: menuNavigatorKey,
        onClose: onClose,
      );

  if (PlatformUtils.isDesktop) {
    // 桌面端：非模态浮层，不挡背景滚动（对齐网页版 PC）。
    // 用 OverlayEntry（无 barrier）+ 半透明 Listener：卡外按下即关闭，
    // 滚轮/拖动等事件穿透到下层页面，背景照常滚动。
    final overlay = Overlay.of(context, rootOverlay: true);
    OverlayEntry? entry;
    var removed = false;
    void close() {
      if (removed) return;
      removed = true;
      entry?.remove();
    }

    entry = OverlayEntry(
      builder: (ctx) {
        final animatedCard = _CardEntryAnimation(child: buildCard(close));
        // 有 LayerLink：卡片跟随头像滚动（对齐网页版）；否则按锚点矩形静态定位。
        // 边界处理：锚点在下半屏 → 卡片底对齐锚点底向上生长；右侧放不下
        // 宽度 → 挂到锚点左侧。maxHeight 按实际可用空间收紧,不再溢出屏幕。
        final screen = MediaQuery.of(ctx).size;
        final alignBottom = anchorRect.center.dy > screen.height * 0.55;
        final placeLeft =
            anchorRect.right + _kGap + _kFloatingWidth >
            screen.width - _kScreenMargin;
        final availableHeight = alignBottom
            ? anchorRect.bottom - _kScreenMargin
            : screen.height - anchorRect.top - _kScreenMargin;
        final maxHeight = availableHeight
            .clamp(200.0, screen.height * 0.8)
            .toDouble();
        final Widget positioned = layerLink != null
            ? CompositedTransformFollower(
                link: layerLink,
                showWhenUnlinked: false,
                targetAnchor: placeLeft
                    ? (alignBottom
                          ? Alignment.bottomLeft
                          : Alignment.topLeft)
                    : (alignBottom
                          ? Alignment.bottomRight
                          : Alignment.topRight),
                followerAnchor: placeLeft
                    ? (alignBottom
                          ? Alignment.bottomRight
                          : Alignment.topRight)
                    : (alignBottom
                          ? Alignment.bottomLeft
                          : Alignment.topLeft),
                offset: Offset(placeLeft ? -_kGap : _kGap, alignBottom ? 8 : -8),
                child: Align(
                  alignment: alignBottom
                      ? (placeLeft
                            ? Alignment.bottomRight
                            : Alignment.bottomLeft)
                      : (placeLeft
                            ? Alignment.topRight
                            : Alignment.topLeft),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: _kFloatingWidth,
                      maxHeight: maxHeight,
                    ),
                    child: animatedCard,
                  ),
                ),
              )
            : _FloatingLayer(anchorRect: anchorRect, child: animatedCard);

        return Stack(
          children: [
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) => close(),
                child: const SizedBox.expand(),
              ),
            ),
            positioned,
            Positioned.fill(
              child: _UserCardMenuNavigator(navigatorKey: menuNavigatorKey!),
            ),
          ],
        );
      },
    );
    overlay.insert(entry);
  } else {
    // 移动端：顶部全宽停靠卡 + 模糊遮罩（对应网页版移动端 card-cloak）。
    showAppGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (dialogContext, _, _) =>
          _DockedLayer(child: buildCard(() => Navigator.of(dialogContext).pop())),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
            alignment: Alignment.topCenter,
            child: child,
          ),
        );
      },
    );
  }
}

class _UserCardMenuNavigator extends StatelessWidget {
  final GlobalKey<NavigatorState> navigatorKey;

  const _UserCardMenuNavigator({required this.navigatorKey});

  static const _hostRouteName = '_userCardMenuHost';

  @override
  Widget build(BuildContext context) {
    return _UserCardMenuNavigatorHost(navigatorKey: navigatorKey);
  }
}

class _UserCardMenuNavigatorHost extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;

  const _UserCardMenuNavigatorHost({required this.navigatorKey});

  @override
  State<_UserCardMenuNavigatorHost> createState() =>
      _UserCardMenuNavigatorHostState();
}

class _UserCardMenuNavigatorHostState extends State<_UserCardMenuNavigatorHost> {
  late final _UserCardMenuNavigatorObserver _observer =
      _UserCardMenuNavigatorObserver(_setMenuActive);
  bool _menuActive = false;

  void _setMenuActive(bool active) {
    if (_menuActive == active || !mounted) return;
    setState(() => _menuActive = active);
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !_menuActive,
      child: Navigator(
        key: widget.navigatorKey,
        clipBehavior: Clip.none,
        observers: [_observer],
        onGenerateRoute: (_) => PageRouteBuilder<void>(
          settings:
              const RouteSettings(name: _UserCardMenuNavigator._hostRouteName),
          opaque: false,
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (_, _, _) => const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _UserCardMenuNavigatorObserver extends NavigatorObserver {
  final ValueChanged<bool> onActiveChanged;
  int _menuRouteCount = 0;

  _UserCardMenuNavigatorObserver(this.onActiveChanged);

  bool _isMenuRoute(Route<dynamic>? route) =>
      route?.settings.name != _UserCardMenuNavigator._hostRouteName;

  void _notify() => onActiveChanged(_menuRouteCount > 0);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isMenuRoute(route)) {
      _menuRouteCount += 1;
      _notify();
    }
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isMenuRoute(route) && _menuRouteCount > 0) {
      _menuRouteCount -= 1;
      _notify();
    }
    super.didPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isMenuRoute(route) && _menuRouteCount > 0) {
      _menuRouteCount -= 1;
      _notify();
    }
    super.didRemove(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (_isMenuRoute(oldRoute) && _menuRouteCount > 0) {
      _menuRouteCount -= 1;
    }
    if (_isMenuRoute(newRoute)) {
      _menuRouteCount += 1;
    }
    _notify();
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }
}

/// 桌面端浮层入场动画（淡入 + 轻微缩放），OverlayEntry 无路由动画，手动补一个
class _CardEntryAnimation extends StatefulWidget {
  final Widget child;
  const _CardEntryAnimation({required this.child});

  @override
  State<_CardEntryAnimation> createState() => _CardEntryAnimationState();
}

class _CardEntryAnimationState extends State<_CardEntryAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    duration: const Duration(milliseconds: 180),
    vsync: this,
  )..forward();
  late final Animation<double> _anim =
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.96, end: 1.0).animate(_anim),
        alignment: Alignment.topLeft,
        child: widget.child,
      ),
    );
  }
}

/// 移动端：顶部全宽停靠卡
class _DockedLayer extends StatelessWidget {
  final Widget child;
  const _DockedLayer({required this.child});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final maxHeight = media.size.height * 0.82;
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          // 顶部多留出头像戳出的高度，避免被状态栏/安全区裁剪
          padding: const EdgeInsets.fromLTRB(
              _kScreenMargin, _kAvatarOverflow + 6, _kScreenMargin, _kScreenMargin),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: _kDockedMaxWidth, maxHeight: maxHeight),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 桌面端：锚定头像旁的浮层
class _FloatingLayer extends StatelessWidget {
  final Rect anchorRect;
  final Widget child;

  const _FloatingLayer({required this.anchorRect, required this.child});

  @override
  Widget build(BuildContext context) {
    return CustomSingleChildLayout(
      delegate: _FloatingLayoutDelegate(
        anchorRect: anchorRect,
        safeInsets: MediaQuery.of(context).padding,
      ),
      child: child,
    );
  }
}

/// 桌面端浮层定位：优先放在锚点右侧，其次左侧，再次下方/上方，并 clamp 在屏幕内。
class _FloatingLayoutDelegate extends SingleChildLayoutDelegate {
  final Rect anchorRect;
  final EdgeInsets safeInsets;

  _FloatingLayoutDelegate({required this.anchorRect, required this.safeInsets});

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final maxWidth = math.min(_kFloatingWidth, constraints.maxWidth - _kScreenMargin * 2);
    final maxHeight = constraints.maxHeight - safeInsets.vertical - _kScreenMargin * 2;
    return BoxConstraints(
      minWidth: 0,
      maxWidth: maxWidth,
      minHeight: 0,
      maxHeight: math.max(160.0, maxHeight),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // 顶部额外留出头像戳出的高度，避免被裁
    final topLimit = safeInsets.top + _kScreenMargin + _kAvatarOverflow;
    final bottomLimit = size.height - safeInsets.bottom - _kScreenMargin;

    double clampY(double y) =>
        y.clamp(topLimit, math.max(topLimit, bottomLimit - childSize.height));

    // 优先右侧
    final rightX = anchorRect.right + _kGap;
    if (rightX + childSize.width <= size.width - _kScreenMargin) {
      return Offset(rightX, clampY(anchorRect.top));
    }
    // 其次左侧
    final leftX = anchorRect.left - _kGap - childSize.width;
    if (leftX >= _kScreenMargin) {
      return Offset(leftX, clampY(anchorRect.top));
    }
    // 再次下方/上方，水平以锚点居中并 clamp
    final dx = (anchorRect.center.dx - childSize.width / 2)
        .clamp(_kScreenMargin, size.width - childSize.width - _kScreenMargin);
    final belowTop = anchorRect.bottom + _kGap;
    if (belowTop + childSize.height <= bottomLimit) {
      return Offset(dx, belowTop);
    }
    final aboveTop = anchorRect.top - _kGap - childSize.height;
    return Offset(dx, math.max(topLimit, aboveTop));
  }

  @override
  bool shouldRelayout(_FloatingLayoutDelegate oldDelegate) =>
      anchorRect != oldDelegate.anchorRect || safeInsets != oldDelegate.safeInsets;
}

/// 用户卡片内容
class _UserCardContent extends ConsumerStatefulWidget {
  final String username;
  final int? topicId;
  final String? topicTitle;
  final int? postNumber;
  final String? avatarFallbackUrl;
  final String? nameFallback;
  final String? flairUrl;
  final String? flairName;
  final String? flairBgColor;
  final String? flairColor;
  final BuildContext anchorContext;
  final GlobalKey<NavigatorState>? menuNavigatorKey;
  final VoidCallback onClose;

  const _UserCardContent({
    required this.username,
    required this.topicId,
    required this.topicTitle,
    required this.postNumber,
    required this.avatarFallbackUrl,
    required this.nameFallback,
    required this.flairUrl,
    required this.flairName,
    required this.flairBgColor,
    required this.flairColor,
    required this.anchorContext,
    required this.menuNavigatorKey,
    required this.onClose,
  });

  @override
  ConsumerState<_UserCardContent> createState() => _UserCardContentState();
}

class _UserCardContentState extends ConsumerState<_UserCardContent> {
  User? _user;
  bool _loading = true;

  bool _isFollowed = false;
  bool _followLoading = false;

  // normal / mute / ignore
  String _notificationLevel = 'normal';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // 带话题上下文时请求该用户在此话题内的发帖数(topic_post_count),
      // 决定「只看 TA」按钮是否显示
      final user = await ref
          .read(discourseServiceProvider)
          .getUserCard(widget.username, includePostCountFor: widget.topicId);
      if (!mounted) return;
      setState(() {
        _user = user;
        _isFollowed = user.isFollowed ?? false;
        _notificationLevel = user.ignored == true
            ? 'ignore'
            : user.muted == true
                ? 'mute'
                : 'normal';
        _loading = false;
      });
    } catch (e, s) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  void _openProfile() {
    widget.onClose();
    EmbeddedStackScope.openProfile(widget.anchorContext, widget.username);
  }

  void _composeMessage() {
    widget.onClose();
    composeMessageToUser(
      context: widget.anchorContext,
      username: widget.username,
      topicId: widget.topicId,
      postNumber: widget.postNumber,
      topicTitle: widget.topicTitle,
    );
  }

  /// 发起私聊(chat 插件 DM):创建/复用 1:1 频道并进入
  Future<void> _openChat() async {
    final anchorContext = widget.anchorContext;
    widget.onClose();
    try {
      final channel = await ProviderScope.containerOf(
        anchorContext,
        listen: false,
      ).read(discourseServiceProvider).createDirectMessageChannel(
        targetUsernames: [widget.username],
        upsert: true,
      );
      if (!anchorContext.mounted) return;
      await Navigator.push(
        anchorContext,
        MaterialPageRoute(
          builder: (_) => ChatChannelPage(channelId: channel.id),
        ),
      );
    } catch (e) {
      ToastService.showError(e.toString());
    }
  }

  Future<void> _toggleFollow() async {
    if (_followLoading) return;
    setState(() => _followLoading = true);
    final service = ref.read(discourseServiceProvider);
    final wasFollowed = _isFollowed;
    try {
      if (wasFollowed) {
        await service.unfollowUser(widget.username);
      } else {
        await service.followUser(widget.username);
      }
      if (mounted) setState(() => _isFollowed = !wasFollowed);
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _followLoading = false);
    }
  }

  /// 该用户在当前话题的发帖数(无话题上下文/响应未带时为 0)
  int get _topicPostCount {
    final topicId = widget.topicId;
    if (topicId == null) return 0;
    return _user?.topicPostCount[topicId] ?? 0;
  }

  /// 当前话题是否已在「只看这个用户」过滤中
  bool get _isFilteringThisUser {
    final topicId = widget.topicId;
    if (topicId == null) return false;
    final params = TopicDetailNotifier.activeParamsFor(topicId);
    if (params == null) return false;
    final container = ProviderScope.containerOf(
      widget.anchorContext,
      listen: false,
    );
    if (!container.exists(topicDetailProvider(params))) return false;
    return container.read(topicDetailProvider(params).notifier).usernameFilter ==
        widget.username;
  }

  /// 只看该用户/取消过滤:发到请求桥,由话题详情页消费(过滤重载 +
  /// UI 复位都在页面侧,卡片只负责发意图)
  void _toggleFilterPosts() {
    final topicId = widget.topicId;
    if (topicId == null) return;
    final cancel = _isFilteringThisUser;
    widget.onClose();
    ProviderScope.containerOf(widget.anchorContext, listen: false)
        .read(topicUserFilterRequestProvider.notifier)
        .request(topicId: topicId, username: cancel ? null : widget.username);
  }

  Future<void> _setNotificationLevel(String level) async {
    final service = ref.read(discourseServiceProvider);

    String? expiringAt;
    if (level == 'ignore') {
      expiringAt = await showIgnoreDurationPicker(widget.anchorContext);
      if (expiringAt == null) return; // 取消
    }

    final old = _notificationLevel;
    setState(() => _notificationLevel = level);
    try {
      await service.updateUserNotificationLevel(
        widget.username,
        level: level,
        expiringAt: expiringAt,
      );
      if (!mounted) return;
      final label = switch (level) {
        'mute' => S.current.userProfile_setToMute,
        'ignore' => S.current.userProfile_setToIgnore,
        _ => S.current.userProfile_restored,
      };
      ToastService.showSuccess(label);
    } catch (e, s) {
      if (mounted) setState(() => _notificationLevel = old);
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = _user;
    final bg = user?.backgroundUrl;
    final hasBg = bg != null && bg.isNotEmpty;
    final surface = theme.colorScheme.surface;

    final body = SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 第一行：名称排在戳出头像的右侧（对齐网页版 first-row）
            Padding(
              padding: const EdgeInsets.only(left: _kAvatarRadius * 2 + 8),
              child: _buildIdentity(theme, user, hasBg),
            ),
            if (user != null) ...[
              if (user.isSuspended || user.isSilenced)
                _buildRestrictionBanner(theme, user),
              if (_hasBio(user)) _buildBio(theme, user),
              _buildLocationWebsite(theme, user),
              _buildFacts(theme, user),
              _buildStatsRow(theme, user),
            ] else if (_loading)
              _buildBodySkeleton(theme),
            const SizedBox(height: 16),
            _buildActions(theme, user),
          ],
        ),
      ),
    );

    final card = Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.overlaySurface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          // 桌面端无遮罩，靠更重的投影把卡片从背景中托起来
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 32,
            spreadRadius: 1,
            offset: const Offset(0, 12),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.14),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          width: 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      // 背景图与内容蒙版放在同一层（child 内嵌套），保证两者矩形完全重合：
      // border 会让 Container 给 child 加内边距，若图放在外层 decoration 会比蒙版多出一圈露边。
      // 背景图走项目图片层以支持 DoH/CF/缓存；蒙版顶部较透出背景，向下过渡到接近不透明保证可读（对齐 .card-content 半透明）。
      child: hasBg
          ? DecoratedBox(
              decoration: BoxDecoration(
                image: DecorationImage(image: discourseImageProvider(bg), fit: BoxFit.cover),
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      surface.withValues(alpha: 0.45),
                      surface.withValues(alpha: 0.92),
                    ],
                  ),
                ),
                child: body,
              ),
            )
          : body,
    );

    return Material(
      color: Colors.transparent,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          card,
          // 大头像：戳出卡片顶边（对齐网页版），上半在卡外、下半压在卡内
          Positioned(
            left: 16,
            top: -_kAvatarOverflow,
            child: _buildAvatar(theme, user),
          ),
        ],
      ),
    );
  }

  bool _hasBio(User user) => user.bio != null && user.bio!.trim().isNotEmpty;


  /// 大头像（带白色描边 + flair），点击进个人页
  Widget _buildAvatar(ThemeData theme, User? user) {
    // 与各调用方传入的 fallback 尺寸保持一致（144），保证 loading 前后 URL 相同、命中缓存不重载
    final avatarUrl = user?.getAvatarUrl(size: 144) ?? widget.avatarFallbackUrl;
    return GestureDetector(
      onTap: _openProfile,
      child: AvatarWithFlair(
        flairSize: 18,
        flairRight: -2,
        flairBottom: -2,
        flairUrl: user?.flairUrl ?? widget.flairUrl,
        flairName: user?.flairName ?? widget.flairName,
        flairBgColor: user?.flairBgColor ?? widget.flairBgColor,
        flairColor: user?.flairColor ?? widget.flairColor,
        avatar: SmartAvatar(
          imageUrl: (avatarUrl?.isNotEmpty ?? false) ? avatarUrl : null,
          radius: _kAvatarRadius,
          fallbackText: widget.username,
          border: Border.all(color: theme.colorScheme.surface, width: 3),
        ),
      ),
    );
  }

  /// 名称 / @username / 信任等级
  Widget _buildIdentity(ThemeData theme, User? user, bool hasBg) {
    final displayName = (user?.name?.isNotEmpty ?? false)
        ? user!.name!
        : (widget.nameFallback?.isNotEmpty ?? false)
            ? widget.nameFallback!
            : widget.username;

    // 背景图上给文字加阴影，保证可读
    final shadows = hasBg
        ? <Shadow>[Shadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 6)]
        : null;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: _openProfile,
            child: Text(
              displayName,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                shadows: shadows,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Flexible(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // 点击 @username 复制用户名
                  onTap: () => copyUsernameToClipboard(widget.username),
                  child: Text(
                    '@${widget.username}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: hasBg
                          ? theme.colorScheme.onSurface.withValues(alpha: 0.9)
                          : theme.colorScheme.onSurfaceVariant,
                      shadows: shadows,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (user != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    user.trustLevelString,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 简介：高度随内容自适应，超过封顶高度时裁剪 + 底部渐隐
  /// （之前硬裁剪会把第 4 行拦腰切半截）。
  Widget _buildBio(ThemeData theme, User user) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: _ClampedFadeBox(
        maxHeight: 66,
        // 用户卡 bio 属只读预览：走新引擎 FluxdoRender，关闭划词选区。
        child: FluxdoRenderCallbacks.generic(
          heroTagNamespace: 'user_card_bio_${user.username}',
        ).render(
          cookedHtml: user.bio!,
          baseTextStyle: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
          compact: true,
          selectionEnabled: false,
        ),
      ),
    );
  }

  Widget _buildRestrictionBanner(ThemeData theme, User user) {
    final isSuspended = user.isSuspended;
    final color = isSuspended ? theme.colorScheme.error : Colors.orange;
    final label = isSuspended
        ? (user.isSuspendedForever
            ? S.current.userProfile_permanentlySuspended
            : S.current.userProfile_suspendedUntil(TimeUtils.formatFullDate(user.suspendedTill)))
        : (user.isSilencedForever
            ? S.current.userProfile_permanentlySilenced
            : S.current.userProfile_silencedUntil(TimeUtils.formatFullDate(user.silencedTill)));
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(isSuspended ? Symbols.block_rounded : Symbols.mic_off_rounded, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: color, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  /// 位置 / 网站（带图标，对齐网页 location-and-website 行）
  Widget _buildLocationWebsite(ThemeData theme, User user) {
    final items = <Widget>[];
    void add(IconData icon, String text) {
      items.add(Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ));
    }

    if (user.location?.isNotEmpty ?? false) {
      add(Symbols.location_on_rounded, user.location!);
    }
    final site = (user.websiteName?.isNotEmpty ?? false)
        ? user.websiteName!
        : (user.website?.isNotEmpty ?? false)
            ? user.website!
            : null;
    if (site != null) add(Symbols.link_rounded, site);

    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Wrap(spacing: 16, runSpacing: 6, children: items),
    );
  }

  /// 最后发布 / 加入时间 / 阅读时间，标签+值 行内流式（对齐网页 metadata 行）
  Widget _buildFacts(ThemeData theme, User user) {
    final items = <Widget>[];
    if (user.lastPostedAt != null) {
      items.add(_metaItem(theme, S.current.userCard_lastPosted,
          TimeUtils.formatRelativeTime(user.lastPostedAt!)));
    }
    if (user.createdAt != null) {
      items.add(_metaItem(theme, S.current.userProfile_joinDate,
          TimeUtils.formatShortDate(user.createdAt)));
    }
    if ((user.timeRead ?? 0) > 0) {
      items.add(_metaItem(theme, S.current.profileStats_timeRead,
          NumberUtils.formatDurationLong(user.timeRead!)));
    }

    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Wrap(spacing: 14, runSpacing: 4, children: items),
    );
  }

  /// 正在关注 / 粉丝 / 积分，标签+加粗值 行内流式
  Widget _buildStatsRow(ThemeData theme, User user) {
    final items = <Widget>[];
    if (user.totalFollowing != null) {
      items.add(_metaItem(theme, S.current.userProfile_following,
          NumberUtils.formatCount(user.totalFollowing!), bold: true));
    }
    if (user.totalFollowers != null) {
      items.add(_metaItem(theme, S.current.userProfile_followers,
          NumberUtils.formatCount(user.totalFollowers!), bold: true));
    }
    if (user.gamificationScore != null) {
      items.add(_metaItem(theme, S.current.userCard_score,
          NumberUtils.formatCount(user.gamificationScore!),
          bold: true, valueColor: theme.colorScheme.primary));
    }

    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(spacing: 14, runSpacing: 4, children: items),
    );
  }

  /// 标签（灰）+ 值 的行内项
  Widget _metaItem(ThemeData theme, String label, String value,
      {bool bold = false, Color? valueColor}) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label ',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          TextSpan(
            text: value,
            style: theme.textTheme.bodySmall?.copyWith(
              color: valueColor ?? theme.colorScheme.onSurface,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  /// 加载中：正文骨架屏（头像/名称已用 Post 兜底秒显，仅正文待加载）
  Widget _buildBodySkeleton(ThemeData theme) {
    return Skeleton(
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            SkeletonBox(width: double.infinity, height: 13),
            SizedBox(height: 8),
            SkeletonBox(width: 230, height: 13),
            SizedBox(height: 16),
            SkeletonBox(width: 150, height: 12),
            SizedBox(height: 10),
            SkeletonBox(width: 190, height: 12),
          ],
        ),
      ),
    );
  }

  Widget _buildActions(ThemeData theme, User? user) {
    final isLoggedIn = ref.watch(
      currentUserProvider.select((value) => value.value != null),
    );
    final canMessage = isLoggedIn && user?.canSendPrivateMessageToUser == true;
    final canChat = isLoggedIn && user?.canChatUser == true;
    final canFollow = isLoggedIn && user?.canFollow == true;
    final canMute = isLoggedIn && user?.canMuteUser == true;
    final canIgnore = isLoggedIn && user?.canIgnoreUser == true;
    // 「只看 TA」:话题上下文中该用户发帖 ≥2 才显示(对齐官方
    // enoughPostsForFiltering 门槛;=1 时过滤只剩主帖+这一帖,无意义)。
    // 已在过滤中时恒显示,承担取消入口。
    final isFiltering = _isFilteringThisUser;
    final canFilter =
        widget.topicId != null && (_topicPostCount >= 2 || isFiltering);

    final primary = <Widget>[];
    if (canChat) {
      primary.add(FilledButton.icon(
        onPressed: _openChat,
        icon: const Icon(Symbols.chat_rounded, size: 18),
        label: Text(S.current.userCard_chat),
      ));
    }
    if (canMessage) {
      primary.add(canChat
          ? FilledButton.tonalIcon(
              onPressed: _composeMessage,
              icon: const Icon(Symbols.mail_rounded, size: 18),
              label: Text(S.current.userProfile_message),
            )
          : FilledButton.icon(
              onPressed: _composeMessage,
              icon: const Icon(Symbols.mail_rounded, size: 18),
              label: Text(S.current.userProfile_message),
            ));
    }
    if (canFollow) {
      primary.add(_isFollowed
          ? OutlinedButton.icon(
              onPressed: _followLoading ? null : _toggleFollow,
              icon: const Icon(Symbols.how_to_reg_rounded, size: 18),
              label: Text(S.current.userProfile_followed),
            )
          : FilledButton.tonalIcon(
              onPressed: _followLoading ? null : _toggleFollow,
              icon: const Icon(Symbols.person_add_alt_rounded, size: 18),
              label: Text(S.current.userProfile_follow),
            ));
    }

    // 窄卡里三个图标+中文文案的按钮塞一行必挤(实测已关注被压到
    // 竖排折行),每行最多两个,超出的换行铺满
    final primaryRows = <Widget>[];
    for (var i = 0; i < primary.length; i += 2) {
      final rowButtons = primary.sublist(
        i,
        (i + 2).clamp(0, primary.length),
      );
      primaryRows.add(Row(
        children: [
          for (var j = 0; j < rowButtons.length; j++) ...[
            if (j > 0) const SizedBox(width: 8),
            Expanded(child: rowButtons[j]),
          ],
        ],
      ));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in primaryRows) ...[
          row,
          const SizedBox(height: 8),
        ],
        if (canFilter) ...[
          OutlinedButton.icon(
            onPressed: _toggleFilterPosts,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(40),
            ),
            icon: Icon(
              isFiltering
                  ? Symbols.filter_list_off_rounded
                  : Symbols.filter_list_rounded,
              size: 18,
            ),
            label: Text(
              isFiltering
                  ? S.current.userCard_cancelFilterPosts
                  : S.current.userCard_filterPosts(_topicPostCount),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _openProfile,
                icon: const Icon(Symbols.account_circle_rounded, size: 18),
                label: Text(S.current.userCard_viewProfile),
              ),
            ),
            if (canMute || canIgnore) ...[
              const SizedBox(width: 8),
              _buildMoreMenu(theme, canMute, canIgnore),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildMoreMenu(ThemeData theme, bool canMute, bool canIgnore) {
    return SwipeDismissiblePopupMenuButton<String>(
      tooltip: '',
      icon: const Icon(Symbols.more_horiz_rounded),
      style: IconButton.styleFrom(
        side: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.5)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        minimumSize: const Size(48, 40),
      ),
      onSelected: _setNotificationLevel,
      menuNavigatorKey: widget.menuNavigatorKey,
      itemBuilder: (context) => [
        if (canMute)
          _notificationLevel == 'mute'
              ? _menuItem('normal', Symbols.volume_up_rounded, S.current.userProfile_restored)
              : _menuItem('mute', Symbols.volume_off_rounded, S.current.userCard_mute),
        if (canIgnore)
          _notificationLevel == 'ignore'
              ? _menuItem('normal', Symbols.visibility_rounded, S.current.userProfile_restored)
              : _menuItem('ignore', Symbols.visibility_off_rounded, S.current.userCard_ignore),
      ],
    );
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
    );
  }
}

/// 封顶裁剪 + 溢出时底部渐隐的容器:短内容自然高度,长内容裁到
/// [maxHeight] 并在底缘淡出(替代硬裁剪的"半行字"观感)。
class _ClampedFadeBox extends StatelessWidget {
  final double maxHeight;
  final Widget child;

  const _ClampedFadeBox({required this.maxHeight, required this.child});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: _OverflowFade(maxHeight: maxHeight, child: child),
          );
        },
      ),
    );
  }
}

/// 内容高度超过 [maxHeight] 时叠加底部 18px 渐隐遮罩
class _OverflowFade extends StatefulWidget {
  final double maxHeight;
  final Widget child;

  const _OverflowFade({required this.maxHeight, required this.child});

  @override
  State<_OverflowFade> createState() => _OverflowFadeState();
}

class _OverflowFadeState extends State<_OverflowFade> {
  final GlobalKey _contentKey = GlobalKey();
  bool _overflowing = false;

  @override
  Widget build(BuildContext context) {
    // 帧末量内容自然高度,超限则挂渐隐
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box = _contentKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize || !mounted) return;
      final overflowing = box.size.height > widget.maxHeight + 0.5;
      if (overflowing != _overflowing) {
        setState(() => _overflowing = overflowing);
      }
    });
    final content = KeyedSubtree(key: _contentKey, child: widget.child);
    if (!_overflowing) return content;
    return ShaderMask(
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: const [Colors.white, Colors.white, Colors.transparent],
        // 渐隐区间锚定可视窗口底部(rect 高是内容全高)
        stops: [
          0,
          ((widget.maxHeight - 18) / rect.height).clamp(0.0, 1.0),
          (widget.maxHeight / rect.height).clamp(0.0, 1.0),
        ],
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: content,
    );
  }
}
