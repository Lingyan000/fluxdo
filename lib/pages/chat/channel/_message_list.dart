part of 'chat_channel_page.dart';

/// 以首屏的一条消息为固定原点，两侧独立增长，分页不搬动已有消息。
class _ChatMessageList extends StatefulWidget {
  const _ChatMessageList({
    super.key,
    required this.controller,
    required this.messages,
    required this.composerHeight,
    required this.itemBuilder,
  });

  final AutoScrollController controller;
  final List<ChatMessage> messages;
  final ValueListenable<double> composerHeight;
  final IndexedWidgetBuilder itemBuilder;

  @override
  State<_ChatMessageList> createState() => _ChatMessageListState();
}

class _ChatMessageListState extends State<_ChatMessageList> {
  static const _centerKey = ValueKey('chat_message_center');
  late int _anchorMessageId = widget.messages.last.id;

  @override
  void didUpdateWidget(_ChatMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(widget.messages, oldWidget.messages)) return;
    final remainingIds = widget.messages.map((message) => message.id).toSet();
    if (remainingIds.contains(_anchorMessageId)) return;

    // 原点消息被删除/对账替换时，保留在相邻旧消息上；只有整窗更换
    // 才以新窗口末条为原点，避免一次删除把正在读的历史区拉回最新页。
    final oldIndex = oldWidget.messages.indexWhere(
      (message) => message.id == _anchorMessageId,
    );
    for (var i = oldIndex - 1; i >= 0; i--) {
      if (remainingIds.contains(oldWidget.messages[i].id)) {
        _anchorMessageId = oldWidget.messages[i].id;
        return;
      }
    }
    for (var i = oldIndex + 1; i < oldWidget.messages.length; i++) {
      if (remainingIds.contains(oldWidget.messages[i].id)) {
        _anchorMessageId = oldWidget.messages[i].id;
        return;
      }
    }
    _anchorMessageId = widget.messages.last.id;
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.messages;
    final anchorIndex = messages.indexWhere((m) => m.id == _anchorMessageId);
    final indices = <Key, int>{
      for (var i = 0; i < messages.length; i++)
        ValueKey('chat_msg_${messages[i].id}'): i,
    };

    // center 之前的 sliver 向屏幕下方增长，之后的向上增长。
    // 两页之间没有占位行；输入条避让始终跟在最末一条消息下方。
    final newerMessages = SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) =>
            widget.itemBuilder(context, anchorIndex + 1 + index),
        childCount: messages.length - anchorIndex - 1,
        findChildIndexCallback: (key) {
          final index = indices[key];
          return index != null && index > anchorIndex
              ? index - anchorIndex - 1
              : null;
        },
      ),
    );
    final olderMessages = SliverList(
      key: _centerKey,
      delegate: SliverChildBuilderDelegate(
        (context, index) => widget.itemBuilder(context, anchorIndex - index),
        childCount: anchorIndex + 1,
        findChildIndexCallback: (key) {
          final index = indices[key];
          return index != null && index <= anchorIndex
              ? anchorIndex - index
              : null;
        },
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) => ValueListenableBuilder<double>(
        valueListenable: widget.composerHeight,
        builder: (context, composerHeight, _) {
          final bottomInset = composerHeight + 8;
          return CustomScrollView(
            controller: widget.controller,
            reverse: true,
            physics: const AlwaysScrollableScrollPhysics(),
            center: _centerKey,
            // 初始 pixels=0 时，最新消息恰好位于输入条上沿。
            // 原点固定后，较新页扩展 minScrollExtent，旧页扩展 maxScrollExtent。
            anchor: constraints.maxHeight > 0
                ? (bottomInset / constraints.maxHeight).clamp(0.0, 1.0)
                : 0,
            slivers: [
              SliverToBoxAdapter(child: SizedBox(height: bottomInset)),
              newerMessages,
              olderMessages,
              const SliverToBoxAdapter(child: SizedBox(height: 8)),
            ],
          );
        },
      ),
    );
  }
}
