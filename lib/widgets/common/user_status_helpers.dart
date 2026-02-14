import 'package:flutter/material.dart';
import '../../models/user.dart';
import '../../services/discourse_cache_manager.dart';
import '../../services/emoji_handler.dart';

/// 信任等级标签
String getTrustLevelLabel(int level) {
  switch (level) {
    case 0:
      return 'L0 新用户';
    case 1:
      return 'L1 基本用户';
    case 2:
      return 'L2 成员';
    case 3:
      return 'L3 活跃用户';
    case 4:
      return 'L4 领袖';
    default:
      return 'L$level';
  }
}

/// 用户状态 emoji 组件
Widget buildStatusEmoji(UserStatus status, {double size = 14, double fontSize = 12}) {
  final emoji = status.emoji;
  if (emoji == null || emoji.isEmpty) return const SizedBox.shrink();

  final isEmojiName =
      emoji.contains(RegExp(r'[a-zA-Z0-9_]')) && !emoji.contains(RegExp(r'[^\x00-\x7F]'));

  if (isEmojiName) {
    final cleanName = emoji.replaceAll(':', '');
    final emojiUrl = EmojiHandler().getEmojiUrl(cleanName);

    return Image(
      image: discourseImageProvider(emojiUrl),
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }

  return Text(
    emoji,
    style: TextStyle(fontSize: fontSize, height: 1.2),
  );
}
