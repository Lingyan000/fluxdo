import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxdo/widgets/common/loading_spinner.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_editor.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/draft.dart';
import 'package:fluxdo/models/shortcut_binding.dart';

import 'package:fluxdo/providers/discourse_providers.dart';
import 'package:fluxdo/services/toast_service.dart';
import 'package:dio/dio.dart';
import 'package:fluxdo/services/ai_post_review_service.dart';
import 'package:fluxdo/services/app_error_handler.dart';
import 'package:fluxdo/services/network/exceptions/api_exception.dart';
import 'package:fluxdo/widgets/ai/ai_post_review_button.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_renderer.dart';
import 'package:fluxdo/services/draft_controller.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/providers/shortcut_provider.dart';
import 'package:fluxdo/widgets/topic/topic_editor_helpers.dart';
import '../l10n/s.dart';
import '../utils/dialog_utils.dart';

class CreateTopicPage extends ConsumerStatefulWidget {
  final int? initialCategoryId;
  final List<String>? initialTags;
  final String draftKey;

  const CreateTopicPage({
    super.key,
    this.initialCategoryId,
    this.initialTags,
    this.draftKey = Draft.newTopicKey,
  });

  @override
  ConsumerState<CreateTopicPage> createState() => _CreateTopicPageState();
}

class _CreateTopicPageState extends ConsumerState<CreateTopicPage> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _contentFocusNode = FocusNode();
  final _editorKey = GlobalKey<MarkdownEditorState>();
  late final ShortcutSurfaceBinding _shortcutSurfaceBinding =
      ShortcutSurfaceBinding(
        ref: ref,
        id: ShortcutSurfaceIds.createTopic,
        triggerAction: ShortcutAction.createTopic,
        kind: ShortcutSurfaceKind.route,
        repeatBehavior: ShortcutSurfaceRepeatBehavior.reveal,
        passthroughActions: ShortcutSurfaceActionSets.globalRoutePassthrough,
      );
  ModalRoute<dynamic>? _route;

  Category? _selectedCategory;
  List<String> _selectedTags = [];
  bool _isSubmitting = false;
  bool _submitted = false; // 提交成功标志，防止 dispose 重新保存草稿
  bool _showPreview = false;
  String? _templateContent;
  bool _isLoadingDraft = false;
  bool _showEmojiPanel = false;

  final PageController _pageController = PageController();
  int _contentLength = 0;

  // 草稿控制器
  late final DraftController _draftController;

  @override
  void initState() {
    super.initState();
    _contentController.addListener(_updateContentLength);

    // 初始化草稿控制器
    _draftController = DraftController(draftKey: widget.draftKey);

    // 添加草稿自动保存监听
    _titleController.addListener(_onDraftContentChanged);
    _contentController.addListener(_onDraftContentChanged);

    // 加载现有草稿
    _loadExistingDraft();

    // 从当前筛选条件自动填入分类和标签
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyCurrentFilter());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == null || identical(route, _route)) return;
    _route = route;
    _shortcutSurfaceBinding.registerDeferred(
      context,
      onClose: () => Navigator.of(context).maybePop(),
      onFocus: _revealSelf,
    );
  }

  void _revealSelf() {
    final route = _route;
    final navigator = route?.navigator;
    if (route == null || navigator == null || route.isCurrent) return;
    navigator.popUntil((candidate) => identical(candidate, route));
  }

  /// 加载现有草稿
  Future<void> _loadExistingDraft() async {
    setState(() => _isLoadingDraft = true);
    try {
      final draft = await _draftController.loadDraft();
      if (!mounted) return;

      if (draft != null && draft.hasContent) {
        // 弹出恢复草稿对话框
        final restore = await _showRestoreDraftDialog();
        if (restore == true && mounted) {
          _restoreDraft(draft);
        } else if (restore == false && mounted) {
          // 用户选择丢弃，删除草稿
          await _draftController.deleteDraft();
        }
      }
    } finally {
      if (mounted) {
        setState(() => _isLoadingDraft = false);
      }
    }
  }

  /// 显示恢复草稿对话框
  Future<bool?> _showRestoreDraftDialog() async {
    return showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.createTopic_restoreDraft),
        content: Text(context.l10n.createTopic_restoreDraftContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.common_discard),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.common_restore),
          ),
        ],
      ),
    );
  }

  /// 恢复草稿内容
  void _restoreDraft(Draft draft) {
    if (draft.data.title != null) {
      _titleController.text = draft.data.title!;
    }
    if (draft.data.reply != null) {
      _contentController.text = draft.data.reply!;
      _templateContent = null; // 恢复草稿后清除模板标记
    }
    if (draft.data.tags != null && draft.data.tags!.isNotEmpty) {
      setState(() => _selectedTags = List.from(draft.data.tags!));
    }
    // 分类需要在 categories 加载后设置，通过 _applyCurrentFilter 中处理
    if (draft.data.categoryId != null) {
      // 监听 categories 加载完成后设置分类
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _restoreCategoryFromDraft(draft.data.categoryId!);
      });
    }
  }

  /// 从草稿恢复分类
  void _restoreCategoryFromDraft(int categoryId) {
    ref.listenManual(categoriesProvider, (previous, next) {
      next.whenData((categories) {
        if (!mounted) return;
        final category = categories
            .where((c) => c.id == categoryId)
            .firstOrNull;
        if (category != null && category.canCreateTopic) {
          setState(() => _selectedCategory = category);
        }
      });
    }, fireImmediately: true);
  }

  /// 草稿内容变化时触发保存
  void _onDraftContentChanged() {
    final data = DraftData(
      title: _titleController.text,
      reply: _contentController.text,
      categoryId: _selectedCategory?.id,
      tags: _selectedTags.isNotEmpty ? _selectedTags : null,
      action: 'createTopic',
      archetypeId: 'regular',
    );
    _draftController.scheduleSave(data);
  }

  /// 舍弃草稿
  Future<void> _discardDraft() async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.createTopic_discardPost),
        content: Text(context.l10n.createTopic_discardPostContent),
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
      await _draftController.deleteDraft();
      if (mounted) Navigator.of(context).pop();
    }
  }

  void _applyCurrentFilter() async {
    // 优先使用传入的分类，否则使用站点默认分类
    int? targetCategoryId = widget.initialCategoryId;
    targetCategoryId ??= await PreloadedDataService()
        .getDefaultComposerCategoryId();

    // 应用传入的标签
    if (widget.initialTags != null &&
        widget.initialTags!.isNotEmpty &&
        _selectedTags.isEmpty) {
      setState(() => _selectedTags = List.from(widget.initialTags!));
    }

    if (targetCategoryId != null && mounted) {
      // 监听 categories 加载完成
      ref.listenManual(categoriesProvider, (previous, next) {
        next.whenData((categories) {
          if (!mounted) return;
          final category = categories
              .where((c) => c.id == targetCategoryId)
              .firstOrNull;
          if (category != null &&
              category.canCreateTopic &&
              _selectedCategory == null) {
            _onCategorySelected(category);
          }
        });
      }, fireImmediately: true);
    }
  }

  @override
  void dispose() {
    _shortcutSurfaceBinding.disposeDeferred();
    // 移除草稿监听器
    _titleController.removeListener(_onDraftContentChanged);
    _contentController.removeListener(_onDraftContentChanged);

    // 关闭时处理草稿：已提交则跳过，有内容则保存，无内容则删除
    if (!_submitted) {
      if (_titleController.text.trim().isNotEmpty ||
          _contentController.text.trim().isNotEmpty) {
        final data = DraftData(
          title: _titleController.text,
          reply: _contentController.text,
          categoryId: _selectedCategory?.id,
          tags: _selectedTags.isNotEmpty ? _selectedTags : null,
          action: 'createTopic',
          archetypeId: 'regular',
        );
        _draftController.saveNow(data);
      } else {
        // 内容为空，删除草稿
        _draftController.deleteDraft();
      }
    }
    _draftController.dispose();

    _pageController.dispose();
    _contentController.removeListener(_updateContentLength);
    _titleController.dispose();
    _contentController.dispose();
    _contentFocusNode.dispose();
    super.dispose();
  }

  void _updateContentLength() {
    setState(() => _contentLength = _contentController.text.length);
  }

  void _onCategorySelected(Category category) {
    setState(() => _selectedCategory = category);

    final currentContent = _contentController.text.trim();
    if (currentContent.isEmpty ||
        (_templateContent != null &&
            currentContent == _templateContent!.trim())) {
      if (category.topicTemplate != null &&
          category.topicTemplate!.isNotEmpty) {
        _contentController.text = category.topicTemplate!;
        _templateContent = category.topicTemplate;
      } else {
        _contentController.clear();
        _templateContent = null;
      }
    }

    // 触发草稿保存
    _onDraftContentChanged();
  }

  /// 标签变化时触发草稿保存
  void _onTagsChanged(List<String> newTags) {
    setState(() => _selectedTags = newTags);
    _onDraftContentChanged();
  }

  void _togglePreview() {
    if (_showPreview) {
      _pageController.animateToPage(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _pageController.animateToPage(
        1,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      FocusScope.of(context).unfocus();
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      // 预览模式下验证错误不可见，切回编辑模式并提示
      if (_showPreview) {
        _togglePreview();
        ToastService.showInfo(S.current.common_checkInput);
      }
      return;
    }

    // 手动验证内容
    final minContentLength = ref.read(minFirstPostLengthProvider).value ?? 20;
    final contentText = _contentController.text.trim();
    if (contentText.isEmpty) {
      if (_showPreview) _togglePreview();
      ToastService.showInfo(S.current.createTopic_enterContent);
      return;
    }
    if (contentText.length < minContentLength) {
      if (_showPreview) _togglePreview();
      ToastService.showInfo(
        S.current.createTopic_minContentLength(minContentLength),
      );
      return;
    }

    if (_selectedCategory == null) {
      if (_showPreview) _togglePreview();
      ToastService.showInfo(S.current.createTopic_selectCategory);
      return;
    }

    if (_selectedCategory!.minimumRequiredTags > 0 &&
        _selectedTags.length < _selectedCategory!.minimumRequiredTags) {
      if (_showPreview) _togglePreview();
      ToastService.showInfo(
        S.current.createTopic_minTags(_selectedCategory!.minimumRequiredTags),
      );
      return;
    }

    if (_templateContent != null &&
        _contentController.text.trim() == _templateContent!.trim()) {
      final confirm = await showAppDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.common_hint),
          content: Text(context.l10n.createTopic_templateNotModified),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n.createTopic_continueEditing),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n.createTopic_confirmPublish),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    setState(() => _isSubmitting = true);

    try {
      final service = ref.read(discourseServiceProvider);
      final topicId = await service.createTopic(
        title: _titleController.text.trim(),
        raw: _contentController.text,
        categoryId: _selectedCategory!.id,
        tags: _selectedTags.isNotEmpty ? _selectedTags : null,
      );

      // 发送成功后删除草稿
      await _draftController.deleteDraft();
      _submitted = true;

      if (!mounted) return;
      Navigator.of(context).pop(topicId);
    } on PostEnqueuedException {
      // 审核场景：删除草稿，提示用户，关闭编辑器
      await _draftController.deleteDraft();
      _submitted = true;
      if (!mounted) return;
      ToastService.showInfo(S.current.createTopic_pendingReview);
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
      case DraftSaveStatus.pending:
        return const SizedBox.shrink();
      case DraftSaveStatus.saving:
        return SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: theme.colorScheme.outline,
          ),
        );
      case DraftSaveStatus.saved:
        return Icon(
          Icons.cloud_done_outlined,
          size: 18,
          color: theme.colorScheme.outline,
        );
      case DraftSaveStatus.error:
        return Icon(
          Icons.cloud_off_outlined,
          size: 18,
          color: theme.colorScheme.error,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(categoriesProvider);
    final tagsAsync = ref.watch(tagsProvider);
    final canTagTopics = ref.watch(canTagTopicsProvider).value ?? false;
    final theme = Theme.of(context);

    // 获取站点配置的最小长度
    final minTitleLength = ref.watch(minTopicTitleLengthProvider).value ?? 15;

    return PopScope(
      canPop: !_showEmojiPanel,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        _editorKey.currentState?.closeEmojiPanel();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: Text(context.l10n.createTopic_title),
          scrolledUnderElevation: 0,
          actions: [
            // 草稿保存状态指示器
            ValueListenableBuilder<DraftSaveStatus>(
              valueListenable: _draftController.statusNotifier,
              builder: (context, status, _) {
                return _buildDraftStatusIndicator(status, theme);
              },
            ),
            // 舍弃按钮
            TextButton(
              onPressed: _isSubmitting ? null : _discardDraft,
              child: Text(context.l10n.common_discard),
            ),
            AiPostReviewButton(
              titleBuilder: () => _titleController.text,
              contentBuilder: () => _contentController.text,
              target: AiPostReviewTarget.topic,
              enabled: !_isSubmitting,
              categoryNameBuilder: () => _selectedCategory?.name,
              categoryDescriptionBuilder: () => _selectedCategory?.description,
              tagsBuilder: () => _selectedTags,
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: FilledButton(
                onPressed: _isSubmitting ? null : _submit,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                child: _isSubmitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(context.l10n.common_publish),
              ),
            ),
          ],
        ),
        body: categoriesAsync.when(
          data: (categories) {
            return Stack(
              children: [
                Column(
                  children: [
                    Expanded(
                      child: PageView(
                        controller: _pageController,
                        allowImplicitScrolling: true,
                        onPageChanged: (index) {
                          setState(() {
                            _showPreview = index == 1;
                          });
                          if (_showPreview) {
                            FocusScope.of(context).unfocus();
                            _editorKey.currentState?.closeEmojiPanel();
                          }
                        },
                        children: [
                          // Page 0: 编辑模式
                          Column(
                            children: [
                              // 标题 + 元数据区域
                              Form(
                                key: _formKey,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    16,
                                    20,
                                    0,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      // 标题输入
                                      TextFormField(
                                        controller: _titleController,
                                        decoration: InputDecoration(
                                          hintText: context
                                              .l10n
                                              .createTopic_titleHint,
                                          hintStyle: TextStyle(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant
                                                .withValues(alpha: 0.5),
                                            fontWeight: FontWeight.normal,
                                          ),
                                          border: InputBorder.none,
                                          contentPadding: EdgeInsets.zero,
                                          isDense: true,
                                        ),
                                        style: theme.textTheme.headlineSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w900,
                                              letterSpacing: -0.5,
                                            ),
                                        maxLines: null,
                                        maxLength: 200,
                                        buildCounter:
                                            (
                                              context, {
                                              required currentLength,
                                              required isFocused,
                                              maxLength,
                                            }) => null,
                                        validator: (value) {
                                          if (value == null ||
                                              value.trim().isEmpty) {
                                            return context
                                                .l10n
                                                .createTopic_enterTitle;
                                          }
                                          if (value.trim().length <
                                              minTitleLength) {
                                            return context.l10n
                                                .createTopic_minTitleLength(
                                                  minTitleLength,
                                                );
                                          }
                                          return null;
                                        },
                                        onTap: () {
                                          _editorKey.currentState
                                              ?.closeEmojiPanel();
                                        },
                                      ),

                                      const SizedBox(height: 16),

                                      // 元数据区域 (分类 + 标签)
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          CategoryTrigger(
                                            category: _selectedCategory,
                                            categories: categories,
                                            onSelected: _onCategorySelected,
                                          ),
                                          if (canTagTopics) ...[
                                            const SizedBox(height: 12),
                                            tagsAsync.when(
                                              data: (tags) => TagsArea(
                                                selectedCategory:
                                                    _selectedCategory,
                                                selectedTags: _selectedTags,
                                                allTags: tags,
                                                onTagsChanged: _onTagsChanged,
                                              ),
                                              loading: () =>
                                                  const SizedBox.shrink(),
                                              error: (e, s) =>
                                                  const SizedBox.shrink(),
                                            ),
                                          ],
                                        ],
                                      ),

                                      const SizedBox(height: 20),
                                      Divider(
                                        height: 1,
                                        color: theme.colorScheme.outlineVariant
                                            .withValues(alpha: 0.3),
                                      ),
                                    ],
                                  ),
                                ),
                              ),

                              // 字符计数
                              Padding(
                                padding: const EdgeInsets.only(
                                  right: 20,
                                  top: 8,
                                ),
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    context.l10n.createTopic_charCount(
                                      _contentLength,
                                    ),
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),

                              // 内容编辑器
                              Expanded(
                                child: MarkdownEditor(
                                  key: _editorKey,
                                  controller: _contentController,
                                  focusNode: _contentFocusNode,
                                  hintText:
                                      context.l10n.createTopic_contentHint,
                                  expands: true,
                                  emojiPanelHeight: 350,
                                  onTogglePreview: _togglePreview,
                                  isPreview: _showPreview,
                                  onEmojiPanelChanged: (show) {
                                    setState(() => _showEmojiPanel = show);
                                  },
                                  mentionDataSource: (term) => ref
                                      .read(discourseServiceProvider)
                                      .searchUsers(
                                        term: term,
                                        categoryId: _selectedCategory?.id,
                                        includeGroups: true,
                                      ),
                                ),
                              ),
                            ],
                          ),

                          // Page 1: 预览模式
                          SingleChildScrollView(
                            padding: EdgeInsets.fromLTRB(
                              24,
                              24,
                              24,
                              MediaQuery.paddingOf(context).bottom + 80,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _titleController.text.isEmpty
                                      ? context.l10n.createTopic_noTitle
                                      : _titleController.text,
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: -0.5,
                                      ),
                                ),
                                const SizedBox(height: 16),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    if (_selectedCategory != null)
                                      CategoryTrigger(
                                        category: _selectedCategory,
                                        categories: categories,
                                        onSelected: _onCategorySelected,
                                      ),
                                    PreviewTagsList(tags: _selectedTags),
                                  ],
                                ),
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 24),
                                  child: Divider(height: 1),
                                ),
                                if (_contentController.text.isEmpty)
                                  Text(
                                    context.l10n.createTopic_noContent,
                                    style: TextStyle(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  )
                                else
                                  MarkdownBody(data: _contentController.text),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                // 预览模式下的退出预览按钮
                if (_showPreview)
                  Positioned(
                    right: 16,
                    bottom: MediaQuery.paddingOf(context).bottom + 16,
                    child: FloatingActionButton.small(
                      onPressed: _togglePreview,
                      tooltip: context.l10n.common_exitPreview,
                      child: const Icon(Icons.edit_outlined),
                    ),
                  ),
                // 草稿加载遮罩
                if (_isLoadingDraft)
                  Positioned.fill(
                    child: Container(
                      color: theme.colorScheme.surface.withValues(alpha: 0.7),
                      child: const Center(child: LoadingSpinner()),
                    ),
                  ),
              ],
            );
          },
          loading: () => const Center(child: LoadingSpinner()),
          error: (err, stack) => Center(
            child: Text(
              context.l10n.createTopic_loadCategoryFailed(err.toString()),
            ),
          ),
        ),
      ),
    );
  }
}
