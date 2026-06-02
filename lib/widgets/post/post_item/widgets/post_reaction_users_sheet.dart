import 'package:flutter/material.dart';
import '../../../../l10n/s.dart';
import '../../../../models/topic.dart';
import '../../../../pages/user_profile_page.dart';
import '../../../../services/discourse/discourse_service.dart';
import '../../../../services/discourse_cache_manager.dart';
import '../../../../services/emoji_handler.dart';
import '../../../common/smart_avatar.dart';

/// 获取 emoji 图片 URL（未加载完成时返回空字符串，由 errorBuilder 处理）
String _getEmojiUrl(String emojiName) {
  return EmojiHandler().getEmojiUrl(emojiName);
}

/// 回应人列表底部弹窗
class PostReactionUsersSheet extends StatefulWidget {
  final int postId;
  final String? initialReactionId;

  const PostReactionUsersSheet({
    super.key,
    required this.postId,
    this.initialReactionId,
  });

  @override
  State<PostReactionUsersSheet> createState() => _PostReactionUsersSheetState();
}

class _PostReactionUsersSheetState extends State<PostReactionUsersSheet> {
  final DiscourseService _service = DiscourseService();
  List<ReactionUsersGroup>? _groups;
  bool _isLoading = true;
  String? _error;

  // 当前选中的标签：null 表示"全部"
  String? _selectedReactionId;

  @override
  void initState() {
    super.initState();
    _loadReactionUsers();
  }

  Future<void> _loadReactionUsers() async {
    try {
      final groups = await _service.getReactionUsers(widget.postId);
      if (mounted) {
        setState(() {
          _groups = groups;
          _isLoading = false;
          // 如果指定了初始 tab 且该回应类型存在，自动选中
          if (widget.initialReactionId != null &&
              groups.any((g) => g.id == widget.initialReactionId)) {
            _selectedReactionId = widget.initialReactionId;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = S.current.common_loadFailed;
          _isLoading = false;
        });
      }
    }
  }

  /// 获取当前需要显示的用户列表
  List<_DisplayUser> _getDisplayUsers() {
    if (_groups == null || _groups!.isEmpty) return [];

    if (_selectedReactionId == null) {
      // 全部：合并所有分组用户，去重
      final seen = <String>{};
      final result = <_DisplayUser>[];
      for (final group in _groups!) {
        for (final user in group.users) {
          if (seen.add(user.username)) {
            result.add(_DisplayUser(user: user, reactionId: group.id));
          }
        }
      }
      return result;
    } else {
      final group = _groups!.where((g) => g.id == _selectedReactionId).firstOrNull;
      if (group == null) return [];
      return group.users.map((u) => _DisplayUser(user: u, reactionId: group.id)).toList();
    }
  }

  /// 总回应人数
  int get _totalCount {
    if (_groups == null) return 0;
    // 去重计数
    final seen = <String>{};
    for (final group in _groups!) {
      for (final user in group.users) {
        seen.add(user.username);
      }
    }
    return seen.length;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.all(16),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.6,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
              child: Row(
                children: [
                  Icon(Icons.emoji_emotions_outlined,
                      color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    context.l10n.post_reactions,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),

            // 内容区域
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  children: [
                    Icon(Icons.error_outline,
                        color: theme.colorScheme.error, size: 32),
                    const SizedBox(height: 8),
                    Text(_error!,
                        style: TextStyle(color: theme.colorScheme.error)),
                  ],
                ),
              )
            else if (_groups == null || _groups!.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Text(context.l10n.post_noReactions,
                    style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant)),
              )
            else ...[
              // 用户列表
              Flexible(
                child: _buildUserList(theme),
              ),

              const Divider(height: 1),

              // Emoji 标签栏（放底部，避免高度变化导致位置跳动）
              _buildTabBar(theme),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar(ThemeData theme) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          // "全部"标签
          _buildTab(
            theme: theme,
            label: context.l10n.common_all,
            count: _totalCount,
            isSelected: _selectedReactionId == null,
            onTap: () => setState(() => _selectedReactionId = null),
          ),
          // 每个回应类型的标签
          ..._groups!.map((group) => _buildTab(
                theme: theme,
                emojiId: group.id,
                count: group.count,
                isSelected: _selectedReactionId == group.id,
                onTap: () =>
                    setState(() => _selectedReactionId = group.id),
              )),
        ],
      ),
    );
  }

  Widget _buildTab({
    required ThemeData theme,
    String? label,
    String? emojiId,
    required int count,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isSelected
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
                : theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected
                  ? theme.colorScheme.primary.withValues(alpha: 0.3)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (label != null)
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: isSelected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                )
              else if (emojiId != null)
                Image(
                  image: emojiImageProvider(_getEmojiUrl(emojiId)),
                  width: 18,
                  height: 18,
                  errorBuilder: (_, _, _) => const SizedBox(width: 18, height: 18),
                ),
              const SizedBox(width: 4),
              Text(
                '$count',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: isSelected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUserList(ThemeData theme) {
    final users = _getDisplayUsers();

    if (users.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Text(context.l10n.common_noData,
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: users.length,
      itemBuilder: (context, index) {
        final item = users[index];
        return _buildUserItem(theme, item);
      },
    );
  }

  Widget _buildUserItem(ThemeData theme, _DisplayUser item) {
    final user = item.user;
    final displayName = user.name?.isNotEmpty == true ? user.name! : user.username;

    return InkWell(
      onTap: () {
        Navigator.pop(context);
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => UserProfilePage(username: user.username),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            // 头像
            SmartAvatar(
              imageUrl: user.getAvatarUrl(size: 96),
              radius: 18,
              fallbackText: user.username,
            ),
            const SizedBox(width: 12),
            // 用户名
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (user.name?.isNotEmpty == true && user.name != user.username)
                    Text(
                      user.username,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            // 回应 emoji（仅在"全部"标签下显示）
            if (_selectedReactionId == null)
              Image(
                image: emojiImageProvider(_getEmojiUrl(item.reactionId)),
                width: 20,
                height: 20,
                errorBuilder: (_, _, _) => const SizedBox(width: 20, height: 20),
              ),
          ],
        ),
      ),
    );
  }
}

/// 用于展示的用户项（包含所属回应类型）
class _DisplayUser {
  final ReactionUser user;
  final String reactionId;

  const _DisplayUser({required this.user, required this.reactionId});
}
