import 'package:flutter/material.dart';

import '../../l10n/s.dart';

/// 聊天会话的二级分类标签。
///
/// 顶层「收藏 / 频道 / 直接消息」仍保持可滑动切换，因此二级
/// TabBarView 禁用滑动，避免两层水平手势争抢。
class ChatConversationTabs extends StatefulWidget {
  const ChatConversationTabs({
    super.key,
    required this.id,
    required this.privateCount,
    required this.groupCount,
    required this.privateChild,
    required this.groupChild,
  });

  /// 同一页内区分「收藏」与「直接消息」，同时用于生成稳定 key。
  final String id;
  final int privateCount;
  final int groupCount;
  final Widget privateChild;
  final Widget groupChild;

  @override
  State<ChatConversationTabs> createState() => _ChatConversationTabsState();
}

class _ChatConversationTabsState extends State<ChatConversationTabs>
    with SingleTickerProviderStateMixin {
  late final TabController _controller;

  @override
  void initState() {
    super.initState();
    // 只有群聊时直接展示有内容的子页，避免首屏误以为列表为空。
    final initialIndex = widget.privateCount == 0 && widget.groupCount > 0
        ? 1
        : 0;
    _controller = TabController(
      length: 2,
      initialIndex: initialIndex,
      vsync: this,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _buildTab({
    required Key key,
    required IconData icon,
    required String label,
    required int count,
  }) {
    final theme = Theme.of(context);
    return Tab(
      key: key,
      height: 42,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 6),
          Container(
            constraints: const BoxConstraints(minWidth: 22),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Material(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: TabBar(
              key: ValueKey('chat-${widget.id}-subtabs'),
              controller: _controller,
              dividerHeight: 0,
              indicatorSize: TabBarIndicatorSize.tab,
              indicator: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              labelColor: theme.colorScheme.onSecondaryContainer,
              unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
              tabs: [
                _buildTab(
                  key: ValueKey('chat-${widget.id}-private-tab'),
                  icon: Icons.person_outline_rounded,
                  label: context.l10n.chat_private_chats,
                  count: widget.privateCount,
                ),
                _buildTab(
                  key: ValueKey('chat-${widget.id}-group-tab'),
                  icon: Icons.groups_outlined,
                  label: context.l10n.chat_group_chats,
                  count: widget.groupCount,
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: TabBarView(
            key: ValueKey('chat-${widget.id}-subtab-view'),
            controller: _controller,
            physics: const NeverScrollableScrollPhysics(),
            children: [widget.privateChild, widget.groupChild],
          ),
        ),
      ],
    );
  }
}
