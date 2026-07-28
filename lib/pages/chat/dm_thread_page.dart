import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../constants.dart';
import '../../models/chat/chat_message.dart';
import '../../providers/core_providers.dart';
import '../../providers/message_bus/chat_providers.dart';
import '../../utils/fluxdo_render_callbacks.dart';
import '../../utils/time_utils.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/common/smart_avatar.dart';

/// 消息串(thread)页:某条消息下的独立对话流 + 回复框。
/// 结构比主频道简化:不带回应/菜单等重操作,专注"在串里聊"。
class DmThreadPage extends ConsumerStatefulWidget {
  const DmThreadPage({
    super.key,
    required this.channelId,
    required this.threadId,
    this.title,
  });

  final int channelId;
  final int threadId;
  final String? title;

  @override
  ConsumerState<DmThreadPage> createState() => _DmThreadPageState();
}

class _DmThreadPageState extends ConsumerState<DmThreadPage> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();
  bool _sending = false;

  (int, int) get _arg => (widget.channelId, widget.threadId);

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final service = ref.read(discourseServiceProvider);
      await service.sendChatMessage(
        widget.channelId,
        text,
        threadId: widget.threadId,
      );
      _inputController.clear();
      ref.invalidate(chatThreadMessagesProvider(_arg));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('发送失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _inputFocusNode.requestFocus();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final messagesAsync = ref.watch(chatThreadMessagesProvider(_arg));
    final currentUsername = ref.watch(
      currentUserProvider.select((s) => s.value?.username),
    );
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        title: Text(widget.title ?? '消息串'),
      ),
      body: Column(
        children: [
          Expanded(
            child: messagesAsync.when(
              data: (messages) {
                if (messages.isEmpty) {
                  return const Center(
                    child: Text('还没有回复', style: TextStyle(color: Colors.grey)),
                  );
                }
                return ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[messages.length - 1 - index];
                    final isOwn = currentUsername != null &&
                        message.user?.username == currentUsername;
                    return _ThreadMessageTile(
                      message: message,
                      isOwn: isOwn,
                      scheme: scheme,
                    );
                  },
                );
              },
              loading: () => const Center(child: LoadingSpinner()),
              error: (error, stack) => ErrorView(
                error: error,
                stackTrace: stack,
                onRetry: () =>
                    ref.invalidate(chatThreadMessagesProvider(_arg)),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      focusNode: _inputFocusNode,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: '回复消息串',
                        filled: true,
                        fillColor: scheme.surfaceContainerHigh,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: '发送',
                    onPressed: _sending ? null : _send,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: LoadingSpinner(size: 18),
                          )
                        : const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 线程内的简化消息行:头像 + 名字/时间 + 正文。
class _ThreadMessageTile extends StatelessWidget {
  const _ThreadMessageTile({
    required this.message,
    required this.isOwn,
    required this.scheme,
  });

  final ChatMessage message;
  final bool isOwn;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final callbacks = FluxdoRenderCallbacks.generic(
      heroTagNamespace: 'chat_thread_msg_${message.id}',
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SmartAvatar(
            imageUrl: message.user?.getAvatarUrl(AppConstants.baseUrl, size: 40),
            radius: 16,
            fallbackText: (message.user?.username ?? '?').isNotEmpty
                ? message.user!.username[0]
                : '?',
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${message.user?.name ?? message.user?.username ?? ''} · '
                  '${TimeUtils.formatCompactTime(message.createdAt)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 2),
                message.isDeleted
                    ? const Text('(消息已删除)',
                        style: TextStyle(color: Colors.grey))
                    : (message.cooked?.isNotEmpty ?? false)
                        ? callbacks.render(
                            cookedHtml: message.cooked!, compact: true)
                        : Text(message.message ?? ''),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
