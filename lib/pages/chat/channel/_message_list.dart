part of 'chat_channel_page.dart';

/// 反向消息流用稳定标识保留历史阅读位置，最新一侧仍位于输入条上方。
class _ChatMessageList extends StatelessWidget {
  const _ChatMessageList({
    super.key,
    required this.controller,
    required this.listController,
    required this.messages,
    required this.composerHeight,
    required this.itemBuilder,
    required this.followLatest,
  });

  final ScrollController controller;
  final ListController listController;
  final List<ChatMessage> messages;
  final ValueListenable<double> composerHeight;
  final IndexedWidgetBuilder itemBuilder;
  final bool followLatest;

  @override
  Widget build(BuildContext context) {
    return StickToTarget(
      scrollController: controller,
      listController: listController,
      target: followLatest ? const StickTarget.bottom() : null,
      threshold: 1,
      child: ValueListenableBuilder<double>(
        valueListenable: composerHeight,
        builder: (context, height, _) => PositionedStreamList(
          scrollController: controller,
          listController: listController,
          positionKey: key!,
          initialIndex: null,
          reverse: true,
          cacheExtent: 300,
          physics: const AlwaysScrollableScrollPhysics(),
          itemKeys: [
            'bottom-inset',
            for (final message in messages.reversed) 'message-${message.id}',
            'top-inset',
          ],
          itemBuilder: (context, index) {
            if (index == 0) return SizedBox(height: height + 8);
            if (index == messages.length + 1) return const SizedBox(height: 8);
            return itemBuilder(context, messages.length - index);
          },
        ),
      ),
    );
  }
}
