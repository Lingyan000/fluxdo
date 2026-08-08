import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/category.dart';
import '../../models/chat/chat_models.dart';
import '../../models/emoji.dart';
import '../../providers/category_provider.dart';
import '../../providers/chat_providers.dart';
import '../../widgets/common/emoji_text.dart';
import '../../widgets/markdown_editor/emoji_sticker_panel.dart';
import 'chat_message_page.dart';

/// 创建公开聊天频道对话框（staff）
///
/// 对齐 Discourse ChatModalCreateChannel：
/// 名称 / slug / 描述 / 分类 / emoji / 消息串
class ChatCreateChannelSheet {
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const _ChatCreateChannelBody(),
    );
  }
}

class _ChatCreateChannelBody extends ConsumerStatefulWidget {
  const _ChatCreateChannelBody();

  @override
  ConsumerState<_ChatCreateChannelBody> createState() =>
      _ChatCreateChannelBodyState();
}

class _ChatCreateChannelBodyState
    extends ConsumerState<_ChatCreateChannelBody> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _slugController = TextEditingController();
  final _descriptionController = TextEditingController();
  int? _categoryId;
  String? _emoji;
  bool _threadingEnabled = false;
  bool _autoJoinUsers = false;
  bool _isSubmitting = false;
  bool _slugManuallyEdited = false;

  @override
  void dispose() {
    _nameController.dispose();
    _slugController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  String _slugify(String name) {
    return name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'[^a-z0-9一-鿿_-]'), '');
  }

  Future<void> _pickEmoji() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => SizedBox(
        height: MediaQuery.of(sheetCtx).size.height * 0.45,
        child: EmojiStickerPanel(
          onEmojiSelected: (Emoji emoji) {
            Navigator.pop(sheetCtx);
            setState(() {
              _emoji = ChatChannel.normalizeEmojiShortcode(emoji.name);
            });
          },
          onStickerSelected: (_) {},
          onBackspace: null,
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final categoryId = _categoryId;
    if (categoryId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请选择分类')),
      );
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final channel = await ref.read(
        createChatChannelProvider((
          name: _nameController.text.trim(),
          chatableId: categoryId,
          slug: _slugController.text.trim().isEmpty
              ? null
              : _slugController.text.trim(),
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          emoji: _emoji,
          autoJoinUsers: _autoJoinUsers,
          threadingEnabled: _threadingEnabled,
        )).future,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatMessagePage(
            channelId: channel.id,
            channelTitle: channel.title ?? _nameController.text.trim(),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('创建失败: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final categoriesAsync = ref.watch(categoriesProvider);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final previewCode = ChatChannel.toEmojiTextCode(_emoji);

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                '创建频道',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '频道名称',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.next,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return '请输入名称';
                  return null;
                },
                onChanged: (v) {
                  if (!_slugManuallyEdited) {
                    _slugController.text = _slugify(v);
                  }
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _slugController,
                decoration: const InputDecoration(
                  labelText: '缩略名 (Slug)',
                  hintText: '可选，自动生成',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => _slugManuallyEdited = true,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _descriptionController,
                decoration: const InputDecoration(
                  labelText: '描述',
                  hintText: '可选',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              categoriesAsync.when(
                data: (categories) {
                  final flat = <Category>[];
                  void walk(List<Category> list) {
                    for (final c in list) {
                      flat.add(c);
                    }
                  }
                  walk(categories);
                  return DropdownButtonFormField<int>(
                    // ignore: deprecated_member_use
                    value: _categoryId,
                    decoration: const InputDecoration(
                      labelText: '分类',
                      border: OutlineInputBorder(),
                    ),
                    items: flat
                        .map(
                          (c) => DropdownMenuItem(
                            value: c.id,
                            child: Text(
                              c.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (id) => setState(() => _categoryId = id),
                    validator: (v) => v == null ? '请选择分类' : null,
                  );
                },
                loading: () => const LinearProgressIndicator(),
                error: (e, _) => Text('分类加载失败: $e'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text('表情图标', style: theme.textTheme.labelLarge),
                  const SizedBox(width: 12),
                  Material(
                    color: theme.colorScheme.primaryContainer,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _pickEmoji,
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: Center(
                          child: previewCode != null
                              ? EmojiText(
                                  previewCode,
                                  style: const TextStyle(fontSize: 22),
                                )
                              : Icon(
                                  Icons.add_reaction_outlined,
                                  color: theme.colorScheme.onPrimaryContainer,
                                ),
                        ),
                      ),
                    ),
                  ),
                  if (_emoji != null)
                    IconButton(
                      tooltip: '清除',
                      onPressed: () => setState(() => _emoji = null),
                      icon: const Icon(Icons.close_rounded),
                    ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用消息串'),
                value: _threadingEnabled,
                onChanged: (v) => setState(() => _threadingEnabled = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('自动加入用户'),
                subtitle: const Text('符合分类权限的用户将自动加入'),
                value: _autoJoinUsers,
                onChanged: (v) => setState(() => _autoJoinUsers = v),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _isSubmitting ? null : _submit,
                child: _isSubmitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('创建'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
