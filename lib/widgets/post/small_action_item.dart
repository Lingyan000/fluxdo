import 'package:flutter/material.dart';
import '../../models/topic.dart';
import '../../utils/time_utils.dart';
import '../common/smart_avatar.dart';

/// 帖子类型常量
class PostTypes {
  static const int regular = 1;
  static const int moderatorAction = 2;
  static const int smallAction = 3;
  static const int whisper = 4;
}

/// action_code 对应的图标映射
const Map<String, IconData> _actionCodeIcons = {
  'closed.enabled': Icons.lock_outline,
  'closed.disabled': Icons.lock_open_outlined,
  'autoclosed.enabled': Icons.lock_outline,
  'autoclosed.disabled': Icons.lock_open_outlined,
  'archived.enabled': Icons.folder_outlined,
  'archived.disabled': Icons.folder_open_outlined,
  'pinned.enabled': Icons.push_pin_outlined,
  'pinned.disabled': Icons.push_pin_outlined,
  'pinned_globally.enabled': Icons.push_pin,
  'pinned_globally.disabled': Icons.push_pin_outlined,
  'banner.enabled': Icons.push_pin,
  'banner.disabled': Icons.push_pin_outlined,
  'visible.enabled': Icons.visibility_outlined,
  'visible.disabled': Icons.visibility_off_outlined,
  'split_topic': Icons.call_split_outlined,
  'invited_user': Icons.person_add_outlined,
  'invited_group': Icons.group_add_outlined,
  'user_left': Icons.person_remove_outlined,
  'removed_user': Icons.person_remove_outlined,
  'removed_group': Icons.group_remove_outlined,
  'public_topic': Icons.forum_outlined,
  'open_topic': Icons.forum_outlined,
  'private_topic': Icons.mail_outline,
  'autobumped': Icons.arrow_upward_outlined,
  'tags_changed': Icons.label_outline,
  'category_changed': Icons.category_outlined,
};

/// action_code 对应的中文描述
const Map<String, String> _actionCodeDescriptions = {
  'closed.enabled': '关闭了话题',
  'closed.disabled': '打开了话题',
  'autoclosed.enabled': '话题被自动关闭',
  'autoclosed.disabled': '话题被自动打开',
  'archived.enabled': '归档了话题',
  'archived.disabled': '取消归档了话题',
  'pinned.enabled': '置顶了话题',
  'pinned.disabled': '取消置顶了话题',
  'pinned_globally.enabled': '全站置顶了话题',
  'pinned_globally.disabled': '取消全站置顶',
  'banner.enabled': '将话题设为横幅',
  'banner.disabled': '移除了横幅',
  'visible.enabled': '公开了话题',
  'visible.disabled': '取消公开了话题',
  'split_topic': '拆分了话题',
  'invited_user': '邀请了',
  'invited_group': '邀请了',
  'user_left': '离开了对话',
  'removed_user': '移除了',
  'removed_group': '移除了',
  'public_topic': '转换为公开话题',
  'open_topic': '转换为话题',
  'private_topic': '转换为私信',
  'autobumped': '自动顶帖',
  'tags_changed': '更新了标签',
  'category_changed': '更新了类别',
  'forwarded': '转发了邮件',
};

/// 系统操作帖子组件（small_action）
/// 用于显示置顶、关闭、邀请等系统操作
class SmallActionItem extends StatelessWidget {
  final Post post;
  final VoidCallback? onTap;

  const SmallActionItem({
    super.key,
    required this.post,
    this.onTap,
  });

  IconData get _icon {
    final code = post.actionCode ?? '';
    return _actionCodeIcons[code] ?? Icons.info_outline;
  }

  String get _description {
    final code = post.actionCode ?? '';
    final who = post.actionCodeWho;
    String base = _actionCodeDescriptions[code] ?? code;
    
    // 如果有操作者信息，且描述需要包含操作者
    if (who != null && who.isNotEmpty) {
      if (code == 'invited_user' || code == 'invited_group' ||
          code == 'removed_user' || code == 'removed_group') {
        base = '$base @$who';
      } else if (code == 'user_left') {
        base = '@$who $base';
      }
    }
    
    return base;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avatarUrl = post.getAvatarUrl(size: 60);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          // 图标
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _icon,
              size: 16,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          // 描述和时间
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _description,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  TimeUtils.formatRelativeTime(post.createdAt),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          // 头像
          SmartAvatar(
            imageUrl: avatarUrl.isNotEmpty ? avatarUrl : null,
            radius: 14,
            fallbackText: post.username,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ],
      ),
    );
  }
}
