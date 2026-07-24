import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxdo/widgets/common/error_view.dart';
import 'package:fluxdo/widgets/common/progressive_top_blur.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_shortcuts.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_switch_fade.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_editor.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/rich_composer_editor.dart';
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
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import '../l10n/s.dart';
import '../utils/dialog_utils.dart';
import 'pending_posts_page.dart';

class CreateTopicPage extends ConsumerStatefulWidget {
  final int? initialCategoryId;
  final List<String>? initialTags;

  /// 预填标题/内容(待审内容撤回重编辑等场景);
  /// 传入任一时跳过草稿恢复弹窗,避免覆盖预填
  final String? initialTitle;
  final String? initialContent;
  final String draftKey;

  const CreateTopicPage({
    super.key,
    this.initialCategoryId,
    this.initialTags,
    this.initialTitle,
    this.initialContent,
    this.draftKey = Draft.newTopicKey,
  });

  @override
  ConsumerState<CreateTopicPage> createState() => _CreateTopicPageState();
}

class _CreateTopicPageState extends ConsumerState<CreateTopicPage> {
  /// 富文本导入失败时本次会话降级纯文本
  bool _richFallback = false;
  final _richKey = GlobalKey<RichComposerEditorState>();

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
  bool _discarded = false; // 用户明确舍弃，防止 dispose 重新保存草稿
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

    // 预填标题/内容(待审内容撤回重编辑等场景):直接落 controller,
    // 并跳过草稿恢复弹窗,避免旧草稿覆盖预填内容
    final hasInitialPrefill = (widget.initialTitle?.isNotEmpty ?? false) ||
        (widget.initialContent?.isNotEmpty ?? false);
    if (hasInitialPrefill) {
      if (widget.initialTitle != null) {
        _titleController.text = widget.initialTitle!;
      }
      if (widget.initialContent != null) {
        _contentController.text = widget.initialContent!;
      }
    } else {
      // 加载现有草稿
      _loadExistingDraft();
    }

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
      _discarded = true;
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
    if (!_submitted && !_discarded) {
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
    // 富文本模式:先强制序列化镜像
    _richKey.currentState?.flushToController();
    if (!_formKey.currentState!.validate()) {
      // 预览模式下验证错误不可见，切回编辑模式并提示
      if (_showPreview) {
        _togglePreview();
        ToastService.showInfo(S.current.common_checkInput);
      }
      // 标题在滚动流里可能已滚出屏,拉回顶部让校验错误可见
      _richKey.currentState?.scrollToTop();
      _editorKey.currentState?.scrollToTop();
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
      // 审核场景：删除草稿，提示用户（带「查看」入口），关闭编辑器
      await _draftController.deleteDraft();
      _submitted = true;
      if (!mounted) return;
      ToastService.show(
        S.current.createTopic_pendingReview,
        type: ToastType.info,
        actionLabel: S.current.review_viewAction,
        onAction: () {
          navigatorKey.currentState?.push(
            MaterialPageRoute(builder: (_) => const PendingPostsPage()),
          );
        },
      );
      Navigator.of(context).pop();
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  /// 滚动头部:顶部透明 AppBar 避让 + 标题输入。写作流只留标题+正文
  /// (分类/标签/字数在底部 ComposerMetaBar 常驻);标题与正文同滚,
  /// 写正文时自然滚出屏,想改标题滚回顶部即可。
  Widget _buildComposerHeader(ThemeData theme, int minTitleLength) {
    // extendBodyBehindAppBar 后滚动内容从屏顶开始,首屏让出渐变模糊层
    // 全高(含消散尾巴 —— 初始态标题不被尾巴遮,滚动上移时才进入
    // 消散区被渐次溶解)
    final topInset = ProgressiveTopBlur.heightFor(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, topInset + 10, 20, 0),
      child: TextFormField(
        controller: _titleController,
        decoration: InputDecoration(
          hintText: context.l10n.createTopic_titleHint,
          hintStyle: TextStyle(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            fontWeight: FontWeight.normal,
          ),
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          isDense: true,
        ),
        style: theme.textTheme.headlineSmall?.copyWith(
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
          if (value == null || value.trim().isEmpty) {
            return context.l10n.createTopic_enterTitle;
          }
          if (value.trim().length < minTitleLength) {
            return context.l10n.createTopic_minTitleLength(minTitleLength);
          }
          return null;
        },
        onTap: () {
          _editorKey.currentState?.closeEmojiPanel();
          _richKey.currentState?.closeEmojiPanel();
        },
      ),
    );
  }

  /// 底部属性条:分类/标签/字数(编辑区与工具栏之间,常驻可改)
  Widget _buildMetaBar(
    List<Category> categories,
    bool canTagTopics,
    AsyncValue<List<String>> tagsAsync,
  ) {
    return ComposerMetaBar(
      category: _selectedCategory,
      categories: categories,
      onCategorySelected: _onCategorySelected,
      showTags: canTagTopics,
      selectedTags: _selectedTags,
      allTags: tagsAsync.value ?? const [],
      onTagsChanged: _onTagsChanged,
      charCount: _contentLength,
    );
  }

  /// 构建草稿保存状态指示器
  /// 草稿保存状态指示器(瞬态):保存中转圈、失败红色警示;
  /// 已保存/空闲不显示 —— 成功无需常驻宣告,失败才需要被看见。
  Widget _buildDraftStatusIndicator(DraftSaveStatus status, ThemeData theme) {
    final Widget child;
    switch (status) {
      case DraftSaveStatus.idle:
      case DraftSaveStatus.pending:
      case DraftSaveStatus.saved:
        return const SizedBox.shrink();
      case DraftSaveStatus.saving:
        child = SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: theme.colorScheme.outline,
          ),
        );
      case DraftSaveStatus.error:
        child = Icon(
          Symbols.cloud_off_rounded,
          size: 18,
          color: theme.colorScheme.error,
        );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(left: 4, right: 4),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(categoriesProvider);
    final tagsAsync = ref.watch(tagsProvider);
    final canTagTopics = ref.watch(canTagTopicsProvider).value ?? false;
    final theme = Theme.of(context);

    // 获取站点配置的最小长度
    final minTitleLength = ref.watch(minTopicTitleLengthProvider).value ?? 15;

    final page = PopScope(
      canPop: !_showEmojiPanel,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        _editorKey.currentState?.closeEmojiPanel();
        _richKey.currentState?.closeEmojiPanel();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        // 顶栏渐变模糊:AppBar 纯透明只承载功能件,模糊/遮罩由 body
        // Stack 顶部的 ProgressiveTopBlur 提供(从上到下消散到全透明,
        // 无均匀毛玻璃的硬下边);分类/标签/字数在底部 ComposerMetaBar
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          title: Text(context.l10n.createTopic_title),
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          // 透明背景下 Material 推导不出状态栏图标亮暗(会给成浅色
          // 图标,浅色主题下隐形),按主题显式指定
          systemOverlayStyle: theme.brightness == Brightness.dark
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark,
          actions: [
            // 草稿保存状态(瞬态:保存中转圈/失败警示;已保存不常驻
            // —— 成功无需一直宣告,失败才需要喊)
            ValueListenableBuilder<DraftSaveStatus>(
              valueListenable: _draftController.statusNotifier,
              builder: (context, status, _) {
                return _buildDraftStatusIndicator(status, theme);
              },
            ),
            // 功能按钮全部图标直出不折叠(⋯ 菜单藏舍弃太难用):
            // 舍弃 🗑 / AI 审核 ✨,tooltip 兜底语义
            IconButton(
              onPressed: _isSubmitting ? null : _discardDraft,
              tooltip: context.l10n.common_discard,
              icon: const Icon(Symbols.delete_rounded, size: 22),
            ),
            // AiPostReviewButton builder 形态:图标按钮即审核结果
            // popover 的锚
            AiPostReviewButton(
              titleBuilder: () => _titleController.text,
              contentBuilder: () => _contentController.text,
              target: AiPostReviewTarget.topic,
              enabled: !_isSubmitting,
              categoryNameBuilder: () => _selectedCategory?.name,
              categoryDescriptionBuilder: () => _selectedCategory?.description,
              tagsBuilder: () => _selectedTags,
              builder: (anchorContext, isReviewing, trigger) {
                // 功能关闭(trigger null 且非审核中)时不占位
                if (trigger == null && !isReviewing) {
                  return const SizedBox.shrink();
                }
                return IconButton(
                  onPressed: trigger,
                  tooltip: context.l10n.aiPostReview_button,
                  icon: isReviewing
                      ? LoadingSpinner(
                          size: 18,
                          color: theme.colorScheme.primary,
                        )
                      : const Icon(Symbols.auto_awesome_rounded, size: 22),
                );
              },
            ),
            const SizedBox(width: 2),
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
        body: Stack(
          children: [
            categoriesAsync.when(
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
                                _richKey.currentState?.closeEmojiPanel();
                              }
                            },
                            children: [
                              // Page 0: 编辑模式 —— 标题/标签/字数打包为
                              // header 注入编辑器滚动流,与正文同滚(手机
                              // 写正文时头部随内容滚出屏,编辑区满格;分类
                              // 已上收 AppBar)。
                              // 双模切换 = 无并存直切 + 新编辑器淡入:
                              // AnimatedSwitcher 会让富/源并存 150ms ——
                              // 共享 focusNode + 输入模型异构(自管 IME
                              // vs TextField),并存窗口里 TextInput 交接
                              // 必然竞态(切后无法删除/快捷键失灵反复
                              // 复发)。ComposerSwitchFade 旧编辑器同帧
                              // dispose,新的从透明淡入(丝滑不并存)。
                              Form(
                                key: _formKey,
                                child: ComposerSwitchFade(
                                  child:
                                      (ref
                                              .watch(preferencesProvider)
                                              .useRichComposer &&
                                          !_richFallback)
                                      // 草稿加载完成前不挂富 composer:初始导入
                                      // 一次性,提前挂会以空文档镜像覆盖草稿。
                                      // 占位留空 —— 加载视觉由页面级草稿遮罩
                                      // 统一提供(双 spinner 叠影)
                                      ? (_isLoadingDraft
                                            ? const SizedBox.shrink()
                                            : RichComposerEditor(
                                                key: _richKey,
                                                header: _buildComposerHeader(
                                                  theme,
                                                  minTitleLength,
                                                ),
                                                metaBar: _buildMetaBar(
                                                  categories,
                                                  canTagTopics,
                                                  tagsAsync,
                                                ),
                                                controller: _contentController,
                                                focusNode: _contentFocusNode,
                                                hintText: context
                                                    .l10n
                                                    .createTopic_contentHint,
                                                emojiPanelHeight: 350,
                                                onEmojiPanelChanged: (show) {
                                                  setState(
                                                    () =>
                                                        _showEmojiPanel = show,
                                                  );
                                                },
                                                mentionDataSource: (term) => ref
                                                    .read(
                                                      discourseServiceProvider,
                                                    )
                                                    .searchUsers(
                                                      term: term,
                                                      categoryId:
                                                          _selectedCategory?.id,
                                                      includeGroups: true,
                                                    ),
                                                onFallbackToPlain: () {
                                                  if (mounted) {
                                                    setState(
                                                      () =>
                                                          _richFallback = true,
                                                    );
                                                  }
                                                },
                                                // 主动切源码(可经工具栏
                                                // 「富文本模式」切回)
                                                onSwitchToSource: () {
                                                  if (mounted) {
                                                    setState(
                                                      () =>
                                                          _richFallback = true,
                                                    );
                                                  }
                                                },
                                              ))
                                      : MarkdownEditor(
                                          key: _editorKey,
                                          header: _buildComposerHeader(
                                            theme,
                                            minTitleLength,
                                          ),
                                          metaBar: _buildMetaBar(
                                            categories,
                                            canTagTopics,
                                            tagsAsync,
                                          ),
                                          controller: _contentController,
                                          focusNode: _contentFocusNode,
                                          hintText: context
                                              .l10n
                                              .createTopic_contentHint,
                                          expands: true,
                                          emojiPanelHeight: 350,
                                          onTogglePreview: _togglePreview,
                                          isPreview: _showPreview,
                                          onEmojiPanelChanged: (show) {
                                            setState(
                                              () => _showEmojiPanel = show,
                                            );
                                          },
                                          // 源码 → 富文本(开关开着即可,
                                          // 门禁降级后也允许重试)
                                          onSwitchToRich:
                                              ref
                                                  .watch(preferencesProvider)
                                                  .useRichComposer
                                              ? () {
                                                  if (mounted) {
                                                    setState(
                                                      () =>
                                                          _richFallback = false,
                                                    );
                                                  }
                                                }
                                              : null,
                                          mentionDataSource: (term) => ref
                                              .read(discourseServiceProvider)
                                              .searchUsers(
                                                term: term,
                                                categoryId:
                                                    _selectedCategory?.id,
                                                includeGroups: true,
                                              ),
                                        ),
                                ),
                              ),

                              // Page 1: 预览模式
                              SingleChildScrollView(
                                padding: EdgeInsets.fromLTRB(
                                  24,
                                  // 透明 AppBar+消散尾巴避让
                                  ProgressiveTopBlur.heightFor(context) + 16,
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
                                      padding: EdgeInsets.symmetric(
                                        vertical: 24,
                                      ),
                                      child: Divider(height: 1),
                                    ),
                                    if (_contentController.text.isEmpty)
                                      Text(
                                        context.l10n.createTopic_noContent,
                                        style: TextStyle(
                                          color: theme
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                      )
                                    else
                                      MarkdownBody(
                                        data: _contentController.text,
                                        onImageScaleChanged: (image, scale) {
                                          final next = applyImageScaleToRaw(
                                            _contentController.text,
                                            image,
                                            scale,
                                          );
                                          if (next != null) {
                                            _contentController.text = next;
                                            setState(() {});
                                          }
                                        },
                                      ),
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
                          child: const Icon(Symbols.edit_rounded),
                        ),
                      ),
                    // 草稿加载遮罩
                    if (_isLoadingDraft)
                      Positioned.fill(
                        child: Container(
                          color: theme.colorScheme.surface.withValues(
                            alpha: 0.7,
                          ),
                          child: const Center(child: LoadingSpinner()),
                        ),
                      ),
                  ],
                );
              },
              loading: () => const Center(child: LoadingSpinner()),
              error: (err, stack) => ErrorView(
                error: err,
                stackTrace: stack,
                onRetry: () => ref.invalidate(categoriesProvider),
              ),
            ),
            // 顶栏渐变模糊:内容从透明 AppBar 下滚过,模糊+遮罩自上
            // 而下消散到全透明(尾巴伸出 AppBar 下缘 36pt)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: ProgressiveTopBlur(
                height: ProgressiveTopBlur.heightFor(context),
              ),
            ),
          ],
        ),
      ),
    );

    // Cmd/Ctrl+Enter 发布(对齐 Discourse composer):包整页,焦点在
    // 标题/标签输入框时同样生效;守卫与发布按钮一致。
    return CallbackShortcuts(
      bindings: {
        for (final activator in composerSubmitActivators())
          activator: () {
            if (!_isSubmitting) _submit();
          },
      },
      child: page,
    );
  }
}
