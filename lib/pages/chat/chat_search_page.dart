import 'dart:async';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_providers.dart';
import '../../utils/time_utils.dart';
import '../../widgets/common/emoji_text.dart';
import 'chat_message_page.dart';

/// 聊天全局搜索页
///
/// 对齐 Discourse chat-search：
/// - 独立入口（聊天页顶栏）
/// - 排序：relevance / latest
/// - 点击结果跳转频道并定位消息
class ChatSearchPage extends ConsumerStatefulWidget {
  const ChatSearchPage({super.key});

  @override
  ConsumerState<ChatSearchPage> createState() => _ChatSearchPageState();
}

class _ChatSearchPageState extends ConsumerState<ChatSearchPage> {
  final TextEditingController _queryController = TextEditingController();
  Timer? _debounce;
  String _query = '';
  String _sort = 'relevance';
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _error;
  final List<ChatGlobalSearchHit> _hits = [];
  bool _hasMore = false;
  int _offset = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _queryController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      final q = value.trim();
      if (q == _query) return;
      setState(() => _query = q);
      _search(reset: true);
    });
  }

  Future<void> _search({required bool reset}) async {
    final q = _query.trim();
    if (q.isEmpty) {
      setState(() {
        _hits.clear();
        _hasMore = false;
        _offset = 0;
        _error = null;
        _isLoading = false;
        _isLoadingMore = false;
      });
      return;
    }

    if (reset) {
      setState(() {
        _isLoading = true;
        _error = null;
        _offset = 0;
        _hits.clear();
      });
    } else {
      if (!_hasMore || _isLoadingMore || _isLoading) return;
      setState(() => _isLoadingMore = true);
    }

    try {
      final result = await ref.read(
        chatGlobalSearchProvider((
          query: q,
          sort: _sort,
          offset: reset ? 0 : _offset,
        )).future,
      );
      if (!mounted) return;
      setState(() {
        if (reset) {
          _hits
            ..clear()
            ..addAll(result.hits);
        } else {
          _hits.addAll(result.hits);
        }
        _hasMore = result.hasMore;
        _offset = _hits.length;
        _isLoading = false;
        _isLoadingMore = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isLoadingMore = false;
        _error = e.toString();
      });
    }
  }

  void _setSort(String sort) {
    if (sort == _sort) return;
    setState(() => _sort = sort);
    _search(reset: true);
  }

  void _openHit(ChatGlobalSearchHit hit) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatMessagePage(
          channelId: hit.channelId,
          channelTitle: hit.channelTitle,
          targetMessageId: hit.message.id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('搜索聊天'),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            tooltip: '排序',
            initialValue: _sort,
            onSelected: _setSort,
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'relevance',
                child: Text('相关性'),
              ),
              PopupMenuItem(
                value: 'latest',
                child: Text('最新'),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.sort_rounded, size: 20),
                  const SizedBox(width: 4),
                  Text(
                    _sort == 'latest' ? '最新' : '相关性',
                    style: theme.textTheme.labelLarge,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _queryController,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索消息…',
                prefixIcon: const Icon(Symbols.search_rounded, size: 20),
                suffixIcon: _queryController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Symbols.close_rounded, size: 18),
                        onPressed: () {
                          _queryController.clear();
                          setState(() => _query = '');
                          _search(reset: true);
                        },
                      )
                    : null,
                isDense: true,
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHigh,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (v) {
                setState(() {}); // 刷新 suffix
                _onQueryChanged(v);
              },
              onSubmitted: (v) {
                _debounce?.cancel();
                setState(() => _query = v.trim());
                _search(reset: true);
              },
            ),
          ),
          Expanded(child: _buildBody(theme)),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_query.isEmpty) {
      return Center(
        child: Text(
          '输入关键词搜索全部聊天消息',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('搜索失败: $_error'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => _search(reset: true),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_hits.isEmpty) {
      return Center(
        child: Text(
          '没有匹配的消息',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
          _search(reset: false);
        }
        return false;
      },
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _hits.length + (_isLoadingMore ? 1 : 0),
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          if (index >= _hits.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final hit = _hits[index];
          return _SearchHitTile(
            hit: hit,
            onTap: () => _openHit(hit),
          );
        },
      ),
    );
  }
}

class _SearchHitTile extends StatelessWidget {
  final ChatGlobalSearchHit hit;
  final VoidCallback onTap;

  const _SearchHitTile({
    required this.hit,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = hit.message;
    final preview = message.message.length > 120
        ? '${message.message.substring(0, 120)}…'
        : message.message;
    final userLabel =
        message.user?.name ?? message.user?.username ?? '未知用户';
    final timeLabel = TimeUtils.formatRelativeTime(message.createdAt);
    final emojiCode = ChatChannelEmoji.shortcode(hit.channelEmoji);

    return ListTile(
      onTap: onTap,
      isThreeLine: true,
      title: Row(
        children: [
          if (emojiCode != null) ...[
            EmojiText(emojiCode, style: const TextStyle(fontSize: 14)),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              hit.channelTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            timeLabel,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(
            userLabel,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          if (hit.threadTitle != null && hit.threadTitle!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '串：${hit.threadTitle}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 2),
          Text(
            preview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

/// 仅用于搜索结果展示的 emoji 短码工具（避免循环依赖额外 import 逻辑）
class ChatChannelEmoji {
  static String? shortcode(String? raw) {
    if (raw == null) return null;
    var value = raw.trim();
    if (value.isEmpty) return null;
    while (value.startsWith(':')) {
      value = value.substring(1);
    }
    while (value.endsWith(':')) {
      value = value.substring(0, value.length - 1);
    }
    value = value.trim();
    if (value.isEmpty) return null;
    if (RegExp(r'^[a-zA-Z0-9_+-]+(?::t\d)?$').hasMatch(value)) {
      return ':$value:';
    }
    return value;
  }
}
