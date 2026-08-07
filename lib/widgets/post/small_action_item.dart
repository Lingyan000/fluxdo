import 'dart:async';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/s.dart';
import '../../models/topic.dart';
import '../../providers/discourse_providers.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/fluxdo_render_callbacks.dart';
import '../../widgets/topic/assign_sheet.dart';
import '../common/relative_time_text.dart';
import '../common/smart_avatar.dart';
import 'post_item/render_parse_cache.dart';
import 'post_item/widgets/post_segment_frame.dart';

/// 还有"活的"指定可编辑(受理人/备注/状态)的 code——unassign 类的 code
/// 表示这条记录发生时话题/帖子已经变回未指定,没有 Assignment 记录可编辑
/// 了,这时候点"编辑指定"弹窗只会显示一片空("尚未指定给任何人"),没有
/// 意义,不该出现这个入口。
bool _hasEditableLiveAssignment(String? code) =>
    code == 'assigned' ||
    code == 'reassigned' ||
    code == 'assigned_group' ||
    code == 'reassigned_group' ||
    code == 'assigned_to_post' ||
    code == 'assigned_group_to_post';

/// discourse-assign 插件产生的 action_code——核对过插件源码 lib/assigner.rb
/// 里 moderator_post_assign_action_code/moderator_post_unassign_action_code
/// 实际会用到的几个值。
const Set<String> _assignActionCodes = {
  'assigned',
  'reassigned',
  'assigned_group',
  'reassigned_group',
  'unassigned',
  'unassigned_group',
  'assigned_to_post',
  'assigned_group_to_post',
  'unassigned_from_post',
  'unassigned_group_from_post',
  'note_change',
  'status_change',
  'details_change',
};

/// 帖子类型常量
class PostTypes {
  static const int regular = 1;
  static const int moderatorAction = 2;
  static const int smallAction = 3;
  static const int whisper = 4;
}

/// action_code 对应的图标映射
const Map<String, IconData> _actionCodeIcons = {
  'closed.enabled': Symbols.lock_rounded,
  'closed.disabled': Symbols.lock_open_rounded,
  'autoclosed.enabled': Symbols.lock_rounded,
  'autoclosed.disabled': Symbols.lock_open_rounded,
  'archived.enabled': Symbols.folder_rounded,
  'archived.disabled': Symbols.folder_open_rounded,
  'pinned.enabled': Symbols.push_pin_rounded,
  'pinned.disabled': Symbols.push_pin_rounded,
  'pinned_globally.enabled': Symbols.push_pin_rounded,
  'pinned_globally.disabled': Symbols.push_pin_rounded,
  'banner.enabled': Symbols.push_pin_rounded,
  'banner.disabled': Symbols.push_pin_rounded,
  'visible.enabled': Symbols.visibility_rounded,
  'visible.disabled': Symbols.visibility_off_rounded,
  'split_topic': Symbols.call_split_rounded,
  'invited_user': Symbols.person_add_rounded,
  'invited_group': Symbols.group_add_rounded,
  'user_left': Symbols.person_remove_rounded,
  'removed_user': Symbols.person_remove_rounded,
  'removed_group': Symbols.group_remove_rounded,
  'public_topic': Symbols.forum_rounded,
  'open_topic': Symbols.forum_rounded,
  'private_topic': Symbols.mail_rounded,
  'autobumped': Symbols.arrow_upward_rounded,
  'tags_changed': Symbols.label_rounded,
  'category_changed': Symbols.category_rounded,
  'assigned': Symbols.assignment_ind_rounded,
  'reassigned': Symbols.assignment_ind_rounded,
  'assigned_group': Symbols.assignment_ind_rounded,
  'reassigned_group': Symbols.assignment_ind_rounded,
  'unassigned': Symbols.assignment_late_rounded,
  'unassigned_group': Symbols.assignment_late_rounded,
  'assigned_to_post': Symbols.assignment_ind_rounded,
  'assigned_group_to_post': Symbols.assignment_ind_rounded,
  'unassigned_from_post': Symbols.assignment_late_rounded,
  'unassigned_group_from_post': Symbols.assignment_late_rounded,
  'note_change': Symbols.edit_note_rounded,
  'status_change': Symbols.edit_note_rounded,
  'details_change': Symbols.edit_note_rounded,
};

/// action_code 对应的本地化描述
Map<String, String> _getActionCodeDescriptions() {
  final l10n = S.current;
  return {
    'closed.enabled': l10n.smallAction_closedEnabled,
    'closed.disabled': l10n.smallAction_closedDisabled,
    'autoclosed.enabled': l10n.smallAction_autoclosedEnabled,
    'autoclosed.disabled': l10n.smallAction_autoclosedDisabled,
    'archived.enabled': l10n.smallAction_archivedEnabled,
    'archived.disabled': l10n.smallAction_archivedDisabled,
    'pinned.enabled': l10n.smallAction_pinnedEnabled,
    'pinned.disabled': l10n.smallAction_pinnedDisabled,
    'pinned_globally.enabled': l10n.smallAction_pinnedGloballyEnabled,
    'pinned_globally.disabled': l10n.smallAction_pinnedGloballyDisabled,
    'banner.enabled': l10n.smallAction_bannerEnabled,
    'banner.disabled': l10n.smallAction_bannerDisabled,
    'visible.enabled': l10n.smallAction_visibleEnabled,
    'visible.disabled': l10n.smallAction_visibleDisabled,
    'split_topic': l10n.smallAction_splitTopic,
    'invited_user': l10n.smallAction_invitedUser,
    'invited_group': l10n.smallAction_invitedGroup,
    'user_left': l10n.smallAction_userLeft,
    'removed_user': l10n.smallAction_removedUser,
    'removed_group': l10n.smallAction_removedGroup,
    'public_topic': l10n.smallAction_publicTopic,
    'open_topic': l10n.smallAction_openTopic,
    'private_topic': l10n.smallAction_privateTopic,
    'autobumped': l10n.smallAction_autobumped,
    'tags_changed': l10n.smallAction_tagsChanged,
    'category_changed': l10n.smallAction_categoryChanged,
    'forwarded': l10n.smallAction_forwarded,
    'assigned': '指定给',
    'reassigned': '重新指定给',
    'assigned_group': '指定给群组',
    'reassigned_group': '重新指定给群组',
    'unassigned': '取消了指定',
    'unassigned_group': '取消了群组指定',
    'assigned_to_post': '把这条帖子指定给',
    'assigned_group_to_post': '把这条帖子指定给群组',
    'unassigned_from_post': '取消了这条帖子的指定',
    'unassigned_group_from_post': '取消了这条帖子的群组指定',
    'note_change': '更新了指定备注',
    'status_change': '更新了指定状态',
    'details_change': '更新了指定信息',
  };
}

/// 系统操作帖子组件（small_action）
/// 用于显示置顶、关闭、邀请、指定等系统操作
class SmallActionItem extends ConsumerWidget {
  final Post post;
  final int topicId;
  final bool selected;
  final VoidCallback? onTap;

  /// 编辑这条系统帖本身的原始内容(标准帖子编辑器)——跟"点开指定
  /// 元数据弹窗"是两回事。是否显示由 [Post.canEdit] 决定,那是服务端
  /// 按当前用户实际算出来的权限(具体规则见 Discourse PostPolicy /
  /// TrustLevel,不是"只有作者能编"这么简单——实测三级用户能编辑
  /// 别人触发的指定系统帖,以服务端返回的 can_edit 为准,不在客户端
  /// 猜测/重新实现这条权限规则)。
  final VoidCallback? onEdit;

  const SmallActionItem({
    super.key,
    required this.post,
    required this.topicId,
    this.selected = false,
    this.onTap,
    this.onEdit,
  });

  bool get _isAssignCode => _assignActionCodes.contains(post.actionCode ?? '');

  /// *_to_post / *_from_post 这几个 code 是帖子级指定(target_type='Post'),
  /// 其余(assigned/reassigned/unassigned/unassigned_group/assigned_group/
  /// reassigned_group)是话题级(target_type='Topic')——两者要打开不同的
  /// 弹窗,之前一律固定打开话题级弹窗,点开帖子级指定的卡片时显示的是
  /// 完全不相关的话题指定状态。
  bool get _isPostLevelAssignCode =>
      post.actionCode == 'assigned_to_post' ||
      post.actionCode == 'assigned_group_to_post' ||
      post.actionCode == 'unassigned_from_post' ||
      post.actionCode == 'unassigned_group_from_post';

  /// 帖子级指定的目标帖子 id——不是这条 small_action 帖自己的 id,而是
  /// custom_fields['action_code_path'](形如 "/p/123")里编码的目标帖子。
  /// 见插件 lib/assigner.rb add_small_action_post 的
  /// `custom_fields.merge!({"action_code_path" => "/p/#{@target.id}", ...})`。
  int? get _postLevelTargetPostId {
    final path = post.actionCodePath;
    if (path == null) return null;
    final match = RegExp(r'/p/(\d+)').firstMatch(path);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  void _openAssignEditor(BuildContext context, WidgetRef ref) {
    if (_isPostLevelAssignCode) {
      final targetPostId = _postLevelTargetPostId;
      if (targetPostId == null) return;
      unawaited(
        showPostAssignDialog(
          context,
          ref,
          topicId: topicId,
          postId: targetPostId,
        ),
      );
    } else {
      unawaited(showAssignSheet(context, ref, topicId: topicId));
    }
  }

  /// 删除这条系统帖本身——权限是 Discourse 核心的 can_delete(跟上面
  /// can_edit 一样,服务端按当前用户算好的,不在客户端重新猜规则)。
  /// 删的是这条 small_action 帖记录本身,不是撤销指定操作;真要撤销
  /// 指定用上面"编辑指定"里的取消指定。
  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条记录'),
        content: const Text('确定删除吗?删除后可以撤销(权限允许的话)。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final service = ref.read(discourseServiceProvider);
      await service.deletePost(post.id);
      final params = TopicDetailNotifier.activeParamsFor(topicId);
      final notifier = params == null
          ? null
          : ref.read(topicDetailProvider(params).notifier);
      // invalidate 会整页重取、丢滚动位置——只改这一条帖子。
      notifier?.markPostDeleted(post.id);
      if (post.canRecover) {
        ToastService.show(
          '已删除',
          actionLabel: '撤销',
          onAction: () async {
            try {
              await service.recoverPost(post.id);
              notifier?.markPostRecovered(post.id);
            } catch (e) {
              ToastService.showError('撤销失败: $e');
            }
          },
        );
      } else {
        ToastService.showSuccess('已删除');
      }
    } catch (e) {
      ToastService.showError('删除失败: $e');
    }
  }

  IconData get _icon {
    final code = post.actionCode ?? '';
    return _actionCodeIcons[code] ?? Symbols.info_rounded;
  }

  String get _description {
    final code = post.actionCode ?? '';
    final who = post.actionCodeWho;
    String base = _getActionCodeDescriptions()[code] ?? code;

    // 如果有操作者信息，且描述需要包含操作者
    if (who != null && who.isNotEmpty) {
      if (code == 'invited_user' ||
          code == 'invited_group' ||
          code == 'removed_user' ||
          code == 'removed_group' ||
          _isAssignCode) {
        base = '$base @$who';
      } else if (code == 'user_left') {
        base = '@$who $base';
      }
    }

    return base;
  }

  /// 指定备注在服务端就是这条 small_action/whisper 帖的 cooked 正文
  /// (见 lib/assigner.rb add_small_action_post),跟普通帖子正文走的是
  /// 同一套 cook 管线——可能带模糊剧透([spoiler])、图片、@提及等任意
  /// 富文本样式。之前直接拿正则把 HTML 标签砸掉当纯文本显示,剧透内容
  /// 会被直接拆穿曝光,链接/图片也全丢了。这里换成跟正文完全同一份渲染
  /// 引擎(FluxdoRenderCallbacks + RenderParseCache),该模糊模糊、该能点
  /// 开点开,不再自己另糊一套阉割版展示。
  ///
  /// 不再按 action_code 白名单判断"这条该不该有内容"——插件默认
  /// unassigned 走 nil 正文,但这条帖子本质是个普通 Post,只要用户有
  /// can_edit 权限就能把它编辑成任意内容(实测取消指定的帖子被编辑出了
  /// 大段 emoji + 文字);cooked 有内容就该显示,不该靠猜代码含义过滤掉。
  Widget? _buildNote(BuildContext context) {
    if (post.cooked.trim().isEmpty) return null;
    final parsed = RenderParseCache.shortPost(post);
    final callbacks = FluxdoRenderCallbacks.forPost(
      post: post,
      topicId: topicId,
      preprocessedCooked: parsed.preprocessed,
      parsedNodes: parsed.nodes,
    );
    return callbacks.render(
      cookedHtml: parsed.preprocessed,
      parsedNodes: parsed.nodes,
      baseTextStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurface,
      ),
      compact: true,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final avatarUrl = post.getAvatarUrl(size: 60);
    final note = _buildNote(context);
    // 只有还有"活的"Assignment 记录可编辑的 code 才让点开编辑弹窗——
    // 取消指定之后再点只会打开一个空的"尚未指定给任何人",没有意义。
    final tappable =
        _isAssignCode && _hasEditableLiveAssignment(post.actionCode);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                width: 0.5,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 只有图标/描述/时间这一行触发"点开指定弹窗编辑"——备注区域
              // 自己是独立手势区(内部可能有剧透/链接/图片点击),跟这层
              // InkWell 挤在一起会抢手势,点剧透变成点开了编辑弹窗。
              InkWell(
                onTap: tappable ? () => _openAssignEditor(context, ref) : onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      // 图标
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer.withValues(
                            alpha: 0.3,
                          ),
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
                            RelativeTimeText(
                              dateTime: post.createdAt,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 官方 Web 端这里只有一个铅笔,打开的是标准帖子编辑器,
                      // 编辑的是这条系统帖的原始正文内容——不是什么"编辑
                      // 指定元数据"的另一个面板,之前当成两码事另做了一个
                      // 假的"编辑指定"图标,纯属臆造,已去掉。权限只看
                      // Discourse 核心的 post.canEdit。
                      if (post.canEdit && onEdit != null)
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 16),
                          tooltip: '编辑',
                          visualDensity: VisualDensity.compact,
                          onPressed: onEdit,
                        ),
                      if (post.canDelete)
                        IconButton(
                          icon: Icon(
                            Icons.delete_outline_rounded,
                            size: 16,
                            color: theme.colorScheme.error,
                          ),
                          tooltip: '删除',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _confirmDelete(context, ref),
                        ),
                      // 头像
                      SmartAvatar(
                        imageUrl: avatarUrl.isNotEmpty ? avatarUrl : null,
                        radius: 14,
                        fallbackText: post.username,
                        backgroundColor:
                            theme.colorScheme.surfaceContainerHighest,
                      ),
                    ],
                  ),
                ),
              ),
              if (note != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: note,
                ),
            ],
          ),
        ),
        if (selected)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: buildPostSelectionIndicatorColor(theme),
                ),
                child: const SizedBox(width: 3),
              ),
            ),
          ),
      ],
    );
  }
}
