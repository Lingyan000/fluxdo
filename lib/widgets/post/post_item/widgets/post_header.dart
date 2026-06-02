import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../../../l10n/s.dart';
import '../../../../constants.dart';
import '../../../../models/topic.dart';
import '../../../../pages/user_profile_page.dart';
import '../../../../services/discourse_cache_manager.dart';
import '../../../../services/emoji_handler.dart';
import '../../../../utils/url_helper.dart';
import '../../../common/flair_badge.dart';
import '../../../common/smart_avatar.dart';
import '../../../common/avatar_glow.dart';
import '../../whisper_indicator.dart';
import 'post_granted_badge.dart';

/// 获取 emoji 图片 URL（未加载完成时返回空字符串，由 errorBuilder 处理）
String _getEmojiUrl(String emojiName) {
  return EmojiHandler().getEmojiUrl(emojiName);
}

/// 帖子头像组件（独立widget避免不必要的重建）
class PostAvatar extends StatefulWidget {
  final Post post;
  final ThemeData theme;
  final double radius;

  const PostAvatar({
    super.key,
    required this.post,
    required this.theme,
    this.radius = 20,
  });

  @override
  State<PostAvatar> createState() => _PostAvatarState();
}

class _PostAvatarState extends State<PostAvatar> {
  @override
  Widget build(BuildContext context) {
    final avatarUrl = widget.post.getAvatarUrl();
    final glowColor = AppConstants.siteCustomization.matchAvatarGlow(widget.post);

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

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => UserProfilePage(username: widget.post.username)),
      ),
      child: avatar,
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
  final Widget Function(BuildContext context, String text, Color backgroundColor, Color textColor) buildCompactBadge;
  final Widget timeAndFloorWidget;

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
                      (post.name != null && post.name!.isNotEmpty) ? post.name! : post.username,
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
                        image: emojiImageProvider(_getEmojiUrl(post.userStatus!.emoji!)),
                        width: 16,
                        height: 16,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ],
                  if (isTopicOwner && post.postNumber > 1) ...[
                    const SizedBox(width: 4),
                    buildCompactBadge(context, context.l10n.post_opBadge, theme.colorScheme.primaryContainer, theme.colorScheme.onPrimaryContainer),
                  ],
                  if (isOwnPost) ...[
                    const SizedBox(width: 4),
                    buildCompactBadge(context, context.l10n.post_meBadge, theme.colorScheme.tertiaryContainer, theme.colorScheme.onTertiaryContainer),
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
                          final titleBuilder = AppConstants.siteCustomization.matchTitleStyle(post);
                          return titleBuilder != null
                              ? titleBuilder(post.userTitle!, 11)
                              : Text(
                                  post.userTitle!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.primary.withValues(alpha: 0.8),
                                    fontSize: 11,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                );
                        }(),
                      ),
                    ],
                    // 帖子头部徽章
                    if (post.badgesGranted != null && post.badgesGranted!.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      ...post.badgesGranted!.map((badge) => PostGrantedBadgeIcon(badge: badge)),
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
        timeAndFloorWidget,
      ],
    );
  }

  Widget _buildReplyIndicator(ThemeData theme, {bool isLoading = false, bool showUsername = false}) {
    final replyToUser = post.replyToUser!;
    final displayName = (replyToUser.name != null && replyToUser.name!.isNotEmpty)
        ? replyToUser.name!
        : replyToUser.username;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isLoading)
            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Icon(Icons.reply, size: 14, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          CircleAvatar(
            radius: 10,
            backgroundColor: theme.colorScheme.primaryContainer,
            backgroundImage: replyToUser.avatarTemplate.isNotEmpty
                ? discourseImageProvider(
                    UrlHelper.resolveUrlWithCdn(replyToUser.avatarTemplate.replaceAll('{size}', '40')),
                  )
                : null,
            child: replyToUser.avatarTemplate.isEmpty
                ? Text(replyToUser.username[0].toUpperCase(), style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w600))
                : null,
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
