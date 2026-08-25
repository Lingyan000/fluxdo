import 'dart:async';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../models/chat/chat_message.dart';
import '../../providers/discourse_providers.dart';
import '../../widgets/common/emoji_text.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/common/relative_time_text.dart';
import '../../widgets/common/smart_avatar.dart';
import 'channel/chat_channel_page.dart';
import 'chat_list_page.dart' show chatPreviewText;

/// 聊天消息搜索:[channelId] 非空=会话内搜索,空=全部会话
class ChatSearchPage extends ConsumerStatefulWidget {
  final int? channelId;

  const ChatSearchPage({super.key, this.channelId});

  @override
  ConsumerState<ChatSearchPage> createState() => _ChatSearchPageState();
}

class _ChatSearchPageState extends ConsumerState<ChatSearchPage> {
  final TextEditingController _queryController = TextEditingController();
  Timer? _debounce;
  List<ChatMessage> _results = [];
  bool _hasMore = false;
  bool _loading = false;
  bool _loadingMore = false;
  Object? _error;
  String _activeQuery = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _queryController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String term) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      final query = term.trim();
      if (query.isEmpty) {
        setState(() {
          _results = [];
          _activeQuery = '';
          _error = null;
        });
        return;
      }
      _search(query);
    });
  }

  Future<void> _search(String query) async {
    setState(() {
      _loading = true;
      _error = null;
      _activeQuery = query;
    });
    try {
      final result = await ref
          .read(discourseServiceProvider)
          .searchChatMessages(query, channelId: widget.channelId);
      if (mounted && _activeQuery == query) {
        setState(() {
          _results = result.messages;
          _hasMore = result.hasMore;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted && _activeQuery == query) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _activeQuery.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final result = await ref
          .read(discourseServiceProvider)
          .searchChatMessages(
            _activeQuery,
            channelId: widget.channelId,
            offset: _results.length,
          );
      if (mounted) {
        setState(() {
          final existing = _results.map((m) => m.id).toSet();
          _results.addAll(
            result.messages.where((m) => !existing.contains(m.id)),
          );
          _hasMore = result.hasMore;
          _loadingMore = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _openResult(ChatMessage message) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatChannelPage(
          channelId: message.channelId,
          threadId: message.threadId,
          initialMessageId: message.id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: TextField(
            controller: _queryController,
            autofocus: true,
            onChanged: _onQueryChanged,
            textInputAction: TextInputAction.search,
            onSubmitted: (v) {
              _debounce?.cancel();
              final query = v.trim();
              if (query.isNotEmpty) _search(query);
            },
            decoration: InputDecoration(
              hintText: widget.channelId != null
                  ? context.l10n.chat_searchInChannelHint
                  : context.l10n.chat_searchAllHint,
              hintStyle: TextStyle(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.5,
                ),
              ),
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
              prefixIcon: const Icon(Symbols.search_rounded, size: 20),
            ),
          ),
        ),
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) return const Center(child: LoadingSpinner());
    if (_error != null) {
      return ErrorView(error: _error!, onRetry: () => _search(_activeQuery));
    }
    if (_activeQuery.isEmpty) {
      return Center(
        child: Text(
          context.l10n.chat_searchPrompt,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Text(
          context.l10n.chat_searchNoResults,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels > n.metrics.maxScrollExtent - 300) _loadMore();
        return false;
      },
      child: ListView.builder(
        padding: EdgeInsets.fromLTRB(
          12,
          8,
          12,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        itemCount: _results.length + (_loadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _results.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: LoadingSpinner()),
            );
          }
          final message = _results[index];
          return Padding(
            padding: EdgeInsets.only(top: index == 0 ? 0 : 3),
            child: SegmentedCardItem(
              index: index,
              count: _results.length,
              child: InkWell(
                onTap: () => _openResult(message),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SmartAvatar(
                        imageUrl: message.user?.getAvatarUrl(size: 64),
                        radius: 16,
                        fallbackText: message.user?.username,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    message.user?.username ?? '',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                ),
                                if (message.createdAt != null)
                                  RelativeTimeText(
                                    dateTime: message.createdAt!,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.outline,
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            EmojiText(
                              chatPreviewText(
                                context,
                                message.excerpt?.isNotEmpty == true
                                    ? message.excerpt!
                                    : message.message,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
