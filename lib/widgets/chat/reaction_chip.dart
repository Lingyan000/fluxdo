import 'package:flutter/material.dart';
import '../../constants.dart';
import '../../models/chat/chat_message.dart';
import '../../services/emoji_handler.dart';
import '../../services/discourse_cache_manager.dart';
import '../common/smart_avatar.dart';
import '../user/user_card.dart' show showUserCard;
import 'overlay_anchor.dart';

/// 聊天消息的表情回应气泡:桌面悬浮 / 移动长按弹出"谁回应了"列表。
/// 对齐官方 `chat-message-reaction.gjs`:hover(桌面)/hold(移动)触发。
class ReactionChip extends StatefulWidget {
  const ReactionChip({
    super.key,
    required this.reaction,
    required this.onTap,
  });

  final ChatReaction reaction;
  final VoidCallback onTap;

  @override
  State<ReactionChip> createState() => _ReactionChipState();
}

class _ReactionChipState extends State<ReactionChip> {
  final GlobalKey<HoverPopupAnchorState> _anchorKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reaction = widget.reaction;

    return HoverPopupAnchor(
      key: _anchorKey,
      alignRight: false,
      gap: 8,
      canShow: () => reaction.users.isNotEmpty,
      popupBuilder: (context, closePopup) => SizedBox(
        width: 220,
        child: _ReactionUsersPopup(reaction: reaction),
      ),
      child: GestureDetector(
        onLongPress: () {
          _anchorKey.currentState?.open();
          Future.delayed(const Duration(seconds: 3), () {
            _anchorKey.currentState?.closeNow();
          });
        },
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: reaction.reacted
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
              border: reaction.reacted
                  ? Border.all(color: scheme.primary, width: 1)
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ReactionEmoji(name: reaction.emoji, size: 14),
                const SizedBox(width: 3),
                Text('${reaction.count}', style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


class _ReactionUsersPopup extends StatelessWidget {
  const _ReactionUsersPopup({required this.reaction});

  final ChatReaction reaction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final users = reaction.users;
    final extra = reaction.count - users.length;

    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(10),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final user in users)
              Builder(
                builder: (rowCtx) => InkWell(
                  onTap: () {
                    final box = rowCtx.findRenderObject() as RenderBox?;
                    if (box == null || !box.hasSize) return;
                    showUserCard(
                      context: rowCtx,
                      anchorRect: box.localToGlobal(Offset.zero) & box.size,
                      username: user.username,
                      nameFallback: user.name,
                      avatarFallbackUrl:
                          user.getAvatarUrl(AppConstants.baseUrl, size: 144),
                    );
                  },
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    child: Row(
                      children: [
                        SmartAvatar(
                          imageUrl:
                              user.getAvatarUrl(AppConstants.baseUrl, size: 40),
                          radius: 11,
                          fallbackText: user.username,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            user.name?.isNotEmpty == true
                                ? user.name!
                                : user.username,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (extra > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                child: Text(
                  '还有 $extra 人',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 表情图片,供聊天消息 reaction 相关组件共用
class ReactionEmoji extends StatelessWidget {
  const ReactionEmoji({super.key, required this.name, this.size = 16});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Image(
      image: emojiImageProvider(EmojiHandler().getEmojiUrl(name)),
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stack) => Text(
        ':$name:',
        style: TextStyle(fontSize: size * 0.6),
      ),
    );
  }
}
