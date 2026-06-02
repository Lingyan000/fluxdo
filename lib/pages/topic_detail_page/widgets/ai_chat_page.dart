import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:jovial_svg/jovial_svg.dart';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:path_provider/path_provider.dart';

import '../../../l10n/s.dart';
import '../../../models/topic.dart';
import '../../../utils/dialog_utils.dart';
import '../../../services/discourse/discourse_service.dart';
import '../../../services/toast_service.dart';
import '../../../widgets/ai/ai_model_select_sheet.dart';
import '../../../widgets/ai/ai_quick_prompts_bar.dart';
import '../../../widgets/share/ai_share_image_preview.dart';
import '../../../widgets/common/dismissible_popup_menu.dart';
import 'ai_chat_input.dart';
import 'ai_chat_message_item.dart';
import 'ai_context_selector.dart';

/// 话题级 AI 聊天模式（图像/文本）
///
/// 每个话题独立维护，autoDispose 让退出后自动重置。null = 跟随当前选中模型
/// 的 output 推断（首次进入时）。用户主动切换后会持有具体值。
final topicChatModeProvider = StateProvider.autoDispose
    .family<PromptType?, int>((_, topicId) => null);

/// AI 聊天全屏页面
class AiChatPage extends ConsumerStatefulWidget {
  final int topicId;
  final TopicDetail? detail;

  /// 状态栏高度（从父 context 传入，modal 内部会清零 padding.top）
  final double topPadding;

  /// 嵌入模式（PageView 中使用），渲染为 Scaffold + AppBar
  final bool embedded;

  /// 回复话题回调（将 AI 回复内容预填到回复框）
  final void Function(String content)? onReplyToTopic;

  const AiChatPage({
    super.key,
    required this.topicId,
    this.topPadding = 0,
    this.embedded = false,
    this.detail,
    this.onReplyToTopic,
  });

  @override
  ConsumerState<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends ConsumerState<AiChatPage> {
  /// 已获取到的上下文帖子（按 postNumber 升序）
  final List<TopicPostContext> _contextPosts = [];

  /// 已获取的帖子 ID 集合（避免重复请求）
  final Set<int> _fetchedPostIds = {};

  /// 是否正在加载上下文
  bool _isLoadingContext = false;

  /// 上一次加载使用的 scope，用于检测变化
  ContextScope? _lastLoadedScope;

  /// 多选模式
  bool _selectionMode = false;
  final Set<String> _selectedMessageIds = {};

  @override
  void didUpdateWidget(AiChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.detail != oldWidget.detail && widget.detail != null) {
      _ensureContextPosts();
    }
  }

  /// 确保上下文帖子已加载，根据当前 scope 需要的数量
  Future<void> _ensureContextPosts() async {
    final detail = widget.detail;
    if (detail == null || _isLoadingContext) return;

    final scope = ref.read(topicAiContextScopeProvider(widget.topicId));

    // 计算需要多少条帖子
    final stream = detail.postStream.stream;
    final needed = _postCountForScope(scope, stream.length);
    final neededIds = stream.take(needed).toList();

    // 检查是否已经有足够的帖子
    if (neededIds.every(_fetchedPostIds.contains)) {
      _lastLoadedScope = scope;
      _syncToNotifier(detail.title);
      return;
    }

    // 找出缺失的帖子 ID
    final missingIds = neededIds
        .where((id) => !_fetchedPostIds.contains(id))
        .toList();
    if (missingIds.isEmpty) return;

    setState(() => _isLoadingContext = true);

    try {
      // 优先从已加载的 detail.postStream.posts 中取
      final loadedPosts = detail.postStream.posts;
      final loadedMap = {for (final p in loadedPosts) p.id: p};

      final fromLoaded = <TopicPostContext>[];
      final stillMissing = <int>[];

      for (final id in missingIds) {
        final post = loadedMap[id];
        if (post != null) {
          fromLoaded.add(
            TopicPostContext(
              postNumber: post.postNumber,
              username: post.username,
              cooked: post.cooked,
            ),
          );
          _fetchedPostIds.add(id);
        } else {
          stillMissing.add(id);
        }
      }

      _contextPosts.addAll(fromLoaded);

      // 仍然缺失的通过 API 获取
      if (stillMissing.isNotEmpty) {
        final service = DiscourseService();
        // getPosts 一次最多获取合理数量，分批获取
        for (var i = 0; i < stillMissing.length; i += 20) {
          final batch = stillMissing.sublist(
            i,
            (i + 20).clamp(0, stillMissing.length),
          );
          final postStream = await service.getPosts(widget.topicId, batch);
          for (final post in postStream.posts) {
            if (!_fetchedPostIds.contains(post.id)) {
              _contextPosts.add(
                TopicPostContext(
                  postNumber: post.postNumber,
                  username: post.username,
                  cooked: post.cooked,
                ),
              );
              _fetchedPostIds.add(post.id);
            }
          }
        }
      }

      // 按 postNumber 排序
      _contextPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));

      _lastLoadedScope = scope;
      if (mounted) {
        _syncToNotifier(detail.title);
      }
    } catch (_) {
      // 加载失败仍允许聊天
    } finally {
      if (mounted) {
        setState(() => _isLoadingContext = false);
      }
    }
  }

  /// 当 scope 变更时检查是否需要加载更多帖子
  void _onScopeChanged(ContextScope newScope) {
    ref.read(topicAiContextScopeProvider(widget.topicId).notifier).state =
        newScope;

    final detail = widget.detail;
    if (detail == null) return;

    final stream = detail.postStream.stream;
    final needed = _postCountForScope(newScope, stream.length);
    final neededIds = stream.take(needed).toSet();

    // 检查是否缺少帖子
    if (!neededIds.every(_fetchedPostIds.contains)) {
      _ensureContextPosts();
    }
  }

  /// 根据 scope 返回需要的帖子数量
  int _postCountForScope(ContextScope scope, int total) {
    return switch (scope) {
      ContextScope.firstPostOnly => 1,
      ContextScope.first5 => 5.clamp(0, total),
      ContextScope.first10 => 10.clamp(0, total),
      ContextScope.first20 => 20.clamp(0, total),
      ContextScope.all => total,
    };
  }

  /// 同步上下文帖子到 Notifier
  void _syncToNotifier(String title) {
    ref
        .read(topicAiChatProvider(widget.topicId).notifier)
        .setContextPosts(title, _contextPosts);
  }

  ({AiProvider provider, AiModel model})? _currentModel() {
    final selected = ref.read(topicSelectedAiModelProvider(widget.topicId));
    if (selected != null) return selected;

    // 用户没有显式选择 → 有明确模式时按该模式选；首次进入没有模式时
    // 默认按文本聊天选，避免被生图默认/上次生图模型带进 image 模式。
    final mode = ref.read(topicChatModeProvider(widget.topicId));
    if (mode != null) {
      final modeModel = _preferredModelForMode(mode);
      if (modeModel != null) return modeModel;
    }

    final textModel = _preferredModelForMode(PromptType.text);
    if (textModel != null) return textModel;

    final defaultModel = ref.read(defaultAiModelProvider);
    final lastUsed = ref.read(lastUsedAiAssistantModelProvider);
    return defaultModel ?? lastUsed;
  }

  ({AiProvider provider, AiModel model})? _modelByKey(String? key) {
    if (key == null || key.isEmpty) return null;
    final separator = key.indexOf(':');
    if (separator <= 0 || separator == key.length - 1) return null;
    final providerId = key.substring(0, separator);
    final modelId = key.substring(separator + 1);
    final all = ref.read(allAvailableAiModelsProvider);
    for (final item in all) {
      if (item.provider.id == providerId && item.model.id == modelId) {
        return item;
      }
    }
    return null;
  }

  bool _matchesMode(AiModel model, PromptType mode) {
    return mode == PromptType.image
        ? model.output.contains(Modality.image)
        : model.output.contains(Modality.text);
  }

  ({AiProvider provider, AiModel model})? _preferredModelForMode(
    PromptType mode,
  ) {
    final explicitDefault = _modelByKey(
      mode == PromptType.image
          ? ref.read(defaultImageAiModelKeyProvider)
          : ref.read(defaultTextAiModelKeyProvider),
    );
    if (explicitDefault != null &&
        _matchesMode(explicitDefault.model, mode)) {
      return explicitDefault;
    }

    final lastModeUsed = mode == PromptType.image
        ? ref.read(lastUsedImageAiModelProvider)
        : ref.read(lastUsedTextAiModelProvider);
    if (lastModeUsed != null && _matchesMode(lastModeUsed.model, mode)) {
      return lastModeUsed;
    }

    return _firstModelForMode(mode);
  }

  void _rememberModel(({AiProvider provider, AiModel model}) model) {
    ref.read(topicSelectedAiModelProvider(widget.topicId).notifier).state =
        model;
    final isImage = model.model.output.contains(Modality.image);
    // 同步当前模式（如果用户切到了别的 modality 的模型，模式跟着走）
    ref.read(topicChatModeProvider(widget.topicId).notifier).state =
        isImage ? PromptType.image : PromptType.text;
    unawaited(
      setLastUsedAiAssistantModel(
        ref,
        model.provider.id,
        model.model.id,
        isImageMode: isImage,
      ),
    );
  }

  /// 找一个支持指定模式的模型
  ///
  /// 优先级：该模式的 default → 全局 default 如果匹配 → allModels 第一个匹配
  ({AiProvider provider, AiModel model})? _firstModelForMode(PromptType mode) {
    final explicitDefault = _modelByKey(
      mode == PromptType.image
          ? ref.read(defaultImageAiModelKeyProvider)
          : ref.read(defaultTextAiModelKeyProvider),
    );
    if (explicitDefault != null &&
        _matchesMode(explicitDefault.model, mode)) {
      return explicitDefault;
    }

    final defaultModel = ref.read(defaultAiModelProvider);
    if (defaultModel != null && _matchesMode(defaultModel.model, mode)) {
      return defaultModel;
    }
    final all = ref.read(allAvailableAiModelsProvider);
    for (final item in all) {
      if (_matchesMode(item.model, mode)) return item;
    }
    return null;
  }

  /// 切换聊天模式（图像/文本）
  ///
  /// - 切到图像但用户没配图像模型 → 弹引导 dialog（→ 设置页）
  /// - 否则写入 [topicChatModeProvider]，并切到该模式上次用的模型
  void _switchMode(PromptType mode) {
    if (mode == PromptType.image && !_hasModelForMode(PromptType.image)) {
      _showImageModelMissingDialog();
      return;
    }
    final current = _currentModel();
    final currentIsImage =
        current?.model.output.contains(Modality.image) ?? false;
    if ((mode == PromptType.image) == currentIsImage && current != null) {
      // 当前模型已经匹配目标模式，仅同步 mode 状态
      ref.read(topicChatModeProvider(widget.topicId).notifier).state = mode;
      return;
    }
    final target = _preferredModelForMode(mode);
    ref.read(topicChatModeProvider(widget.topicId).notifier).state = mode;
    if (target != null) {
      _rememberModel(target);
    }
  }

  Future<void> _showImageModelMissingDialog() async {
    final theme = Theme.of(context);
    final result = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.image_outlined,
            color: theme.colorScheme.primary, size: 32),
        title: Text(S.current.ai_imageModelMissingTitle),
        content: Text(S.current.ai_imageModelMissingMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(S.current.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(S.current.ai_imageModelMissingGoSettings),
          ),
        ],
      ),
    );
    if (result == true && mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const AiProvidersPage(),
        ),
      );
    }
  }

  /// 是否有支持指定模式的可用模型
  bool _hasModelForMode(PromptType mode) {
    return _firstModelForMode(mode) != null;
  }

  /// 获取话题标题
  String get _topicTitle => widget.detail?.title ?? '';

  /// 获取话题 slug
  String? get _topicSlug => widget.detail?.slug;

  /// 进入多选模式
  void _enterSelectionMode() {
    setState(() {
      _selectionMode = true;
      _selectedMessageIds.clear();
    });
  }

  /// 退出多选模式
  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedMessageIds.clear();
    });
  }

  /// 切换消息选中状态
  void _toggleMessageSelection(String messageId) {
    setState(() {
      if (_selectedMessageIds.contains(messageId)) {
        _selectedMessageIds.remove(messageId);
      } else {
        _selectedMessageIds.add(messageId);
      }
    });
  }

  /// 导出选中的消息为图片
  void _exportSelectedMessages() {
    final chatState = ref.read(topicAiChatProvider(widget.topicId));
    final selectedMessages = chatState.messages
        .where((m) => _selectedMessageIds.contains(m.id))
        .toList();

    if (selectedMessages.isEmpty) {
      ToastService.show(S.current.ai_selectExportMessages);
      return;
    }

    _exitSelectionMode();

    AiShareImagePreview.showMessages(
      context,
      messages: selectedMessages,
      topicTitle: _topicTitle,
      topicId: widget.topicId,
      topicSlug: _topicSlug,
      onReplyToTopic: _onReplyImageReady,
    );
  }

  /// 单条消息导出图片
  void _shareMessageAsImage(AiChatMessage message) {
    AiShareImagePreview.show(
      context,
      message: message,
      topicTitle: _topicTitle,
      topicId: widget.topicId,
      topicSlug: _topicSlug,
      onReplyToTopic: _onReplyImageReady,
    );
  }

  /// 复制消息文本
  void _copyMessageText(AiChatMessage message) {
    Clipboard.setData(ClipboardData(text: message.content));
    ToastService.showSuccess(S.current.ai_copiedToClipboard);
  }

  /// 预览页上传完成后的回调
  void _onReplyImageReady(String imageMarkdown) {
    widget.onReplyToTopic?.call(imageMarkdown);
  }

  /// 把生成的图片附件回复到话题：上传到 Discourse → 拿 markdown → 通过
  /// [widget.onReplyToTopic] 让外层把 markdown 预填到回复框
  Future<void> _replyImageToTopic(AiChatAttachment attachment) async {
    final replyCallback = widget.onReplyToTopic;
    if (replyCallback == null) return;

    ToastService.showInfo(S.current.ai_replyToTopicUploading);

    try {
      final filePath = await _attachmentToTempFile(attachment);
      if (filePath == null) {
        throw Exception('attachment has no readable bytes');
      }
      final service = DiscourseService();
      final result = await service.uploadImage(filePath);
      final markdown = result.toMarkdown(alt: 'AI generated');
      replyCallback(markdown);
      ToastService.showSuccess(S.current.ai_replyToTopicSuccess);
    } catch (e) {
      debugPrint('[AiChatPage] _replyImageToTopic error: $e');
      ToastService.showError(S.current.ai_replyToTopicUploadFailed);
    }
  }

  /// 把 attachment 的内容写到临时文件，返回 path
  ///
  /// 优先用 localPath（生成图片走 path_provider 已落盘）；fallback 到
  /// base64Data（多模态用户上传图）
  Future<String?> _attachmentToTempFile(AiChatAttachment attachment) async {
    final localPath = attachment.localPath;
    if (localPath != null && localPath.isNotEmpty && File(localPath).existsSync()) {
      return localPath;
    }
    final b64 = attachment.base64Data;
    if (b64 != null && b64.isNotEmpty) {
      final bytes = base64Decode(b64);
      final ext = _extFromMime(attachment.mimeType);
      final tempDir = await getTemporaryDirectory();
      final fileName = 'ai_reply_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final tempFile = File('${tempDir.path}/$fileName');
      await tempFile.writeAsBytes(bytes);
      return tempFile.path;
    }
    return null;
  }

  String _extFromMime(String mime) {
    final lower = mime.toLowerCase();
    if (lower.contains('jpeg') || lower.contains('jpg')) return 'jpg';
    if (lower.contains('webp')) return 'webp';
    if (lower.contains('gif')) return 'gif';
    return 'png';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chatState = ref.watch(topicAiChatProvider(widget.topicId));
    final chatNotifier = ref.read(topicAiChatProvider(widget.topicId).notifier);

    // 首次 build 且有 detail 时加载上下文
    if (widget.detail != null && _lastLoadedScope == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureContextPosts();
      });
    }

    if (widget.embedded) {
      return _buildEmbedded(context, theme, chatState, chatNotifier);
    }
    return _buildSheet(context, theme, chatState, chatNotifier);
  }

  /// 嵌入模式（PageView 中使用）：Scaffold + AppBar
  Widget _buildEmbedded(
    BuildContext context,
    ThemeData theme,
    TopicAiChatState chatState,
    TopicAiChatNotifier chatNotifier,
  ) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: 12,
        title: _selectionMode
            ? _buildSelectionToolbar(context, theme)
            : _buildHeaderTitle(context, chatState, dense: true),
        centerTitle: false,
        actions: _selectionMode
            ? null
            : _buildToolbarActions(context, theme, chatState, chatNotifier),
      ),
      body: _buildBody(context, theme, chatState, chatNotifier),
    );
  }

  /// 头部标题：第一行会话标题（无则"AI 助手"），第二行当前模型（可点切换）
  Widget _buildHeaderTitle(
    BuildContext context,
    TopicAiChatState chatState, {
    required bool dense,
  }) {
    final theme = Theme.of(context);
    return Consumer(
      builder: (context, ref, _) {
        ref.watch(topicSelectedAiModelProvider(widget.topicId));
        ref.watch(defaultAiModelProvider);
        ref.watch(defaultTextAiModelProvider);
        ref.watch(defaultImageAiModelProvider);
        ref.watch(lastUsedAiAssistantModelProvider);
        ref.watch(lastUsedTextAiModelProvider);
        ref.watch(lastUsedImageAiModelProvider);
        ref.watch(topicChatModeProvider(widget.topicId));
        final current = _currentModel();
        final session = chatState.sessions
            .where((s) => s.id == chatState.currentSessionId)
            .cast<AiChatSession?>()
            .firstWhere((_) => true, orElse: () => null);
        final title = (session?.title?.trim().isNotEmpty ?? false)
            ? session!.title!
            : context.l10n.ai_title;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w500,
                      fontSize: dense ? 15 : 16,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (current != null)
                    // AppBar 只显示当前模型名（不带图标，不点击 — 切换在底部）
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        current.model.name ?? current.model.id,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }


  /// BottomSheet 模式（当前默认）
  Widget _buildSheet(
    BuildContext context,
    ThemeData theme,
    TopicAiChatState chatState,
    TopicAiChatNotifier chatNotifier,
  ) {
    final mediaQuery = MediaQuery.of(context);
    final bottomInset = mediaQuery.viewInsets.bottom;
    final screenHeight = mediaQuery.size.height;
    final contentHeight = (screenHeight * 0.9).clamp(
      0.0,
      screenHeight - widget.topPadding - bottomInset,
    );

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        height: contentHeight,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              // 顶部拖动条
              Container(
                margin: const EdgeInsets.symmetric(vertical: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.3,
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // 自定义标题栏
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _selectionMode
                    ? _buildSelectionToolbar(context, theme)
                    : Row(
                        children: [
                          Expanded(
                            child: _buildHeaderTitle(
                              context,
                              chatState,
                              dense: false,
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: _buildToolbarActions(
                              context,
                              theme,
                              chatState,
                              chatNotifier,
                            ),
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 8),

              // Body
              Expanded(
                child: _buildBody(context, theme, chatState, chatNotifier),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 工具栏操作按钮（两种模式共用）
  List<Widget> _buildToolbarActions(
    BuildContext context,
    ThemeData theme,
    TopicAiChatState chatState,
    TopicAiChatNotifier chatNotifier,
  ) {
    return [
      Consumer(
        builder: (context, ref, _) {
          final scope = ref.watch(
            topicAiContextScopeProvider(widget.topicId),
          );
          return AiContextSelector(
            currentScope: scope,
            onChanged: _onScopeChanged,
          );
        },
      ),
      if (chatState.messages.isNotEmpty)
        IconButton(
          icon: const Icon(Icons.check_box_outlined),
          tooltip: context.l10n.ai_multiSelectExport,
          iconSize: 20,
          onPressed: _enterSelectionMode,
        ),
      SwipeDismissiblePopupMenuButton<String>(
        icon: const Icon(Icons.more_vert),
        tooltip: context.l10n.ai_moreTooltip,
        iconSize: 20,
        onSelected: (value) {
          switch (value) {
            case 'new_session':
              chatNotifier.createNewSession();
            case 'history':
              _showSessionHistory(context, chatState, chatNotifier);
            case 'clear':
              _confirmClear(context, chatNotifier);
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'new_session',
            child: ListTile(
              leading: const Icon(Icons.add_comment_outlined),
              title: Text(context.l10n.ai_newSession),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
          if (chatState.sessions.isNotEmpty)
            PopupMenuItem(
              value: 'history',
              child: ListTile(
                leading: const Icon(Icons.history),
                title: Text(context.l10n.ai_sessionHistory),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          if (chatState.messages.isNotEmpty)
            PopupMenuItem(
              value: 'clear',
              child: ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(context.l10n.ai_clearChat),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
        ],
      ),
    ];
  }

  /// 聊天内容主体（两种模式共用）
  Widget _buildBody(
    BuildContext context,
    ThemeData theme,
    TopicAiChatState chatState,
    TopicAiChatNotifier chatNotifier,
  ) {
    return Column(
      children: [
        // 上下文加载提示
        if (_isLoadingContext)
          LinearProgressIndicator(
            minHeight: 2,
            color: theme.colorScheme.primary,
          ),

        // 聊天主要内容区
        Expanded(
          child: chatState.messages.isEmpty
              ? _buildEmptyState(context, theme)
              : _buildMessageList(context, ref, chatState),
        ),

        // 底部输入区
        // 用 Consumer 监听模型切换：附件按钮（allowAttachments）需要根据
        // 当前模型 input 模态实时显隐
        Consumer(
          builder: (context, ref, _) {
            ref.watch(topicSelectedAiModelProvider(widget.topicId));
            ref.watch(defaultAiModelProvider);
            ref.watch(defaultTextAiModelProvider);
            ref.watch(defaultImageAiModelProvider);
            ref.watch(lastUsedAiAssistantModelProvider);
            ref.watch(lastUsedTextAiModelProvider);
            ref.watch(lastUsedImageAiModelProvider);
            ref.watch(topicChatModeProvider(widget.topicId));
            final currentModel = _currentModel();
            final isImageMode = _currentPresetType() == PromptType.image;
            return AiChatInput(
              isGenerating: chatState.isGenerating,
              allowAttachments:
                  currentModel?.model.input.contains(Modality.image) ?? false,
              isImageMode: isImageMode,
              canEnterImageMode: _hasModelForMode(PromptType.image),
              onToggleImageMode: () => _switchMode(
                isImageMode ? PromptType.text : PromptType.image,
              ),
              onSend: (content, attachments) {
                final scope = ref.read(
                  topicAiContextScopeProvider(widget.topicId),
                );
                final model = _currentModel();
                if (model == null) return;
                _rememberModel(model);
                chatNotifier.sendMessage(
                  content,
                  scope,
                  selectedModel: model,
                  attachments: attachments.isEmpty ? null : attachments,
                  thinkingConfig: ref.read(aiThinkingConfigProvider),
                );
              },
              onStop: chatNotifier.stopGeneration,
              modelButton: currentModel == null
                  ? null
                  : _ModelLogoButton(
                      allModels:
                          ref.watch(allAvailableAiModelsProvider),
                      current: currentModel,
                      onChanged: _rememberModel,
                    ),
              thinkingButton:
                  currentModel != null &&
                          currentModel.model.abilities
                              .contains(ModelAbility.reasoning)
                      ? _ThinkingButton(ref: ref)
                      : null,
            );
          },
        ),
      ],
    );
  }

  /// 当前应该用哪种 preset
  ///
  /// 优先级：用户显式选的模式 > 当前模型推断 > 文本
  PromptType _currentPresetType() {
    final mode = ref.read(topicChatModeProvider(widget.topicId));
    if (mode != null) return mode;
    final model = _currentModel()?.model;
    if (model != null && model.output.contains(Modality.image)) {
      return PromptType.image;
    }
    return PromptType.text;
  }

  /// AiQuickPromptsBar 选完一个 preset（已渲染好的最终 prompt）后调用
  ///
  /// [aspect] 是用户在维度面板选的（或 preset 默认）aspect ratio，会透传给
  /// 生图 API 的 size 参数（OpenAI ImageSize / Gemini imageConfig.aspectRatio）
  void _sendPresetPrompt(String prompt, {String? aspect}) {
    final scope = ref.read(topicAiContextScopeProvider(widget.topicId));
    final model = _currentModel();
    if (model == null) return;
    _rememberModel(model);
    ref.read(topicAiChatProvider(widget.topicId).notifier).sendMessage(
          prompt,
          scope,
          selectedModel: model,
          thinkingConfig: ref.read(aiThinkingConfigProvider),
          imageAspect: aspect,
        );
  }

  Widget _buildEmptyState(BuildContext context, ThemeData theme) {
    return Consumer(
      builder: (context, ref, _) {
        // 监听模型/模式相关 provider，让模式切换时空状态视觉跟着变
        ref.watch(topicSelectedAiModelProvider(widget.topicId));
        ref.watch(defaultAiModelProvider);
        ref.watch(defaultTextAiModelProvider);
        ref.watch(defaultImageAiModelProvider);
        ref.watch(lastUsedAiAssistantModelProvider);
        ref.watch(lastUsedTextAiModelProvider);
        ref.watch(lastUsedImageAiModelProvider);
        ref.watch(topicChatModeProvider(widget.topicId));
        ref.watch(allAvailableAiModelsProvider);
        final type = _currentPresetType();
        final isImage = type == PromptType.image;

        // 模式区分：image 用橙色 accent + palette icon（调色板，比 auto_awesome
        // 更切题）+ "生成图片"；text 用 primary + chat_bubble icon + "ai_askTitle"
        final accent = isImage
            ? const Color(0xFFEA580C)
            : theme.colorScheme.primary;
        final iconData = isImage
            ? Icons.palette_outlined
            : Icons.chat_bubble_outline_rounded;
        final title = isImage
            ? context.l10n.ai_imageGenTitle
            : context.l10n.ai_askTitle;
        final subtitle = isImage
            ? context.l10n.ai_imageGenSubtitle
            : context.l10n.ai_askSubtitle;

        // 参考徽章页风格：oversized icon 作右上 watermark（5% accent），
        // 真实内容（subtitle + stacked pills）左对齐顶部。无独立 title 文字。
        // SizedBox 强制铺满 Expanded 给的宽度，避免父 Column.center 把内容
        // 收缩到 intrinsic 宽度后视觉居中
        return SizedBox(
          width: double.infinity,
          child: Stack(
            children: [
              // 背景 watermark icon — 右上角溢出一点，5% accent alpha
              Positioned(
                right: -28,
                top: -20,
                child: Icon(
                  iconData,
                  size: 180,
                  color: accent.withValues(alpha: 0.06),
                ),
              ),
              // Positioned.fill 让 ScrollView 拿到 viewport 约束，能正确滚动
              Positioned.fill(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                    // 小一号 accent 色标题（取代之前的圆形 icon + titleMedium）
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.5,
                        color: accent,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurface,
                        height: 1.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 24),
                    AiQuickPromptsBar(
                      type: type,
                      topicTitle: _topicTitle,
                      stacked: true,
                      onPick: (preset, dimensionValues, rendered, aspect) {
                        _sendPresetPrompt(rendered, aspect: aspect);
                      },
                    ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMessageList(
    BuildContext context,
    WidgetRef ref,
    TopicAiChatState chatState,
  ) {
    final messages = chatState.messages;
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[messages.length - 1 - index];
        return AiChatMessageItem(
          message: message,
          onRetry: message.status == MessageStatus.error
              ? () {
                  final scope = ref.read(
                    topicAiContextScopeProvider(widget.topicId),
                  );
                  final model = _currentModel();
                  if (model == null) return;
                  _rememberModel(model);
                  ref
                      .read(topicAiChatProvider(widget.topicId).notifier)
                      .retryLastMessage(scope, selectedModel: model);
                }
              : null,
          onShareAsImage: message.status == MessageStatus.completed &&
                  message.content.isNotEmpty
              ? () => _shareMessageAsImage(message)
              : null,
          onCopyText: message.status == MessageStatus.completed &&
                  message.content.isNotEmpty
              ? () => _copyMessageText(message)
              : null,
          onReplyImage: widget.onReplyToTopic != null &&
                  message.status == MessageStatus.completed
              ? (att) => _replyImageToTopic(att)
              : null,
          selectionMode: _selectionMode,
          isSelected: _selectedMessageIds.contains(message.id),
          onSelectionToggle: _selectionMode
              ? () => _toggleMessageSelection(message.id)
              : null,
        );
      },
    );
  }

  /// 多选模式工具栏
  Widget _buildSelectionToolbar(BuildContext context, ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.close),
              iconSize: 20,
              onPressed: _exitSelectionMode,
            ),
            const SizedBox(width: 4),
            Text(
              context.l10n.ai_selectedCount(_selectedMessageIds.length),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        FilledButton.icon(
          onPressed: _selectedMessageIds.isEmpty
              ? null
              : _exportSelectedMessages,
          icon: const Icon(Icons.image_outlined, size: 18),
          label: Text(context.l10n.ai_exportImage),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          ),
        ),
      ],
    );
  }

  void _showSessionHistory(
    BuildContext context,
    TopicAiChatState chatState,
    TopicAiChatNotifier notifier,
  ) {
    showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return _SessionHistorySheet(
          sessions: chatState.sessions,
          currentSessionId: chatState.currentSessionId,
          onSwitch: (sessionId) {
            notifier.switchSession(sessionId);
            Navigator.pop(ctx);
          },
          onDelete: (sessionId) async {
            await notifier.deleteSession(sessionId);
          },
        );
      },
    );
  }

  void _confirmClear(BuildContext context, TopicAiChatNotifier notifier) {
    showAppDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.ai_clearChatTitle),
        content: Text(context.l10n.ai_clearChatConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () {
              notifier.clearMessages();
              Navigator.pop(ctx);
            },
            child: Text(context.l10n.ai_clearLabel),
          ),
        ],
      ),
    );
  }
}

/// 输入框底部的模型按钮：圆形 logo，点击弹 [showAiModelSelectSheet]
///
/// 视觉参考 Kelivo 底部 model 按钮 —— 不带文字，只 logo，一目了然不占空间。
class _ModelLogoButton extends StatelessWidget {
  final List<({AiProvider provider, AiModel model})> allModels;
  final ({AiProvider provider, AiModel model}) current;
  final ValueChanged<({AiProvider provider, AiModel model})> onChanged;

  const _ModelLogoButton({
    required this.allModels,
    required this.current,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final iconWidget = ModelIcon(
      providerName: current.provider.name,
      modelName: current.model.name ?? current.model.id,
      size: 28,
    );

    if (allModels.length <= 1) {
      // 只有一个模型，点击没意义 → 单纯展示 logo
      return Padding(padding: const EdgeInsets.all(4), child: iconWidget);
    }

    return Tooltip(
      message: S.current.ai_selectModel,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () async {
          final picked = await showAiModelSelectSheet(
            context: context,
            allModels: allModels,
            current: current,
            mode: current.model.output.contains(Modality.image)
                ? PromptType.image
                : PromptType.text,
          );
          if (picked != null) onChanged(picked);
        },
        child: Padding(padding: const EdgeInsets.all(4), child: iconWidget),
      ),
    );
  }
}



/// 会话历史记录列表
class _SessionHistorySheet extends StatefulWidget {
  final List<AiChatSession> sessions;
  final String? currentSessionId;
  final ValueChanged<String> onSwitch;
  final Future<void> Function(String) onDelete;

  const _SessionHistorySheet({
    required this.sessions,
    required this.currentSessionId,
    required this.onSwitch,
    required this.onDelete,
  });

  @override
  State<_SessionHistorySheet> createState() => _SessionHistorySheetState();
}

class _SessionHistorySheetState extends State<_SessionHistorySheet> {
  late List<AiChatSession> _sessions;

  @override
  void initState() {
    super.initState();
    _sessions = List.of(widget.sessions);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.5,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Text(
                    S.current.ai_sessionHistory,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    S.current.ai_sessionCount(_sessions.length),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // 列表
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _sessions.length,
                itemBuilder: (context, index) {
                  final session = _sessions[index];
                  final isCurrent = session.id == widget.currentSessionId;

                  return ListTile(
                    leading: Icon(
                      isCurrent
                          ? Icons.chat_bubble
                          : Icons.chat_bubble_outline,
                      size: 20,
                      color: isCurrent
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    title: Text(
                      _formatSessionTitle(session, index),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            isCurrent ? FontWeight.w500 : FontWeight.normal,
                        color: isCurrent
                            ? theme.colorScheme.primary
                            : null,
                      ),
                    ),
                    subtitle: Text(
                      _formatTime(session.updatedAt),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: isCurrent
                        ? null
                        : IconButton(
                            icon: Icon(
                              Icons.delete_outline,
                              size: 18,
                              color: theme.colorScheme.error,
                            ),
                            onPressed: () async {
                              await widget.onDelete(session.id);
                              if (!mounted) return;
                              _sessions.removeWhere(
                                  (s) => s.id == session.id);
                              if (_sessions.isEmpty) {
                                if (context.mounted) {
                                  Navigator.pop(context);
                                }
                              } else {
                                setState(() {});
                              }
                            },
                          ),
                    onTap: isCurrent
                        ? null
                        : () => widget.onSwitch(session.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatSessionTitle(AiChatSession session, int index) {
    return session.title ?? S.current.ai_sessionTitle(_sessions.length - index);
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 1) return S.current.time_justNow;
    if (diff.inHours < 1) return S.current.time_minutesAgo(diff.inMinutes);
    if (diff.inDays < 1) return S.current.time_hoursAgo(diff.inHours);
    if (diff.inDays < 30) return S.current.time_daysAgo(diff.inDays);

    return '${time.month}/${time.day}';
  }
}

/// 思考深度按钮：灯泡图标随等级变化，点击 toggle，长按弹出选择面板
class _ThinkingButton extends StatelessWidget {
  final WidgetRef ref;
  const _ThinkingButton({required this.ref});

  static String _svgAsset(ThinkingLevel level) {
    return switch (level) {
      ThinkingLevel.off => 'assets/icons/thinking/idea-01-no-rays.svg',
      ThinkingLevel.auto => 'assets/icons/thinking/idea-01-stroke-rounded.svg',
      ThinkingLevel.low => 'assets/icons/thinking/idea-01-no-side-rays.svg',
      ThinkingLevel.medium => 'assets/icons/thinking/idea-01-stroke-rounded.svg',
      ThinkingLevel.high => 'assets/icons/thinking/idea-01-more-rays.svg',
      ThinkingLevel.custom => 'assets/icons/thinking/idea-01-moremore-rays.svg',
    };
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(aiThinkingConfigProvider);
    final isOn = config.isEnabled;
    final theme = Theme.of(context);
    final color = isOn
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;

    return IconButton(
        onPressed: () => _showLevelSheet(context),
        icon: _IdeaIcon(asset: _svgAsset(config.level), color: color, size: 20),
        tooltip: AiL10n.current.thinkingLevelLabel,
        style: IconButton.styleFrom(
          minimumSize: const Size(36, 36),
          padding: EdgeInsets.zero,
        ),
    );
  }

  void _setConfig(ThinkingConfig config) {
    ref.read(aiThinkingConfigProvider.notifier).state = config;
    ref.read(aiChatStorageServiceProvider).setThinkingConfig(config);
  }

  void _showLevelSheet(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        final current = ref.read(aiThinkingConfigProvider);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 12),
              _levelTile(ctx, ThinkingLevel.off,
                  AiL10n.current.thinkingOff, current.level),
              _levelTile(ctx, ThinkingLevel.auto,
                  AiL10n.current.thinkingAuto, current.level),
              _levelTile(ctx, ThinkingLevel.low,
                  AiL10n.current.thinkingLow, current.level),
              _levelTile(ctx, ThinkingLevel.medium,
                  AiL10n.current.thinkingMedium, current.level),
              _levelTile(ctx, ThinkingLevel.high,
                  AiL10n.current.thinkingHigh, current.level),
              _customTile(ctx, current),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _levelTile(BuildContext context, ThinkingLevel level,
      String label, ThinkingLevel current) {
    final cs = Theme.of(context).colorScheme;
    final isSelected = level == current;
    final color = isSelected ? cs.primary : cs.onSurfaceVariant;
    return ListTile(
      leading: _IdeaIcon(asset: _svgAsset(level), color: color, size: 22),
      title: Text(label, style: TextStyle(
          color: isSelected ? cs.primary : null,
          fontWeight: isSelected ? FontWeight.w500 : null)),
      trailing: isSelected
          ? Icon(Icons.check, color: cs.primary, size: 20) : null,
      onTap: () {
        _setConfig(ref.read(aiThinkingConfigProvider)
            .copyWith(level: level));
        Navigator.pop(context);
      },
    );
  }

  Widget _customTile(BuildContext context, ThinkingConfig current) {
    final cs = Theme.of(context).colorScheme;
    final isSelected = current.level == ThinkingLevel.custom;
    return ListTile(
      leading: Icon(Icons.tune, size: 22,
          color: isSelected ? cs.primary : cs.onSurfaceVariant),
      title: Text(AiL10n.current.thinkingCustom, style: TextStyle(
          color: isSelected ? cs.primary : null,
          fontWeight: isSelected ? FontWeight.w500 : null)),
      trailing: isSelected
          ? Text('${current.customBudget}', style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w500, color: cs.primary))
          : null,
      onTap: () {
        Navigator.pop(context);
        _showCustomDialog(context, current);
      },
    );
  }

  void _showCustomDialog(BuildContext context, ThinkingConfig current) {
    final controller = TextEditingController(
        text: '${current.customBudget}');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AiL10n.current.thinkingCustom),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '1024 - 64000',
            border: const OutlineInputBorder(),
            suffixText: 'tokens',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AiL10n.current.cancel),
          ),
          FilledButton(
            onPressed: () {
              final val = int.tryParse(controller.text.trim());
              if (val != null && val >= 1024) {
                _setConfig(ThinkingConfig(
                  level: ThinkingLevel.custom,
                  customBudget: val.clamp(1024, 64000),
                ));
              }
              Navigator.pop(ctx);
            },
            child: Text(AiL10n.current.modelDetailConfirm),
          ),
        ],
      ),
    );
  }
}

/// 灯泡图标，用 Kelivo 的 idea-01 系列 SVG 渲染，ColorFiltered 着色。
class _IdeaIcon extends StatelessWidget {
  final String asset;
  final Color color;
  final double size;

  const _IdeaIcon({
    required this.asset,
    required this.color,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: ColorFiltered(
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        child: ScalableImageWidget.fromSISource(
          si: ScalableImageSource.fromSvg(
            rootBundle,
            asset,
            warnF: (_) {},
          ),
        ),
      ),
    );
  }
}
