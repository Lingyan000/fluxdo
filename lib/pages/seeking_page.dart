import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/s.dart';
import '../models/seeking.dart';
import '../providers/seeking_provider.dart';
import '../providers/selected_topic_provider.dart';
import '../services/toast_service.dart';
import '../utils/responsive.dart';
import '../utils/time_utils.dart';
import '../widgets/common/smart_avatar.dart';
import '../widgets/content/collapsed_html_content.dart';
import '../widgets/layout/master_detail_layout.dart';
import '../widgets/layout/pane_projection_back_scope.dart';
import '../providers/shortcut_provider.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'topics_screen.dart' show PaneContentWidget;
import 'user_profile_page.dart';

/// 追觅：实时监控指定用户的发帖 / 回复 / 点赞 / 表情回应 / Boost 动态。
///
/// 移植自 BestLINUXDO 扩展的「追觅」面板。刷新调度在 [seekingProvider]，
/// 页面只负责展示与名单管理。
class SeekingPage extends ConsumerStatefulWidget {
  const SeekingPage({super.key, this.isActive = true});

  /// 底栏 PageView 复用时的激活标记。
  final bool isActive;

  @override
  ConsumerState<SeekingPage> createState() => _SeekingPageState();
}

class _SeekingPageState extends ConsumerState<SeekingPage> {
  static const double _parallelMasterWidth = PaneBreakpoints.wideMasterWidth;
  static const double _parallelMinDetailWidth =
      PaneBreakpoints.wideMinDetailWidth;

  /// 只看此人过滤（点用户头像切换）
  String? _focusUser;

  /// 桌面 ESC 两段式(右栏开→关右栏;右栏空→maybePop,底栏 tab 首路由
  /// 为 no-op)。isActive 谓词防截胡其他 tab。
  late final PaneHostEscBinding _escBinding = PaneHostEscBinding(
    ref: ref,
    enabled: () => widget.isActive,
  );

  @override
  void dispose() {
    _escBinding.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SeekingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 未读清零推迟到**离开**页面时：进入页面就清零会让用户徽标
    // （_UserChip 的 99+ 角标）永远只存在一帧，谁有新动态根本看不见。
    // 停留期间徽标保持累积，离开时视为已阅、下次进入从零计。
    if (oldWidget.isActive && !widget.isActive) {
      unawaited(ref.read(seekingProvider.notifier).markAllRead());
    }
  }

  Future<void> _showAddUserDialog() async {
    final controller = TextEditingController();
    final username = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.seeking_addUser),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: ctx.l10n.seeking_addUserHint),
          onSubmitted: (value) => Navigator.pop(ctx, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(ctx.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(ctx.l10n.common_confirm),
          ),
        ],
      ),
    );
    if (username == null || username.trim().isEmpty || !mounted) return;
    final result = await ref.read(seekingProvider.notifier).addUser(username);
    if (!mounted) return;
    switch (result) {
      case 'exists':
        ToastService.showInfo(context.l10n.seeking_userExists);
      case 'full':
        ToastService.showInfo(
          context.l10n.seeking_userLimit(SeekingNotifier.maxUsers),
        );
      case 'notFound':
        ToastService.showInfo(context.l10n.seeking_userNotFound);
      case 'failed':
        ToastService.showError(context.l10n.seeking_addUserFailed);
      default:
        break;
    }
  }

  Future<void> _syncFollowing() async {
    final added = await ref.read(seekingProvider.notifier).syncFollowing();
    if (!mounted) return;
    if (added < 0) {
      ToastService.showError(context.l10n.seeking_syncFollowFailed);
    } else {
      ToastService.showSuccess(context.l10n.seeking_syncFollowDone(added));
    }
  }

  void _openActivity(SeekingActivity activity) {
    if (activity.topicId <= 0) return;
    // 与其他宿主同构:宽屏写入本页平行视界栈进右栏;窄屏走真路由全屏
    // (保原生转场/侧滑,不写栈——投影态只服务"宽屏选中后缩窄"的接续)。
    if (_canShowParallel(context)) {
      ref
          .read(selectedSeekingProvider.notifier)
          .select(
            topicId: activity.topicId,
            initialTitle: activity.title,
            scrollToPostNumber: activity.postNumber,
          );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: activity.topicId,
          initialTitle: activity.title,
          scrollToPostNumber: activity.postNumber,
          autoSwitchToMasterDetail: true,
          stackProvider: selectedSeekingProvider,
        ),
      ),
    );
  }

  void _openProfile(String username) {
    if (_canShowParallel(context)) {
      ref.read(selectedSeekingProvider.notifier).selectProfile(username);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => UserProfilePage(username: username)),
    );
  }

  bool _canShowParallel(BuildContext context) =>
      MasterDetailLayout.canShowBothPanesFor(
        context,
        masterWidth: _parallelMasterWidth,
        minDetailWidth: _parallelMinDetailWidth,
      );

  Key _paneKey(PaneEntry entry) => ValueKey(
    'seeking_pane_${entry.kind}_'
    '${entry.instanceId ?? entry.username ?? entry.topicId}',
  );

  @override
  Widget build(BuildContext context) {
    // 底栏会保活所有已配置页面。追觅后台轮询更新 refreshing / profiles / data
    // 时，隐藏页面若仍订阅 Provider，会在其他页面操作期间反复重建列表。
    // 非激活状态只初始化后台监控，不订阅状态；切回本页时再恢复订阅
    // 和完整界面。read 不会让隐藏页面随轮询结果反复重建。
    if (!widget.isActive) {
      ref.read(seekingProvider);
      return const SizedBox.shrink();
    }

    final enabled = ref.watch(seekingProvider.select((value) => value.enabled));
    final users = ref.watch(seekingProvider.select((value) => value.users));
    final holdUntil = ref.watch(
      seekingProvider.select((value) => value.holdUntil),
    );
    final paceSeconds = ref.watch(
      seekingProvider.select((value) => value.paceSeconds),
    );
    final l10n = context.l10n;

    final page = Scaffold(
      appBar: AppBar(
        title: Text(l10n.seeking_title),
        actions: [
          IconButton(
            tooltip: l10n.seeking_syncFollow,
            icon: const Icon(Symbols.group_add_rounded),
            onPressed: _syncFollowing,
          ),
          IconButton(
            tooltip: l10n.seeking_addUser,
            icon: const Icon(Symbols.person_add_rounded),
            onPressed: _showAddUserDialog,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Switch(
              value: enabled,
              onChanged: (v) =>
                  ref.read(seekingProvider.notifier).setEnabled(v),
            ),
          ),
        ],
      ),
      body: users.isEmpty
          ? _EmptyHint(onAdd: _showAddUserDialog, onSync: _syncFollowing)
          : Column(
              children: [
                if (holdUntil != null)
                  MaterialBanner(
                    content: Text(l10n.seeking_rateLimited),
                    leading: const Icon(Symbols.hourglass_top_rounded),
                    actions: const [SizedBox.shrink()],
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 780;
                      final activityPane = _SeekingActivityPane(
                        focusUser: _focusUser,
                        onOpenActivity: _openActivity,
                        onOpenProfile: _openProfile,
                      );
                      if (!wide) {
                        return Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                              child: _PaceSelector(
                                paceSeconds: paceSeconds,
                                onChanged: (seconds) => ref
                                    .read(seekingProvider.notifier)
                                    .setPaceSeconds(seconds),
                              ),
                            ),
                            SizedBox(
                              height: 76,
                              child: _buildUserList(compact: true),
                            ),
                            const Divider(height: 1),
                            Expanded(child: activityPane),
                          ],
                        );
                      }

                      // 宽屏复用项目统一的平行视界布局，名单栏支持拖动调宽。
                      return MasterDetailLayout(
                        masterWidth: 300,
                        minDetailWidth: 480,
                        master: Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: _PaceSelector(
                                paceSeconds: paceSeconds,
                                onChanged: (seconds) => ref
                                    .read(seekingProvider.notifier)
                                    .setPaceSeconds(seconds),
                              ),
                            ),
                            const Divider(height: 1),
                            Expanded(child: _buildUserList(compact: false)),
                          ],
                        ),
                        detail: activityPane,
                      );
                    },
                  ),
                ),
              ],
            ),
    );

    final selected = ref.watch(selectedSeekingProvider);
    // ESC:栈非空(右栏开着/投影着)都让分发落 detail scope。
    _escBinding.sync(context, paneOpen: selected.hasSelection);
    // 栈空:本页原样(宽屏内部自带名单/时间线双栏)。返回链 scope 常挂,
    // 树形稳定(选中/清空只在 scope 之下换分支)。
    if (!selected.hasSelection) {
      return PaneProjectionBackScope(
        stackProvider: selectedSeekingProvider,
        isActive: widget.isActive,
        masterWidth: _parallelMasterWidth,
        minDetailWidth: _parallelMinDetailWidth,
        child: page,
      );
    }

    final notifier = ref.read(selectedSeekingProvider.notifier);
    // 窄屏栈非空 = 投影态:详情在本页体内全宽顶替(不 push 合成路由,
    // 宽窄切换 State 原地保留),返回/预测返回由 scope 统一接管。
    // 胶片带:本页列表格是 page(内部自带名单/时间线双栏),压栈时被
    // 顶出左侧,倒二层格作预览(格子恒驻 State 全保)。
    return PaneProjectionBackScope(
      stackProvider: selectedSeekingProvider,
      isActive: widget.isActive,
      masterWidth: _parallelMasterWidth,
      minDetailWidth: _parallelMinDetailWidth,
      child: MasterDetailLayout(
        masterWidth: _parallelMasterWidth,
        minDetailWidth: _parallelMinDetailWidth,
        // 与搜索页同语义:列表态初始=masterWidth,压栈才对半分(旧的
        // min 0.32/preferred 0.4 让初始占四成屏宽,与其他双栏页不一致)。
        maxMasterRatio: selected.isStacked ? 0.8 : 0.52,
        preferredMasterRatio: selected.isStacked ? 0.5 : null,
        projectDetailWhenNarrow: true,
        pinMaster: false,
        master: page,
        panes: [
          for (var i = 0; i < selected.stack.length; i++)
            KeyedSubtree(
              key: _paneKey(selected.stack[i]),
              child: PaneContentWidget(
                entry: selected.stack[i],
                stackProvider: selectedSeekingProvider,
                parentActive: widget.isActive,
                truncateOnPush: i < selected.stack.length - 1,
                // 回调内重读 provider,不闭包捕获 build 时的快照。
                onBack: () {
                  if (ref.read(selectedSeekingProvider).isStacked) {
                    notifier.pop();
                  } else {
                    notifier.clear();
                  }
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildUserList({required bool compact}) {
    return Consumer(
      builder: (context, ref, _) {
        final users = ref.watch(seekingProvider.select((value) => value.users));
        final profiles = ref.watch(
          seekingProvider.select((value) => value.profiles),
        );
        final unread = ref.watch(
          seekingProvider.select((value) => value.unread),
        );
        final refreshing = ref.watch(
          seekingProvider.select((value) => value.refreshing),
        );
        final totalUnread = unread.values.fold<int>(
          0,
          (sum, value) => sum + value,
        );
        return ListView.builder(
          scrollDirection: compact ? Axis.horizontal : Axis.vertical,
          padding: compact
              ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
              : const EdgeInsets.symmetric(vertical: 8),
          itemCount: users.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return _AllUsersChip(
                compact: compact,
                focused: _focusUser == null,
                unread: totalUnread,
                onTap: () => setState(() => _focusUser = null),
              );
            }
            final username = users[index - 1];
            return _UserChip(
              username: username,
              profile: profiles[username],
              unread: unread[username] ?? 0,
              refreshing: refreshing == username,
              focused: _focusUser == username,
              compact: compact,
              onTap: () => setState(() {
                _focusUser = _focusUser == username ? null : username;
              }),
              onRemove: () =>
                  ref.read(seekingProvider.notifier).removeUser(username),
            );
          },
        );
      },
    );
  }
}

class _SeekingActivityPane extends ConsumerWidget {
  const _SeekingActivityPane({
    required this.focusUser,
    required this.onOpenActivity,
    required this.onOpenProfile,
  });

  final String? focusUser;
  final ValueChanged<SeekingActivity> onOpenActivity;
  final ValueChanged<String> onOpenProfile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(seekingProvider.select((value) => value.enabled));
    final data = ref.watch(seekingProvider.select((value) => value.data));
    final profiles = ref.watch(
      seekingProvider.select((value) => value.profiles),
    );
    final timeline = focusUser == null
        ? SeekingState(data: data).timeline
        : (data[focusUser] ?? const <SeekingActivity>[]);
    final theme = Theme.of(context);
    if (timeline.isEmpty) {
      return Center(
        child: Text(
          enabled
              ? context.l10n.seeking_waitingData
              : context.l10n.seeking_disabledHint,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: timeline.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final activity = timeline[index];
        return _ActivityTile(
          key: ValueKey('${activity.username}:${activity.uid}'),
          activity: activity,
          showAvatar: focusUser == null,
          avatarUrl: profiles[activity.username]?.getAvatarUrl() ?? '',
          onTap: () => onOpenActivity(activity),
          onOpenProfile: () => onOpenProfile(activity.username),
        );
      },
    );
  }
}

class _PaceSelector extends StatelessWidget {
  const _PaceSelector({required this.paceSeconds, required this.onChanged});

  final int paceSeconds;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      children: [
        Text(l10n.seeking_paceTitle),
        const SizedBox(width: 10),
        Expanded(
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: 10, label: Text(l10n.seeking_paceHigh)),
              ButtonSegment(value: 30, label: Text(l10n.seeking_paceMedium)),
              ButtonSegment(value: 60, label: Text(l10n.seeking_paceLow)),
            ],
            selected: {paceSeconds},
            onSelectionChanged: (selection) => onChanged(selection.first),
          ),
        ),
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.onAdd, required this.onSync});

  final VoidCallback onAdd;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Symbols.visibility_rounded,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            context.l10n.seeking_emptyHint,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.tonalIcon(
                onPressed: onAdd,
                icon: const Icon(Symbols.person_add_rounded, size: 18),
                label: Text(context.l10n.seeking_addUser),
              ),
              const SizedBox(width: 12),
              FilledButton.tonalIcon(
                onPressed: onSync,
                icon: const Icon(Symbols.group_add_rounded, size: 18),
                label: Text(context.l10n.seeking_syncFollow),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _UserChip extends StatelessWidget {
  const _UserChip({
    required this.username,
    required this.profile,
    required this.unread,
    required this.refreshing,
    required this.focused,
    required this.compact,
    required this.onTap,
    required this.onRemove,
  });

  final String username;
  final SeekingUserProfile? profile;
  final int unread;
  final bool refreshing;
  final bool focused;
  final bool compact;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avatarUrl = profile?.getAvatarUrl() ?? '';
    return Padding(
      padding: compact
          ? const EdgeInsets.only(right: 10)
          : const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        onLongPress: () => showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(ctx.l10n.seeking_removeUser),
            content: Text('@$username'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(ctx.l10n.common_cancel),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  onRemove();
                },
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                ),
                child: Text(ctx.l10n.common_delete),
              ),
            ],
          ),
        ),
        child: Container(
          padding: compact
              ? const EdgeInsets.symmetric(horizontal: 6, vertical: 4)
              : const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: focused
              ? BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withValues(
                    alpha: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(10),
                )
              : null,
          child: compact
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _UserAvatar(
                      avatarUrl: avatarUrl,
                      username: username,
                      unread: unread,
                      refreshing: refreshing,
                    ),
                    const SizedBox(height: 3),
                    SizedBox(
                      width: 52,
                      child: Text(
                        username,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    _UserAvatar(
                      avatarUrl: avatarUrl,
                      username: username,
                      unread: unread,
                      refreshing: refreshing,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        username,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: focused
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: context.l10n.seeking_removeUser,
                      icon: const Icon(Symbols.close_rounded, size: 18),
                      onPressed: onRemove,
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _AllUsersChip extends StatelessWidget {
  const _AllUsersChip({
    required this.compact,
    required this.focused,
    required this.unread,
    required this.onTap,
  });

  final bool compact;
  final bool focused;
  final int unread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: theme.colorScheme.secondaryContainer,
          child: Icon(
            Symbols.groups_rounded,
            size: 18,
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
        if (unread > 0)
          Positioned(
            right: -4,
            top: -4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.error,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                unread > 99 ? '99+' : '$unread',
                style: TextStyle(fontSize: 9, color: theme.colorScheme.onError),
              ),
            ),
          ),
      ],
    );
    return Padding(
      padding: compact
          ? const EdgeInsets.only(right: 10)
          : const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: compact
              ? const EdgeInsets.symmetric(horizontal: 6, vertical: 4)
              : const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: focused
              ? BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withValues(
                    alpha: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(10),
                )
              : null,
          child: compact
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    icon,
                    const SizedBox(height: 3),
                    SizedBox(
                      width: 52,
                      child: Text(
                        context.l10n.common_all,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    icon,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        context.l10n.common_all,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: focused
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _UserAvatar extends StatelessWidget {
  const _UserAvatar({
    required this.avatarUrl,
    required this.username,
    required this.unread,
    required this.refreshing,
  });

  final String avatarUrl;
  final String username;
  final int unread;
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        SmartAvatar(imageUrl: avatarUrl, radius: 16, fallbackText: username),
        if (unread > 0)
          Positioned(
            right: -4,
            top: -4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.error,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                unread > 99 ? '99+' : '$unread',
                style: TextStyle(fontSize: 9, color: theme.colorScheme.onError),
              ),
            ),
          ),
        if (refreshing)
          const Positioned(
            right: -2,
            bottom: -2,
            child: SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
          ),
      ],
    );
  }
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({
    super.key,
    required this.activity,
    required this.showAvatar,
    required this.avatarUrl,
    required this.onTap,
    required this.onOpenProfile,
  });

  final SeekingActivity activity;
  final bool showAvatar;
  final String avatarUrl;
  final VoidCallback onTap;
  final VoidCallback onOpenProfile;

  (IconData, Color) _typeIcon(ThemeData theme) {
    return switch (activity.type) {
      SeekingActivityType.post => (
        Symbols.edit_note_rounded,
        theme.colorScheme.primary,
      ),
      SeekingActivityType.reply => (
        Symbols.reply_rounded,
        theme.colorScheme.tertiary,
      ),
      SeekingActivityType.like => (
        Symbols.favorite_rounded,
        theme.colorScheme.error,
      ),
      SeekingActivityType.reaction => (
        Symbols.add_reaction_rounded,
        theme.colorScheme.secondary,
      ),
      SeekingActivityType.boost => (
        Symbols.rocket_launch_rounded,
        theme.colorScheme.tertiary,
      ),
    };
  }

  String _typeLabel(BuildContext context) {
    final l10n = context.l10n;
    return switch (activity.type) {
      SeekingActivityType.post => l10n.seeking_typePost,
      SeekingActivityType.reply => l10n.seeking_typeReply,
      SeekingActivityType.like => l10n.seeking_typeLike,
      SeekingActivityType.reaction => l10n.seeking_typeReaction,
      SeekingActivityType.boost => l10n.seeking_typeBoost,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color) = _typeIcon(theme);
    final excerpt = activity.excerpt?.trim() ?? '';
    return ListTile(
      dense: true,
      leading: showAvatar
          ? Stack(
              clipBehavior: Clip.none,
              children: [
                SmartAvatar(
                  imageUrl: avatarUrl,
                  radius: 16,
                  fallbackText: activity.username,
                ),
                Positioned(
                  right: -4,
                  bottom: -4,
                  child: CircleAvatar(
                    radius: 8,
                    backgroundColor: theme.colorScheme.surface,
                    child: Icon(icon, color: color, size: 11),
                  ),
                ),
              ],
            )
          : Icon(icon, color: color, size: 20),
      title: Row(
        children: [
          Flexible(
            child: GestureDetector(
              onTap: onOpenProfile,
              child: Text(
                activity.username,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            _typeLabel(context),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      trailing: SizedBox(
        width: 76,
        child: Text(
          TimeUtils.formatRelativeTime(activity.createdAt),
          maxLines: 1,
          textAlign: TextAlign.right,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (activity.title.isNotEmpty)
            Text(
              activity.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          if (excerpt.isNotEmpty)
            CollapsedHtmlContent(
              html: excerpt,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textStyle: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
        ],
      ),
      onTap: onTap,
    );
  }
}
