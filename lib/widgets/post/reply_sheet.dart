import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../markdown_editor/markdown_editor.dart';
import '../../models/topic.dart';
import '../../models/draft.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/presence_service.dart';
import '../../services/emoji_handler.dart';
import '../../services/draft_controller.dart';
import 'package:dio/dio.dart';
import '../../services/app_error_handler.dart';
import '../../services/network/exceptions/api_exception.dart';
import '../../services/toast_service.dart';
import '../../services/preloaded_data_service.dart';
import '../common/smart_avatar.dart';
import '../../l10n/s.dart';
import '../../utils/dialog_utils.dart';
import '../common/loading_spinner.dart';

/// 显示回复底部弹框
/// [topicId] 话题 ID (回复话题/帖子时必需)
/// [categoryId] 分类 ID（可选，用于用户搜索）
/// [replyToPost] 可选，被回复的帖子
/// [targetUsername] 可选，私信目标用户名 (创建私信时必需)
/// [preloadedDraftFuture] 预加载的草稿 Future（在点击回复按钮时就发起请求）
/// [initialContent] 可选，预填内容（划词引用时使用）
/// [initialTitle] 可选，预填标题（私信模式时使用）
/// 返回创建的 Post 对象，取消或失败返回 null
Future<Post?> showReplySheet({
  required BuildContext context,
  int? topicId,
  int? categoryId,
  Post? replyToPost,
  String? targetUsername,
  Future<Draft?>? preloadedDraftFuture,
  String? initialContent,
  String? initialTitle,
  bool isPrivateMessageTopic = false,
}) async {
  final result = await showAppBottomSheet<Post?>(
    context: context,
    isScrollControlled: true,
    useSafeArea: false,
    backgroundColor: Colors.transparent,
    builder: (context) => ReplySheet(
      topicId: topicId,
      categoryId: categoryId,
      replyToPost: replyToPost,
      targetUsername: targetUsername,
      preloadedDraftFuture: preloadedDraftFuture,
      initialContent: initialContent,
      initialTitle: initialTitle,
      isPrivateMessageTopic: isPrivateMessageTopic,
    ),
  );
  return result;
}

/// 显示编辑帖子底部弹框
/// [topicId] 话题 ID
/// [post] 要编辑的帖子
/// [categoryId] 分类 ID（可选，用于用户搜索）
/// 返回更新后的 Post 对象，取消或失败返回 null
Future<Post?> showEditSheet({
  required BuildContext context,
  required int topicId,
  required Post post,
  int? categoryId,
}) async {
  final result = await showAppBottomSheet<Post?>(
    context: context,
    isScrollControlled: true,
    useSafeArea: false,
    backgroundColor: Colors.transparent,
    builder: (context) => ReplySheet(
      topicId: topicId,
      categoryId: categoryId,
      editPost: post,
    ),
  );
  return result;
}

class ReplySheet extends ConsumerStatefulWidget {
  final int? topicId;
  final int? categoryId;
  final Post? replyToPost;
  final String? targetUsername;
  final Post? editPost; // 编辑模式：要编辑的帖子
  final Future<Draft?>? preloadedDraftFuture; // 预加载的草稿
  final String? initialContent; // 预填内容（划词引用时使用）
  final String? initialTitle; // 预填标题（私信模式时使用）
  final bool isPrivateMessageTopic; // 当前话题是否为私信话题

  const ReplySheet({
    super.key,
    this.topicId,
    this.categoryId,
    this.replyToPost,
    this.targetUsername,
    this.editPost,
    this.preloadedDraftFuture,
    this.initialContent,
    this.initialTitle,
    this.isPrivateMessageTopic = false,
  });

  @override
  ConsumerState<ReplySheet> createState() => _ReplySheetState();
}

class _ReplySheetState extends ConsumerState<ReplySheet> {
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _contentFocusNode = FocusNode();
  final _editorKey = GlobalKey<MarkdownEditorState>();

  bool _isSubmitting = false;
  bool _submitted = false; // 提交成功标志，防止 dispose 重新保存草稿
  bool _showEmojiPanel = false;
  bool _isLoadingRaw = false; // 编辑模式：加载原始内容中
  bool _isLoadingDraft = false; // 加载草稿中

  // 表情面板高度
  static const double _emojiPanelHeight = 280.0;

  // 草稿控制器（仅在回复话题或创建私信时使用，编辑模式不使用）
  DraftController? _draftController;

  // Presence 服务（正在输入状态）
  PresenceService? _presenceService;

  bool get _isPrivateMessage => widget.targetUsername != null;
  /// 是否在私信话题中（创建新私信 或 回复已有私信话题）
  bool get _isInPrivateMessageContext => _isPrivateMessage || widget.isPrivateMessageTopic;
  bool get _isEditMode => widget.editPost != null;

  @override
  void initState() {
    super.initState();
    EmojiHandler().init();

    // 编辑模式：加载帖子原始内容
    if (_isEditMode) {
      _loadPostRaw();
    } else {
      // 预填内容（划词引用）
      if (widget.initialContent != null && widget.initialContent!.isNotEmpty) {
        _contentController.text = widget.initialContent!;
        // 光标移到末尾
        _contentController.selection = TextSelection.fromPosition(
          TextPosition(offset: _contentController.text.length),
        );
      }
      // 预填标题（私信模式）
      if (widget.initialTitle != null && widget.initialTitle!.isNotEmpty) {
        _titleController.text = widget.initialTitle!;
      }
      // 非编辑模式：初始化草稿控制器并加载草稿
      _initDraftController();
    }

    // 初始化 Presence 服务（非私信场景、非编辑模式）
    if (!_isInPrivateMessageContext && !_isEditMode && widget.topicId != null) {
      _presenceService = PresenceService(DiscourseService());
      _presenceService!.enterReplyChannel(widget.topicId!);
    }

    // 添加内容变化监听以触发草稿自动保存
    _contentController.addListener(_onContentChanged);
    _titleController.addListener(_onContentChanged);

    // 自动聚焦（非编辑模式时立即聚焦，编辑模式在加载完成后聚焦）
    if (!_isEditMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isLoadingDraft) {
          _contentFocusNode.requestFocus();
        }
      });
    }
  }

  /// 初始化草稿控制器
  void _initDraftController() {
    String draftKey;
    if (_isPrivateMessage) {
      draftKey = Draft.newPrivateMessageKey;
    } else if (widget.topicId != null) {
      // 区分回复话题和回复帖子
      draftKey = Draft.replyKey(
        widget.topicId!,
        replyToPostNumber: widget.replyToPost?.postNumber,
      );
    } else {
      return;
    }

    _draftController = DraftController(draftKey: draftKey);
    _loadExistingDraft();
  }

  /// 加载现有草稿
  Future<void> _loadExistingDraft() async {
    setState(() => _isLoadingDraft = true);
    try {
      Draft? draft;
      if (widget.preloadedDraftFuture != null) {
        // 使用预加载的草稿（在点击回复按钮时就已发起请求）
        draft = await widget.preloadedDraftFuture;
        if (draft != null) {
          // 同步 DraftController 的序列号等状态
          _draftController?.syncFromPreloadedDraft(draft);
        }
      } else {
        // 没有预加载，正常加载
        draft = await _draftController?.loadDraft();
      }
      if (!mounted) return;

      if (draft != null && draft.hasContent) {
        // 回复模式直接恢复，不需要确认
        _restoreDraft(draft);
      }
    } finally {
      if (mounted) {
        setState(() => _isLoadingDraft = false);
        _contentFocusNode.requestFocus();
      }
    }
  }

  /// 舍弃草稿
  Future<void> _discardDraft() async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.post_discardTitle),
        content: Text(context.l10n.post_discardConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.common_discard),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      await _draftController?.deleteDraft();
      if (mounted) Navigator.of(context).pop();
    }
  }

  /// 恢复草稿内容
  void _restoreDraft(Draft draft) {
    if (draft.data.reply != null) {
      // 有预填内容时，将草稿追加到引用内容后面
      if (widget.initialContent != null && widget.initialContent!.isNotEmpty) {
        _contentController.text = '${widget.initialContent}${draft.data.reply}';
      } else {
        _contentController.text = draft.data.reply!;
      }
    }
    if (_isPrivateMessage && draft.data.title != null) {
      _titleController.text = draft.data.title!;
    }
  }

  /// 内容变化时触发草稿保存
  void _onContentChanged() {
    if (_isEditMode || _draftController == null) return;

    final data = DraftData(
      reply: _contentController.text,
      title: _isPrivateMessage ? _titleController.text : null,
      action: _isPrivateMessage ? 'privateMessage' : 'reply',
      replyToPostNumber: widget.replyToPost?.postNumber,
      recipients: _isPrivateMessage && widget.targetUsername != null
          ? [widget.targetUsername!]
          : null,
      archetypeId: _isPrivateMessage ? 'private_message' : 'regular',
    );

    _draftController!.scheduleSave(data);
  }

  /// 加载帖子原始内容
  Future<void> _loadPostRaw() async {
    setState(() => _isLoadingRaw = true);
    try {
      final raw = await DiscourseService().getPostRaw(widget.editPost!.id);
      if (mounted && raw != null) {
        _contentController.text = raw;
        // 加载完成后聚焦并将光标移到末尾
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _contentFocusNode.requestFocus();
          _contentController.selection = TextSelection.fromPosition(
            TextPosition(offset: _contentController.text.length),
          );
        });
      }
    } catch (e) {
      if (mounted) {
        _showError(S.current.post_loadContentFailed(e.toString().replaceAll('Exception: ', '')));
      }
    } finally {
      if (mounted) setState(() => _isLoadingRaw = false);
    }
  }

  @override
  void dispose() {
    // 移除监听器
    _contentController.removeListener(_onContentChanged);
    _titleController.removeListener(_onContentChanged);

    // 关闭时处理草稿：已提交则跳过，有内容则保存，无内容则删除
    if (_draftController != null && !_submitted) {
      final hasContent = _contentController.text.trim().isNotEmpty ||
          (_isPrivateMessage && _titleController.text.trim().isNotEmpty);
      if (hasContent) {
        final data = DraftData(
          reply: _contentController.text,
          title: _isPrivateMessage ? _titleController.text : null,
          action: _isPrivateMessage ? 'privateMessage' : 'reply',
          replyToPostNumber: widget.replyToPost?.postNumber,
          recipients: _isPrivateMessage && widget.targetUsername != null
              ? [widget.targetUsername!]
              : null,
          archetypeId: _isPrivateMessage ? 'private_message' : 'regular',
        );
        // 异步保存，不阻塞 dispose
        _draftController!.saveNow(data);
      } else {
        // 内容为空，删除草稿
        _draftController!.deleteDraft();
      }
    }
    _draftController?.dispose();

    // 释放 Presence 服务（会自动离开频道）
    _presenceService?.dispose();

    _titleController.dispose();
    _contentController.dispose();
    _contentFocusNode.dispose();
    super.dispose();
  }

  void _showError(String message) {
    showAppDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.common_hint),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.common_confirm),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final content = _contentController.text.trim();
    if (content.isEmpty) {
      _showError(S.current.post_contentRequired);
      return;
    }

    // 最小字数校验
    final preloaded = PreloadedDataService();
    final minLength = _isInPrivateMessageContext
        ? await preloaded.getMinPmPostLength()
        : await preloaded.getMinPostLength();
    if (content.length < minLength) {
      ToastService.showInfo(S.current.createTopic_minContentLength(minLength));
      return;
    }

    if (_isPrivateMessage && _titleController.text.trim().isEmpty) {
      _showError(S.current.post_titleRequired);
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      if (_isEditMode) {
        // 编辑模式：更新帖子
        final updatedPost = await DiscourseService().updatePost(
          postId: widget.editPost!.id,
          raw: content,
        );
        if (!mounted) return;
        Navigator.of(context).pop(updatedPost);
      } else if (_isPrivateMessage) {
        await DiscourseService().createPrivateMessage(
          targetUsernames: [widget.targetUsername!],
          title: _titleController.text.trim(),
          raw: content,
        );
        // 发送成功后删除草稿
        await _draftController?.deleteDraft();
        _submitted = true;
        if (!mounted) return;
        Navigator.of(context).pop(null); // 私信模式不返回 Post
      } else {
        // 回复模式：返回创建的 Post 对象
        final newPost = await DiscourseService().createReply(
          topicId: widget.topicId!,
          raw: content,
          replyToPostNumber: widget.replyToPost?.postNumber,
        );
        // 发送成功后删除草稿
        await _draftController?.deleteDraft();
        _submitted = true;
        if (!mounted) return;
        Navigator.of(context).pop(newPost);
      }
    } on PostEnqueuedException {
      // 审核场景：删除草稿，提示用户，关闭编辑器
      await _draftController?.deleteDraft();
      _submitted = true;
      if (!mounted) return;
      ToastService.showInfo(S.current.post_pendingReview);
      Navigator.of(context).pop();
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  /// 构建草稿保存状态指示器
  Widget _buildDraftStatusIndicator(DraftSaveStatus status, ThemeData theme) {
    switch (status) {
      case DraftSaveStatus.idle:
        return const SizedBox.shrink();
      case DraftSaveStatus.pending:
        return const SizedBox.shrink();
      case DraftSaveStatus.saving:
        return SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: theme.colorScheme.outline,
          ),
        );
      case DraftSaveStatus.saved:
        return Icon(
          Icons.cloud_done_outlined,
          size: 16,
          color: theme.colorScheme.outline,
        );
      case DraftSaveStatus.error:
        return Icon(
          Icons.cloud_off_outlined,
          size: 16,
          color: theme.colorScheme.error,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 使用 FractionallySizedBox 固定 0.95 高度
    // SafeArea(bottom: false)：顶部安全区域由 SafeArea 处理，
    // 底部安全区域由 ChatBottomPanelContainer 内部管理，避免双重底部间距
    return SafeArea(
      bottom: false,
      child: FractionallySizedBox(
        heightFactor: 0.95,
        alignment: Alignment.bottomCenter,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          resizeToAvoidBottomInset: false,
          // PopScope 用于处理表情面板开启时的返回逻辑
          body: PopScope(
            canPop: !_showEmojiPanel,
            onPopInvokedWithResult: (bool didPop, dynamic result) async {
              if (didPop) return;
              if (_showEmojiPanel) {
                _editorKey.currentState?.closeEmojiPanel();
                setState(() => _showEmojiPanel = false);
              }
            },
            child: Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                  ),
                  child: Column(
                children: [
                  // 1. 顶部 Header (固定)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 拖拽手柄
                      Container(
                        width: 32,
                        height: 4,
                        margin: const EdgeInsets.only(top: 12, bottom: 8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      
                      // 标题行
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Row(
                          children: [
                            // 标题信息
                            if (_isEditMode) ...[
                              Icon(
                                Icons.edit_outlined,
                                size: 18,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  context.l10n.post_editPostTitle(widget.editPost!.postNumber),
                                  style: theme.textTheme.titleSmall,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ] else if (_isPrivateMessage)
                              Expanded(
                                child: Text(
                                  context.l10n.post_sendPmTitle(widget.targetUsername!),
                                  style: theme.textTheme.titleSmall,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              )
                            else if (widget.replyToPost != null) ...[
                              SmartAvatar(
                                imageUrl: widget.replyToPost!.getAvatarUrl().isNotEmpty
                                    ? widget.replyToPost!.getAvatarUrl()
                                    : null,
                                radius: 14,
                                fallbackText: widget.replyToPost!.username,
                                backgroundColor: theme.colorScheme.primaryContainer,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  context.l10n.post_replyToUser(widget.replyToPost!.username),
                                  style: theme.textTheme.titleSmall,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ] else
                              Text(
                                context.l10n.post_replyToTopic,
                                style: theme.textTheme.titleSmall,
                              ),

                            if (!_isPrivateMessage && !_isEditMode && widget.replyToPost == null)
                              const Spacer(),

                            // 草稿保存状态指示器
                            if (_draftController != null) ...[
                              ValueListenableBuilder<DraftSaveStatus>(
                                valueListenable: _draftController!.statusNotifier,
                                builder: (context, status, _) {
                                  return _buildDraftStatusIndicator(status, theme);
                                },
                              ),
                              const SizedBox(width: 8),
                              // 舍弃按钮
                              TextButton(
                                onPressed: _isSubmitting ? null : _discardDraft,
                                child: Text(context.l10n.common_discard),
                              ),
                              const SizedBox(width: 8),
                            ],

                            // 发送/保存按钮
                            FilledButton(
                              onPressed: (_isSubmitting || _isLoadingRaw) ? null : _submit,
                              child: _isSubmitting
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : Text(_isEditMode ? context.l10n.common_save : context.l10n.common_send),
                            ),
                          ],
                        ),
                      ),
                      
                      Divider(
                        height: 1,
                        color: theme.colorScheme.outlineVariant.withValues(alpha:0.5),
                      ),
                    ],
                  ),

                  // 私信标题输入框（仅私信模式）
                  if (_isPrivateMessage) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: _titleController,
                        decoration: InputDecoration(
                          hintText: context.l10n.common_title,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                        textInputAction: TextInputAction.next,
                        onTap: () {
                          if (_showEmojiPanel) {
                            _editorKey.currentState?.closeEmojiPanel();
                            setState(() => _showEmojiPanel = false);
                          }
                        },
                      ),
                    ),
                    Divider(
                      height: 1,
                      color: theme.colorScheme.outlineVariant.withValues(alpha:0.2),
                    ),
                  ],

                  // 2. 编辑器区域 (使用 MarkdownEditor)
                  Expanded(
                    child: MarkdownEditor(
                      key: _editorKey,
                      controller: _contentController,
                      focusNode: _contentFocusNode,
                      hintText: context.l10n.editor_hintText,
                      expands: true,
                      emojiPanelHeight: _emojiPanelHeight,
                      onEmojiPanelChanged: (show) {
                        setState(() => _showEmojiPanel = show);
                      },
                      mentionDataSource: (term) => DiscourseService().searchUsers(
                        term: term,
                        topicId: widget.topicId,
                        categoryId: widget.categoryId,
                        includeGroups: !_isInPrivateMessageContext, // 私信不允许提及群组
                      ),
                    ),
                  ),

                ],
              ),
            ),
            // 草稿加载遮罩
            if (_isLoadingDraft)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withValues(alpha: 0.7),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                  ),
                  child: const Center(child: LoadingSpinner()),
                ),
              ),
          ]),
          ),
        ),
      ),
    );
  }
}
