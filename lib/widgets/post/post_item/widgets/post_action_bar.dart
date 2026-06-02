import 'dart:async';

import 'package:flutter/material.dart';
import '../../../../l10n/s.dart';
import '../../../../models/topic.dart';
import '../../../../services/discourse_cache_manager.dart';
import '../../../../services/emoji_handler.dart';
import '../../../../utils/platform_utils.dart';

/// 获取 emoji 图片 URL（未加载完成时返回空字符串，由 errorBuilder 处理）
String _getEmojiUrl(String emojiName) {
  return EmojiHandler().getEmojiUrl(emojiName);
}

/// 帖子底部操作栏
class PostActionBar extends StatefulWidget {
  final Post post;
  final bool isGuest;
  final bool isOwnPost;
  final bool isLiking;
  final List<PostReaction> reactions;
  final PostReaction? currentUserReaction;
  final GlobalKey likeButtonKey;
  final List<Post> replies;
  final ValueNotifier<bool> isLoadingRepliesNotifier;
  final ValueNotifier<bool> showRepliesNotifier;
  final VoidCallback onToggleLike;
  final VoidCallback onShowReactionPicker;
  final void Function(String? reactionId) onShowReactionUsers;
  final VoidCallback? onReply;
  final VoidCallback onShowMoreMenu;
  final VoidCallback onToggleReplies;
  final bool hideRepliesButton;
  final VoidCallback? onAddBoost;
  final bool canBoost;
  final bool hasBoosts;

  const PostActionBar({
    super.key,
    required this.post,
    required this.isGuest,
    required this.isOwnPost,
    required this.isLiking,
    required this.reactions,
    required this.currentUserReaction,
    required this.likeButtonKey,
    required this.replies,
    required this.isLoadingRepliesNotifier,
    required this.showRepliesNotifier,
    required this.onToggleLike,
    required this.onShowReactionPicker,
    required this.onShowReactionUsers,
    this.onReply,
    required this.onShowMoreMenu,
    required this.onToggleReplies,
    this.hideRepliesButton = false,
    this.onAddBoost,
    this.canBoost = false,
    this.hasBoosts = false,
  });

  @override
  State<PostActionBar> createState() => _PostActionBarState();
}

class _PostActionBarState extends State<PostActionBar> {
  Timer? _hoverTimer;

  /// 防止 hover 重复触发选择器（选择器显示期间 + 关闭后短暂冷却）
  bool _pickerCooldown = false;

  @override
  void dispose() {
    _hoverTimer?.cancel();
    super.dispose();
  }

  void _onHoverEnter() {
    if (widget.isOwnPost || _pickerCooldown) return;
    _hoverTimer?.cancel();
    _hoverTimer = Timer(const Duration(milliseconds: 300), () {
      _pickerCooldown = true;
      widget.onShowReactionPicker();
    });
  }

  void _onHoverExit() {
    _hoverTimer?.cancel();
    // 鼠标离开后重置冷却，允许下次 hover 重新触发
    _pickerCooldown = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        // 回复数按钮
        if (widget.post.replyCount > 0 && !widget.hideRepliesButton)
          ValueListenableBuilder<bool>(
            valueListenable: widget.isLoadingRepliesNotifier,
            builder: (context, isLoadingReplies, _) {
              return ValueListenableBuilder<bool>(
                valueListenable: widget.showRepliesNotifier,
                builder: (context, showReplies, _) {
                  return GestureDetector(
                    onTap: isLoadingReplies ? null : widget.onToggleReplies,
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: showReplies
                            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: showReplies
                              ? theme.colorScheme.primary.withValues(alpha: 0.2)
                              : Colors.transparent,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isLoadingReplies && widget.replies.isEmpty)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else ...[
                            Icon(
                              Icons.chat_bubble_outline_rounded,
                              size: 15,
                              color: showReplies
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${widget.post.replyCount}',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: showReplies
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              showReplies ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                              size: 18,
                              color: showReplies
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),

        const Spacer(),
        if (!widget.isGuest) ...[
          // 回应和赞
          // 左右两个 GestureDetector 是兄弟关系（非嵌套），避免手势竞争
          if (!widget.isOwnPost || widget.reactions.isNotEmpty)
            _buildLikeReactionArea(theme),

          if (!widget.isOwnPost && widget.canBoost && !widget.hasBoosts) ...[
            const SizedBox(width: 8),
            Tooltip(
              message: 'Boost',
              child: GestureDetector(
                onTap: widget.onAddBoost,
                child: Container(
                  height: 36,
                  width: 36,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.rocket_launch_outlined,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],

          const SizedBox(width: 8),

          // 回复按钮
          Tooltip(
            message: context.l10n.common_reply,
            child: GestureDetector(
              onTap: widget.onReply,
              child: Container(
                height: 36,
                width: 36,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.reply,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],

        const SizedBox(width: 8),

        // 更多按钮
        GestureDetector(
          onTap: widget.onShowMoreMenu,
          child: Container(
            height: 36,
            width: 36,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.more_horiz,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  /// 构建点赞/回应区域，桌面端支持 hover 触发表情选择器
  Widget _buildLikeReactionArea(ThemeData theme) {
    Widget area = Container(
      key: widget.likeButtonKey,
      height: 36,
      decoration: BoxDecoration(
        color: widget.currentUserReaction != null
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: widget.currentUserReaction != null
              ? theme.colorScheme.primary.withValues(alpha: 0.2)
              : Colors.transparent,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 左侧区域：回应表情 + 数量 → 查看回应人
          if (widget.reactions.isNotEmpty)
            GestureDetector(
              onTap: () => widget.onShowReactionUsers(null),
              onLongPress: widget.isOwnPost ? null : widget.onShowReactionPicker,
              behavior: HitTestBehavior.opaque,
              child: Container(
                height: 36,
                padding: const EdgeInsets.only(left: 12),
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!(widget.reactions.length == 1 && widget.reactions.first.id == 'heart'))
                      ...widget.reactions.take(3).map((reaction) => GestureDetector(
                        onTap: () => widget.onShowReactionUsers(reaction.id),
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          height: 36,
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          alignment: Alignment.center,
                          child: Image(
                            image: emojiImageProvider(_getEmojiUrl(reaction.id)),
                            width: 16,
                            height: 16,
                            errorBuilder: (_, _, _) => const SizedBox(width: 16, height: 16),
                          ),
                        ),
                      )),
                    if (!(widget.reactions.length == 1 && widget.reactions.first.id == 'heart'))
                      const SizedBox(width: 4),
                    Text(
                      '${widget.reactions.fold(0, (sum, r) => sum + r.count)}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: widget.currentUserReaction != null
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                ),
              ),
            ),

          // 右侧区域：点赞/回应图标 → 点赞/取消
          GestureDetector(
            onTap: widget.isOwnPost ? null : (widget.isLiking ? null : widget.onToggleLike),
            onLongPress: widget.isOwnPost ? null : widget.onShowReactionPicker,
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: 36,
              padding: EdgeInsets.only(
                left: widget.reactions.isNotEmpty ? 0 : 12,
                right: 12,
              ),
              alignment: Alignment.center,
              child: widget.currentUserReaction != null
                  ? Image(
                      image: emojiImageProvider(_getEmojiUrl(widget.currentUserReaction!.id)),
                      width: 20,
                      height: 20,
                      errorBuilder: (_, _, _) => const Icon(Icons.favorite, size: 20),
                    )
                  : Icon(
                      Icons.favorite_border,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
            ),
          ),
        ],
      ),
    );

    // 桌面端：hover 延迟触发表情选择器
    if (PlatformUtils.isDesktop && !widget.isOwnPost) {
      area = MouseRegion(
        onEnter: (_) => _onHoverEnter(),
        onExit: (_) => _onHoverExit(),
        child: area,
      );
    }

    return area;
  }
}
