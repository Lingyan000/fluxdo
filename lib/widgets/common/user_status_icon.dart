import 'package:flutter/material.dart';

import '../../models/mention_user.dart';
import '../../services/discourse_cache_manager.dart';
import '../../services/emoji_handler.dart';

/// 用户自定义状态的小 emoji 图标:悬浮显示状态文字(Tooltip 对触屏长按
/// 也生效);[onTap] 传 null 则纯展示不可点(列表行场景,避免手机上点
/// 状态点不进私聊)。
class UserStatusIcon extends StatelessWidget {
  const UserStatusIcon({
    super.key,
    required this.status,
    this.size = 14,
    this.onTap,
  });

  final UserCustomStatus? status;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final emoji = status?.emoji;
    if (emoji == null || emoji.isEmpty) return const SizedBox.shrink();
    final icon = Image(
      image: emojiImageProvider(EmojiHandler().getEmojiUrl(emoji)),
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stack) => const SizedBox.shrink(),
    );
    final wrapped = Tooltip(
      message: status?.description ?? '',
      child: icon,
    );
    if (onTap == null) return wrapped;
    return InkWell(
      borderRadius: BorderRadius.circular(size),
      onTap: onTap,
      child: wrapped,
    );
  }
}
