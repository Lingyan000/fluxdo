import 'package:flutter/material.dart';

import '../../models/topic.dart' show FlagType;
import '../../services/discourse/discourse_service.dart';
import '../../services/preloaded_data_service.dart';

/// 聊天消息举报面板（频道消息与消息串消息共用）
class ChatMessageFlagSheet extends StatefulWidget {
  final int channelId;
  final int messageId;
  final String username;
  final List<String>? availableFlagKeys;

  const ChatMessageFlagSheet({
    super.key,
    required this.channelId,
    required this.messageId,
    required this.username,
    this.availableFlagKeys,
  });

  @override
  State<ChatMessageFlagSheet> createState() => _ChatMessageFlagSheetState();
}

class _ChatMessageFlagSheetState extends State<ChatMessageFlagSheet> {
  List<FlagType> _flagTypes = [];
  FlagType? _selected;
  final _messageController = TextEditingController();
  bool _loading = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _loadTypes();
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _loadTypes() async {
    final preloaded = PreloadedDataService();
    final types = await preloaded.getPostActionTypes();
    if (!mounted) return;
    setState(() {
      final parsed = (types ?? const [])
          .map((t) => FlagType.fromJson(Map<String, dynamic>.from(t as Map)))
          .where((f) => f.isFlag && f.enabled && f.appliesToChatMessage)
          .toList()
        ..sort((a, b) => a.position.compareTo(b.position));
      // 若消息自带 available_flags，再按 nameKey 过滤
      if (widget.availableFlagKeys != null &&
          widget.availableFlagKeys!.isNotEmpty) {
        final keys = widget.availableFlagKeys!.toSet();
        _flagTypes =
            parsed.where((f) => keys.contains(f.nameKey)).toList();
        if (_flagTypes.isEmpty) {
          // 服务端给了符号但预加载类型匹配不上时，回退全部 chat 适用类型
          _flagTypes = parsed;
        }
      } else {
        _flagTypes = parsed.isNotEmpty ? parsed : FlagType.defaultTypes;
      }
      _loading = false;
    });
  }

  Future<void> _submit() async {
    if (_selected == null || _submitting) return;
    if (_selected!.requireMessage && _messageController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写举报说明')),
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      await DiscourseService().flagChatMessage(
        widget.channelId,
        widget.messageId,
        _selected!.id,
        message: _messageController.text.trim().isEmpty
            ? null
            : _messageController.text.trim(),
      );
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已提交举报')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('举报失败: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '举报 @${widget.username} 的消息',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              )
            else ...[
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _flagTypes.length,
                  itemBuilder: (context, index) {
                    final type = _flagTypes[index];
                    return RadioListTile<FlagType>(
                      value: type,
                      groupValue: _selected,
                      onChanged: _submitting
                          ? null
                          : (v) => setState(() => _selected = v),
                      title: Text(type.name),
                      subtitle: type.shortDescription != null ||
                              type.description.isNotEmpty
                          ? Text(
                              (type.shortDescription ?? type.description)
                                  .replaceAll('%{username}', widget.username)
                                  .replaceAll(
                                    '@%{username}',
                                    '@${widget.username}',
                                  ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            )
                          : null,
                    );
                  },
                ),
              ),
              if (_selected?.requireMessage == true)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    controller: _messageController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: '请说明举报原因',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _selected == null || _submitting ? null : _submit,
                    child: const Text('提交'),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
