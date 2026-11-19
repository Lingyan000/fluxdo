import 'dart:async';
import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_submission_snapshot.dart';

import '../markdown_editor/uploads/upload_task_labels.dart';

import 'package:fluxdo/widgets/markdown_editor/composer_draft_status.dart';

import '../../utils/platform_utils.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/draft_store_provider.dart';

import 'pm_recipient_field.dart';
import 'reply_submission.dart';
import '../markdown_editor/composer_shortcuts.dart';
import '../markdown_editor/composer_close_confirmation.dart';
import '../markdown_editor/composer_switch_fade.dart';
import '../markdown_editor/composer_workbench.dart';
import '../markdown_editor/composer_header_actions.dart';
import '../common/character_counts_overlay.dart';
import '../markdown_editor/composer_view_mode_switcher.dart';
import '../markdown_editor/markdown_renderer.dart';
import '../markdown_editor/markdown_editor.dart';
import '../markdown_editor/rich_composer/rich_composer_editor.dart';
import '../../providers/preferences_provider.dart';
import '../../models/topic.dart';
import '../../models/draft.dart';
import '../../providers/category_provider.dart';
import '../../services/composer_min_length_resolver.dart';
import '../../models/pending_post.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/ai_post_review_service.dart';
import '../../services/presence_service.dart';
import '../../services/emoji_handler.dart';
import '../../services/draft_controller.dart';
import '../../services/dynamic_content_suspension_service.dart';
import '../../services/embedded_browser_controller_pool.dart';

import 'package:dio/dio.dart';

import '../../services/app_error_handler.dart';
import '../../services/network/exceptions/api_exception.dart';
import '../../services/toast_service.dart';
import '../common/smart_avatar.dart';
import '../../l10n/s.dart';
import '../../utils/dialog_utils.dart';
import '../../providers/shortcut_provider.dart';
import '../ai/ai_post_review_button.dart';
import '../common/emoji_text.dart';

import 'package:m3e_ui/m3e_ui.dart';

/// Windows 平台视图从 Widget 树移除到 WebView2 Controller 真正析构存在
/// 明显时间差。若立即弹出编辑器，旧 SVG WebView 的析构会和输入框首帧、
/// 键盘焦点及草稿加载同时争抢平台/UI 消息泵。只在确有浏览器槽位时短暂
/// 等待，原生 SVG 或普通帖子不会增加打开延迟。
Future<void> _waitForEmbeddedBrowserTeardown() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
  await WidgetsBinding.instance.endOfFrame;
  final pool = EmbeddedBrowserControllerPool.instance;
  if (pool.activeCount == 0) return;
  final deadline = DateTime.now().add(const Duration(milliseconds: 900));
  while (pool.activeCount > 0 && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// 显示回复底部弹框
/// [topicId] 话题 ID (回复话题/帖子时必需)
/// [categoryId] 分类 ID（可选，用于用户搜索）
/// [replyToPost] 可选，被回复的帖子
/// [targetUsername] 可选，私信目标用户名（创建时作为预选收件人）
/// [draftKey] 可选，恢复已有草稿时传入原草稿 key（草稿列表入口使用）
/// [preloadedDraftFuture] 预加载的草稿 Future（在点击回复按钮时就发起请求）
/// [initialContent] 可选，预填内容（划词引用时使用）
/// [initialTitle] 可选，预填标题（私信模式时使用）
/// [onEnqueued] 可选，帖子被送审时回调(携带待审内容摘要);
/// 不传时降级为 toast 提示 + 「查看」跳转待审列表页
/// 返回创建的 Post 对象，取消或失败返回 null
Future<Post?> showReplySheet({
  required BuildContext context,
  int? topicId,
  int? categoryId,
  Post? replyToPost,
  String? targetUsername,

  /// 新建私信（可无预设收件人）：收件人由用户在编辑器内搜索增删
  bool composePrivateMessage = false,
  String? draftKey,
  Future<Draft?>? preloadedDraftFuture,
  String? initialContent,

  /// [initialContent] 是从快捷回复带来的完整正文：以它为准，不与已存草稿
  /// 拼接（默认语义是划词引用前缀 + 草稿）
  bool initialContentIsComplete = false,
  String? initialTitle,
  String? topicTitle,
  bool isPrivateMessageTopic = false,
  bool isPmWithNonHumanUser = false,
  ShortcutSurfaceConfig? shortcutSurface,
  ValueChanged<PendingPost>? onEnqueued,

  /// 非空时编辑器从这个全局矩形（如快捷回复面板）连续变形展开，
  /// 而不是从屏幕底部滑入
  Rect? morphFrom,
  double morphFromRadius = 0,
  Color? morphFromColor,
  MorphSheetAnchor? Function()? returnAnchor,
  VoidCallback? onHandoffComplete,

  /// 起点元素截图与「弹层已接替起点」回调，见 [showAppMorphSheet]
  ui.Image? morphFromSnapshot,
  VoidCallback? onHandoffStart,
}) async {
  final suspension = DynamicContentSuspensionService.instance.acquire(
    reason: 'reply_sheet',
  );
  try {
    await _waitForEmbeddedBrowserTeardown();
    if (!context.mounted) return null;
    Widget buildSheet(BuildContext context) => ReplySheet(
      topicId: topicId,
      categoryId: categoryId,
      replyToPost: replyToPost,
      targetUsername: targetUsername,
      composePrivateMessage: composePrivateMessage,
      draftKey: draftKey,
      preloadedDraftFuture: preloadedDraftFuture,
      initialContent: initialContent,
      initialContentIsComplete: initialContentIsComplete,
      initialTitle: initialTitle,
      topicTitle: topicTitle,
      isPrivateMessageTopic: isPrivateMessageTopic,
      isPmWithNonHumanUser: isPmWithNonHumanUser,
      onEnqueued: onEnqueued,
    );
    if (morphFrom != null) {
      return await showAppMorphSheet<Post?>(
        context: context,
        fromRect: morphFrom,
        fromRadius: morphFromRadius,
        fromColor: morphFromColor,
        returnAnchor: returnAnchor,
        onHandoffComplete: onHandoffComplete,
        fromSnapshot: morphFromSnapshot,
        onHandoffStart: onHandoffStart,
        shortcutSurface: shortcutSurface,
        builder: buildSheet,
      );
    }
    return await showAppBottomSheet<Post?>(
      context: context,
      isScrollControlled: true,
      respectPopScopeOnDrag: true,
      useSafeArea: false,
      backgroundColor: Colors.transparent,
      shortcutSurface: shortcutSurface,
      // 动态帖子位于弹层下方时，全屏实时模糊会被每个动画帧重新计算，
      // 与编辑器同步 cook 叠加后可同时打满 GPU 和 UI isolate。
      blur: false,
      builder: buildSheet,
    );
  } finally {
    suspension.release();
  }
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
  bool isPrivateMessageTopic = false,
  bool isPmWithNonHumanUser = false,
  ShortcutSurfaceConfig? shortcutSurface,
}) async {
  final suspension = DynamicContentSuspensionService.instance.acquire(
    reason: 'edit_sheet',
  );
  try {
    await _waitForEmbeddedBrowserTeardown();
    if (!context.mounted) return null;
    return await showAppBottomSheet<Post?>(
      context: context,
      isScrollControlled: true,
      respectPopScopeOnDrag: true,
      useSafeArea: false,
      backgroundColor: Colors.transparent,
      shortcutSurface: shortcutSurface,
      blur: false,
      builder: (context) => ReplySheet(
        topicId: topicId,
        categoryId: categoryId,
        editPost: post,
        isPrivateMessageTopic: isPrivateMessageTopic,
        isPmWithNonHumanUser: isPmWithNonHumanUser,
      ),
    );
  } finally {
    suspension.release();
  }
}

class ReplySheet extends ConsumerStatefulWidget {
  final int? topicId;
  final int? categoryId;
  final Post? replyToPost;
  final String? targetUsername;

  /// 新建私信（无预设收件人）
  final bool composePrivateMessage;
  final String? draftKey; // 恢复已有草稿时传入的原草稿 key
  final Post? editPost; // 编辑模式：要编辑的帖子
  final Future<Draft?>? preloadedDraftFuture; // 预加载的草稿
  final String? initialContent; // 预填内容（划词引用时使用）

  /// [initialContent] 为完整正文（从快捷回复展开），不与已存草稿拼接
  final bool initialContentIsComplete;
  final String? initialTitle; // 预填标题（私信模式时使用）
  final String? topicTitle; // 普通回帖审核时带上的话题标题
  final bool isPrivateMessageTopic; // 当前话题是否为私信话题
  final bool isPmWithNonHumanUser; // 当前私信话题是否包含非真人用户
  final ValueChanged<PendingPost>? onEnqueued; // 帖子被送审时回调

  /// 停靠形态（宽屏帖子列底部的非模态编辑器）：非 null 时编辑器不是路由，
  /// 关闭 / 发送完成通过它交还宿主（参数为发出的帖子，未发出为 null）
  final ValueChanged<Post?>? onDockedClose;

  const ReplySheet({
    super.key,
    this.topicId,
    this.categoryId,
    this.replyToPost,
    this.targetUsername,
    this.composePrivateMessage = false,
    this.draftKey,
    this.editPost,
    this.preloadedDraftFuture,
    this.initialContent,
    this.initialContentIsComplete = false,
    this.initialTitle,
    this.topicTitle,
    this.isPrivateMessageTopic = false,
    this.isPmWithNonHumanUser = false,
    this.onEnqueued,
    this.onDockedClose,
  });

  @override
  ConsumerState<ReplySheet> createState() => _ReplySheetState();
}

/// 停靠形态下宿主对编辑器的操作（经 GlobalKey 取 state）
abstract interface class ReplyComposerHandle {
  /// 正文是否有内容
  bool get hasContent;

  /// 取出当前完整正文（富文本模式先序列化）并让出草稿：此后编辑器卸载时
  /// 不再写草稿，由宿主带着正文重建编辑器。[deleteDraft] 为 true 时同时
  /// 删除当前回复对象的草稿（正文整体迁到别的回复对象）
  Future<String> detachContent({required bool deleteDraft});
}

class _ReplySheetState extends ConsumerState<ReplySheet>
    implements ReplyComposerHandle {
  bool get _docked => widget.onDockedClose != null;

  /// 编辑器关闭出口：停靠形态交还宿主，弹层形态出栈
  void _finish([Object? result]) {
    final onDockedClose = widget.onDockedClose;
    if (onDockedClose != null) {
      onDockedClose(result is Post ? result : null);
    } else {
      Navigator.of(context).pop(result);
    }
  }

  @override
  bool get hasContent => _contentController.text.trim().isNotEmpty;

  /// 首次挂载时淡入（富文本编辑器在入场动画结束后才出现，不要硬切）
  Widget _fadeIn(Widget child) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 160),
    builder: (context, opacity, child) =>
        Opacity(opacity: opacity, child: child),
    child: child,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (identical(animation, _routeAnimation)) return;
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    _routeAnimation = animation;
    if (animation == null || animation.isCompleted) {
      _routeSettled = true;
    } else {
      _routeSettled = false;
      animation.addStatusListener(_onRouteAnimationStatus);
    }
  }

  void _onRouteAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    if (mounted && !_routeSettled) setState(() => _routeSettled = true);
  }

  @override
  Future<String> detachContent({required bool deleteDraft}) async {
    _flushRichContent();
    final content = _contentController.text;
    _discarded = true;
    _draftController?.disable();
    if (deleteDraft) await _draftController?.deleteDraft();
    return content;
  }

  /// 富文本导入失败(cook 不可用)时本次会话降级纯文本
  bool _richFallback = false;
  bool _allowClose = false;
  bool _closePending = false;
  bool _richModeEnabled = false;

  Future<void> _closeWithCurrentContent(dynamic result) async {
    if (_closePending || _allowClose) return;
    _closePending = true;
    try {
      if (!_submitted && !_discarded && !_isSubmitting) {
        final ready = _richKey.currentState?.prepareToClose() ?? true;
        final hasEdits =
            _isEditMode && _contentController.text != (_originalContent ?? '');
        if (!ready || hasEdits) {
          final discard = await confirmComposerDiscard(
            context,
            synchronizationFailed: !ready,
          );
          if (!mounted || !discard) return;
          // 放弃未保存的修改后，卸载不能再用旧镜像触发草稿保存。
          _discarded = true;
          _draftController?.disable();
          _richKey.currentState?.prepareForDocumentReplacement();
        }
      }
      if (!mounted) return;
      setState(() => _allowClose = true);
      // 等待 PopScope 更新许可；dispose 随后保存刚刚同步的草稿。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _finish(result);
      });
    } finally {
      _closePending = false;
    }
  }

  /// 富文本未就绪或导出失败时，绝不能消费 controller 中的旧镜像。
  bool _flushRichContent() {
    final rich = _richKey.currentState;
    final ready = rich != null
        ? rich.flushToController()
        : (_showPreview ||
              _richFallback ||
              !ref.read(preferencesProvider).useRichComposer);
    if (!ready) {
      ToastService.showError(S.current.composer_syncFailed);
    }
    return ready;
  }

  /// 预览渲染。与 MarkdownEditor 内部预览同款（MarkdownBody + 空态文案），
  /// 但对富文本/源码两种模式都生效。
  Widget _buildPreview(ThemeData theme) {
    final text = _contentController.text;
    return SingleChildScrollView(
      key: const ValueKey('reply-preview'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: text.trim().isEmpty
          ? Text(
              S.current.editor_noContent,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            )
          : MarkdownBody(
              data: text,
              // 富文本通过图片菜单修改尺寸；直接改 raw 会使语义镜像失效。
              onImageScaleChanged: _richModeEnabled && !_richFallback
                  ? null
                  : (image, scale) {
                      final next = applyImageScaleToRaw(
                        _contentController.text,
                        image,
                        scale,
                      );
                      if (next == null) return;
                      _contentController.text = next;
                      setState(() {});
                    },
            ),
    );
  }

  /// 预览态独立于编辑模式，切换时保留原编辑器。
  bool _showPreview = false;

  /// 当前视图档位。
  ComposerViewMode get _viewMode {
    if (_showPreview) return ComposerViewMode.preview;
    return (ref.read(preferencesProvider).useRichComposer && !_richFallback)
        ? ComposerViewMode.rich
        : ComposerViewMode.source;
  }

  /// 三档齐全：预览对富文本/源码都可用（此前预览按钮挂在源码工具栏上，
  /// 富文本态下根本看不到，是个割裂）。
  void _setViewMode(ComposerViewMode next) {
    if (next == _viewMode) return;
    if (next == ComposerViewMode.preview) {
      _togglePreview();
      return;
    }
    final hadFocus = _contentFocusNode.hasFocus;
    if (!_flushRichContent()) return;
    _editorKey.currentState?.closeEmojiPanel();
    _richKey.currentState?.closeEmojiPanel();
    _contentFocusNode.unfocus();
    setState(() {
      _showPreview = false;
      _richFallback = next == ComposerViewMode.source;
    });
    if (hadFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _contentFocusNode.requestFocus();
      });
    }
  }

  Widget _buildReplyContext() {
    final theme = Theme.of(context);
    final target = widget.replyToPost;
    final title = widget.topicTitle?.trim();
    final (label, icon) = _isEditMode
        ? ('#${widget.editPost!.postNumber}', Symbols.edit_rounded)
        : _isPrivateMessage && _recipients.isNotEmpty
        ? (_recipients.map((name) => '@$name').join(', '), Symbols.mail_rounded)
        : target != null
        ? ('@${target.username} · #${target.postNumber}', Symbols.reply_rounded)
        : title != null && title.isNotEmpty
        ? (title, Symbols.reply_rounded)
        : (_viewMode.label, _viewMode.icon);
    return Tooltip(
      message: label,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            AppIcon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: EmojiText(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _previewHadFocus = false;

  void _togglePreview() {
    final leaving = _showPreview;
    if (!leaving) {
      _previewHadFocus = _contentFocusNode.hasFocus;
      if (!_flushRichContent()) return;
      _editorKey.currentState?.closeEmojiPanel();
      _richKey.currentState?.closeEmojiPanel();
      FocusScope.of(context).unfocus();
    }
    setState(() => _showPreview = !leaving);
    if (leaving && _previewHadFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _editorKey.currentState?.resumeEditing();
        _richKey.currentState?.resumeEditing();
      });
    }
  }

  void _showQuickPanel() {
    if (_showPreview) _togglePreview();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _editorKey.currentState?.showQuickPanel();
      _richKey.currentState?.showQuickPanel();
    });
  }

  Widget _buildHeaderActions(
    double availableWidth, {
    double? minimumTitleWidth,
  }) => ComposerHeaderActions(
    availableWidth: availableWidth,
    minimumTitleWidth: minimumTitleWidth,
    submitLabel: _isEditMode
        ? context.l10n.common_save
        : context.l10n.common_send,
    submitIcon: _isEditMode ? AppIcons.check : null,
    onSubmit: (_isSubmitting || _isLoadingRaw) ? null : _submit,
    submitting: _isSubmitting,
    previewing: _showPreview,
    onTogglePreview: !_isSubmitting && !_isLoadingRaw ? _togglePreview : null,
    draftStatus: _draftController?.statusNotifier,
    onRetryDraft: _isSubmitting ? null : _retryDraftSave,
    showDiscard: _draftController != null,
    onDiscard: _isSubmitting ? null : _discardDraft,
    reviewBuilder:
        _canReviewPost && ref.watch(preferencesProvider).aiPostReviewEnabled
        ? (builder) => AiPostReviewButton(
            titleBuilder: () => widget.topicTitle,
            contentBuilder: () {
              if (!_flushRichContent()) return '';
              return _contentController.text;
            },
            target: AiPostReviewTarget.reply,
            enabled: !_isSubmitting && !_isLoadingRaw,
            builder: (_, reviewing, trigger) => builder(reviewing, trigger),
          )
        : null,
  );

  Widget _buildHeaderTitle(
    ThemeData theme, {
    TextStyle? style,
    bool wrapTarget = false,
  }) {
    final target = widget.replyToPost;
    final label = _isEditMode
        ? context.l10n.post_editPostTitle(widget.editPost!.postNumber)
        : _isPrivateMessage
        ? (_recipients.isEmpty
              ? context.l10n.pm_newTitle
              : context.l10n.post_sendPmTitle(_recipients.join(', ')))
        : target != null
        ? context.l10n.post_replyToUser(target.username)
        : context.l10n.post_replyToTopic;
    return Row(
      children: [
        if (!_isEditMode && !_isPrivateMessage && target != null) ...[
          SmartAvatar(
            imageUrl: target.getAvatarUrl().isNotEmpty
                ? target.getAvatarUrl()
                : null,
            radius: 14,
            fallbackText: target.username,
            backgroundColor: theme.colorScheme.primaryContainer,
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Tooltip(
            message: label,
            child: Text(
              wrapTarget ? '@${target!.username}' : label,
              key: const ValueKey('reply-composer-title-text'),
              style: style,
              maxLines: wrapTarget ? null : 1,
              overflow: wrapTarget
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildResponsiveHeader(ThemeData theme, double width) {
    final target = widget.replyToPost;
    final compactTarget =
        (width < 600 || !PlatformUtils.isDesktop) &&
        !_isEditMode &&
        !_isPrivateMessage &&
        target != null;
    final style = compactTarget
        ? theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)
        : null;
    double? titleWidth;
    if (compactTarget) {
      final painter = TextPainter(
        text: TextSpan(
          text: context.l10n.post_replyToUser(target.username),
          style: style,
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      titleWidth = painter.width.ceilToDouble() + 28 + 8;
      painter.dispose();
    }
    // 56 navigation + 32 title margins + 44 more + 8 gap + 48 submit + 16 trailing.
    // When even the compact action row cannot fit the recipient, give it its
    // own full-width row instead of truncating the identity or shrinking taps.
    final separateTarget = compactTarget && titleWidth! > width - 204;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: kToolbarHeight,
          child: AppBar(
            key: const ValueKey('reply-composer-header'),
            primary: false,
            centerTitle: false,
            automaticallyImplyLeading: false,
            leading: CloseButton(
              onPressed: () => _docked
                  ? _closeWithCurrentContent(null)
                  : Navigator.of(context).maybePop(),
            ),
            title: separateTarget
                ? Text(context.l10n.common_reply)
                : _buildHeaderTitle(theme, style: style),
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            actions: [
              _buildHeaderActions(
                width,
                minimumTitleWidth: separateTarget ? width : titleWidth,
              ),
            ],
          ),
        ),
        if (separateTarget)
          Padding(
            key: const ValueKey('reply-composer-recipient-row'),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _buildHeaderTitle(theme, style: style, wrapTarget: true),
          ),
      ],
    );
  }

  var _richKey = GlobalKey<RichComposerEditorState>();

  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _contentFocusNode = FocusNode();
  var _editorKey = GlobalKey<MarkdownEditorState>();

  bool _isSubmitting = false;
  bool _submitted = false; // 提交成功标志，防止 dispose 重新保存草稿
  bool _discarded = false; // 用户明确舍弃，防止 dispose 重新保存草稿
  bool _showEmojiPanel = false;
  bool _isLoadingRaw = false; // 编辑模式：加载原始内容中
  String? _originalContent;
  bool _isLoadingDraft = false; // 加载草稿中

  /// 草稿加载遮罩是否显示：加载很快结束（多数情况，点回复时已预取）时
  /// 不出现，免得在入场动画里闪一下遮罩与转圈
  bool _loadingOverlayVisible = false;
  Timer? _loadingOverlayTimer;
  static const Duration _loadingOverlayDelay = Duration(milliseconds: 450);

  /// 入场动画是否已结束：富文本编辑器构建较重，等动画结束再挂载，
  /// 避免在动画中途掉帧
  bool _routeSettled = true;
  Animation<double>? _routeAnimation;
  bool _restoringDraft = false;
  bool _reloadingDraft = false;

  // 表情面板高度
  static const double _emojiPanelHeight = 280.0;

  // 草稿控制器（仅在回复话题或创建私信时使用，编辑模式不使用）
  DraftController? _draftController;

  // Presence 服务（正在输入状态）
  PresenceService? _presenceService;

  // 私信收件人（初始为目标用户，从草稿恢复时还原草稿中的完整收件人列表）
  late List<String> _recipients = [
    if (widget.targetUsername != null) widget.targetUsername!,
  ];

  bool get _isPrivateMessage =>
      widget.targetUsername != null || widget.composePrivateMessage;

  /// 所有新建私信入口都允许继续增删收件人；已有私信话题回复不走这里。
  bool get _canEditRecipients => _isPrivateMessage && !_isEditMode;

  /// 是否在私信话题中（创建新私信 或 回复已有私信话题）
  bool get _isInPrivateMessageContext =>
      _isPrivateMessage || widget.isPrivateMessageTopic;
  bool get _isEditMode => widget.editPost != null;

  /// 当前正文最小字数（含 warden 等站点插件按分类的改写）
  ///
  /// 计数器分母与提交校验共用，避免「计数器说够了、提交却被拦」。
  int? _minPostLength;

  /// 正文实时长度（驱动计数器）
  int _contentLength = 0;

  /// 编辑模式改的是已有楼层，是否首帖按被编辑帖子的楼层号判断；
  /// 回复永远不是首帖。
  bool get _isFirstPost => _isEditMode && widget.editPost!.postNumber == 1;

  bool get _canReviewPost =>
      !_isEditMode &&
      !_isPrivateMessage &&
      !_isInPrivateMessageContext &&
      widget.topicId != null;

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
    // 字数计数器单独监听：编辑模式下 _onContentChanged 会直接 return，
    // 但计数器在编辑帖子时同样需要实时更新
    _contentController.addListener(_onContentLengthChanged);
    _loadMinPostLength();
    _draftLifecycle = AppLifecycleListener(
      onInactive: _flushDraftForLifecycle,
      onPause: _flushDraftForLifecycle,
      onResume: () => _flushDraftForLifecycle(refresh: true),
    );

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
    var shouldLoadDraft = true;
    if (widget.draftKey != null) {
      // 草稿列表入口：沿用原草稿 key 恢复
      draftKey = widget.draftKey!;
    } else if (_isPrivateMessage) {
      // 对齐 Discourse（services/composer.js privateMessageDraftKey）：
      // 新私信用带时间戳的唯一 key，不自动带回其他私信的草稿，
      // 避免给 A 写一半的草稿被带进给 B 的私信窗口造成串发
      draftKey = Draft.generateNewPrivateMessageKey();
      shouldLoadDraft = false; // 全新 key 服务端必无草稿，跳过加载
    } else if (widget.topicId != null) {
      // 区分回复话题和回复帖子
      draftKey = Draft.replyKey(
        widget.topicId!,
        replyToPostNumber: widget.replyToPost?.postNumber,
      );
    } else {
      return;
    }

    _draftController = DraftController(
      draftKey: draftKey,
      localStore: ref.read(localDraftStoreProvider),
      onRemoteDraftChanged: (data) {
        if (mounted &&
            !_allowClose &&
            !_submitted &&
            !_discarded &&
            (!_isLoadingDraft || _reloadingDraft)) {
          _restoreDraft(
            Draft(draftKey: draftKey, data: data),
            appendInitialContent: false,
          );
        }
      },
      currentEditorData: () {
        if (!mounted || (_isLoadingDraft && !_reloadingDraft)) return null;
        if (!_flushRichContent()) return null;
        return _currentDraftData();
      },
    );
    if (shouldLoadDraft) {
      _loadExistingDraft();
    }
  }

  /// 加载现有草稿
  Future<void> _loadExistingDraft() async {
    setState(() => _isLoadingDraft = true);
    // 从快捷回复展开时正文已确定，不需要加载遮罩
    if (!widget.initialContentIsComplete) {
      _loadingOverlayTimer = Timer(_loadingOverlayDelay, () {
        if (mounted && _isLoadingDraft) {
          setState(() => _loadingOverlayVisible = true);
        }
      });
    }
    try {
      final draft = await _draftController?.loadDraft(
        preloadedDraftFuture: widget.preloadedDraftFuture,
      );
      if (!mounted || _allowClose) return;

      // 从快捷回复展开时正文已是最新，草稿只用于建立同步基线
      if (draft != null &&
          draft.hasContent &&
          !widget.initialContentIsComplete) {
        // 回复模式直接恢复，不需要确认
        _restoreDraft(draft);
      }
    } finally {
      _loadingOverlayTimer?.cancel();
      if (mounted && !_allowClose) {
        setState(() {
          _isLoadingDraft = false;
          _loadingOverlayVisible = false;
        });
        if (widget.initialContent?.isNotEmpty == true) _onContentChanged();
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
      _discarded = true;
      _draftController?.disable();
      await _draftController?.deleteDraft();
      if (mounted) _finish();
    }
  }

  /// 恢复草稿内容
  void _restoreDraft(Draft draft, {bool appendInitialContent = true}) {
    _restoringDraft = true;
    _richKey.currentState?.prepareForDocumentReplacement();
    _richKey = GlobalKey<RichComposerEditorState>();
    _editorKey = GlobalKey<MarkdownEditorState>();
    try {
      final prefix = appendInitialContent ? widget.initialContent ?? '' : '';
      _contentController.text = '$prefix${draft.data.reply ?? ''}';
      if (_isPrivateMessage) {
        _titleController.text = draft.data.title ?? '';
        setState(
          () => _recipients = List.of(draft.data.recipients ?? const []),
        );
      }
    } finally {
      _restoringDraft = false;
    }
    setState(() {});
  }

  /// 内容变化时触发草稿保存
  /// 同步正文长度到计数器
  void _onContentLengthChanged() {
    final length = _contentController.text.length;
    if (length == _contentLength) return;
    setState(() => _contentLength = length);
  }

  /// 解析当前上下文的最小正文字数（含插件按分类的改写）
  Future<void> _loadMinPostLength() async {
    final categoryId = widget.categoryId;
    final category = categoryId == null
        ? null
        : ref.read(categoryMapProvider).value?[categoryId];
    final min = await ComposerMinLengthResolver.resolve(
      category: category,
      isFirstPost: _isFirstPost,
      isPrivateMessage: _isInPrivateMessageContext,
      isPmWithNonHumanUser: widget.isPmWithNonHumanUser,
    );
    if (!mounted) return;
    setState(() => _minPostLength = min);
  }

  void _onContentChanged() {
    if (_isEditMode ||
        _draftController == null ||
        _isLoadingDraft ||
        _restoringDraft) {
      return;
    }

    _draftController!.scheduleSave(_currentDraftData());
  }

  DraftData _currentDraftData() => DraftData(
    reply: _contentController.text,
    title: _isPrivateMessage ? _titleController.text : null,
    action: _isPrivateMessage ? 'privateMessage' : 'reply',
    replyToPostNumber: widget.replyToPost?.postNumber,
    recipients: _isPrivateMessage ? _recipients : null,
    archetypeId: _isPrivateMessage ? 'private_message' : 'regular',
  );

  AppLifecycleListener? _draftLifecycle;
  void _flushDraftForLifecycle({bool refresh = false}) {
    if (!mounted ||
        _isSubmitting ||
        _isLoadingDraft ||
        _submitted ||
        _discarded) {
      return;
    }
    if (!_flushRichContent()) return;
    if (refresh) {
      _draftController?.scheduleSave(_currentDraftData());
      _draftController?.retryPending();
    } else {
      _draftController?.saveNow(_currentDraftData());
    }
  }

  Future<void> _reloadRemoteDraft() async {
    setState(() {
      _reloadingDraft = true;
      _isLoadingDraft = true;
      _loadingOverlayVisible = true;
    });
    try {
      if (await _draftController?.reloadFromRemote() != true && mounted) {
        ToastService.showError(S.current.composer_draftReloadFailed);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingDraft = false;
          _reloadingDraft = false;
          _loadingOverlayVisible = false;
        });
      }
    }
  }

  bool _retryingDraft = false;
  Future<void> _retryDraftSave() async {
    if (_isSubmitting || _retryingDraft || _draftController == null) return;
    _retryingDraft = true;
    try {
      if (!_flushRichContent()) return;
      final force = _draftController!.hasConflict;
      if (force &&
          !await confirmComposerDraftOverwrite(
            context,
            onReload: _reloadRemoteDraft,
          )) {
        return;
      }
      if (!mounted) return;
      await _draftController!.saveNow(_currentDraftData(), forceSave: force);
    } finally {
      _retryingDraft = false;
    }
  }

  /// 收件人本身也是私信草稿的一部分；只改名单不继续输入也要及时保存。
  void _onRecipientsChanged(List<String> recipients) {
    setState(() => _recipients = recipients);
    _onContentChanged();
  }

  /// 加载帖子原始内容
  Future<void> _loadPostRaw() async {
    setState(() => _isLoadingRaw = true);
    try {
      final raw = await DiscourseService().getPostRaw(widget.editPost!.id);
      if (mounted && !_allowClose && raw != null) {
        _originalContent = raw;
        _contentController.text = raw;
        // 加载完成后聚焦并将光标移到末尾
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _allowClose) return;
          _contentFocusNode.requestFocus();
          _contentController.selection = TextSelection.fromPosition(
            TextPosition(offset: _contentController.text.length),
          );
        });
      }
    } catch (e) {
      if (mounted && !_allowClose) {
        _showError(
          S.current.post_loadContentFailed(
            e.toString().replaceAll('Exception: ', ''),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoadingRaw = false);
    }
  }

  @override
  void dispose() {
    _loadingOverlayTimer?.cancel();
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    final rich = _richKey.currentState;
    final currentContentSafe = rich != null
        ? rich.flushToController()
        : (_allowClose || _showPreview || _richFallback || !_richModeEnabled);
    _draftLifecycle?.dispose();
    // 移除监听器
    _contentController.removeListener(_onContentChanged);
    _titleController.removeListener(_onContentChanged);
    _contentController.removeListener(_onContentLengthChanged);

    // 关闭时处理草稿：已提交则跳过，有内容则保存，无内容则删除
    if (currentContentSafe &&
        _draftController != null &&
        !_submitted &&
        !_discarded &&
        !_isLoadingDraft) {
      final hasContent =
          _contentController.text.trim().isNotEmpty ||
          (_isPrivateMessage && _titleController.text.trim().isNotEmpty);
      if (hasContent) {
        final data = DraftData(
          reply: _contentController.text,
          title: _isPrivateMessage ? _titleController.text : null,
          action: _isPrivateMessage ? 'privateMessage' : 'reply',
          replyToPostNumber: widget.replyToPost?.postNumber,
          recipients: _isPrivateMessage ? _recipients : null,
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

  List<Object?> _submissionValues() => [
    _contentController.text,
    _titleController.text,
    ..._recipients,
  ];

  bool _submissionPending = false;

  Future<void> _submit() async {
    if (_submissionPending || _isSubmitting || _closePending || _allowClose) {
      return;
    }
    _submissionPending = true;
    try {
      await _submitChecked();
    } finally {
      _submissionPending = false;
    }
  }

  Future<void> _submitChecked() async {
    if ((_editorKey.currentState?.hasPendingUploads ?? false) ||
        (_richKey.currentState?.hasPendingUploads ?? false)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(UploadTaskLabels.of(context).pendingSubmit)),
      );
      return;
    }

    // 富文本模式:镜像 debounce 窗口内提交也不丢内容,先强制序列化
    if (!_flushRichContent()) return;
    final approved = ComposerSubmissionSnapshot(_submissionValues());
    final content = _contentController.text.trim();
    if (content.isEmpty) {
      _showError(S.current.post_contentRequired);
      return;
    }

    if (_isPrivateMessage && _titleController.text.trim().isEmpty) {
      _showError(S.current.post_titleRequired);
      return;
    }

    // 新建私信必须至少保留一个收件人。
    if (_isPrivateMessage && _recipients.isEmpty) {
      _showError(S.current.pm_noRecipient);
      return;
    }

    // 最小字数（与计数器共用同一份解析结果，含 warden 按分类改写，否则在
    // 搞七捻三（16）这类分类下会出现计数器与校验不一致）→ 站点插件发送前
    // 确认 → 草稿冲突，与底栏快捷回复等入口共用一套
    if (!await ReplySubmission.preflight(
      context: context,
      ref: ref,
      content: content,
      topicId: widget.topicId,
      minLength: _minPostLength,
      categoryId: widget.categoryId,
      isFirstPost: _isFirstPost,
      isPrivateMessageContext: _isInPrivateMessageContext,
      isPmWithNonHumanUser: widget.isPmWithNonHumanUser,
      isEditing: _isEditMode,
      isPrivateMessage: _isPrivateMessage,
      draftController: _draftController,
      onReloadDraft: _reloadRemoteDraft,
    )) {
      return;
    }
    if (!mounted || _closePending || _allowClose) return;
    if (!approved.verify(
      synchronize: _flushRichContent,
      read: _submissionValues,
    )) {
      return;
    }
    setState(() => _isSubmitting = true);
    // 对齐 Discourse 前端 composer.set("disableDrafts", true):
    // 发送途中关掉自动保存,避免与 PostCreator 推进的 draft_sequence 撞 409
    _draftController?.disable();

    try {
      if (_isEditMode) {
        // 编辑模式：更新帖子
        final updatedPost = await DiscourseService().updatePost(
          postId: widget.editPost!.id,
          raw: content,
        );
        _submitted = true;
        if (!mounted || _allowClose) return;
        _finish(updatedPost);
      } else if (_isPrivateMessage) {
        await DiscourseService().createPrivateMessage(
          targetUsernames: _recipients,
          title: _titleController.text.trim(),
          raw: content,
          draftKey: _draftController?.draftKey,
          onDraftSequence: (seq) => _draftController?.syncSequence(seq),
        );
        // 发送成功后删除草稿
        await _draftController?.deleteDraft();
        _submitted = true;
        if (!mounted || _allowClose) return;
        _finish(); // 私信模式不返回 Post
      } else {
        // 回复模式：返回创建的 Post 对象（送审时为 null）
        final result = await ReplySubmission.createReply(
          topicId: widget.topicId!,
          raw: content,
          replyToPostNumber: widget.replyToPost?.postNumber,
          draftController: _draftController,
          onEnqueued: widget.onEnqueued,
        );
        if (!result.succeeded) return;
        _submitted = true;
        if (!mounted || _allowClose) return;
        _finish(result.post);
      }
    } on PostEnqueuedException catch (e) {
      // 审核场景：删除草稿，提示用户，关闭编辑器
      await _draftController?.deleteDraft();
      _submitted = true;
      if (!mounted || _allowClose) return;
      ReplySubmission.announceEnqueued(
        e.pendingPost,
        replyToPostNumber: widget.replyToPost?.postNumber,
        recordReplyTarget: widget.editPost == null && widget.topicId != null,
        onEnqueued: widget.onEnqueued,
      );
      _finish();
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理:发送失败,恢复草稿保存
      _draftController?.enable();
    } catch (e, s) {
      _draftController?.enable();
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Widget _buildCharCountOverlay() => CharacterCountsOverlay(
    length: _contentLength,
    minimumLength: _minPostLength,
  );

  @override
  Widget build(BuildContext context) {
    _richModeEnabled = ref.watch(preferencesProvider).useRichComposer;
    final theme = Theme.of(context);

    // 使用 FractionallySizedBox 固定 0.95 高度
    // SafeArea(bottom: false)：顶部安全区域由 SafeArea 处理，
    // 底部安全区域由 ChatBottomPanelContainer 内部管理，避免双重底部间距
    // CallbackShortcuts 包整个弹层:Cmd/Ctrl+Enter 提交(对齐 Discourse
    // composer),焦点在标题输入框时同样生效;守卫与发送按钮一致。
    // 停靠形态高度由宿主决定：不占 95%、不处理顶部安全区
    final sheet = SafeArea(
      top: !_docked,
      bottom: false,
      child: FractionallySizedBox(
        heightFactor: _docked ? 1 : 0.95,
        alignment: Alignment.bottomCenter,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          resizeToAvoidBottomInset: false,
          // PopScope 用于处理表情面板开启时的返回逻辑
          // 停靠形态不是路由：返回键照常离开页面（草稿在卸载时保存），
          // 只在表情面板打开时先收起面板
          body: PopScope(
            canPop: _docked
                ? !_showEmojiPanel
                : _allowClose && !_showEmojiPanel,
            onPopInvokedWithResult: (bool didPop, dynamic result) async {
              if (didPop) return;
              if (!_showEmojiPanel) {
                _closeWithCurrentContent(result);
                return;
              }
              if (_showEmojiPanel) {
                _editorKey.currentState?.closeEmojiPanel();
                _richKey.currentState?.closeEmojiPanel();
                setState(() => _showEmojiPanel = false);
              }
            },
            child: Stack(
              children: [
                Container(
                  decoration: ShapeDecoration(
                    color: theme.colorScheme.surface,
                    shape: RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.vertical(
                        top: context.shapes.radius(16),
                      ),
                    ),
                  ),
                  child: Column(
                    children: [
                      // 1. 顶部 Header (固定)
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 拖拽手柄（停靠形态由宿主提供调高手柄，不重复画）
                          if (!_docked)
                            Container(
                              width: 32,
                              height: 4,
                              margin: const EdgeInsets.only(top: 12, bottom: 8),
                              decoration: ShapeDecoration(
                                color: theme.colorScheme.outlineVariant,
                                shape: RoundedSuperellipseBorder(
                                  borderRadius: context.shapes.borderRadius(2),
                                ),
                              ),
                            ),

                          LayoutBuilder(
                            builder: (context, bounds) =>
                                _buildResponsiveHeader(theme, bounds.maxWidth),
                          ),

                          Divider(
                            height: 1,
                            color: theme.colorScheme.outlineVariant.withValues(
                              alpha: 0.5,
                            ),
                          ),
                        ],
                      ),

                      // 新建私信：所有入口都可增删收件人，预设对象保留为首个 chip。
                      if (_canEditRecipients)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: PmRecipientField(
                            recipients: _recipients,
                            autofocus: widget.targetUsername == null,
                            onChanged: _onRecipientsChanged,
                          ),
                        ),
                      // 私信标题输入框（仅私信模式）
                      if (_isPrivateMessage) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: TextField(
                            controller: _titleController,
                            decoration: InputDecoration(
                              hintText: context.l10n.common_title,
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 12,
                              ),
                            ).withoutBorder(),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                            textInputAction: TextInputAction.next,
                            onTap: () {
                              if (_showEmojiPanel) {
                                _editorKey.currentState?.closeEmojiPanel();
                                _richKey.currentState?.closeEmojiPanel();
                                setState(() => _showEmojiPanel = false);
                              }
                            },
                          ),
                        ),
                        Divider(
                          height: 1,
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.2,
                          ),
                        ),
                      ],

                      // 2. 编辑器区域(feature flag:富文本 / markdown;
                      // ComposerSwitchFade 无并存直切+淡入 —— 防双模
                      // 并存 IME 交接竞态,说明见 create_topic_page)
                      Expanded(
                        child: ComposerPreviewPane(
                          previewing: _showPreview,
                          previewFooter: ComposerPreviewFooter(
                            metadata: _buildReplyContext(),
                            rich:
                                ref
                                    .watch(preferencesProvider)
                                    .useRichComposer &&
                                !_richFallback,
                          ),
                          preview: _buildPreview(theme),
                          editor: ComposerSwitchFade(
                            child:
                                (ref.watch(
                                      preferencesProvider.select(
                                        (p) => p.useRichComposer,
                                      ),
                                    ) &&
                                    !_richFallback)
                                // 富文本的初始导入是一次性的(不监听 controller
                                // 后续变化)——编辑原帖 raw / 草稿加载完成前挂载
                                // 会用空 controller 建空文档,之后镜像回写覆盖
                                // 真内容(毁帖)。内容源就绪后才挂;占位留空,
                                // 加载视觉由草稿遮罩/RichComposer 自身统一提供
                                // (双 spinner 叠影)。
                                // 入场动画结束前也先不挂（构建重，避免掉帧）；
                                // 从快捷回复展开时正文已确定，不必等草稿
                                ? ((!_routeSettled ||
                                          _isLoadingRaw ||
                                          (_isLoadingDraft &&
                                              !_reloadingDraft &&
                                              !widget.initialContentIsComplete))
                                      ? const SizedBox.shrink()
                                      : _fadeIn(
                                          RichComposerEditor(
                                            key: _richKey,
                                            metaBar: PlatformUtils.isDesktop
                                                ? null
                                                : _buildReplyContext(),
                                            onSwitchToSource: () =>
                                                _setViewMode(
                                                  ComposerViewMode.source,
                                                ),
                                            controller: _contentController,
                                            focusNode: _contentFocusNode,
                                            hintText:
                                                context.l10n.editor_hintText,
                                            bodyOverlay:
                                                _buildCharCountOverlay(),
                                            emojiPanelHeight: _emojiPanelHeight,
                                            onEmojiPanelChanged: (show) {
                                              setState(
                                                () => _showEmojiPanel = show,
                                              );
                                            },
                                            mentionDataSource: (term) =>
                                                DiscourseService().searchUsers(
                                                  term: term,
                                                  topicId: widget.topicId,
                                                  categoryId: widget.categoryId,
                                                  includeGroups:
                                                      !_isInPrivateMessageContext,
                                                ),
                                            onFallbackToPlain: () {
                                              if (mounted) {
                                                setState(
                                                  () => _richFallback = true,
                                                );
                                              }
                                            },
                                            // 模式切换由编辑台承载。
                                          ),
                                        ))
                                : MarkdownEditor(
                                    key: _editorKey,
                                    metaBar: PlatformUtils.isDesktop
                                        ? null
                                        : _buildReplyContext(),
                                    onSwitchToRich:
                                        ref
                                            .watch(preferencesProvider)
                                            .useRichComposer
                                        ? () => _setViewMode(
                                            ComposerViewMode.rich,
                                          )
                                        : null,
                                    controller: _contentController,
                                    focusNode: _contentFocusNode,
                                    hintText: context.l10n.editor_hintText,
                                    expands: true,
                                    // 预览已由头部切换器统一承载(对富文本也生效)
                                    showPreviewButton: false,
                                    bodyOverlay: _buildCharCountOverlay(),
                                    emojiPanelHeight: _emojiPanelHeight,
                                    onEmojiPanelChanged: (show) {
                                      setState(() => _showEmojiPanel = show);
                                    },
                                    mentionDataSource: (term) =>
                                        DiscourseService().searchUsers(
                                          term: term,
                                          topicId: widget.topicId,
                                          categoryId: widget.categoryId,
                                          includeGroups:
                                              !_isInPrivateMessageContext, // 私信不允许提及群组
                                        ),
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 草稿加载遮罩（加载超过一小段时间才淡入）
                if (_isLoadingDraft && _loadingOverlayVisible)
                  Positioned.fill(
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 160),
                      builder: (context, opacity, child) =>
                          Opacity(opacity: opacity, child: child),
                      child: Container(
                        decoration: ShapeDecoration(
                          color: theme.colorScheme.surface.withValues(
                            alpha: 0.7,
                          ),
                          shape: RoundedSuperellipseBorder(
                            borderRadius: BorderRadius.vertical(
                              top: context.shapes.radius(16),
                            ),
                          ),
                        ),
                        child: const Center(child: LoadingSpinner()),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    return CallbackShortcuts(
      bindings: {
        for (final activator in composerQuickPanelActivators())
          activator: _showQuickPanel,
        for (final activator in composerSubmitActivators())
          activator: () {
            if (!_isSubmitting && !_isLoadingRaw) _submit();
          },
      },
      child: sheet,
    );
  }
}
