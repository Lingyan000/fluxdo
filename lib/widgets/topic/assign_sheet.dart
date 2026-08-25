import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../models/assignment.dart';
import '../../models/mention_user.dart';
import '../../models/topic.dart';
import '../../providers/core_providers.dart';
import '../../providers/topic_detail_provider.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';
import '../common/smart_avatar.dart';
import '../markdown_editor/markdown_editor.dart';
import '../../services/preloaded_data_service.dart';

/// 状态下拉的可选值——assign_statuses 是 client:true 的站点设置,
/// 随预加载 siteSettings 下发(官方 Web 端就是读
/// siteSettings.assign_statuses.split("|")),这里同源读取,不硬编码。
/// enable_assign_status 关闭时官方不显示状态下拉,同样照做。
List<String> get _assignStatusOptions =>
    PreloadedDataService().assignStatuses;

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
  await showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
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
  final result = await showDialog<_AssignDialogResult>(
    context: context,
    builder: (ctx) => _AssignDetailsDialog(
      presetUser: current?.assignedToUser,
      presetGroupName: current?.assignedToGroupName,
      initialNote: current?.note,
      initialStatus: current?.status,
      onSearch: (term) =>
          ref.read(discourseServiceProvider).searchUsers(term: term),
    ),
  );
  if (result == null) return;
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
    ToastService.showSuccess('已指定');
  } catch (e) {
    ToastService.showError('操作失败: $e');
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
    ToastService.showSuccess('已取消指定');
  } catch (e) {
    ToastService.showError('操作失败: $e');
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
  bool _busy = false;
  AssignSuggestions? _suggestions;
  bool _loadingSuggestions = true;

  @override
  void initState() {
    super.initState();
    _loadSuggestions();
  }

  Future<void> _loadSuggestions() async {
    try {
      final result = await ref
          .read(discourseServiceProvider)
          .fetchAssignSuggestions();
      if (mounted) setState(() => _suggestions = result);
    } catch (e) {
      // 候选列表拉不到不影响手动输入用户名指定,静默失败即可
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
    ref.invalidate(topicDetailProvider(params));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) ToastService.showError('操作失败: $e');
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
      ToastService.showSuccess('已指定给自己');
    });
  }

  Future<void> _unassign() async {
    await _run(() async {
      await ref
          .read(discourseServiceProvider)
          .unassignTarget(targetId: widget.topicId);
      _refetch();
      if (mounted) Navigator.of(context).pop();
      ToastService.showSuccess('已取消指定');
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
      ToastService.showSuccess('已指定给 ${user.displayName}');
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
      ToastService.showSuccess('已指定给群组 $groupName');
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
    final result = await showDialog<_AssignDialogResult>(
      context: context,
      builder: (ctx) => _AssignDetailsDialog(
        presetUser: presetUser,
        presetGroupName: presetGroupName,
        initialNote: initialNote,
        initialStatus: initialStatus,
        onSearch: (term) =>
            ref.read(discourseServiceProvider).searchUsers(term: term),
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
    final scheme = Theme.of(context).colorScheme;

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

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(Icons.assignment_ind_outlined, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text('指定', style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (detail.isAssigned)
              ListTile(
                leading: detail.assignedToUser != null
                    ? SmartAvatar(
                        imageUrl: detail.assignedToUser!.getAvatarUrl(),
                        radius: 16,
                        fallbackText: detail.assignedToUser!.displayName,
                      )
                    : CircleAvatar(
                        radius: 16,
                        backgroundColor: scheme.secondaryContainer,
                        child: const Icon(Icons.group_rounded),
                      ),
                title: Text(
                  detail.assignedToUser?.displayName ??
                      detail.assignedToGroupName ??
                      '',
                ),
                subtitle: (detail.assignmentNote?.isNotEmpty ?? false)
                    ? Text(detail.assignmentNote!)
                    : (detail.assignmentStatus?.isNotEmpty ?? false)
                    ? Text(detail.assignmentStatus!)
                    : null,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      tooltip: '编辑备注/状态',
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
                      child: const Text('取消指定'),
                    ),
                  ],
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('尚未指定给任何人', style: TextStyle(color: Colors.grey)),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.person_pin_circle_outlined),
              title: const Text('指定给我'),
              enabled: !_busy,
              onTap: _assignToMe,
            ),
            ListTile(
              leading: const Icon(Icons.person_add_alt_outlined),
              title: const Text('指定给其他用户…'),
              enabled: !_busy,
              onTap: () => _showAssignDetailsDialog(),
            ),
            if (_loadingSuggestions)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: LoadingSpinner(size: 20)),
              )
            else if (_suggestions != null &&
                _suggestions!.suggestions.isNotEmpty)
              SizedBox(
                height: 48,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: _suggestions!.suggestions.length,
                  itemBuilder: (context, index) {
                    final user = _suggestions!.suggestions[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: _busy ? null : () => _assignToUser(user),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: SmartAvatar(
                            imageUrl: user.getAvatarUrl(),
                            radius: 16,
                            fallbackText: user.displayName,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (_suggestions != null &&
                _suggestions!.assignAllowedForGroups.isNotEmpty) ...[
              const Divider(height: 1),
              // assignAllowedGroups(assign_allowed_on_groups)是全站配置成
              // "可被指定"的群组名单,不代表当前用户有权把话题指定给它们——
              // 真正代表"我有权指定给这个群组"的是 assign_allowed_for_groups
              // (插件 AssignController#suggestions 里 Group.assignable(current_user)
              // 算出来的),之前两个字段用反了,导致列出了一堆用户实际上
              // 没权限指定的群组,点了就等 403。
              for (final group in _suggestions!.assignAllowedForGroups)
                ListTile(
                  leading: const Icon(Icons.group_outlined),
                  title: Text('指定给群组 $group'),
                  enabled: !_busy,
                  onTap: () => _assignToGroup(group),
                ),
            ],
          ],
        ),
      ),
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

  bool get _isEditMode =>
      widget.presetUser != null || widget.presetGroupName != null;

  @override
  void initState() {
    super.initState();
    _selectedUser = widget.presetUser;
    _noteText = widget.initialNote ?? '';
    _status = widget.initialStatus;
  }

  /// 备注跟标准的发帖编辑器一样全屏打开(工具栏/表情/@提及等全功能),
  /// 不是这个对话框自己糊一个阉割版单行/多行输入框——备注最终原样存成
  /// small_action 帖的正文(见 lib/assigner.rb add_small_action_post),
  /// 官方 Web 端编辑它用的就是标准帖子编辑器。
  Future<void> _editNote() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _AssignNoteEditorPage(initialText: _noteText),
        fullscreenDialog: true,
      ),
    );
    if (result != null && mounted) setState(() => _noteText = result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(_isEditMode ? '编辑指定' : '指定给用户'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_isEditMode)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    SmartAvatar(
                      imageUrl: widget.presetUser?.getAvatarUrl(),
                      radius: 14,
                      fallbackText:
                          widget.presetUser?.displayName ??
                          widget.presetGroupName,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.presetUser?.displayName ??
                          widget.presetGroupName ??
                          '',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              )
            else ...[
              // Autocomplete 自带浮层下拉(CompositedTransformFollower),
              // 候选列表在对话框上层飘着,不会撑大/顶变对话框本身的布局——
              // 之前手写的 TextField+内联 ListView 会跟着结果数量抻高对话
              // 框,视觉上很抽象。
              Autocomplete<MentionUser>(
                displayStringForOption: (u) => u.name ?? u.username,
                optionsBuilder: (value) async {
                  final term = value.text.trim();
                  if (term.isEmpty) return const Iterable<MentionUser>.empty();
                  final result = await widget.onSearch(term);
                  return result.users;
                },
                fieldViewBuilder: (context, controller, focusNode, onSubmit) {
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '受理人',
                      hintText: '搜索用户名/昵称',
                      suffixIcon: Icon(Icons.search_rounded),
                    ),
                  );
                },
                optionsViewBuilder: (context, onSelected, options) {
                  final list = options.toList();
                  return Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(8),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxHeight: 240,
                          maxWidth: 320,
                        ),
                        child: ListView.builder(
                          padding: EdgeInsets.zero,
                          shrinkWrap: true,
                          itemCount: list.length,
                          itemBuilder: (context, index) {
                            final u = list[index];
                            return ListTile(
                              dense: true,
                              leading: SmartAvatar(
                                imageUrl: u.getAvatarUrl(''),
                                radius: 14,
                                fallbackText: u.name ?? u.username,
                              ),
                              title: Text(u.name ?? u.username),
                              subtitle: Text('@${u.username}'),
                              onTap: () => onSelected(u),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
                onSelected: (u) {
                  setState(() {
                    _selectedUser = TopicUser(
                      id: -1,
                      username: u.username,
                      name: u.name,
                      avatarTemplate: u.avatarTemplate ?? '',
                    );
                  });
                },
              ),
              const SizedBox(height: 8),
            ],
            if (_assignStatusEnabled) ...[
              DropdownButtonFormField<String>(
                initialValue: _status,
                decoration: const InputDecoration(labelText: '状态(可选)'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('不设置')),
                  // 现有指定的状态值可能已被站点从配置里删掉——仍要出现在
                  // 列表里,否则 Dropdown 对不上 value 直接断言崩溃。
                  if (_status != null &&
                      !_assignStatusOptions.contains(_status))
                    DropdownMenuItem(value: _status, child: Text(_status!)),
                  ..._assignStatusOptions.map(
                    (s) => DropdownMenuItem(value: s, child: Text(s)),
                  ),
                ],
                onChanged: (v) => setState(() => _status = v),
              ),
              const SizedBox(height: 8),
            ],
            InkWell(
              onTap: _editNote,
              borderRadius: BorderRadius.circular(4),
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: '备注(可选)',
                  border: OutlineInputBorder(),
                  suffixIcon: Icon(Icons.edit_note_rounded),
                ),
                child: Text(
                  _noteText.isEmpty ? '点击用编辑器填写' : _noteText,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: _noteText.isEmpty
                      ? theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        )
                      : theme.textTheme.bodyMedium,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
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
            if (!_isEditMode && result.user == null) {
              ToastService.showError('请先从搜索结果里选择一个用户');
              return;
            }
            Navigator.of(context).pop(result);
          },
          child: const Text('指定'),
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
        title: const Text('编辑备注'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_controller.text),
            child: const Text('完成'),
          ),
        ],
      ),
      body: SafeArea(
        child: MarkdownEditor(
          controller: _controller,
          hintText: '指定备注',
          expands: true,
        ),
      ),
    );
  }
}
