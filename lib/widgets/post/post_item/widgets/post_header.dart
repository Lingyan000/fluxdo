import 'package:flutter/material.dart';
import '../../../../constants.dart';
import '../../../../models/topic.dart';
import '../../../../pages/user_profile_page.dart';
import '../../../../services/discourse_cache_manager.dart';
import '../../../../services/emoji_handler.dart';
import '../../../common/flair_badge.dart';
import '../../../common/smart_avatar.dart';
import '../../../common/avatar_glow.dart';
import '../../whisper_indicator.dart';
import 'post_granted_badge.dart';

/// 帖子头像组件（独立widget避免不必要的重建）
class PostAvatar extends StatefulWidget {
  final Post post;
  final ThemeData theme;

  const PostAvatar({
    super.key,
    required this.post,
    required this.theme,
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
      flairSize: 17,
      flairRight: -4,
      flairBottom: -2,
      flairUrl: widget.post.flairUrl,
      flairName: widget.post.flairName,
      flairBgColor: widget.post.flairBgColor,
      flairColor: widget.post.flairColor,
      avatar: SmartAvatar(
        imageUrl: avatarUrl.isNotEmpty ? avatarUrl : null,
        radius: 20,
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
  final ValueNotifier<bool> isLoadingReplyHistoryNotifier;
  final VoidCallback onToggleReplyHistory;
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
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: theme.colorScheme.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  // 用户状态 emoji
                  if (post.userStatus?.emoji != null) ...[
                    const SizedBox(width: 4),
                    Tooltip(
                      message: post.userStatus!.description ?? '',
                      child: Image(
                        image: discourseImageProvider(EmojiHandler().getEmojiUrl(post.userStatus!.emoji!)),
                        width: 16,
                        height: 16,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ],
                  if (isTopicOwner && post.postNumber > 1) ...[
                    const SizedBox(width: 4),
                    buildCompactBadge(context, '主', theme.colorScheme.primaryContainer, theme.colorScheme.onPrimaryContainer),
                  ],
                  if (isOwnPost) ...[
                    const SizedBox(width: 4),
                    buildCompactBadge(context, '我', theme.colorScheme.tertiaryContainer, theme.colorScheme.onTertiaryContainer),
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
        if (post.replyToUser != null) ...[
          ValueListenableBuilder<bool>(
            valueListenable: isLoadingReplyHistoryNotifier,
            builder: (context, isLoading, _) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: isLoading ? null : onToggleReplyHistory,
                child: Container(
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
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        Icon(
                          Icons.reply,
                          size: 14,
                          color: theme.colorScheme.primary,
                        ),
                      const SizedBox(width: 6),
                      CircleAvatar(
                        radius: 10,
                        backgroundColor: theme.colorScheme.primaryContainer,
                        backgroundImage: post.replyToUser!.avatarTemplate.isNotEmpty
                            ? discourseImageProvider(post.replyToUser!.getAvatarUrl())
                            : null,
                        child: post.replyToUser!.avatarTemplate.isEmpty
                            ? Text(
                                post.replyToUser!.username[0].toUpperCase(),
                                style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold),
                              )
                            : null,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 12),
        ],
        timeAndFloorWidget,
      ],
    );
  }
}
