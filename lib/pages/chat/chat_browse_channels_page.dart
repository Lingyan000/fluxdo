import 'dart:async';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../models/chat/chat_channel.dart';
import '../../providers/chat/chat_channels_provider.dart';
import '../../providers/discourse_providers.dart';
import '../../services/toast_service.dart';
import '../../widgets/common/error_view.dart';
import 'channel/chat_channel_page.dart';
import 'chat_list_page.dart' show ChatChannelAvatar;

/// 频道浏览器:全部公共频道(含未加入),搜索 + 加入/进入
class ChatBrowseChannelsPage extends ConsumerStatefulWidget {
  const ChatBrowseChannelsPage({super.key});

  @override
  ConsumerState<ChatBrowseChannelsPage> createState() =>
      _ChatBrowseChannelsPageState();
}

class _ChatBrowseChannelsPageState
    extends ConsumerState<ChatBrowseChannelsPage> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  List<ChatChannel>? _channels;
  Object? _error;
  bool _loading = true;

  /// 本页会话内已点过"加入"的频道 id(乐观标记)
  final Set<int> _joined = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({String? filter}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final service = ref.read(discourseServiceProvider);
      final channels = await service.browseChatChannels(filter: filter);
      if (mounted) {
        setState(() {
          _channels = channels;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  void _onSearchChanged(String term) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _load(filter: term.trim().isEmpty ? null : term.trim());
    });
  }

  bool _isFollowing(ChatChannel channel) {
    if (_joined.contains(channel.id)) return true;
    if (channel.currentUserMembership?.following == true) return true;
    // 已在我的频道列表里也算已加入
    final mine = ref.read(chatChannelsProvider).value?.publicChannels;
    return mine?.any((c) => c.id == channel.id) ?? false;
  }

  Future<void> _join(ChatChannel channel) async {
    try {
      final service = ref.read(discourseServiceProvider);
      await service.joinChatChannel(channel.id);
      setState(() => _joined.add(channel.id));
      // 会话列表刷新拿到新频道(bus 订阅一并补上)
      unawaited(ref.read(chatChannelsProvider.notifier).refresh());
    } catch (e) {
      ToastService.showError(e.toString());
    }
  }

  void _open(ChatChannel channel) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatChannelPage(channelId: channel.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.chat_browseChannels)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: context.l10n.chat_searchChannelHint,
                hintStyle: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.5,
                  ),
                ),
                prefixIcon: const Icon(Symbols.search_rounded, size: 20),
                isDense: true,
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.4,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
            ),
          ),
          Expanded(child: _buildBody(theme)),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) return const Center(child: LoadingSpinner());
    if (_error != null) {
      return ErrorView(error: _error!, onRetry: _load);
    }
    final channels = _channels ?? const [];
    if (channels.isEmpty) {
      return Center(
        child: Text(
          context.l10n.chat_noChannelsFound,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        12,
        4,
        12,
        16 + MediaQuery.paddingOf(context).bottom,
      ),
      itemCount: channels.length,
      itemBuilder: (context, index) {
        final channel = channels[index];
        final following = _isFollowing(channel);
        return Padding(
          padding: EdgeInsets.only(top: index == 0 ? 0 : 3),
          child: SegmentedCardItem(
            index: index,
            count: channels.length,
            child: InkWell(
              onTap: following ? () => _open(channel) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    ChatChannelAvatar(channel: channel, radius: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            channel.title ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (channel.description?.isNotEmpty == true) ...[
                            const SizedBox(height: 2),
                            Text(
                              channel.description!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          const SizedBox(height: 2),
                          Text(
                            context.l10n.chat_memberCount(
                              channel.membershipsCount ?? 0,
                            ),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    following
                        ? FilledButton.tonal(
                            onPressed: () => _open(channel),
                            child: Text(context.l10n.chat_enterChannel),
                          )
                        : FilledButton(
                            onPressed: () => _join(channel),
                            child: Text(context.l10n.chat_joinChannel),
                          ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
