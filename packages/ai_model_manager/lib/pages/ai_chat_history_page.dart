import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/ai_l10n.dart';
import '../models/ai_chat_message.dart';
import '../providers/ai_provider_providers.dart';
import '../services/ai_chat_storage_service.dart';
import '../utils/dialog_utils.dart';

/// 打开会话回调类型
typedef OpenSessionCallback = void Function(
    BuildContext context, int topicId, String sessionId);

/// AI 会话历史管理页面
/// 两级结构：第一级话题，第二级会话
class AiChatHistoryPage extends ConsumerStatefulWidget {
  /// 点击会话时的回调，由外部实现导航逻辑
  final OpenSessionCallback? onOpenSession;

  const AiChatHistoryPage({super.key, this.onOpenSession});

  @override
  ConsumerState<AiChatHistoryPage> createState() => _AiChatHistoryPageState();
}

class _AiChatHistoryPageState extends ConsumerState<AiChatHistoryPage> {
  late List<TopicSessionGroup> _groups;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final storageService = ref.read(aiChatStorageServiceProvider);
    _groups = storageService.getAllTopicsWithSessions();
  }

  int get _totalSessionCount =>
      _groups.fold(0, (sum, g) => sum + g.sessions.length);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(AiL10n.current.sessionHistory),
        actions: [
          if (_groups.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: AiL10n.current.clearAllConversations,
              onPressed: () => _confirmDeleteAll(context),
            ),
        ],
      ),
      body: _groups.isEmpty
          ? _buildEmpty(theme)
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _groups.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _MaxSessionsRow(ref: ref);
                }
                final group = _groups[index - 1];
                return _TopicGroupTile(
                  group: group,
                  onOpenSession: widget.onOpenSession,
                  onDeleteSession: (sessionId) =>
                      _deleteSession(group.topicId, sessionId),
                  onDeleteTopic: () => _deleteTopic(group.topicId),
                );
              },
            ),
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            AiL10n.current.noSessionHistory,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteSession(int topicId, String sessionId) async {
    final storageService = ref.read(aiChatStorageServiceProvider);
    await storageService.deleteSession(topicId, sessionId);
    setState(() => _reload());
  }

  Future<void> _deleteTopic(int topicId) async {
    final storageService = ref.read(aiChatStorageServiceProvider);
    await storageService.deleteAllTopicSessions(topicId);
    setState(() => _reload());
  }

  void _confirmDeleteAll(BuildContext context) {
    showAppDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AiL10n.current.clearAllConversations),
        content: Text(AiL10n.current.confirmDeleteAllSessions(_totalSessionCount)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AiL10n.current.cancel),
          ),
          FilledButton(
            onPressed: () async {
              final storageService = ref.read(aiChatStorageServiceProvider);
              await storageService.deleteAllSessions();
              if (mounted) {
                setState(() => _reload());
              }
              if (ctx.mounted) {
                Navigator.pop(ctx);
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(AiL10n.current.clearAll),
          ),
        ],
      ),
    );
  }
}

/// 话题分组 Tile（可展开）
class _TopicGroupTile extends StatelessWidget {
  final TopicSessionGroup group;
  final OpenSessionCallback? onOpenSession;
  final Future<void> Function(String sessionId) onDeleteSession;
  final VoidCallback onDeleteTopic;

  const _TopicGroupTile({
    required this.group,
    this.onOpenSession,
    required this.onDeleteSession,
    required this.onDeleteTopic,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topicTitle = group.topicTitle ?? AiL10n.current.topicWithId(group.topicId);

    return ExpansionTile(
      leading: Icon(
        Icons.topic_outlined,
        size: 20,
        color: theme.colorScheme.primary,
      ),
      title: Text(
        topicTitle,
        style: theme.textTheme.titleSmall,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        AiL10n.current.sessionCount(group.sessions.length),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              Icons.delete_outline,
              size: 18,
              color: theme.colorScheme.error,
            ),
            tooltip: AiL10n.current.deleteAllTopicSessions,
            onPressed: () => _confirmDeleteTopic(context, topicTitle),
          ),
          const Icon(Icons.expand_more, size: 20),
        ],
      ),
      children: group.sessions.map((session) {
        return ListTile(
          contentPadding: const EdgeInsets.only(left: 56, right: 16),
          leading: Icon(
            Icons.chat_bubble_outline,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          title: Text(
            session.title ?? AiL10n.current.unnamedSession,
            style: theme.textTheme.bodyMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            _formatTime(session.updatedAt),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          trailing: IconButton(
            icon: Icon(
              Icons.close,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            onPressed: () => onDeleteSession(session.id),
          ),
          onTap: onOpenSession != null
              ? () => onOpenSession!(context, group.topicId, session.id)
              : null,
        );
      }).toList(),
    );
  }

  void _confirmDeleteTopic(BuildContext context, String topicTitle) {
    showAppDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AiL10n.current.deleteTopicSessions),
        content: Text(AiL10n.current.confirmDeleteTopicSessions(topicTitle)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AiL10n.current.cancel),
          ),
          FilledButton(
            onPressed: () {
              onDeleteTopic();
              Navigator.pop(ctx);
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(AiL10n.current.delete),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 1) return AiL10n.current.justNow;
    if (diff.inHours < 1) return AiL10n.current.minutesAgo(diff.inMinutes);
    if (diff.inDays < 1) return AiL10n.current.hoursAgo(diff.inHours);
    if (diff.inDays < 30) return AiL10n.current.daysAgo(diff.inDays);

    return '${time.month}/${time.day}';
  }
}

class _MaxSessionsRow extends StatelessWidget {
  final WidgetRef ref;
  const _MaxSessionsRow({required this.ref});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final storageService = ref.watch(aiChatStorageServiceProvider);
    final maxSessions = storageService.getMaxSessions();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showPicker(context, storageService, maxSessions),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.storage_outlined,
                  size: 20, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(AiL10n.current.maxSessionCount,
                        style: theme.textTheme.bodyMedium),
                    Text(
                      AiL10n.current.autoDeleteOldestSession,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$maxSessions',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPicker(
    BuildContext context,
    AiChatStorageService storageService,
    int currentValue,
  ) {
    final options = [10, 20, 30, 50, 100, 200];
    showAppBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: options
              .map((v) => ListTile(
                    title: Text('$v'),
                    trailing:
                        v == currentValue ? const Icon(Icons.check) : null,
                    onTap: () {
                      storageService.setMaxSessions(v);
                      Navigator.pop(ctx);
                      (context as Element).markNeedsBuild();
                    },
                  ))
              .toList(),
        ),
      ),
    );
  }
}
