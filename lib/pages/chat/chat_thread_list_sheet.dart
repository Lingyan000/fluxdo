import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/chat/chat_models.dart';
import '../../providers/chat_providers.dart';
import '../../utils/time_utils.dart';
import '../../utils/url_helper.dart';
import '../../widgets/common/app_bottom_sheet.dart';
import '../../widgets/common/smart_avatar.dart';
import 'chat_thread_sheet.dart';

/// 频道消息串列表（对齐 Discourse chat.channel.threads）
class ChatThreadListSheet extends ConsumerWidget {
  final int channelId;
  final String channelTitle;

  const ChatThreadListSheet({
    super.key,
    required this.channelId,
    required this.channelTitle,
  });

  static Future<void> show(
    BuildContext context, {
    required int channelId,
    required String channelTitle,
  }) {
    return AppBottomSheet.showDraggable(
      context: context,
      showCloseButton: true,
      title: '消息串',
      maxSize: 0.9,
      initialSize: 0.72,
      minSize: 0.4,
      contentPadding: EdgeInsets.zero,
      bodyBuilder: (ctx, _) => ChatThreadListSheet(
        channelId: channelId,
        channelTitle: channelTitle,
      ),
    );
  }

  String? _avatarUrl(ChatUser? user) {
    if (user?.avatarTemplate == null) return null;
    return UrlHelper.resolveUrlWithCdn(
      user!.avatarTemplate!.replaceAll('{size}', '48'),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final threadsAsync = ref.watch(chatChannelThreadsProvider(channelId));

    return threadsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('加载失败: $e'),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: () =>
                    ref.invalidate(chatChannelThreadsProvider(channelId)),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
      data: (threads) {
        if (threads.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                '还没有消息串\n回复消息即可开启讨论',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(chatChannelThreadsProvider(channelId));
            await ref.read(chatChannelThreadsProvider(channelId).future);
          },
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: threads.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
            itemBuilder: (context, index) {
              final thread = threads[index];
              final om = thread.originalMessage;
              final avatar = _avatarUrl(om?.user);
              final replyCount =
                  thread.preview?.replyCount ?? thread.replyCount;
              final lastAt = thread.preview?.lastReplyCreatedAt;
              final time = lastAt != null
                  ? TimeUtils.formatRelativeTime(lastAt)
                  : (om?.createdAt != null
                      ? TimeUtils.formatRelativeTime(om!.createdAt!)
                      : null);

              return ListTile(
                leading: SmartAvatar(
                  imageUrl: avatar,
                  radius: 20,
                  fallbackText: om?.user?.username,
                ),
                title: Text(
                  thread.displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.forum_outlined,
                        size: 14,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        replyCount > 0 ? '$replyCount 条回复' : '消息串',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      if (om?.user?.username != null) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '@${om!.user!.username}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                      if (time != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          time,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () async {
                  // 先关列表再开详情，避免多层 sheet 叠太深
                  Navigator.pop(context);
                  ChatMessage? original;
                  if (om != null) {
                    try {
                      original = ChatMessage.fromJson(om.toMessageJson());
                    } catch (_) {}
                  }
                  if (!context.mounted) return;
                  await ChatThreadSheet.show(
                    context,
                    channelId: channelId,
                    thread: thread,
                    originalMessage: original,
                  );
                },
              );
            },
          ),
        );
      },
    );
  }
}
