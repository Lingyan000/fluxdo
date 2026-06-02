import 'package:flutter/material.dart';
import '../../../../utils/time_utils.dart';
import '../../../common/smart_avatar.dart';
import '../../../../l10n/s.dart';

/// 构建 Chat Transcript 聊天记录引用卡片
///
/// Discourse Chat 插件生成的聊天引用结构：
/// - div.chat-transcript 主容器
/// - div.chat-transcript-user 用户信息
/// - div.chat-transcript-messages 消息内容
/// - div.chat-transcript-reactions 反应（可选）
Widget buildChatTranscript({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
  required Widget Function(String html, TextStyle? textStyle) htmlBuilder,
}) {
  // 解析元数据
  final username = element.attributes['data-username'] ?? '';
  final datetime = element.attributes['data-datetime'] ?? '';
  final channelName = element.attributes['data-channel-name'];
  final isChained = element.classes.contains('chat-transcript-chained');

  // 解析用户头像 - 与 quote_card_builder 保持一致
  final imgElement = element.querySelector('img.avatar');
  final avatarUrl = imgElement?.attributes['src'] ?? '';

  // 解析消息内容
  final messagesElement = element.querySelector('.chat-transcript-messages');
  final messagesHtml = messagesElement?.innerHtml ?? '';

  // 解析反应
  final reactionsElement = element.querySelector('.chat-transcript-reactions');
  final List<_ChatReaction> reactions = [];
  if (reactionsElement != null) {
    final reactionElements =
        reactionsElement.querySelectorAll('.chat-transcript-reaction');
    for (final reaction in reactionElements) {
      final emojiImg = reaction.querySelector('img.emoji');
      final emojiUrl = emojiImg?.attributes['src'];
      // 反应文本包含 emoji 和数量
      final text = reaction.text.trim();
      final countMatch = RegExp(r'(\d+)$').firstMatch(text);
      final count =
          countMatch != null ? int.tryParse(countMatch.group(1)!) ?? 1 : 1;
      if (emojiUrl != null) {
        reactions.add(_ChatReaction(emojiUrl: emojiUrl, count: count));
      }
    }
  }

  // 格式化时间
  final formattedTime = TimeUtils.formatCompactTime(
    TimeUtils.parseUtcTime(datetime),
  );

  // 检查是否有 details（可折叠线程）
  final detailsElement = element.querySelector(':scope > details');
  final bool isThread = detailsElement != null;

  return Container(
    margin: isChained ? EdgeInsets.zero : const EdgeInsets.symmetric(vertical: 8),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      border: isChained
          ? null
          : Border(
              left: BorderSide(
                color: theme.colorScheme.outline,
                width: 4,
              ),
            ),
      borderRadius: isChained
          ? null
          : const BorderRadius.only(
              topRight: Radius.circular(4),
              bottomRight: Radius.circular(4),
            ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 频道名称（如果有且不是链式引用）
        if (channelName != null && !isChained) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Icon(
                  Icons.tag,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  channelName,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],

        // 用户信息行：头像 + 用户名 + 时间
        Padding(
          padding: EdgeInsets.fromLTRB(
            12,
            isChained ? 8 : (channelName != null ? 4 : 8),
            12,
            0,
          ),
          child: Row(
            children: [
              // 头像 - 与 quote_card_builder 保持一致
              if (avatarUrl.isNotEmpty) ...[
                SmartAvatar(
                  imageUrl: avatarUrl,
                  radius: 12,
                  fallbackText: username,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
                const SizedBox(width: 8),
              ],
              // 用户名
              Text(
                '$username:',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
              // 时间
              if (formattedTime.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  formattedTime,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),

        // 消息内容
        if (messagesHtml.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: htmlBuilder(
              messagesHtml,
              theme.textTheme.bodyMedium?.copyWith(
                height: 1.5,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),

        // 反应
        if (reactions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children:
                  reactions.map((r) => _buildReactionChip(theme, r)).toList(),
            ),
          ),

        // 线程标识
        if (isThread) ...[
          _buildThreadHeader(theme, detailsElement),
        ],
      ],
    ),
  );
}

/// 构建反应小标签
Widget _buildReactionChip(ThemeData theme, _ChatReaction reaction) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(
        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        width: 1,
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.network(
          reaction.emojiUrl,
          width: 16,
          height: 16,
          errorBuilder: (_, _, _) => const SizedBox(width: 16, height: 16),
        ),
        if (reaction.count > 1) ...[
          const SizedBox(width: 3),
          Text(
            reaction.count.toString(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    ),
  );
}

/// 构建线程头部
Widget _buildThreadHeader(ThemeData theme, dynamic detailsElement) {
  final summaryElement = detailsElement?.querySelector('summary');
  final threadHeaderElement =
      summaryElement?.querySelector('.chat-transcript-thread-header');
  final threadTitle = threadHeaderElement
          ?.querySelector('.chat-transcript-thread-header__title')
          ?.text ??
      S.current.chat_thread;

  return Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.forum_outlined,
          size: 14,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Text(
          threadTitle,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}

/// 检查元素是否是 chat-transcript
bool isChatTranscript(dynamic element) {
  if (element.localName != 'div') return false;
  return element.classes.contains('chat-transcript');
}

/// 反应数据模型
class _ChatReaction {
  final String emojiUrl;
  final int count;

  _ChatReaction({required this.emojiUrl, required this.count});
}
