import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../../l10n/s.dart';
import '../../../models/topic.dart';
import '../../common/smart_avatar.dart';

/// 用户在 Boost 作者 popover 中点选的操作
enum BoostAuthorPopoverAction {
  /// 点击作者行：弹标准用户卡片
  authorCard,

  /// 点击「主页」：直接进入个人主页
  profile,

  /// 点击「举报」
  flag,

  /// 点击「删除」
  delete,
}

/// 弹出锚定在 boost 气泡上的轻量作者预览 popover。
///
/// 非模态：卡片外按下即关闭，且指针事件穿透到下层页面（滑动时弹层关闭、
/// 页面照常滚动，与桌面端用户卡片浮层一致）；作为路由存在，系统返回键可关闭。
///
/// [anchorRect] 为气泡在全局坐标系中的矩形（弹幕场景是点击瞬间的快照）。
/// 返回用户点选的操作；未选择直接关闭时返回 null。
Future<BoostAuthorPopoverAction?> showBoostAuthorPopover({
  required BuildContext context,
  required Rect anchorRect,
  required Boost boost,
  bool canViewAuthor = false,
  bool canFlag = false,
  bool canDelete = false,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    _BoostAuthorPopoverRoute(
      anchorRect: anchorRect,
      boost: boost,
      canViewAuthor: canViewAuthor,
      canFlag: canFlag,
      canDelete: canDelete,
    ),
  );
}

class _BoostAuthorPopoverRoute extends PopupRoute<BoostAuthorPopoverAction> {
  final Rect anchorRect;
  final Boost boost;
  final bool canViewAuthor;
  final bool canFlag;
  final bool canDelete;

  _BoostAuthorPopoverRoute({
    required this.anchorRect,
    required this.boost,
    required this.canViewAuthor,
    required this.canFlag,
    required this.canDelete,
  });

  @override
  Color? get barrierColor => null;

  // 关闭交给自定义穿透 barrier 处理
  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 150);

  @override
  Widget buildModalBarrier() {
    // 非模态 barrier：卡外按下立即关闭 popover，同时不消费事件，
    // 让下层页面继续响应（滚动/点击一步到位）。
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (isCurrent) {
          navigator?.pop();
        }
      },
      child: const SizedBox.expand(),
    );
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return CustomSingleChildLayout(
      delegate: _BoostPopoverLayoutDelegate(
        anchorRect: anchorRect,
        safeInsets: MediaQuery.paddingOf(context),
      ),
      child: _BoostAuthorPopoverCard(
        boost: boost,
        canViewAuthor: canViewAuthor,
        canFlag: canFlag,
        canDelete: canDelete,
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.95, end: 1).animate(curved),
        child: child,
      ),
    );
  }
}

/// 将 popover 定位到锚点下方（空间不足时翻转到上方），水平以锚点居中并
/// clamp 在屏幕边距内。
class _BoostPopoverLayoutDelegate extends SingleChildLayoutDelegate {
  final Rect anchorRect;
  final EdgeInsets safeInsets;

  static const double _gap = 8;
  static const double _margin = 12;
  static const double _maxWidth = 300;

  const _BoostPopoverLayoutDelegate({
    required this.anchorRect,
    required this.safeInsets,
  });

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final maxWidth = math.min(_maxWidth, constraints.maxWidth - _margin * 2);
    final maxHeight = constraints.maxHeight - safeInsets.vertical - _margin * 2;
    return BoxConstraints(
      maxWidth: math.max(0, maxWidth),
      maxHeight: math.max(0, maxHeight),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final dx = (anchorRect.center.dx - childSize.width / 2)
        .clamp(
          _margin,
          math.max(_margin, size.width - childSize.width - _margin),
        )
        .toDouble();
    final bottomLimit = size.height - safeInsets.bottom - _margin;
    final below = anchorRect.bottom + _gap;
    if (below + childSize.height <= bottomLimit) {
      return Offset(dx, below);
    }
    final above = anchorRect.top - _gap - childSize.height;
    return Offset(dx, math.max(safeInsets.top + _margin, above));
  }

  @override
  bool shouldRelayout(covariant _BoostPopoverLayoutDelegate oldDelegate) =>
      anchorRect != oldDelegate.anchorRect ||
      safeInsets != oldDelegate.safeInsets;
}

class _BoostAuthorPopoverCard extends StatelessWidget {
  final Boost boost;
  final bool canViewAuthor;
  final bool canFlag;
  final bool canDelete;

  const _BoostAuthorPopoverCard({
    required this.boost,
    required this.canViewAuthor,
    required this.canFlag,
    required this.canDelete,
  });

  void _select(BuildContext context, BoostAuthorPopoverAction action) {
    Navigator.of(context).pop(action);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = boost.user;
    final displayName = (user.name?.trim().isNotEmpty ?? false)
        ? user.name!.trim()
        : user.username;
    final avatarUrl = user.avatarTemplate.isEmpty
        ? null
        : user.getAvatarUrl(size: 96);

    final actions = <Widget>[
      if (canViewAuthor)
        _PopoverActionButton(
          icon: Symbols.person_rounded,
          label: context.l10n.boost_authorProfile,
          onTap: () => _select(context, BoostAuthorPopoverAction.profile),
        ),
      if (canFlag)
        _PopoverActionButton(
          icon: Symbols.flag_rounded,
          label: context.l10n.common_report,
          foregroundColor: theme.colorScheme.error,
          onTap: () => _select(context, BoostAuthorPopoverAction.flag),
        ),
      if (canDelete)
        _PopoverActionButton(
          icon: Symbols.delete_rounded,
          label: context.l10n.common_delete,
          foregroundColor: theme.colorScheme.error,
          onTap: () => _select(context, BoostAuthorPopoverAction.delete),
        ),
    ];

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220),
      child: IntrinsicWidth(
        child: Material(
          color: theme.colorScheme.surfaceContainer,
          elevation: 4,
          shadowColor: Colors.black.withValues(alpha: 0.35),
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: canViewAuthor
                    ? () =>
                          _select(context, BoostAuthorPopoverAction.authorCard)
                    : null,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                  child: Row(
                    children: [
                      SmartAvatar(
                        imageUrl: avatarUrl,
                        radius: 18,
                        fallbackText: user.username,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '@${user.username}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (actions.isNotEmpty) ...[
                Divider(
                  height: 1,
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.5,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Row(
                    children: [
                      for (var i = 0; i < actions.length; i++) ...[
                        if (i > 0) const SizedBox(width: 4),
                        Expanded(child: actions[i]),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PopoverActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? foregroundColor;
  final VoidCallback onTap;

  const _PopoverActionButton({
    required this.icon,
    required this.label,
    this.foregroundColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = foregroundColor ?? theme.colorScheme.onSurfaceVariant;

    return InkWell(
      onTap: onTap,
      customBorder: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
