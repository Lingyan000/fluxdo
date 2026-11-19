import 'dart:async';

import 'package:common_ui/common_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../constants.dart';
import '../../../l10n/s.dart';
import '../../../models/mention_user.dart';
import '../../../models/topic.dart';
import '../../../services/toast_service.dart';
import '../../../widgets/common/smart_avatar.dart';

/// 在成员弹层中搜索和邀请，成功后回到同一份名单。
class PrivateMessageInviteSheet extends StatefulWidget {
  const PrivateMessageInviteSheet({
    super.key,
    required this.detail,
    required this.currentUsername,
    required this.search,
    required this.onInvite,
    required this.onBack,
  });

  final TopicDetail detail;
  final String currentUsername;
  final Future<MentionSearchResult> Function(String term) search;
  final Future<void> Function(MentionItem recipient) onInvite;
  final VoidCallback onBack;

  @override
  State<PrivateMessageInviteSheet> createState() =>
      _PrivateMessageInviteSheetState();
}

class _PrivateMessageInviteSheetState extends State<PrivateMessageInviteSheet> {
  Timer? _debounce;
  int _generation = 0;
  String _term = '';
  List<MentionItem> _results = const [];
  bool _searching = false;
  bool _searchFailed = false;
  bool _sending = false;
  final _selected = <(bool, String), MentionItem>{};
  final _failed = <(bool, String)>{};

  (bool, String) _key(MentionItem item) =>
      (item.isGroup, item.mentionName.toLowerCase());

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _search(String input) {
    final term = input.trim();
    _debounce?.cancel();
    final generation = ++_generation;
    setState(() {
      _term = term;
      _results = const [];
      _searchFailed = false;
      _searching = term.isNotEmpty;
    });
    if (term.isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final result = await widget.search(term);
        if (!mounted || generation != _generation) return;
        setState(() {
          _results = result.items
              .where(
                (item) =>
                    item.isGroup ||
                    item.mentionName.toLowerCase() !=
                        widget.currentUsername.toLowerCase(),
              )
              .toList();
          _searching = false;
        });
      } catch (_) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _searching = false;
          _searchFailed = true;
        });
      }
    });
  }

  void _toggle(MentionItem item) {
    final key = _key(item);
    setState(() {
      if (_selected.remove(key) == null) _selected[key] = item;
      _failed.remove(key);
    });
  }

  Future<void> _submit() async {
    if (_sending || _selected.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _sending = true;
      _failed.clear();
    });
    for (final entry in _selected.entries.toList()) {
      try {
        await widget.onInvite(entry.value);
        if (!mounted) return;
        setState(() => _selected.remove(entry.key));
      } catch (_) {
        if (!mounted) return;
        _failed.add(entry.key);
      }
    }
    if (!mounted) return;
    setState(() => _sending = false);
    if (_failed.isEmpty) {
      ToastService.showSuccess(context.l10n.pm_inviteSucceeded);
      widget.onBack();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final joined = <(bool, String)>{
      for (final user in widget.detail.allowedUsers)
        (false, user.username.toLowerCase()),
      for (final group in widget.detail.allowedGroups)
        (true, group.name.toLowerCase()),
    };
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_sending) widget.onBack();
      },
      child: AppSheetScaffold(
        style: AppSheetStyle.card,
        title: l10n.pm_inviteParticipants,
        showCloseButton: false,
        showDragHandle: true,
        actions: [
          TextButton(
            onPressed: _sending ? null : widget.onBack,
            child: Text(l10n.common_cancel),
          ),
        ],
        contentPadding: EdgeInsets.zero,
        footer: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            onPressed: _sending || _selected.isEmpty ? null : _submit,
            child: _sending
                ? const LoadingSpinner(size: 20)
                : Text(
                    _selected.isEmpty
                        ? l10n.pm_inviteParticipants
                        : l10n.pm_inviteCount(_selected.length),
                  ),
          ),
        ),
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: InputFieldShell(
                  child: TextField(
                    autofocus: true,
                    enabled: !_sending,
                    onChanged: _search,
                    textInputAction: TextInputAction.search,
                    textAlignVertical: TextAlignVertical.center,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search_rounded),
                      hintText: l10n.pm_recipientHint,
                      contentPadding: const EdgeInsetsDirectional.only(
                        top: 8,
                        bottom: 8,
                        end: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (_selected.isNotEmpty)
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 48,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      for (final item in _selected.values)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: 6),
                          child: InputChip(
                            label: Text(item.mentionName),
                            onDeleted: _sending ? null : () => _toggle(item),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            if (_failed.isNotEmpty && !_sending)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      l10n.pm_inviteFailedRetry(
                        _failed
                            .map((key) => _selected[key]!.mentionName)
                            .join(', '),
                      ),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
              ),
            if (_results.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: _searching
                      ? const LoadingSpinner(size: 24)
                      : _searchFailed
                      ? TextButton(
                          onPressed: () => _search(_term),
                          child: Text(l10n.common_loadFailedTapRetry),
                        )
                      : Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            _term.isEmpty
                                ? l10n.pm_inviteParticipantsHint
                                : l10n.search_noResults,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                ),
              )
            else
              SliverList.builder(
                itemCount: _results.length,
                itemBuilder: (ctx, index) {
                  final item = _results[index];
                  final key = _key(item);
                  final alreadyJoined = joined.contains(key);
                  final checked = _selected.containsKey(key);
                  final user = item.user;
                  return ListTile(
                    leading: user == null
                        ? const CircleAvatar(child: Icon(Icons.group_rounded))
                        : SmartAvatar(
                            radius: 20,
                            imageUrl: user.getAvatarUrl(
                              AppConstants.baseUrl,
                              size: 80,
                            ),
                            fallbackText: user.username,
                          ),
                    title: Text(
                      item.displayName.trim().isEmpty
                          ? item.mentionName
                          : item.displayName,
                    ),
                    subtitle: Text(
                      item.isGroup
                          ? '${l10n.mention_group} · ${item.mentionName}'
                          : '@${item.mentionName}',
                    ),
                    trailing: alreadyJoined
                        ? Text(l10n.pm_alreadyJoined)
                        : Icon(
                            checked
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded,
                          ),
                    selected: checked,
                    enabled: !_sending && !alreadyJoined,
                    onTap: () => _toggle(item),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
