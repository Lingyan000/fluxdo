import 'dart:async';

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
import 'package:fluxdo/services/composer_min_length_resolver.dart';
import 'package:fluxdo/widgets/common/character_counts_overlay.dart';
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
import '../constants.dart';
import '../l10n/s.dart';
import '../utils/dialog_utils.dart';
import '../utils/discourse_url_parser.dart';
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
  bool _createAsPostVoting = false; // post-voting(问答)模式
  Timer? _featuredLinkDebounce;
  int _titleChangeGeneration = 0;
  bool _isResolvingFeaturedLink = false;
  bool _updatingFeaturedLinkTitle = false;

  /// 对齐官方 `autoPosted`：标题 URL 已自动搬运过一次的门闩
  bool _featuredLinkAutoPosted = false;
  String? _featuredLink;

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
    // 标题上的三件事（featured link 解析 / 草稿 / 计数器）合并成一个监听，
    // 标题输入是热路径，不必每个按键跑三轮回调。
    _titleController.addListener(_onTitleInputChanged);
    _contentController.addListener(_onDraftContentChanged);

    // 预填标题/内容(待审内容撤回重编辑等场景):直接落 controller,
    // 并跳过草稿恢复弹窗,避免旧草稿覆盖预填内容
    final hasInitialPrefill =
        (widget.initialTitle?.isNotEmpty ?? false) ||
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
    // 先按站点默认算一版下限，_applyCurrentFilter 选中分类后会再刷新
    _refreshMinContentLength();
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
    _featuredLinkDebounce?.cancel();
    // 移除草稿监听器
    _titleController.removeListener(_onTitleInputChanged);
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

  /// 是否允许当前 composer 使用话题精选链接。
  ///
  /// 对齐官方 `Composer#canEditTopicFeaturedLink`
  /// (frontend/discourse/app/models/composer.js)：
  /// 1. 信任级别 0 的用户不允许（防垃圾链接）；
  /// 2. 站点开关 `topic_featured_link_enabled` 必须为真；
  /// 3. 当前分类需在 `topic_featured_link_allowed_category_ids` 白名单内。
  ///
  /// 预加载 blob 未就绪时 `siteSettingsSync` 为 null，取正向判定按「未开启」
  /// 处理，避免凭空发起 inline-onebox 请求并改写用户标题。
  bool get _featuredLinkEnabled {
    final preloaded = PreloadedDataService();
    if (preloaded.siteSettingsSync?['topic_featured_link_enabled'] != true) {
      return false;
    }

    // TL0 不允许精选链接（官方第一道门）
    final trustLevel = preloaded.currentUserSync?['trust_level'];
    if (trustLevel is int && trustLevel == 0) return false;

    final allowed = preloaded.topicFeaturedLinkAllowedCategoryIdsSync;
    final categoryId = _selectedCategory?.id;

    // 尚未选分类：对齐官方的特例分支——白名单已下发，且（未分类在白名单里
    // 或站点压根不允许未分类话题）时放行。linux.do 属于后者：
    // allow_uncategorized_topics=false，所以刚打开发帖页、还没选分类时
    // 也应当能粘链接——反正发布前必定会选一个合法分类。
    if (categoryId == null) {
      if (allowed == null || allowed.isEmpty) return true;
      final uncategorizedId = preloaded.uncategorizedCategoryIdSync;
      final allowUncategorized =
          preloaded.siteSettingsSync?['allow_uncategorized_topics'] == true;
      return (uncategorizedId != null && allowed.contains(uncategorizedId)) ||
          !allowUncategorized;
    }

    // 白名单未下发或为空 = 不限制（对齐官方
    // `categoryIds === undefined || !categoryIds.length`）
    if (allowed == null || allowed.isEmpty) return true;
    return allowed.contains(categoryId);
  }

  /// 正文是否仍为「默认态」（空或等于分类模板）。
  ///
  /// 官方 `bodyIsDefault()`：只有正文还没被用户动过时才自动把标题 URL 搬进
  /// 正文，否则会在用户已经写了内容的帖子末尾突兀地多出一行链接。
  bool _bodyIsDefault() {
    final reply = _contentController.text;
    if (reply.isEmpty) return true;
    final template = _templateContent;
    if (template != null && reply.trim() == template.trim()) return true;
    return false;
  }

  /// 标题 URL 是否指向本站。
  ///
  /// 官方只把**外部**链接做成精选链接（`only feature links to external
  /// sites`），指向本站的 URL 直接不处理。
  bool _isSameSiteUrl(TitleUrlInfo candidate) {
    final siteHost = Uri.tryParse(AppConstants.baseUrl)?.host;
    if (siteHost == null || siteHost.isEmpty) return false;
    return candidate.uri.host.toLowerCase() == siteHost.toLowerCase();
  }

  /// 标题输入的单一监听入口（草稿 / 计数器 / featured link 三合一）。
  void _onTitleInputChanged() {
    _onDraftContentChanged();
    _updateTitleLength();
    _onTitleChanged();
  }

  /// 对齐 Discourse composer：标题只包含一个 URL 时，异步取 onebox 标题，
  /// 并记下原 URL 作为 `featured_link`。
  ///
  /// 注意这里**只**改标题、不碰正文：正文追加统一放到提交前（见
  /// [_applyFeaturedLinkToContent]），否则与富文本编辑器的 flush 抢写。
  void _onTitleChanged() {
    // 自增必须晚于「自改标题」的早退判断：_replaceTitleWithOneboxTitle 写回
    // controller 会重入本方法，若在早退前推进 generation，就会把刚发出的那次
    // 解析判成过期，_isCurrentTitleUrl 随之永远为 false。
    if (_updatingFeaturedLinkTitle) return;

    _featuredLinkDebounce?.cancel();
    final generation = ++_titleChangeGeneration;

    // 对齐官方 `autoPosted`：标题被清空才重置自动处理资格，否则整个
    // composer 生命周期内只自动搬运一次，不会反复往正文里塞链接。
    if (_titleController.text.trim().isEmpty) {
      _featuredLinkAutoPosted = false;
    }
    if (_featuredLinkAutoPosted) return;

    final candidate = DiscourseUrlParser.parseTitleUrl(_titleController.text);
    // 对齐官方：只给外部链接做精选，且正文仍为默认态时才接管。
    if (!_featuredLinkEnabled ||
        candidate == null ||
        _isSameSiteUrl(candidate) ||
        !_bodyIsDefault()) {
      if (_isResolvingFeaturedLink || _featuredLink != null) {
        setState(() {
          _isResolvingFeaturedLink = false;
          _featuredLink = null;
        });
      }
      return;
    }

    // 同一个 URL 已经解析过时，不重复请求。
    if (_featuredLink == candidate.absoluteUrl) {
      if (_isResolvingFeaturedLink) {
        setState(() => _isResolvingFeaturedLink = false);
      }
      return;
    }

    setState(() {
      _isResolvingFeaturedLink = true;
      _featuredLink = null;
    });
    _featuredLinkDebounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_resolveFeaturedLink(candidate, generation));
    });
  }

  Future<void> _resolveFeaturedLink(
    TitleUrlInfo candidate,
    int generation,
  ) async {
    if (!_isCurrentTitleUrl(candidate, generation)) {
      if (mounted &&
          generation == _titleChangeGeneration &&
          _isResolvingFeaturedLink) {
        setState(() => _isResolvingFeaturedLink = false);
      }
      return;
    }

    String? resolvedTitle;
    try {
      final boxes = await ref
          .read(discourseServiceProvider)
          .fetchInlineOneboxes([
            candidate.absoluteUrl,
          ], categoryId: _selectedCategory?.id)
          .timeout(const Duration(seconds: 5));
      resolvedTitle = boxes[candidate.absoluteUrl]?.title.trim();
    } catch (_) {
      // fetchInlineOneboxes 已将 onebox 失败降级为空结果；这里保留 URL。
    }

    if (!mounted || !_isCurrentTitleUrl(candidate, generation)) return;

    setState(() {
      _featuredLink = candidate.absoluteUrl;
      _isResolvingFeaturedLink = false;
      _featuredLinkAutoPosted = true;
    });

    // 对齐官方：解析成功当场就把链接写进正文，用户能立即看到。
    await _applyFeaturedLinkToContent(candidate.absoluteUrl);

    if (resolvedTitle != null && resolvedTitle.isNotEmpty) {
      _replaceTitleWithOneboxTitle(resolvedTitle);
    }
  }

  bool _isCurrentTitleUrl(TitleUrlInfo candidate, int generation) {
    return mounted &&
        generation == _titleChangeGeneration &&
        _featuredLinkEnabled &&
        // 官方同样在真正发请求前再查一次 bodyIsDefault：debounce 窗口内
        // 用户可能已经开始写正文了。
        _bodyIsDefault() &&
        _titleController.text.trim() == candidate.url;
  }

  /// 提交时提前结束未完成的解析，把标题里的 URL 直接定为 featured link。
  ///
  /// onebox 只负责「把标题换成网页标题」这个锦上添花的步骤；用户主动点发布
  /// 就说明他接受当前标题，没必要拿一个网络请求把提交按钮卡住。
  void _settlePendingFeaturedLink() {
    _featuredLinkDebounce?.cancel();
    if (!_featuredLinkEnabled) return;

    final candidate = DiscourseUrlParser.parseTitleUrl(_titleController.text);
    if (candidate == null ||
        _isSameSiteUrl(candidate) ||
        !_bodyIsDefault()) {
      return;
    }
    // 推进 generation 使飞在路上的解析回调失效，避免它在提交途中改标题。
    _titleChangeGeneration++;
    _isResolvingFeaturedLink = false;
    _featuredLink = candidate.absoluteUrl;
  }

  /// 把 featured link 落进正文（对齐官方 `appendText(url, null, {block: true})`）。
  ///
  /// 富文本模式下必须走编辑器的插入 API：它持有独立的 EditorState，
  /// 且镜像是单向的（doc → controller），直接写 controller 不会显示，
  /// 还会被下一次序列化覆盖掉。
  Future<void> _applyFeaturedLinkToContent(String url) async {
    if (url.isEmpty) return;
    if (_contentController.text.contains(url)) return;

    final richEditor = _richKey.currentState;
    if (richEditor != null) {
      // 富文本：经 EditorState 插入，内部会自行镜像回 controller
      await richEditor.insertMarkdownSnippet(url);
      return;
    }

    // 纯文本：直接拼接。用 value 整体赋值并给出合法选区——text setter 会把
    // selection 置为 -1，平台以「无光标态」初始化输入连接后，IME 退格
    // 对既有文本失效。
    final trimmed = _contentController.text.trimRight();
    final next = trimmed.isEmpty ? url : '$trimmed\n\n$url';
    _contentController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  void _replaceTitleWithOneboxTitle(String title) {
    final resolvedTitle = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (resolvedTitle.isEmpty ||
        resolvedTitle == _titleController.text.trim()) {
      return;
    }

    _updatingFeaturedLinkTitle = true;
    try {
      _titleController.value = _titleController.value.copyWith(
        text: resolvedTitle,
        selection: TextSelection.collapsed(offset: resolvedTitle.length),
        composing: TextRange.empty,
      );
    } finally {
      _updatingFeaturedLinkTitle = false;
    }
  }

  /// 标题长度变化时重建（驱动标题计数器）
  int _titleLength = 0;
  void _updateTitleLength() {
    final length = _titleController.text.trim().length;
    if (length == _titleLength) return;
    setState(() => _titleLength = length);
  }

  /// 首帖最小字数（含 warden 等插件按分类的改写）；null 表示尚未解析出
  int? _minContentLength;

  /// 解析当前分类下的首帖最小字数
  ///
  /// 分类可随时切换（如从「云端资产」切到「搞七捻三」），每次切换都要重算，
  /// 计数器分母与提交校验共用该结果。
  Future<void> _refreshMinContentLength() async {
    final category = _selectedCategory;
    final min = await ComposerMinLengthResolver.resolve(
      category: category,
      isFirstPost: true,
      isPrivateMessage: false,
    );
    if (!mounted) return;
    setState(() => _minContentLength = min);
  }

  void _onCategorySelected(Category category) {
    setState(() {
      _selectedCategory = category;
      // 分类联动问答默认值:强制分类锁定开;默认分类预勾选;
      // 切到普通分类保留用户当前选择
      if (category.onlyPostVotingInThisCategory ||
          category.createAsPostVotingDefault) {
        _createAsPostVoting = true;
      }
    });
    // 分类决定 warden 最小字数，切换后立即重算
    _refreshMinContentLength();

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
    // 富文本模式:先强制序列化镜像。
    // 必须排在下面两步**之前**：它俩都要读 _contentController 判断正文是否
    // 仍为默认态，而富文本的内容在 flush 前还在 EditorState 里。
    _richKey.currentState?.flushToController();
    // 标题是纯 URL 但 onebox 还在飞（或还在 debounce 窗口内）时，不阻断提交：
    // featured link 本身不依赖 onebox 结果，直接用当前标题里的 URL 定案。
    _settlePendingFeaturedLink();
    // 已解析成功的情况下链接早已写进正文，这里只是兜底：接住「没等
    // onebox 回来就点了发布」这条路径（内部已去重，不会重复追加）。
    final pendingLink = _featuredLink;
    if (pendingLink != null) {
      await _applyFeaturedLinkToContent(pendingLink);
      // 富文本插入后需要重新序列化，否则 controller 拿不到刚插的链接。
      _richKey.currentState?.flushToController();
    }
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
    // 与计数器共用同一份解析结果（含 warden 按分类改写）
    final minContentLength =
        _minContentLength ??
        await ComposerMinLengthResolver.resolve(
          category: _selectedCategory,
          isFirstPost: true,
          isPrivateMessage: false,
        );
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
      // 上方最小字数解析可能 await 过，用 context 前先确认页面还在
      if (!mounted) return;
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
        featuredLink: _featuredLink,
        createAsPostVoting: _createAsPostVoting,
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
      // 标题字数提示悬浮在输入框右下角(与正文同一套做法):
      // 不占布局空间,标题为空或已达标时完全不出现
      child: Stack(
        children: [
          TextFormField(
            controller: _titleController,
            decoration: InputDecoration(
              // 对齐官方 `titlePlaceholder`：允许精选链接时提示可以粘链接
              hintText: _featuredLinkEnabled
                  ? context.l10n.createTopic_titleOrLinkHint
                  : context.l10n.createTopic_titleHint,
              hintStyle: TextStyle(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.5,
                ),
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
            // 对齐官方 `titleMaxLength`：允许精选链接时不设 maxLength，否则会
            // 把粘贴进来的长链接截断（超长交由校验提示，不靠硬截）。
            maxLength: _featuredLinkEnabled
                ? null
                : PreloadedDataService().maxTopicTitleLengthSync,
            // 计数改用悬浮层(见下方 Stack),这里不占位
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
              // 允许精选链接时不靠 maxLength 硬截，改由校验抦（对齐官方
              // `composer.error.title_too_long`）。
              final maxTitleLength = PreloadedDataService()
                  .maxTopicTitleLengthSync;
              if (value.trim().length > maxTitleLength) {
                return context.l10n.createTopic_maxTitleLength(maxTitleLength);
              }
              return null;
            },
            onTap: () {
              _editorKey.currentState?.closeEmojiPanel();
              _richKey.currentState?.closeEmojiPanel();
            },
          ),
          // 标题为空时同样提示（对齐 missingReplyCharacters > 0）：
          // 一进来就知道标题有字数门槛，不用先打字才发现
          Positioned(
            right: 0,
            bottom: 0,
            child: CharacterCountsOverlay(
              length: _titleLength,
              minimumLength: minTitleLength,
              // 标题不带社区警告文案（对齐主题组件 showWarning=false）
              showWarning: false,
            ),
          ),
          // 正在解析标题里的链接。官方是把整个 composer 置 loading 态，这里
          // 不阻断输入，只在标题右上角提示「在拿网页标题」。
          // 用 LoadingSpinner：它内部跟随 M3eFlags，M3E 开启走 Expressive
          // 形变环，关闭自动回退经典转圈（线宽按 size 等比缩放）。
          if (_isResolvingFeaturedLink)
            const Positioned(
              right: 0,
              top: 0,
              child: LoadingSpinner(size: 16),
            ),
        ],
      ),
    );
  }

  /// 字数不足时悬浮在正文区右下角的提示（对齐网页主题 CSS 的绝对定位）
  Widget _buildCharCountOverlay() => CharacterCountsOverlay(
    length: _contentLength,
    minimumLength: _minContentLength,
  );

  /// 底部属性条:分类/标签/字数(编辑区与工具栏之间,常驻可改)
  Widget _buildMetaBar(
    List<Category> categories,
    bool canTagTopics,
    AsyncValue<List<String>> tagsAsync,
  ) {
    // 站点是否装 post-voting 插件:从分类 JSON 是否下发插件字段派生
    final sitePostVoting = categories.any((c) => c.hasPostVotingFields);
    final locked = _selectedCategory?.onlyPostVotingInThisCategory ?? false;
    return ComposerMetaBar(
      category: _selectedCategory,
      categories: categories,
      onCategorySelected: _onCategorySelected,
      showTags: canTagTopics,
      selectedTags: _selectedTags,
      allTags: tagsAsync.value ?? const [],
      onTagsChanged: _onTagsChanged,
      showPostVotingToggle: sitePostVoting,
      postVotingEnabled: _createAsPostVoting || locked,
      postVotingLocked: locked,
      onPostVotingChanged: (v) => setState(() => _createAsPostVoting = v),
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
                                                bodyOverlay:
                                                    _buildCharCountOverlay(),
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
                                          bodyOverlay: _buildCharCountOverlay(),
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
