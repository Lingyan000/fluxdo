import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../../../l10n/s.dart';
import '../../../../constants.dart';
import '../../../../models/topic.dart';
import '../../../../services/discourse_cache_manager.dart';
import '../../../../services/emoji_handler.dart';
import '../../../../utils/url_helper.dart';
import '../../../common/flair_badge.dart';
import '../../../common/smart_avatar.dart';
import '../../../common/avatar_glow.dart';
import '../../../common/radial_long_press_menu.dart';
import '../../../user/avatar_action_menu.dart';
import '../../../user/user_card.dart';
import '../../whisper_indicator.dart';
import '../../post_boost/boost_danmaku.dart';
import 'post_granted_badge.dart';

/// 获取 emoji 图片 URL（未加载完成时返回空字符串，由 errorBuilder 处理）
String _getEmojiUrl(String emojiName) {
  return EmojiHandler().getEmojiUrl(emojiName);
}

/// 生日 / 社区纪念日图标(真实站点用 poster-icon 包一个 twemoji 表情,
/// 对齐同款视觉：14x14 + 悬浮提示)。
class _PostAnniversaryIcon extends StatelessWidget {
  final String emojiName;
  final String tooltip;

  const _PostAnniversaryIcon({required this.emojiName, required this.tooltip});

  @override
  Widget build(BuildContext context) {
    final url = _getEmojiUrl(emojiName);
    if (url.isEmpty) return const SizedBox.shrink();
    return Tooltip(
      message: tooltip,
      child: Image(
        image: discourseImageProvider(url),
        width: 14,
        height: 14,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );
  }
}

/// 帖子头像组件（独立widget避免不必要的重建）
class PostAvatar extends StatefulWidget {
  final Post post;
  final ThemeData theme;
  final double radius;
  final int? topicId;

  /// 长按菜单「@用户」回调（null = 链路不可回复，菜单不显示该项）
  final void Function(String username)? onMentionUser;

  const PostAvatar({
    super.key,
    required this.post,
    required this.theme,
    this.radius = 20,
    this.topicId,
    this.onMentionUser,
  });

  @override
  State<PostAvatar> createState() => _PostAvatarState();
}

class _PostAvatarState extends State<PostAvatar> {
  final LayerLink _link = LayerLink();

  void _openUserCard() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final topLeft = box.localToGlobal(Offset.zero);
    final anchorRect = topLeft & box.size;
    showUserCard(
      context: context,
      anchorRect: anchorRect,
      layerLink: _link,
      username: widget.post.username,
      topicId: widget.topicId,
      postNumber: widget.post.postNumber,
      avatarFallbackUrl: widget.post.getAvatarUrl(size: 144),
      nameFallback: widget.post.name,
      flairUrl: widget.post.flairUrl,
      flairName: widget.post.flairName,
      flairBgColor: widget.post.flairBgColor,
      flairColor: widget.post.flairColor,
    );
  }

  @override
  Widget build(BuildContext context) {
    final avatarUrl = widget.post.getAvatarUrl();
    final glowColor = AppConstants.siteCustomization.matchAvatarGlow(
      widget.post,
    );

    Widget avatar = AvatarWithFlair(
      flairSize: widget.radius * 0.85,
      flairRight: -4,
      flairBottom: -2,
      flairUrl: widget.post.flairUrl,
      flairName: widget.post.flairName,
      flairBgColor: widget.post.flairBgColor,
      flairColor: widget.post.flairColor,
      avatar: SmartAvatar(
        imageUrl: avatarUrl.isNotEmpty ? avatarUrl : null,
        radius: widget.radius,
        fallbackText: widget.post.username,
        border: Border.all(
          color: widget.theme.colorScheme.outlineVariant,
          width: 1,
        ),
      ),
    );

    if (glowColor != null) {
      avatar = AvatarGlow(glowColor: glowColor, child: avatar);
    }

    return RadialLongPressMenu(
      onTap: _openUserCard,
      itemsBuilder: () => buildAvatarMenuItems(
        context,
        username: widget.post.username,
        topicId: widget.topicId,
        postNumber: widget.post.postNumber,
        onMentionUser: widget.onMentionUser,
      ),
      // 按压替代显示：头像本身 + primary 圆环，语义是"按住的这个人浮在模糊层上"
      pressAreaIndicatorBuilder: (ctx, rect, opacity) => Opacity(
        opacity: opacity,
        child: SmartAvatar(
          imageUrl: avatarUrl.isNotEmpty ? avatarUrl : null,
          radius: rect.shortestSide / 2,
          fallbackText: widget.post.username,
          border: Border.all(color: Theme.of(ctx).colorScheme.primary, width: 2),
        ),
      ),
      child: CompositedTransformTarget(link: _link, child: avatar),
    );
  }
}

/// 帖子头部组件（头像、用户名、时间、徽章）
class PostHeader extends StatelessWidget {
  final Post post;
  final int topicId;
  final bool isTopicOwner;
  final bool isOwnPost;
  final bool isWhisper;
  final Widget cachedAvatarWidget;
  final ValueNotifier<bool>? isLoadingReplyHistoryNotifier;
  final VoidCallback? onToggleReplyHistory;

  /// 自定义回复指示点击回调（用于弹框内滚动跳转，不加载回复历史）
  final VoidCallback? onReplyIndicatorTap;

  /// 隐藏回复指示器
  final bool hideReplyIndicator;
  final Widget Function(
    BuildContext context,
    String text,
    Color backgroundColor,
    Color textColor,
  )
  buildCompactBadge;
  final Widget timeAndFloorWidget;

  /// 弹幕开关：null = 不展示；true/false = 当前是否正在显示弹幕
  final bool? danmakuActive;
  final VoidCallback? onToggleDanmaku;

  const PostHeader({
    super.key,
    required this.post,
    required this.topicId,
    required this.isTopicOwner,
    required this.isOwnPost,
    required this.isWhisper,
    required this.cachedAvatarWidget,
    required this.isLoadingReplyHistoryNotifier,
    required this.onToggleReplyHistory,
    this.onReplyIndicatorTap,
    this.hideReplyIndicator = false,
    required this.buildCompactBadge,
    required this.timeAndFloorWidget,
    this.danmakuActive,
    this.onToggleDanmaku,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        cachedAvatarWidget,
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      (post.name != null && post.name!.isNotEmpty)
                          ? post.name!
                          : post.username,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: (post.moderator || post.admin)
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  // 版主盾牌图标（版主或分类群组版主）
                  if (post.moderator || post.groupModerator) ...[
                    const SizedBox(width: 4),
                    FaIcon(
                      FontAwesomeIcons.shieldHalved,
                      size: 12,
                      color: theme.colorScheme.primary,
                    ),
                  ],
                  // 用户状态 emoji
                  if (post.userStatus?.emoji != null) ...[
                    const SizedBox(width: 4),
                    Tooltip(
                      message: post.userStatus!.description ?? '',
                      child: Image(
                        image: emojiImageProvider(
                          _getEmojiUrl(post.userStatus!.emoji!),
                        ),
                        width: 16,
                        height: 16,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ],
                  if (isTopicOwner && post.postNumber > 1) ...[
                    const SizedBox(width: 4),
                    buildCompactBadge(
                      context,
                      context.l10n.post_opBadge,
                      theme.colorScheme.primaryContainer,
                      theme.colorScheme.onPrimaryContainer,
                    ),
                  ],
                  if (isOwnPost) ...[
                    const SizedBox(width: 4),
                    buildCompactBadge(
                      context,
                      context.l10n.post_meBadge,
                      theme.colorScheme.tertiaryContainer,
                      theme.colorScheme.onTertiaryContainer,
                    ),
                  ],
                  if (isWhisper) ...[
                    const SizedBox(width: 8),
                    const WhisperIndicator(),
                  ],
                ],
              ),
              // @username + 用户头衔 + 帖子头部徽章
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    Text(
                      '@${post.username}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                    if (post.userTitle != null) ...[
                      const SizedBox(width: 6),
                      Flexible(
                        child: () {
                          final titleBuilder = AppConstants.siteCustomization
                              .matchTitleStyle(post);
                          return titleBuilder != null
                              ? titleBuilder(post.userTitle!, 11)
                              : Text(
                                  post.userTitle!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.primary.withValues(
                                      alpha: 0.8,
                                    ),
                                    fontSize: 11,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                );
                        }(),
                      ),
                    ],
                    // 生日 / 社区纪念日(真实站点用 poster-icon + twemoji
                    // birthday/cake 表情,顺序在徽章之前)
                    if (post.isTodayBirthday) ...[
                      const SizedBox(width: 4),
                      _PostAnniversaryIcon(
                        emojiName: 'birthday',
                        tooltip: context.l10n.post_todayIsBirthday,
                      ),
                    ],
                    if (post.isTodayCakeday) ...[
                      const SizedBox(width: 4),
                      _PostAnniversaryIcon(
                        emojiName: 'cake',
                        tooltip: context.l10n.post_todayIsCakeday,
                      ),
                    ],
                    // 帖子头部徽章
                    if (post.badgesGranted != null &&
                        post.badgesGranted!.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      ...post.badgesGranted!.map(
                        (badge) => PostGrantedBadgeIcon(badge: badge),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        // 右侧：回复指示 + 时间 + 楼层号
        _buildRightSection(context, theme),
      ],
    );
  }

  Widget _buildRightSection(BuildContext context, ThemeData theme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (post.replyToUser != null && !hideReplyIndicator) ...[
          if (onToggleReplyHistory != null)
            ValueListenableBuilder<bool>(
              valueListenable: isLoadingReplyHistoryNotifier!,
              builder: (context, isLoading, _) {
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: isLoading ? null : onToggleReplyHistory,
                  child: _buildReplyIndicator(theme, isLoading: isLoading),
                );
              },
            )
          else if (onReplyIndicatorTap != null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onReplyIndicatorTap,
              child: _buildReplyIndicator(theme),
            )
          else
            _buildReplyIndicator(theme, showUsername: true),
          const SizedBox(width: 12),
        ],
        // 弹幕开关：小图标按钮，紧挨时间/楼层
        if (danmakuActive != null && onToggleDanmaku != null) ...[
          Tooltip(
            message: danmakuActive!
                ? context.l10n.boost_danmakuDismiss
                : context.l10n.boost_danmakuShow,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggleDanmaku,
              child: Padding(
                // 扩大点击区域到 ~32dp
                padding: const EdgeInsets.all(6),
                child: DanmakuIcon(
                  color: danmakuActive!
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.7,
                        ),
                  off: !danmakuActive!,
                  size: 20,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
        timeAndFloorWidget,
      ],
    );
  }

  Widget _buildReplyIndicator(
    ThemeData theme, {
    bool isLoading = false,
    bool showUsername = false,
  }) {
    final replyToUser = post.replyToUser!;
    final displayName =
        (replyToUser.name != null && replyToUser.name!.isNotEmpty)
        ? replyToUser.name!
        : replyToUser.username;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.1),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isLoading)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(Symbols.reply_rounded, size: 14, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          SmartAvatar(
            imageUrl: replyToUser.avatarTemplate.isNotEmpty
                ? UrlHelper.resolveUrlWithCdn(
                    replyToUser.avatarTemplate.replaceAll('{size}', '40'),
                  )
                : null,
            radius: 10,
            backgroundColor: theme.colorScheme.primaryContainer,
            fallbackText: replyToUser.username,
          ),
          if (showUsername) ...[
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 80),
              child: Text(
                displayName,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontSize: 11,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
