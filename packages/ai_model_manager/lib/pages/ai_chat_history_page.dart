import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/ai_l10n.dart';
import '../models/ai_chat_message.dart';
import '../providers/ai_provider_providers.dart';
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
    return Scaffold(
      appBar: AppBar(
        title: Text(AiL10n.current.sessionHistory),
        actions: [
          if (_groups.isNotEmpty)
            IconButton(
              icon: const Icon(Symbols.delete_sweep_rounded),
              tooltip: AiL10n.current.clearAllConversations,
              onPressed: () => _confirmDeleteAll(context),
            ),
        ],
      ),
      body: _groups.isEmpty
          ? AppEmptyState(
              icon: const Icon(Symbols.chat_bubble_rounded),
              title: AiL10n.current.noSessionHistory,
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _groups.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _MaxSessionsRow(
                    currentValue: ref.read(aiChatStorageServiceProvider).getMaxSessions(),
                    onSelected: _setMaxSessions,
                  );
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

  Future<void> _setMaxSessions(int value) async {
    await ref.read(aiChatStorageServiceProvider).setMaxSessions(value);
    if (mounted) setState(_reload);
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
        content:
            Text(AiL10n.current.confirmDeleteAllSessions(_totalSessionCount)),
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
    final topicTitle =
        group.topicTitle ?? AiL10n.current.topicWithId(group.topicId);

    return ExpansionTile(
      leading: Icon(
        Symbols.topic_rounded,
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
              Symbols.delete_rounded,
              size: 18,
              color: theme.colorScheme.error,
            ),
            tooltip: AiL10n.current.deleteAllTopicSessions,
            onPressed: () => _confirmDeleteTopic(context, topicTitle),
          ),
          const Icon(Symbols.expand_more_rounded, size: 20),
        ],
      ),
      children: group.sessions.map((session) {
        return ListTile(
          contentPadding: const EdgeInsets.only(left: 56, right: 16),
          leading: Icon(
            Symbols.chat_bubble_rounded,
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
              Symbols.close_rounded,
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
  final int currentValue;
  final ValueChanged<int> onSelected;
  const _MaxSessionsRow({required this.currentValue, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: InkWell(
        customBorder: RoundedSuperellipseBorder(
            borderRadius: context.shapes.borderRadius(12)),
        onTap: () => _showPicker(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: ShapeDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            shape: RoundedSuperellipseBorder(
              borderRadius: context.shapes.borderRadius(12),
            ),
          ),
          child: Row(
            children: [
              Icon(Symbols.storage_rounded,
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
                decoration: ShapeDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: context.shapes.borderRadius(8),
                  ),
                ),
                child: Text(
                  '$currentValue',
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

  Future<void> _showPicker(BuildContext context) async {
    const options = [10, 20, 30, 50, 100, 200];
    final selected = await showAppBottomSheet<int>(
      context: context,
      builder: (ctx) => AppSheetScaffold(
        contentPadding: EdgeInsets.zero,
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: options
              .map((v) => ListTile(
                    title: Text('$v'),
                    trailing: v == currentValue
                        ? const Icon(Symbols.check_rounded)
                        : null,
                    onTap: () => Navigator.pop(ctx, v),
                  ))
              .toList(),
        ),
      ),
    );
    if (selected != null && context.mounted) onSelected(selected);
  }
}
