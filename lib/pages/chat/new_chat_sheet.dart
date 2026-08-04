import 'dart:async';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../models/chat/chat_channel.dart';
import '../../models/mention_user.dart';
import '../../providers/discourse_providers.dart';
import '../../services/toast_service.dart';
import '../../utils/url_helper.dart';
import '../../widgets/common/app_bottom_sheet.dart';
import '../../widgets/common/smart_avatar.dart';

/// 新建会话:搜人多选;单选=1:1 私聊(自动复用旧会话),多选=群聊
Future<ChatChannel?> showNewChatSheet(BuildContext context) async {
  final selected = await showUserPickerSheet(
    context,
    title: S.current.chat_newChat,
    confirmLabel: (count) => count > 1
        ? S.current.chat_createGroup(count)
        : S.current.chat_startChat,
  );
  if (selected == null || selected.isEmpty || !context.mounted) return null;
  try {
    final service = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(discourseServiceProvider);
    return await service.createDirectMessageChannel(
      targetUsernames: selected.map((u) => u.username).toList(),
      // 1:1 upsert 复用旧会话;群聊也 upsert,避免误触重复建群
      upsert: true,
    );
  } catch (e) {
    ToastService.showError(e.toString());
    return null;
  }
}

/// 通用搜人多选弹层(新建会话/群聊拉人共用),返回选中的用户
Future<List<MentionUser>?> showUserPickerSheet(
  BuildContext context, {
  required String title,
  required String Function(int count) confirmLabel,
}) {
  return AppBottomSheet.showDraggable<List<MentionUser>>(
    context: context,
    title: title,
    initialSize: 0.75,
    minSize: 0.5,
    bodyBuilder: (sheetContext, scrollController) => _UserPickerBody(
      scrollController: scrollController,
      confirmLabel: confirmLabel,
    ),
  );
}

class _UserPickerBody extends ConsumerStatefulWidget {
  final ScrollController scrollController;
  final String Function(int count) confirmLabel;

  const _UserPickerBody({
    required this.scrollController,
    required this.confirmLabel,
  });

  @override
  ConsumerState<_UserPickerBody> createState() => _UserPickerBodyState();
}

class _UserPickerBodyState extends ConsumerState<_UserPickerBody> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  List<MentionUser> _results = [];
  final List<MentionUser> _selected = [];
  bool _searching = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String term) {
    _debounce?.cancel();
    if (term.trim().isEmpty) {
      setState(() => _results = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      setState(() => _searching = true);
      try {
        final service = ref.read(discourseServiceProvider);
        final result = await service.searchUsers(
          term: term.trim(),
          includeGroups: false,
          limit: 10,
        );
        if (mounted) {
          setState(() {
            _results = result.users;
            _searching = false;
          });
        }
      } catch (_) {
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  void _toggle(MentionUser user) {
    setState(() {
      final index = _selected.indexWhere((u) => u.username == user.username);
      if (index >= 0) {
        _selected.removeAt(index);
      } else {
        _selected.add(user);
      }
    });
  }

  void _confirm() {
    if (_selected.isEmpty) return;
    Navigator.pop(context, List<MentionUser>.unmodifiable(_selected));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        // 搜索框 + 创建按钮
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
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
                    fillColor: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.4),
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
              const SizedBox(width: 10),
              FilledButton(
                onPressed: _selected.isEmpty ? null : _confirm,
                child: Text(widget.confirmLabel(_selected.length)),
              ),
            ],
          ),
        ),
        // 已选用户 chips
        if (_selected.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final user in _selected)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InputChip(
                      avatar: SmartAvatar(
                        imageUrl: _avatarUrl(user),
                        radius: 10,
                        fallbackText: user.username,
                      ),
                      label: Text(user.username),
                      onDeleted: () => _toggle(user),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        // 搜索结果
        Expanded(
          child: _searching
              ? const Center(child: LoadingSpinner())
              : ListView.builder(
                  controller: widget.scrollController,
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                  itemCount: _results.length,
                  itemBuilder: (context, index) {
                    final user = _results[index];
                    final selected = _selected.any(
                      (u) => u.username == user.username,
                    );
                    return _UserResultTile(
                      user: user,
                      selected: selected,
                      onTap: () => _toggle(user),
                    );
                  },
                ),
        ),
      ],
    );
  }

  static String? _avatarUrl(MentionUser user) {
    final template = user.avatarTemplate;
    if (template == null || template.isEmpty) return null;
    return UrlHelper.resolveUrlWithCdn(template.replaceAll('{size}', '96'));
  }
}

/// 搜索结果行:头像 + 用户名/昵称 + 选中勾
class _UserResultTile extends StatelessWidget {
  final MentionUser user;
  final bool selected;
  final VoidCallback onTap;

  const _UserResultTile({
    required this.user,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avatarUrl = _UserPickerBodyState._avatarUrl(user);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            SmartAvatar(
              imageUrl: avatarUrl,
              radius: 19,
              fallbackText: user.username,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(user.username, style: theme.textTheme.bodyLarge),
                  if (user.name?.isNotEmpty == true)
                    Text(
                      user.name!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: selected
                  ? Icon(
                      Symbols.check_circle_rounded,
                      key: const ValueKey('on'),
                      fill: 1,
                      color: theme.colorScheme.primary,
                    )
                  : Icon(
                      Symbols.circle_rounded,
                      key: const ValueKey('off'),
                      color: theme.colorScheme.outlineVariant,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
