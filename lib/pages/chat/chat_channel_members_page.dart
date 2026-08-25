import 'dart:async';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../models/chat/chat_channel.dart';
import '../../providers/discourse_providers.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';
import '../../widgets/common/smart_avatar.dart';
import '../user_profile_page.dart';

/// 成员列表页:搜索 + offset 分页 + 群聊管理(踢人)
///
/// 从详情页"成员"摘要行进入;详情页不再内嵌大列表
/// (4 万人频道内嵌是灾难,分页/搜索也没地方放)。
class ChatChannelMembersPage extends ConsumerStatefulWidget {
  final int channelId;

  /// 群聊且有权限时可踢人;公共频道只读
  final bool canRemoveMembers;

  const ChatChannelMembersPage({
    super.key,
    required this.channelId,
    this.canRemoveMembers = false,
  });

  @override
  ConsumerState<ChatChannelMembersPage> createState() =>
      _ChatChannelMembersPageState();
}

class _ChatChannelMembersPageState
    extends ConsumerState<ChatChannelMembersPage> {
  static const _pageSize = 50;

  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  final List<ChatChannelMember> _members = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({required bool reset}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _members.clear();
        _hasMore = true;
      });
    }
    try {
      final page = await ref
          .read(discourseServiceProvider)
          .getChatChannelMembers(
            widget.channelId,
            offset: reset ? 0 : _members.length,
            limit: _pageSize,
            username: _filter.isEmpty ? null : _filter,
          );
      if (!mounted) return;
      setState(() {
        final existing = _members.map((m) => m.user.id).toSet();
        _members.addAll(page.where((m) => !existing.contains(m.user.id)));
        _hasMore = page.length >= _pageSize;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
        ToastService.showError(e.toString());
      }
    }
  }

  void _onSearchChanged(String term) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _filter = term.trim();
      _load(reset: true);
    });
  }

  void _loadMore() {
    if (_loadingMore || !_hasMore || _loading) return;
    setState(() => _loadingMore = true);
    _load(reset: false);
  }

  Future<void> _removeMember(ChatChannelMember member) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          dialogContext.l10n.chat_removeMemberConfirm(member.user.username),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(dialogContext.l10n.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              dialogContext.l10n.chat_removeMember,
              style: TextStyle(
                color: Theme.of(dialogContext).colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(discourseServiceProvider)
          .removeChatChannelMember(widget.channelId, member.user.id);
      setState(() => _members.removeWhere((m) => m.user.id == member.user.id));
    } catch (e) {
      ToastService.showError(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentUserId = ref.watch(currentUserProvider).value?.id;
    // 我置顶,其余按服务端顺序
    final self = _members.where((m) => m.user.id == currentUserId).toList();
    final others = _members.where((m) => m.user.id != currentUserId).toList();

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.chat_members)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: context.l10n.chat_searchUserHint,
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
          Expanded(
            child: _loading
                ? const Center(child: LoadingSpinner())
                : NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.pixels > n.metrics.maxScrollExtent - 300) {
                        _loadMore();
                      }
                      return false;
                    },
                    child: ListView(
                      padding: EdgeInsets.fromLTRB(
                        12,
                        4,
                        12,
                        16 + MediaQuery.paddingOf(context).bottom,
                      ),
                      children: [
                        if (self.isNotEmpty) ...[
                          _sectionLabel(theme, context.l10n.chat_memberSelf),
                          SegmentedCardGroup(
                            children: [
                              for (final m in self)
                                _memberTile(m, isSelf: true),
                            ],
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (others.isNotEmpty) ...[
                          if (self.isNotEmpty)
                            _sectionLabel(theme, context.l10n.chat_members),
                          SegmentedCardGroup(
                            children: [
                              for (final m in others)
                                _memberTile(m, isSelf: false),
                            ],
                          ),
                        ],
                        if (_loadingMore)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(child: LoadingSpinner()),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(ThemeData theme, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Text(
        label,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _memberTile(ChatChannelMember member, {required bool isSelf}) {
    final theme = Theme.of(context);
    return ListTile(
      leading: SmartAvatar(
        imageUrl: member.user.getAvatarUrl(size: 96),
        radius: 18,
        fallbackText: member.user.username,
      ),
      title: Text(member.user.username),
      subtitle: member.user.name?.isNotEmpty == true
          ? Text(member.user.name!)
          : null,
      trailing: !isSelf && widget.canRemoveMembers
          ? IconButton(
              icon: Icon(
                Symbols.person_remove_rounded,
                size: 20,
                color: theme.colorScheme.error,
              ),
              onPressed: () => _removeMember(member),
              tooltip: context.l10n.chat_removeMember,
            )
          : null,
      onTap: isSelf
          ? null
          : () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => UserProfilePage(username: member.user.username),
              ),
            ),
    );
  }
}
