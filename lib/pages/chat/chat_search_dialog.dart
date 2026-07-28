import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../constants.dart';
import '../../models/chat/chat_message.dart';
import '../../providers/core_providers.dart';
import '../../utils/time_utils.dart';
import '../../widgets/common/smart_avatar.dart';

/// 聊天搜索弹窗(`GET /chat/api/search`):[channelId] 非空时只搜该频道。
/// 支持 相关/最新 两种排序(对应接口的 sort=relevance|latest)。
/// 返回用户点选的那条消息。
Future<ChatMessage?> showChatSearchDialog(
  BuildContext context, {
  int? channelId,
}) {
  return showDialog<ChatMessage>(
    context: context,
    builder: (_) => _ChatSearchDialog(channelId: channelId),
  );
}

class _ChatSearchDialog extends ConsumerStatefulWidget {
  const _ChatSearchDialog({this.channelId});

  final int? channelId;

  @override
  ConsumerState<_ChatSearchDialog> createState() => _ChatSearchDialogState();
}

class _ChatSearchDialogState extends ConsumerState<_ChatSearchDialog> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  Future<List<ChatMessage>>? _future;
  String _sort = 'relevance';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _search({bool immediate = false}) {
    _debounce?.cancel();
    void run() {
      if (!mounted) return;
      final query = _controller.text.trim();
      setState(() {
        _future = query.isEmpty
            ? null
            : ref.read(discourseServiceProvider).searchChatMessages(
                  query,
                  channelId: widget.channelId,
                  sort: _sort,
                );
      });
    }

    if (immediate) {
      run();
    } else {
      _debounce = Timer(const Duration(milliseconds: 400), run);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.channelId != null ? '搜索本频道' : '搜索聊天'),
      content: SizedBox(
        width: 460,
        height: 460,
        child: Column(
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              onChanged: (_) => _search(),
              decoration: const InputDecoration(
                hintText: '搜索消息…',
                prefixIcon: Icon(Icons.search_rounded),
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(value: 'relevance', label: Text('相关')),
                    ButtonSegment(value: 'latest', label: Text('最新')),
                  ],
                  selected: {_sort},
                  onSelectionChanged: (selection) {
                    _sort = selection.first;
                    _search(immediate: true);
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _future == null
                  ? const Center(
                      child: Text('输入关键词搜索聊天记录',
                          style: TextStyle(color: Colors.grey)))
                  : FutureBuilder<List<ChatMessage>>(
                      future: _future,
                      builder: (ctx, snapshot) {
                        if (snapshot.connectionState != ConnectionState.done) {
                          return const Center(child: LoadingSpinner());
                        }
                        if (snapshot.hasError) {
                          return Center(child: Text('搜索失败: ${snapshot.error}'));
                        }
                        final results = snapshot.data ?? const [];
                        if (results.isEmpty) {
                          return const Center(
                              child: Text('没有匹配的消息',
                                  style: TextStyle(color: Colors.grey)));
                        }
                        return ListView.builder(
                          itemCount: results.length,
                          itemBuilder: (ctx, index) {
                            final msg = results[index];
                            return ListTile(
                              leading: SmartAvatar(
                                imageUrl: msg.user?.getAvatarUrl(
                                    AppConstants.baseUrl, size: 40),
                                radius: 16,
                                fallbackText:
                                    (msg.user?.username ?? '?').isNotEmpty
                                        ? msg.user!.username[0]
                                        : '?',
                              ),
                              title: Text(
                                msg.excerpt ?? msg.message ?? '',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${msg.user?.name ?? msg.user?.username ?? ''}'
                                '${msg.channelTitle != null ? ' · ${msg.channelTitle}' : ''}'
                                ' · ${TimeUtils.formatCompactTime(msg.createdAt)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => Navigator.of(ctx).pop(msg),
                            );
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
