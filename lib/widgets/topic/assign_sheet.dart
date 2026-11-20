import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../models/assignment.dart';
import '../../models/mention_user.dart';
import '../../models/topic.dart';
import '../../providers/core_providers.dart';
import '../../providers/topic_detail_provider.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';
import '../common/app_bottom_sheet.dart';
import '../common/smart_avatar.dart';
import '../markdown_editor/markdown_editor.dart';
import '../../services/preloaded_data_service.dart';

/// 状态下拉的可选值——assign_statuses 是 client:true 的站点设置,
/// 随预加载 siteSettings 下发(官方 Web 端就是读
/// siteSettings.assign_statuses.split("|")),这里同源读取,不硬编码。
/// enable_assign_status 关闭时官方不显示状态下拉,同样照做。
List<String> get _assignStatusOptions => PreloadedDataService().assignStatuses;

bool get _assignStatusEnabled =>
    PreloadedDataService().assignStatusEnabled &&
    _assignStatusOptions.isNotEmpty;

/// _AssignDetailsDialog 的返回值:受理人(二选一)+ 备注 + 状态。
class _AssignDialogResult {
  final TopicUser? user;
  final String? groupName;
  final String? note;
  final String? status;

  const _AssignDialogResult({
    this.user,
    this.groupName,
    this.note,
    this.status,
  });
}

/// 指定(discourse-assign 插件)管理弹窗:查看当前指定对象/备注,
/// 指定给我/他人/群组,编辑备注状态,取消指定——对齐插件官方 API
/// (`/assign/assign`、`/assign/unassign`、`/assign/suggestions`,
/// `/assign/claim/:topic_id`)。
Future<void> showAssignSheet(
  BuildContext context,
  WidgetRef ref, {
  required int topicId,
}) async {
  await AppBottomSheet.show<void>(
    context: context,
    title: context.l10n.topicAssign_title,
    builder: (ctx) => _AssignSheet(topicId: topicId),
  );
}

/// 帖子级指定(target_type='Post')——插件的 indirectly_assigned_to
/// 字段对应的就是这个,跟话题级指定(target_type='Topic')是两回事,
/// 但复用同一套"受理人搜索+状态+备注"对话框。
Future<void> showPostAssignDialog(
  BuildContext context,
  WidgetRef ref, {
  required int topicId,
  required int postId,
  PostAssignmentInfo? current,
}) async {
  final result = await showAppDialog<_AssignDialogResult>(
    context: context,
    builder: (ctx) => _AssignDetailsDialog(
      presetUser: current?.assignedToUser,
      presetGroupName: current?.assignedToGroupName,
      initialNote: current?.note,
      initialStatus: current?.status,
      onSearch: (term) => ref
          .read(discourseServiceProvider)
          .searchUsers(term: term, includeGroups: false, throwOnError: true),
    ),
  );
  if (result == null || !context.mounted) return;
  final service = ref.read(discourseServiceProvider);
  try {
    if (result.groupName != null) {
      await service.assignTarget(
        targetId: postId,
        targetType: 'Post',
        groupName: result.groupName,
        note: result.note,
        status: result.status,
      );
    } else if (result.user != null) {
      await service.assignTarget(
        targetId: postId,
        targetType: 'Post',
        username: result.user!.username,
        note: result.note,
        status: result.status,
      );
    } else {
      return;
    }
    _refetchTopic(ref, topicId);
    ToastService.showSuccess(S.current.topicAssign_success);
  } catch (e) {
    ToastService.showError(S.current.common_operationFailed(e.toString()));
  }
}

/// 取消帖子级指定。
Future<void> unassignPost(
  WidgetRef ref, {
  required int topicId,
  required int postId,
}) async {
  try {
    await ref
        .read(discourseServiceProvider)
        .unassignTarget(targetId: postId, targetType: 'Post');
    _refetchTopic(ref, topicId);
    ToastService.showSuccess(S.current.topicAssign_unassignSuccess);
  } catch (e) {
    ToastService.showError(S.current.common_operationFailed(e.toString()));
  }
}

void _refetchTopic(WidgetRef ref, int topicId) {
  final params = TopicDetailNotifier.activeParamsFor(topicId);
  if (params == null) return;
  ref.invalidate(topicDetailProvider(params));
}

class _AssignSheet extends ConsumerStatefulWidget {
  const _AssignSheet({required this.topicId});

  final int topicId;

  @override
  ConsumerState<_AssignSheet> createState() => _AssignSheetState();
}

class _AssignSheetState extends ConsumerState<_AssignSheet> {
  late final ProviderContainer _container;
  bool _busy = false;
  AssignSuggestions? _suggestions;
  bool _loadingSuggestions = true;
  bool _suggestionsFailed = false;

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
    _loadSuggestions();
  }

  Future<void> _loadSuggestions() async {
    setState(() {
      _loadingSuggestions = true;
      _suggestionsFailed = false;
    });
    try {
      final result = await ref
          .read(discourseServiceProvider)
          .fetchAssignSuggestions();
      if (mounted) setState(() => _suggestions = result);
    } catch (_) {
      if (mounted) setState(() => _suggestionsFailed = true);
    } finally {
      if (mounted) setState(() => _loadingSuggestions = false);
    }
  }

  // 深层组件只知道 topicId,不知道页面实例的 instanceId——凭空 new 一个
  // 默认 params 会创建/命中一个孤儿 provider,更新落不到正在显示的那份
  // 数据上(同类坑见 topic_detail_provider.dart 里 _updatePostById 的
  // 注释)。走活跃实例注册表找回真实 params。
  //
  // 操作成功后直接让 provider 重新拉取整个话题,而不是本地拼一份"我以为
  // 长这样"的 assigned_to_user/assigned_to_group——插件字段的实际形状
  // 没有实测样本核对过,之前就因为拼错导致类型转换崩溃过一次;重新拉取
  // 权威、慢一点但不会看着"指定成功"实际上数据是错的。
  void _refetch() {
    final params = TopicDetailNotifier.activeParamsFor(widget.topicId);
    if (params == null) return;
    // 请求完成前可能已关闭弹层，继续刷新话题时使用所属容器。
    _container.invalidate(topicDetailProvider(params));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ToastService.showError(
          context.l10n.common_operationFailed(e.toString()),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _assignToMe() async {
    final me = ref.read(currentUserProvider).value;
    if (me == null) return;
    await _run(() async {
      // 插件 config/routes.rb 里的 PUT /assign/claim/:topic_id 是条死路由——
      // 对应的 AssignController#claim 在当前版本源码里根本不存在(只有
      // suggestions/unassign/assign/assigned/group_members 五个 action),
      // 实测直接 404。"指定给我"本质就是把 username 传成自己,走标准的
      // assign 接口即可,没必要依赖这条已经不存在的快捷路由。
      await ref
          .read(discourseServiceProvider)
          .assignTarget(targetId: widget.topicId, username: me.username);
      _refetch();
      if (mounted) Navigator.of(context).pop();
      ToastService.showSuccess(S.current.topicAssign_selfSuccess);
    });
  }

  Future<void> _unassign() async {
    await _run(() async {
      await ref
          .read(discourseServiceProvider)
          .unassignTarget(targetId: widget.topicId);
      _refetch();
      if (mounted) Navigator.of(context).pop();
      ToastService.showSuccess(S.current.topicAssign_unassignSuccess);
    });
  }

  Future<void> _assignToUser(
    TopicUser user, {
    String? note,
    String? status,
  }) async {
    await _run(() async {
      await ref
          .read(discourseServiceProvider)
          .assignTarget(
            targetId: widget.topicId,
            username: user.username,
            note: note,
            status: status,
          );
      _refetch();
      if (mounted) Navigator.of(context).pop();
      ToastService.showSuccess(
        S.current.topicAssign_assignedTo(user.displayName),
      );
    });
  }

  Future<void> _assignToGroup(
    String groupName, {
    String? note,
    String? status,
  }) async {
    await _run(() async {
      await ref
          .read(discourseServiceProvider)
          .assignTarget(
            targetId: widget.topicId,
            groupName: groupName,
            note: note,
            status: status,
          );
      _refetch();
      if (mounted) Navigator.of(context).pop();
      ToastService.showSuccess(S.current.topicAssign_groupSuccess(groupName));
    });
  }

  /// 弹出"受理人(可搜索)+ 状态 + 备注"完整对话框——对齐官方"指定帖子"
  /// 弹窗的三个字段。[presetUser]/[presetGroupName] 非空时表示编辑现有
  /// 指定(受理人锁定,只改备注/状态),否则展示用户搜索框重新选人。
  Future<void> _showAssignDetailsDialog({
    TopicUser? presetUser,
    String? presetGroupName,
    String? initialNote,
    String? initialStatus,
  }) async {
    final result = await showAppDialog<_AssignDialogResult>(
      context: context,
      builder: (ctx) => _AssignDetailsDialog(
        presetUser: presetUser,
        presetGroupName: presetGroupName,
        initialNote: initialNote,
        initialStatus: initialStatus,
        onSearch: (term) => ref
            .read(discourseServiceProvider)
            .searchUsers(term: term, includeGroups: false, throwOnError: true),
      ),
    );
    if (result == null || !mounted) return;
    if (result.groupName != null) {
      await _assignToGroup(
        result.groupName!,
        note: result.note,
        status: result.status,
      );
    } else if (result.user != null) {
      await _assignToUser(
        result.user!,
        note: result.note,
        status: result.status,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    // 不再吃调用方传进来的静态快照——那份数据在 sheet 开着的时候不会跟着
    // _refetch() 一起变,取消/重新指定后弹窗里显示的还是操作前的旧状态。
    // 直接 watch 当前话题正在用的 provider 实例,数据跟页面上的真实状态
    // 保持一致。
    final params = TopicDetailNotifier.activeParamsFor(widget.topicId);
    final detail = params == null
        ? null
        : ref.watch(topicDetailProvider(params)).value;
    if (detail == null) {
      return const SizedBox(
        height: 120,
        child: Center(child: LoadingSpinner(size: 24)),
      );
    }

    final users = _suggestions?.suggestions ?? const <TopicUser>[];
    // 只使用服务端返回的当前用户有权指定的群组。
    final groups = _suggestions?.assignAllowedForGroups ?? const <String>[];

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_busy) ...[const M3eLinearProgress(), const SizedBox(height: 12)],
          if (detail.isAssigned)
            SegmentedCardGroup(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.topicAssign_current,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _AssigneeIdentity(
                        user: detail.assignedToUser,
                        groupName: detail.assignedToGroupName,
                      ),
                      if (detail.assignmentStatus?.isNotEmpty ?? false) ...[
                        const SizedBox(height: 12),
                        Text(
                          detail.assignmentStatus!,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: context.emphasis.selected,
                          ),
                        ),
                      ],
                      if (detail.assignmentNote?.isNotEmpty ?? false) ...[
                        const SizedBox(height: 8),
                        Text(
                          detail.assignmentNote!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          OutlinedButton.icon(
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            label: Text(l10n.common_edit),
                            onPressed: _busy
                                ? null
                                : () => _showAssignDetailsDialog(
                                    presetUser: detail.assignedToUser,
                                    presetGroupName: detail.assignedToGroupName,
                                    initialNote: detail.assignmentNote,
                                    initialStatus: detail.assignmentStatus,
                                  ),
                          ),
                          TextButton(
                            onPressed: _busy ? null : _unassign,
                            child: Text(l10n.topicAssign_unassign),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
              child: Text(
                l10n.topicAssign_unassigned,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (detail.isAssigned) const SizedBox(height: 16),
          SegmentedCardGroup(
            children: [
              ListTile(
                leading: Icon(
                  Icons.person_pin_circle_outlined,
                  color: context.emphasis.accent,
                ),
                title: Text(l10n.topicAssign_toMe),
                enabled: !_busy,
                onTap: _assignToMe,
              ),
              ListTile(
                leading: const Icon(Icons.person_search_outlined),
                title: Text(l10n.topicAssign_toOther),
                trailing: const Icon(Icons.chevron_right_rounded),
                enabled: !_busy,
                onTap: () => _showAssignDetailsDialog(),
              ),
            ],
          ),
          if (_loadingSuggestions)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: LoadingSpinner(size: 24)),
            )
          else if (_suggestionsFailed)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextButton.icon(
                onPressed: _busy ? null : _loadSuggestions,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(l10n.common_loadFailedTapRetry),
              ),
            ),
          if (users.isNotEmpty) ...[
            _AssignSectionLabel(l10n.topicAssign_suggestions),
            SegmentedCardGroup(
              children: [
                for (final user in users)
                  ListTile(
                    title: _AssigneeIdentity(user: user),
                    enabled: !_busy,
                    onTap: () => _assignToUser(user),
                  ),
              ],
            ),
          ],
          if (groups.isNotEmpty) ...[
            _AssignSectionLabel(l10n.topicAssign_groups),
            SegmentedCardGroup(
              children: [
                for (final group in groups)
                  ListTile(
                    title: _AssigneeIdentity(groupName: group),
                    enabled: !_busy,
                    onTap: () => _assignToGroup(group),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _AssignSectionLabel extends StatelessWidget {
  const _AssignSectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}

/// 当前受理人和候选列表共用身份展示，长名称在可用宽度内换行。
class _AssigneeIdentity extends StatelessWidget {
  const _AssigneeIdentity({this.user, this.groupName});

  final TopicUser? user;
  final String? groupName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        if (user != null)
          SmartAvatar(
            imageUrl: user!.getAvatarUrl(),
            radius: 20,
            fallbackText: user!.displayName,
          )
        else
          Container(
            width: 40,
            height: 40,
            decoration: ShapeDecoration(
              color: theme.colorScheme.secondaryContainer,
              shape: context.shapes.circle(),
            ),
            child: Icon(
              Icons.group_outlined,
              size: 22,
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                user?.displayName ?? groupName ?? '',
                style: theme.textTheme.titleSmall,
              ),
              if (user != null)
                Text(
                  '@${user!.username}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "受理人(可搜索)+ 状态 + 备注"对话框——对齐 discourse-assign 官方
/// "指定帖子/话题"弹窗的三个字段。备注是多行的:插件把它原样存成
/// small_action 帖的正文(见 lib/assigner.rb add_small_action_post),
/// 官方 Web 端那边就是个支持多行/富文本的编辑器,单行输入框会把换行
/// 吞掉,对不上服务端实际存的内容。
class _AssignDetailsDialog extends StatefulWidget {
  const _AssignDetailsDialog({
    required this.onSearch,
    this.presetUser,
    this.presetGroupName,
    this.initialNote,
    this.initialStatus,
  });

  final Future<MentionSearchResult> Function(String term) onSearch;
  final TopicUser? presetUser;
  final String? presetGroupName;
  final String? initialNote;
  final String? initialStatus;

  @override
  State<_AssignDetailsDialog> createState() => _AssignDetailsDialogState();
}

class _AssignDetailsDialogState extends State<_AssignDetailsDialog> {
  late String _noteText;
  TopicUser? _selectedUser;
  String? _status;
  int _searchGeneration = 0;
  bool _searching = false;
  bool _searchFailed = false;
  bool _searchEmpty = false;

  bool get _isEditMode =>
      widget.presetUser != null || widget.presetGroupName != null;

  @override
  void initState() {
    super.initState();
    _selectedUser = widget.presetUser;
    _noteText = widget.initialNote ?? '';
    _status = widget.initialStatus;
  }

  Future<Iterable<MentionUser>> _searchUsers(TextEditingValue value) async {
    final term = value.text.trim();
    final generation = ++_searchGeneration;
    setState(() {
      _searching = term.isNotEmpty;
      _searchFailed = false;
      _searchEmpty = false;
    });
    if (term.isEmpty) return const [];

    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted || generation != _searchGeneration) return const [];
    try {
      final result = await widget.onSearch(term);
      if (!mounted || generation != _searchGeneration) return const [];
      setState(() {
        _searching = false;
        _searchEmpty = result.users.isEmpty;
      });
      return result.users;
    } catch (_) {
      if (mounted && generation == _searchGeneration) {
        setState(() {
          _searching = false;
          _searchFailed = true;
        });
      }
      return const [];
    }
  }

  /// 备注跟标准的发帖编辑器一样全屏打开(工具栏/表情/@提及等全功能),
  /// 不是这个对话框自己糊一个阉割版单行/多行输入框——备注最终原样存成
  /// small_action 帖的正文(见 lib/assigner.rb add_small_action_post),
  /// 官方 Web 端编辑它用的就是标准帖子编辑器。
  Future<void> _editNote() async {
    final result = await Navigator.of(context).push<String>(
      InteractionPageRoute(
        builder: (_) => _AssignNoteEditorPage(initialText: _noteText),
        fullscreenDialog: true,
      ),
    );
    if (result != null && mounted) setState(() => _noteText = result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(
        _isEditMode ? l10n.topicAssign_edit : l10n.topicAssign_toUser,
      ),
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_isEditMode)
              SegmentedCardGroup(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: _AssigneeIdentity(
                      user: widget.presetUser,
                      groupName: widget.presetGroupName,
                    ),
                  ),
                ],
              )
            else ...[
              Text(
                l10n.topicAssign_assignee,
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              Autocomplete<MentionUser>(
                displayStringForOption: (u) =>
                    (u.name?.isNotEmpty ?? false) ? u.name! : u.username,
                optionsBuilder: _searchUsers,
                optionsViewOpenDirection: OptionsViewOpenDirection.mostSpace,
                fieldViewBuilder: (context, controller, focusNode, onSubmit) {
                  return InputFieldShell(
                    hasError: _searchFailed,
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => onSubmit(),
                      onChanged: (_) => setState(() => _selectedUser = null),
                      decoration: InputDecoration(
                        hintText: l10n.topicAssign_searchHint,
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _searching
                            ? const Padding(
                                padding: EdgeInsets.all(14),
                                child: LoadingSpinner(size: 20),
                              )
                            : _selectedUser != null
                            ? Icon(
                                Icons.check_circle_rounded,
                                color: context.emphasis.selected,
                              )
                            : null,
                      ),
                    ),
                  );
                },
                optionsViewBuilder: (context, onSelected, options) {
                  final list = options.toList();
                  return Material(
                    elevation: 4,
                    color: theme.colorScheme.surfaceContainer,
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedSuperellipseBorder(
                      borderRadius: context.shapes.borderRadius(12),
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 240),
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          shrinkWrap: true,
                          itemCount: list.length,
                          itemBuilder: (context, index) {
                            final user = list[index];
                            return ListTile(
                              leading: SmartAvatar(
                                imageUrl: user.getAvatarUrl(''),
                                radius: 18,
                                fallbackText: user.username,
                              ),
                              title: Text(
                                (user.name?.isNotEmpty ?? false)
                                    ? user.name!
                                    : user.username,
                              ),
                              subtitle: Text('@${user.username}'),
                              selected:
                                  AutocompleteHighlightedOption.of(context) ==
                                  index,
                              onTap: () => onSelected(user),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
                onSelected: (user) {
                  ++_searchGeneration;
                  setState(() {
                    _searching = false;
                    _searchFailed = false;
                    _searchEmpty = false;
                    _selectedUser = TopicUser(
                      id: user.id ?? -1,
                      username: user.username,
                      name: user.name,
                      avatarTemplate: user.avatarTemplate ?? '',
                    );
                  });
                },
              ),
              if (_searchFailed || _searchEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      _searchFailed
                          ? l10n.common_loadFailedRetry
                          : l10n.search_noResults,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _searchFailed
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
            if (_assignStatusEnabled) ...[
              const SizedBox(height: 20),
              DropdownButtonFormField<String>(
                initialValue: _status,
                isExpanded: true,
                decoration: InputDecoration(labelText: l10n.topicAssign_status),
                items: [
                  DropdownMenuItem(
                    value: null,
                    child: Text(l10n.common_notSet),
                  ),
                  // 现有指定的状态值可能已被站点从配置里删掉——仍要出现在
                  // 列表里,否则 Dropdown 对不上 value 直接断言崩溃。
                  if (_status != null &&
                      !_assignStatusOptions.contains(_status))
                    DropdownMenuItem(
                      value: _status,
                      child: Text(_status!, overflow: TextOverflow.ellipsis),
                    ),
                  ..._assignStatusOptions.map(
                    (status) => DropdownMenuItem(
                      value: status,
                      child: Text(status, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
                onChanged: (v) => setState(() => _status = v),
              ),
            ],
            const SizedBox(height: 20),
            SegmentedCardGroup(
              children: [
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  title: Text(l10n.topicAssign_note),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _noteText.isEmpty ? l10n.topicAssign_noteHint : _noteText,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  trailing: const Icon(Icons.edit_note_rounded),
                  onTap: _editNote,
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(
          onPressed: !_isEditMode && _selectedUser == null
              ? null
              : () {
                  final note = _noteText.trim();
                  final result = _isEditMode
                      ? _AssignDialogResult(
                          user: widget.presetUser,
                          groupName: widget.presetGroupName,
                          note: note.isEmpty ? null : note,
                          status: _status,
                        )
                      : _AssignDialogResult(
                          user: _selectedUser,
                          note: note.isEmpty ? null : note,
                          status: _status,
                        );
                  Navigator.of(context).pop(result);
                },
          child: Text(_isEditMode ? l10n.common_save : l10n.topicAssign_title),
        ),
      ],
    );
  }
}

/// 备注全屏编辑页——跟发帖用的是同一个 [MarkdownEditor],工具栏/表情/
/// @提及等功能原样带上,不是阉割版。
class _AssignNoteEditorPage extends StatefulWidget {
  const _AssignNoteEditorPage({required this.initialText});

  final String initialText;

  @override
  State<_AssignNoteEditorPage> createState() => _AssignNoteEditorPageState();
}

class _AssignNoteEditorPageState extends State<_AssignNoteEditorPage> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.topicAssign_editNote),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: context.l10n.common_close,
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_controller.text),
            child: Text(context.l10n.common_done),
          ),
        ],
      ),
      body: SafeArea(
        child: MarkdownEditor(
          controller: _controller,
          hintText: context.l10n.topicAssign_notePlaceholder,
          expands: true,
          // 简短备注字段，不需要预览
          showPreviewButton: false,
        ),
      ),
    );
  }
}
