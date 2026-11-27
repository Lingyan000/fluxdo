import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:positioned_sliver_list/positioned_sliver_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/s.dart';
import '../../models/topic.dart';
import '../../providers/theme_provider.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/fonts/font_catalog.dart';
import '../../services/fonts/font_download_service.dart';
import '../../services/toast_service.dart';
import '../../utils/fluxdo_render_callbacks.dart';
import '../../utils/idle_task.dart';
import '../../utils/scroll_busy_signal.dart';
import '../../widgets/common/app_bottom_sheet.dart';
import '../../widgets/common/emoji_text.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/common/paper_texture.dart';
import '../../widgets/common/positioned_stream_list.dart';
import '../../widgets/common/relative_time_text.dart';
import '../../widgets/post/post_item/quote_selection_helper.dart';
import 'reader_document.dart';
import 'reader_preferences.dart';
import 'widgets/reader_chrome.dart';
import 'widgets/reader_toc_panel.dart';
import 'widgets/reader_typesetting_sheet.dart';

/// 首贴沉浸阅读页。
///
/// 专注渲染话题 1 楼（主帖）正文，保留完整富文本渲染（代码块、表格、图片、
/// 引用、标题与选区复制等）并移除头像、签名、勋章与操作栏；提供基于原生 HTML
/// 标题（`h1`–`h5`）的目录导航、接入应用自身字体与主题背景体系的实时排版调节，
/// 以及长首贴的阅读位置记忆。
class TopicReaderPage extends ConsumerStatefulWidget {
  const TopicReaderPage({
    super.key,
    required this.initialDetail,
    this.firstPostLoader,
  });

  final TopicDetail initialDetail;

  /// 当进入阅读页时 1 楼不在当前分页里，用于加载 1 楼的可注入加载器（测试可覆写）。
  final Future<Post?> Function(int topicId)? firstPostLoader;

  /// 宽屏双栏（左侧常驻目录 + 右侧正文）宽度阈值。
  static const double wideBreakpoint = 1024;

  /// 舒适阅读栏最大宽度。
  static const double maxReadingWidth = 700;

  static const double _tocSidebarWidth = 280;
  static const double _headingTopBuffer = 14;
  static const double _spyBuffer = 120;

  @override
  ConsumerState<TopicReaderPage> createState() => _TopicReaderPageState();
}

class _TopicReaderPageState extends ConsumerState<TopicReaderPage> {
  final ScrollController _scrollController = ScrollController();
  final ListController _listController = ListController();
  final HeadingAnchorRegistry _headingRegistry = HeadingAnchorRegistry();
  final ParagraphWarmupTracker _warmupTracker = ParagraphWarmupTracker();
  final GlyphPrebaker _glyphBaker = GlyphPrebaker(
    shouldDefer: () => isIdleTaskUserInteracting,
  );
  int _warmUpGeneration = 0;
  IdleTaskHandle? _pendingWarmUpHandle;
  Object? _lastWarmupEnvKey;
  int _warmItemCursor = 0;
  int _warmNodeCursor = 0;

  FluxdoRenderCallbacks? _shortCallbacks;
  ReaderPositionStore? _positionStore;

  /// 阅读进度与当前章节标题的局部状态源：滚动每 80ms 更新时仅通知页眉、
  /// 顶栏副标题和宽屏目录侧栏，避免整页 setState 触发主题重建与正文重排。
  final ValueNotifier<({double progress, String? activeHeadingId})>
  _readingStateNotifier = ValueNotifier((progress: 0.0, activeHeadingId: null));

  /// 记忆化阅读主题：开启纸张配色或独立阅读字体时按配置值复用同一 ThemeData，
  /// 避免任意 rebuild 重复 copyWith 击穿正文缓存或挤出全局本地化主题缓存。
  ThemeData? _cachedBaseThemeRaw;
  Object? _cachedReaderThemeKey;
  ThemeData? _cachedReaderTheme;

  /// 稳定化的正文交互回调（按 post + callbacks 复用，防止父组件 rebuild 时
  /// 因内联闭包不 identical 击穿 FluxdoRender._cachedColumn）。
  Post? _cachedHandlersPost;
  FluxdoRenderCallbacks? _cachedHandlersSource;
  LinkActionHandler? _stableLinkHandler;
  MentionTapHandler? _stableMentionHandler;
  QuoteRequestCallback? _stableCopyQuoteHandler;

  Post? _firstPost;
  bool _isLoadingFirstPost = false;
  Object? _loadError;
  ReaderDocument? _document;
  List<String> _documentItemKeys = const [];

  bool _chromeVisible = false;
  bool? _wideSidebarOverride;

  double _progress = 0.0;
  String _currentItemKey = 'reader_header';
  String? _activeHeadingId;
  int? _initialRestoreIndex;
  bool _positionRestored = false;

  int _jumpGeneration = 0;
  bool _isJumping = false;
  Timer? _spyThrottle;
  Timer? _saveThrottle;
  StreamSubscription<FontEntry>? _fontInstalledSub;

  // 正文区轻触判定状态：FluxdoRender 启用自研选区时会吸收单点手势，
  // 通过只包裹列表层的 Listener 捕获短按，并在交互子控件命中时抑制浮层切换。
  Offset? _pointerDownPos;
  Duration? _pointerDownTime;
  int _pointerDownButtons = 0;
  bool _pointerMoved = false;
  bool _interactiveTapConsumed = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _listController.itemPositions.addListener(_onPositionsChanged);

    SharedPreferences? prefs;
    try {
      prefs = ref.read(sharedPreferencesProvider);
    } catch (_) {
      prefs = null;
    }
    _positionStore = ReaderPositionStore(prefs);

    // 若阅读偏好选择了目录字体，进入时主动向引擎注册，并监听后续下载完成事件。
    final initialFont = ref.read(readerPreferencesProvider).fontChoice;
    if (FontCatalog.byId(initialFont) != null) {
      unawaited(ref.read(themeProvider.notifier).ensureFontLoaded(initialFont));
    }
    _fontInstalledSub = FontDownloadService.instance.onInstalled.listen((entry) {
      if (!mounted) return;
      if (ref.read(readerPreferencesProvider).fontChoice == entry.id) {
        unawaited(ref.read(themeProvider.notifier).ensureFontLoaded(entry.id));
      }
    });

    _firstPost = _findFirstPost(widget.initialDetail.postStream.posts);
    if (_firstPost != null) {
      _buildDocument(_firstPost!);
      _resolveInitialRestoreIndex();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateScrollState();
      });
    } else {
      unawaited(_loadFirstPost());
    }
  }

  @override
  void dispose() {
    _fontInstalledSub?.cancel();
    _spyThrottle?.cancel();
    _saveThrottle?.cancel();
    _persistPositionNow();
    _cancelWarmUp();
    _glyphBaker.dispose();
    _readingStateNotifier.dispose();
    _warmupTracker.reset();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _listController.itemPositions.removeListener(_onPositionsChanged);
    _listController.dispose();
    super.dispose();
  }

  Post? _findFirstPost(List<Post> posts) {
    for (final post in posts) {
      if (post.postNumber == 1) return post;
    }
    return null;
  }

  Future<void> _loadFirstPost() async {
    if (_isLoadingFirstPost) return;
    setState(() {
      _isLoadingFirstPost = true;
      _loadError = null;
    });
    try {
      final Post? post;
      if (widget.firstPostLoader != null) {
        post = await widget.firstPostLoader!(widget.initialDetail.id);
      } else {
        final detail = await DiscourseService().getTopicDetail(
          widget.initialDetail.id,
          postNumber: 1,
        );
        post = _findFirstPost(detail.postStream.posts);
      }
      if (!mounted) return;
      if (post == null) {
        setState(() {
          _isLoadingFirstPost = false;
          _loadError = StateError('First post not found');
        });
        return;
      }
      setState(() {
        _firstPost = post;
        _isLoadingFirstPost = false;
        _buildDocument(post!);
        _resolveInitialRestoreIndex();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateScrollState();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingFirstPost = false;
        _loadError = e;
      });
    }
  }

  void _buildDocument(Post firstPost) {
    final detail = widget.initialDetail;
    final authorName = detail.createdBy?.name?.trim().isNotEmpty == true
        ? detail.createdBy!.name!
        : (firstPost.name?.trim().isNotEmpty == true
              ? firstPost.name!
              : firstPost.username);
    _shortCallbacks = null;
    _cachedHandlersPost = null;
    _cachedHandlersSource = null;
    final doc = ReaderDocumentBuilder.build(
      topicId: detail.id,
      title: detail.title,
      authorName: authorName,
      topicCreatedAt: detail.createdAt,
      firstPost: firstPost,
      replyCount: (detail.postsCount - 1).clamp(0, 999999),
    );
    _document = doc;
    _documentItemKeys = List<String>.unmodifiable([
      for (final item in doc.items) item.itemKey,
    ]);
  }

  void _resolveInitialRestoreIndex() {
    final doc = _document;
    if (doc == null || _positionRestored) return;
    _positionRestored = true;

    final saved = _positionStore?.read(widget.initialDetail.id);
    if (saved == null) return;
    final byKey = doc.itemIndexByKey[saved.itemKey];
    if (byKey != null && byKey > 0) {
      _initialRestoreIndex = byKey;
      _currentItemKey = saved.itemKey;
      _progress = saved.progress;
      _readingStateNotifier.value = (
        progress: _progress,
        activeHeadingId: _activeHeadingId,
      );
    }
  }

  void _showCopyToast() {
    if (!mounted) return;
    ToastService.showSuccess(context.l10n.common_copiedToClipboard);
  }

  void _ensureStableHandlers(Post post, FluxdoRenderCallbacks callbacks) {
    if (identical(_cachedHandlersPost, post) &&
        identical(_cachedHandlersSource, callbacks)) {
      return;
    }
    _cachedHandlersPost = post;
    _cachedHandlersSource = callbacks;
    _stableLinkHandler = (ctx, href) {
      _markInteractiveTap();
      callbacks.linkHandler(ctx, href);
    };
    _stableMentionHandler = (ctx, username, href) {
      _markInteractiveTap();
      callbacks.mentionTapHandler(ctx, username, href);
    };
    _stableCopyQuoteHandler = (plainText) =>
        QuoteSelectionHelper.copyQuoteToClipboard(
          selectedText: plainText,
          post: post,
          topicId: widget.initialDetail.id,
        );
  }

  FluxdoRenderCallbacks _callbacksForShortPost(
    Post post,
    String preprocessed,
    List<BlockNode> parsedNodes,
  ) {
    return _shortCallbacks ??= FluxdoRenderCallbacks.forPost(
      post: post,
      heroTagNamespace: 'reader_post_${post.id}',
      topicId: widget.initialDetail.id,
      preprocessedCooked: preprocessed,
      parsedNodes: parsedNodes,
    );
  }

  void _onScroll() {
    if (!mounted) return;
    _scheduleSpyUpdate();
  }

  void _onPositionsChanged() {
    if (!mounted) return;
    _scheduleSpyUpdate();
  }

  void _scheduleSpyUpdate() {
    if (_isJumping) return;
    if (_spyThrottle?.isActive ?? false) return;
    _spyThrottle = Timer(const Duration(milliseconds: 80), () {
      _spyThrottle = null;
      if (mounted) _updateScrollState();
    });
  }

  void _cancelWarmUp() {
    _warmUpGeneration++;
    _pendingWarmUpHandle?.cancel();
    _pendingWarmUpHandle = null;
    _glyphBaker.clear();
  }

  /// 长文分块空闲预热：滚动停稳后预热当前锚点前方最多 3 个 chunk 的段落排版
  /// 与字形（仅针对未缓存的新段落，单步 4ms，新滚动开始立即取消）。
  void _scheduleReaderWarmUp() {
    final doc = _document;
    if (doc == null || doc.items.isEmpty) return;
    final hasChunks = doc.items.any((item) => item is ReaderPostChunkItem);
    if (!hasChunks) return;

    _pendingWarmUpHandle?.cancel();
    _pendingWarmUpHandle = null;
    final generation = ++_warmUpGeneration;

    int currentAnchorIndex() {
      if (_listController.isAttached) {
        final anchor = _listController.anchor;
        if (anchor != null && anchor.index < doc.items.length) {
          return anchor.index;
        }
      }
      return doc.itemIndexByKey[_currentItemKey] ?? 0;
    }

    void step() {
      if (!mounted || generation != _warmUpGeneration) return;
      final snapshot = _warmupTracker.snapshot();
      if (snapshot == null) return;
      final envKey = snapshot.environmentKey;
      final anchorIdx = currentAnchorIndex();
      final maxItemIdx = (anchorIdx + 3).clamp(0, doc.items.length - 1);
      if (_lastWarmupEnvKey != envKey || _warmItemCursor < anchorIdx) {
        _lastWarmupEnvKey = envKey;
        _warmItemCursor = anchorIdx;
        _warmNodeCursor = 0;
      }
      if (_warmItemCursor > maxItemIdx) return;

      _pendingWarmUpHandle = scheduleIdleTask(() {
        _pendingWarmUpHandle = null;
        if (!mounted || generation != _warmUpGeneration) return;
        final currentSnapshot = _warmupTracker.snapshot();
        if (currentSnapshot == null) return;
        final currentEnvKey = currentSnapshot.environmentKey;
        if (_lastWarmupEnvKey != currentEnvKey) {
          _lastWarmupEnvKey = currentEnvKey;
          _warmItemCursor = currentAnchorIndex();
          _warmNodeCursor = 0;
        }

        final limitIdx = (currentAnchorIndex() + 3).clamp(
          0,
          doc.items.length - 1,
        );
        while (_warmItemCursor <= limitIdx) {
          final item = doc.items[_warmItemCursor];
          if (item is! ReaderPostChunkItem) {
            _warmItemCursor++;
            _warmNodeCursor = 0;
            continue;
          }
          final nodes = item.longData.parsedChunkAt(item.chunkIndex);
          final next = ParagraphWarmup.warmParagraphs(
            nodes: nodes,
            ctx: currentSnapshot,
            context: context,
            mentionTapHandler: FluxdoRenderCallbacks.handlePrewarmedMentionTap,
            totalImagesInPost: 0,
            glyphBaker: _glyphBaker,
            devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            startIndex: _warmNodeCursor,
            budgetMicros: 4000,
          );
          if (next == -1) {
            _warmItemCursor++;
            _warmNodeCursor = 0;
          } else {
            _warmNodeCursor = next;
          }
          break;
        }
        if (_warmItemCursor <= limitIdx) {
          step();
        }
      }, isCanceled: () => !mounted || generation != _warmUpGeneration);
    }

    step();
  }

  void _updateScrollState() {
    final doc = _document;
    if (doc == null || doc.items.isEmpty) return;

    double nextProgress = _progress;
    double pixels = 0;
    if (_scrollController.hasClients &&
        _scrollController.position.hasContentDimensions) {
      final pos = _scrollController.position;
      pixels = pos.pixels;
      nextProgress = ReaderDocumentBuilder.computeProgress(
        pixels: pos.pixels,
        maxScrollExtent: pos.maxScrollExtent,
      );
    }

    int anchorIndex = 0;
    if (_listController.isAttached) {
      final anchor = _listController.anchor;
      if (anchor != null && anchor.index < doc.items.length) {
        anchorIndex = anchor.index;
      }
    }

    final nextItemKey = doc.items[anchorIndex].itemKey;
    final nextHeadingId = _resolveActiveHeadingId(
      doc: doc,
      anchorIndex: anchorIndex,
      pixels: pixels,
    );

    final visualChanged =
        (nextProgress - _progress).abs() >= 0.005 ||
        nextHeadingId != _activeHeadingId;

    _currentItemKey = nextItemKey;
    if (visualChanged) {
      _progress = nextProgress;
      _activeHeadingId = nextHeadingId;
      _readingStateNotifier.value = (
        progress: nextProgress,
        activeHeadingId: nextHeadingId,
      );
    }
    _schedulePersistPosition();
  }

  String? _resolveActiveHeadingId({
    required ReaderDocument doc,
    required int anchorIndex,
    required double pixels,
  }) {
    if (doc.headings.isEmpty) return null;
    final threshold =
        pixels + TopicReaderPage._headingTopBuffer + TopicReaderPage._spyBuffer;
    String? mountedActive;
    for (final heading in doc.headings) {
      final ctx = _headingRegistry.contextOf(heading.anchorKey);
      if (ctx == null) continue;
      final RenderObject? box;
      try {
        box = ctx.findRenderObject();
      } catch (_) {
        continue;
      }
      if (box == null || !box.attached) continue;
      final viewport = RenderAbstractViewport.maybeOf(box);
      if (viewport == null) continue;
      final offset = viewport.getOffsetToReveal(box, 0.0).offset;
      if (offset <= threshold) {
        mountedActive = heading.id;
      }
    }
    if (mountedActive != null) return mountedActive;

    String? fallbackActive;
    for (final heading in doc.headings) {
      final idx = doc.itemIndexByKey[heading.itemKey];
      if (idx != null && idx <= anchorIndex) {
        fallbackActive = heading.id;
      }
    }
    return fallbackActive;
  }

  void _schedulePersistPosition() {
    if (_saveThrottle?.isActive ?? false) return;
    _saveThrottle = Timer(const Duration(milliseconds: 600), () {
      _saveThrottle = null;
      _persistPositionNow();
    });
  }

  void _persistPositionNow() {
    final store = _positionStore;
    if (store == null || _document == null) return;
    unawaited(
      store.write(
        widget.initialDetail.id,
        ReaderPosition(
          itemKey: _currentItemKey,
          progress: _progress,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      ),
    );
  }

  void _toggleChrome() {
    setState(() {
      _chromeVisible = !_chromeVisible;
    });
  }

  void _hideChrome() {
    if (!_chromeVisible) return;
    setState(() {
      _chromeVisible = false;
    });
  }

  void _markInteractiveTap() {
    _interactiveTapConsumed = true;
  }

  void _handleReadingPointerDown(PointerDownEvent event) {
    _pointerDownPos = event.position;
    _pointerDownTime = event.timeStamp;
    _pointerDownButtons = event.buttons;
    _pointerMoved = false;
    _interactiveTapConsumed = false;
  }

  void _handleReadingPointerMove(PointerMoveEvent event) {
    final downPos = _pointerDownPos;
    if (downPos == null) return;
    if ((event.position - downPos).distance > 10) {
      _pointerMoved = true;
    }
  }

  void _handleReadingPointerCancel(PointerCancelEvent _) {
    _pointerDownPos = null;
    _pointerDownTime = null;
    _pointerMoved = false;
  }

  void _handleReadingPointerUp(PointerUpEvent event) {
    final downPos = _pointerDownPos;
    final downTime = _pointerDownTime;
    final moved = _pointerMoved;
    final buttons = _pointerDownButtons;
    _pointerDownPos = null;
    _pointerDownTime = null;
    _pointerMoved = false;

    if (downPos == null || downTime == null || moved) return;
    if (buttons != 0 && (buttons & kPrimaryButton) == 0) return;
    if ((event.position - downPos).distance > 10) return;
    if (event.timeStamp - downTime > const Duration(milliseconds: 280)) return;

    Future<void>.microtask(() {
      if (!mounted || _interactiveTapConsumed) return;
      _toggleChrome();
    });
  }

  Future<void> _jumpToHeading(ReaderHeading heading) async {
    final doc = _document;
    if (doc == null) return;
    final targetIndex = doc.itemIndexByKey[heading.itemKey];
    if (targetIndex == null || !_listController.isAttached) return;

    final gen = ++_jumpGeneration;
    _isJumping = true;
    _spyThrottle?.cancel();
    if (_activeHeadingId != heading.id) {
      _activeHeadingId = heading.id;
      _readingStateNotifier.value = (
        progress: _progress,
        activeHeadingId: heading.id,
      );
    }

    try {
      await _listController.jumpToIndex(
        targetIndex,
        offset: TopicReaderPage._headingTopBuffer,
      );
      if (!mounted || gen != _jumpGeneration) return;
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || gen != _jumpGeneration) return;
      _alignHeadingAnchor(heading.anchorKey);
    } finally {
      if (gen == _jumpGeneration) {
        _isJumping = false;
        if (mounted) _updateScrollState();
      }
    }
  }

  void _alignHeadingAnchor(String anchorKey) {
    final ctx = _headingRegistry.contextOf(anchorKey);
    if (ctx == null || !_scrollController.hasClients) return;
    final RenderObject? box;
    try {
      box = ctx.findRenderObject();
    } catch (_) {
      return;
    }
    if (box == null || !box.attached) return;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return;
    final target =
        viewport.getOffsetToReveal(box, 0.0).offset -
        TopicReaderPage._headingTopBuffer;
    _scrollController.jumpTo(
      target.clamp(
        _scrollController.position.minScrollExtent,
        _scrollController.position.maxScrollExtent,
      ),
    );
  }

  void _handleTocButtonTap(bool isWide, ReaderDocument doc) {
    if (!doc.hasHeadings) return;
    if (isWide) {
      final currentOpen = _isWideSidebarOpen(doc);
      setState(() {
        _wideSidebarOverride = !currentOpen;
      });
      return;
    }
    _hideChrome();
    _showNarrowTocSheet(doc);
  }

  bool _isWideSidebarOpen(ReaderDocument doc) {
    return doc.hasHeadings && (_wideSidebarOverride ?? true);
  }

  void _showNarrowTocSheet(ReaderDocument doc) {
    final palette = ReaderPalette.resolve(
      Theme.of(context),
      ref.read(readerPreferencesProvider).paperTheme,
    );
    AppBottomSheet.showDraggable<void>(
      context: context,
      title: context.l10n.reader_toc,
      showDragHandle: true,
      showTitleDivider: true,
      initialSize: 0.65,
      minSize: 0.45,
      maxSize: 0.9,
      bodyBuilder: (sheetCtx, scrollController) {
        return ReaderTocPanel(
          headings: doc.headings,
          palette: palette,
          activeHeadingId: _activeHeadingId,
          scrollController: scrollController,
          onSelectHeading: (heading) {
            Navigator.of(sheetCtx).pop();
            unawaited(_jumpToHeading(heading));
          },
        );
      },
    );
  }

  void _openTypesettingSheet() {
    _hideChrome();
    unawaited(showReaderTypesettingSheet(context));
  }

  String _runningHeaderTitle(ReaderDocument doc, String? activeHeadingId) {
    if (activeHeadingId != null) {
      for (final heading in doc.headings) {
        if (heading.id == activeHeadingId) return heading.title;
      }
    }
    return widget.initialDetail.title;
  }

  String _topBarSubtitle(
    ReaderDocument doc,
    double progress,
    String? activeHeadingId,
  ) {
    final percent = (progress.clamp(0.0, 1.0) * 100).round();
    final headingTitle = activeHeadingId == null
        ? null
        : doc.headings
              .where((h) => h.id == activeHeadingId)
              .firstOrNull
              ?.title;
    if (headingTitle != null && headingTitle.isNotEmpty) {
      return '$headingTitle · $percent%';
    }
    return '$percent%';
  }

  ThemeData _effectiveReaderTheme(
    ThemeData baseTheme,
    ReaderPalette palette,
    ReaderPreferences prefs,
    Set<String> loadedFonts,
  ) {
    // 选择了特定字体（系统或目录字体）时同步给标题渲染风格；跟随主题则保持主题默认。
    final overrideFamily = prefs.resolveOverrideFontFamily(
      loadedFonts: loadedFonts,
      platform: baseTheme.platform,
    );
    if (!palette.isCustomLight && overrideFamily == null) {
      return baseTheme;
    }

    final existingRenderStyle = baseTheme.extension<FluxdoRenderStyle>();
    final themeKey = (
      baseTheme.brightness,
      baseTheme.colorScheme,
      baseTheme.textTheme,
      baseTheme.platform,
      existingRenderStyle,
      palette.isCustomLight,
      palette.background,
      palette.surface,
      palette.ink,
      palette.mutedInk,
      palette.outline,
      overrideFamily,
    );
    final cached = _cachedReaderTheme;
    if (cached != null &&
        (identical(_cachedBaseThemeRaw, baseTheme) ||
            _cachedReaderThemeKey == themeKey) &&
        _cachedReaderThemeKey == themeKey) {
      _cachedBaseThemeRaw = baseTheme;
      return cached;
    }

    var themed = baseTheme;
    if (palette.isCustomLight) {
      final scheme = baseTheme.colorScheme;
      themed = themed.copyWith(
        scaffoldBackgroundColor: palette.background,
        colorScheme: scheme.copyWith(
          surface: palette.background,
          surfaceContainerLowest: palette.background,
          surfaceContainerLow: palette.surface,
          surfaceContainer: palette.surface,
          onSurface: palette.ink,
          onSurfaceVariant: palette.mutedInk,
          outlineVariant: palette.outline,
        ),
      );
    }

    if (overrideFamily != null) {
      final updatedRenderStyle = FluxdoRenderStyle(
        headingFontFamily: overrideFamily,
        headingFontFamilyFallback: null,
        quoteBackground: existingRenderStyle?.quoteBackground ?? true,
        quoteBarWidth: existingRenderStyle?.quoteBarWidth ?? 4,
      );
      final extensions = Map<Object, ThemeExtension<dynamic>>.from(
        themed.extensions,
      )..[FluxdoRenderStyle] = updatedRenderStyle;
      themed = themed.copyWith(
        textTheme: themed.textTheme.apply(fontFamily: overrideFamily),
        extensions: extensions.values,
      );
    }
    _cachedBaseThemeRaw = baseTheme;
    _cachedReaderThemeKey = themeKey;
    _cachedReaderTheme = themed;
    return themed;
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(readerPreferencesProvider);
    final loadedFonts = ref.watch(themeProvider.select((t) => t.loadedFonts));
    final baseTheme = Theme.of(context);
    final palette = ReaderPalette.resolve(baseTheme, prefs.paperTheme);
    final readerTheme = _effectiveReaderTheme(
      baseTheme,
      palette,
      prefs,
      loadedFonts,
    );
    final scaffoldBackground = palette.isCustomLight
        ? palette.background
        : PageBackgroundScope.contentColor(context, palette.background);

    final doc = _document;
    if (doc == null) {
      return Theme(
        data: readerTheme,
        child: Scaffold(
          backgroundColor: scaffoldBackground,
          appBar: AppBar(
            leading: BackButton(
              key: const ValueKey('reader_top_back'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Text(
              widget.initialDetail.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          body: _isLoadingFirstPost
              ? const Center(child: LoadingSpinner.standard())
              : ErrorView(
                  error: _loadError ?? StateError('Unable to load post'),
                  onRetry: _loadFirstPost,
                ),
        ),
      );
    }

    final bodyStyle = prefs.resolveBodyStyle(
      readerTheme.textTheme.bodyMedium,
      palette.ink,
      loadedFonts: loadedFonts,
      platform: baseTheme.platform,
    );
    final isWide =
        MediaQuery.sizeOf(context).width >= TopicReaderPage.wideBreakpoint;
    final sidebarOpen = isWide && _isWideSidebarOpen(doc);
    final topPadding = MediaQuery.paddingOf(context).top;

    final readingSurface = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        ScrollBusySignal.onScrollNotification(notification);
        if (notification is ScrollStartNotification) {
          _cancelWarmUp();
          if (notification.dragDetails != null && _chromeVisible) {
            _hideChrome();
          }
        } else if (notification is ScrollEndNotification) {
          _scheduleReaderWarmUp();
        }
        return false;
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: Column(
              children: [
                // 极简常驻页眉独立占位于滚动视口上方，避免正文与图片滚到页眉文字下方造成重影。
                Padding(
                  padding: EdgeInsets.only(top: topPadding),
                  child: ValueListenableBuilder<
                    ({double progress, String? activeHeadingId})
                  >(
                    valueListenable: _readingStateNotifier,
                    builder: (context, readingState, _) => ReaderRunningHeader(
                      title: _runningHeaderTitle(
                        doc,
                        readingState.activeHeadingId,
                      ),
                      progress: readingState.progress,
                      palette: palette,
                      visible: !_chromeVisible,
                    ),
                  ),
                ),
                Expanded(
                  child: ParagraphWarmupScope(
                    tracker: _warmupTracker,
                    child: Listener(
                      key: const ValueKey('reader_content_tap_surface'),
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: _handleReadingPointerDown,
                      onPointerMove: _handleReadingPointerMove,
                      onPointerUp: _handleReadingPointerUp,
                      onPointerCancel: _handleReadingPointerCancel,
                      child: PositionedStreamList(
                        scrollController: _scrollController,
                        listController: _listController,
                        itemKeys: _documentItemKeys,
                        initialIndex: _initialRestoreIndex,
                        positionKey: widget.initialDetail.id,
                        cacheExtent: 900,
                        itemBuilder: (context, index) => _buildListItem(
                          context: context,
                          item: doc.items[index],
                          palette: palette,
                          prefs: prefs,
                          loadedFonts: loadedFonts,
                          platform: baseTheme.platform,
                          bodyStyle: bodyStyle,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 轻触呼出的顶部栏（使用平台自适应 BackButton）
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ValueListenableBuilder<
              ({double progress, String? activeHeadingId})
            >(
              valueListenable: _readingStateNotifier,
              builder: (context, readingState, _) => ReaderTopBar(
                visible: _chromeVisible,
                title: widget.initialDetail.title,
                subtitle: _topBarSubtitle(
                  doc,
                  readingState.progress,
                  readingState.activeHeadingId,
                ),
                palette: palette,
                onBack: () => Navigator.of(context).pop(),
              ),
            ),
          ),

          // 轻触呼出的底部玻璃胶囊（有标题时「目录 | 排版」，无标题时仅「排版」）
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ReaderBottomCapsule(
              visible: _chromeVisible,
              showToc: doc.hasHeadings,
              tocActive: sidebarOpen,
              onTapToc: () => _handleTocButtonTap(isWide, doc),
              onTapTypesetting: _openTypesettingSheet,
            ),
          ),
        ],
      ),
    );

    final sidebarDuration =
        MediaQuery.disableAnimationsOf(context) ||
            MediaQuery.reduceMotionOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 280);
    final sidebarCurve = M3eMotion.defaultSpatial.curveFor(
      const Duration(milliseconds: 280),
    );

    Widget body = readingSurface;
    if (isWide) {
      final sidebarDecoration = BoxDecoration(
        color: palette.isCustomLight
            ? palette.surface.withValues(alpha: 0.72)
            : PageBackgroundScope.isActive(context)
            ? palette.surface.withValues(alpha: 0.56)
            : palette.surface.withValues(alpha: 0.72),
        border: sidebarOpen
            ? Border(
                right: BorderSide(
                  color: palette.outline.withValues(alpha: 0.55),
                  width: 0.5,
                ),
              )
            : null,
      );
      body = Row(
        children: [
          AnimatedContainer(
            key: const ValueKey('reader_wide_toc_sidebar'),
            duration: sidebarDuration,
            curve: sidebarCurve,
            width: sidebarOpen ? TopicReaderPage._tocSidebarWidth : 0,
            decoration: sidebarDecoration,
            child: ClipRect(
              child: sidebarOpen
                  ? OverflowBox(
                      alignment: Alignment.topLeft,
                      minWidth: TopicReaderPage._tocSidebarWidth,
                      maxWidth: TopicReaderPage._tocSidebarWidth,
                      child: Padding(
                        padding: EdgeInsets.only(top: topPadding),
                        child: ValueListenableBuilder<
                          ({double progress, String? activeHeadingId})
                        >(
                          valueListenable: _readingStateNotifier,
                          builder: (context, readingState, _) => ReaderTocPanel(
                            headings: doc.headings,
                            palette: palette,
                            activeHeadingId: readingState.activeHeadingId,
                            isSidebar: true,
                            onClose: () => setState(() {
                              _wideSidebarOverride = false;
                            }),
                            onSelectHeading: (heading) =>
                                unawaited(_jumpToHeading(heading)),
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          Expanded(child: readingSurface),
        ],
      );
    }

    if (palette.usePaperTexture) {
      body = Stack(
        children: [
          Positioned.fill(child: PaperBackground(color: palette.background)),
          body,
        ],
      );
    }

    return Theme(
      data: readerTheme,
      child: Scaffold(
        backgroundColor: scaffoldBackground,
        body: body,
      ),
    );
  }

  Widget _buildListItem({
    required BuildContext context,
    required ReaderListItem item,
    required ReaderPalette palette,
    required ReaderPreferences prefs,
    required Set<String> loadedFonts,
    required TargetPlatform platform,
    required TextStyle bodyStyle,
  }) {
    final horizontalPadding = MediaQuery.sizeOf(context).width >= 600
        ? 32.0
        : 20.0;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: TopicReaderPage.maxReadingWidth,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: switch (item) {
            ReaderHeaderItem() => _buildHeaderItem(
              context,
              item,
              palette,
              prefs,
              loadedFonts,
              platform,
            ),
            ReaderPostShortItem() => _buildShortPostItem(
              context,
              item,
              bodyStyle,
            ),
            ReaderPostChunkItem() => _buildChunkPostItem(
              context,
              item,
              bodyStyle,
            ),
            ReaderFooterItem() => _buildFooterItem(context, item, palette),
          },
        ),
      ),
    );
  }

  Widget _buildHeaderItem(
    BuildContext context,
    ReaderHeaderItem item,
    ReaderPalette palette,
    ReaderPreferences prefs,
    Set<String> loadedFonts,
    TargetPlatform platform,
  ) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final titleStyle = prefs.resolveHeadingStyle(
      theme.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        height: 1.38,
        letterSpacing: 0.2,
      ),
      palette.ink,
      loadedFonts: loadedFonts,
      platform: platform,
    );
    final minutes = (item.estimatedWordCount / 360).ceil().clamp(1, 999);
    final metaStyle = theme.textTheme.bodySmall?.copyWith(
      color: palette.mutedInk,
    );
    final metaWidgets = <Widget>[
      Text(item.authorName, style: metaStyle),
      if (item.createdAt != null)
        RelativeTimeText(dateTime: item.createdAt, style: metaStyle),
      if (item.estimatedWordCount >= 200)
        Text(l10n.reader_estimatedMinutes(minutes), style: metaStyle),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText.rich(
            TextSpan(
              style: titleStyle,
              children: EmojiText.buildEmojiSpans(
                context,
                item.title,
                titleStyle,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (var i = 0; i < metaWidgets.length; i++) ...[
                if (i > 0)
                  Text(
                    '·',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: palette.mutedInk.withValues(alpha: 0.6),
                    ),
                  ),
                metaWidgets[i],
              ],
            ],
          ),
          const SizedBox(height: 22),
          Divider(
            height: 1,
            thickness: 0.6,
            color: palette.outline.withValues(alpha: 0.55),
          ),
        ],
      ),
    );
  }

  Widget _buildShortPostItem(
    BuildContext context,
    ReaderPostShortItem item,
    TextStyle bodyStyle,
  ) {
    final post = item.post;
    final callbacks = _callbacksForShortPost(
      post,
      item.preprocessedHtml,
      item.parsedNodes,
    );
    _ensureStableHandlers(post, callbacks);
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: HeadingAnchorScope(
        registry: _headingRegistry,
        child: FluxdoRender(
          cookedHtml: item.preprocessedHtml,
          parsedNodes: item.parsedNodes,
          baseTextStyle: bodyStyle,
          selectionScopeId: post.id,
          linkHandler: _stableLinkHandler,
          emojiImageBuilder: callbacks.emojiImageBuilder,
          mentionTapHandler: _stableMentionHandler,
          imageContentBuilder: callbacks.imageContentBuilder,
          codeBlockHighlighter: callbacks.codeBlockHighlighter,
          codeBlockBuilder: callbacks.codeBlockBuilder,
          quoteAvatarBuilder: callbacks.quoteAvatarBuilder,
          quoteCardBuilder: callbacks.quoteCardBuilder,
          footnoteTapHandler: callbacks.footnoteTapHandler,
          lazyVideoBuilder: callbacks.lazyVideoBuilder,
          iframeBuilder: callbacks.iframeBuilder,
          localDateBuilder: callbacks.localDateBuilder,
          mathBlockBuilder: callbacks.mathBlockBuilder,
          mathInlineBuilder: callbacks.mathInlineBuilder,
          oneboxBuilder: callbacks.oneboxBuilder,
          imageGridBuilder: callbacks.imageGridBuilder,
          policyBuilder: callbacks.policyBuilder,
          pollBuilder: callbacks.pollBuilder,
          chatTranscriptBuilder: callbacks.chatTranscriptBuilder,
          svgBuilder: callbacks.svgBuilder,
          videoBuilder: callbacks.videoBuilder,
          audioBuilder: callbacks.audioBuilder,
          onDownloadAttachment: callbacks.onDownloadAttachment,
          selectionEnabled: true,
          onCopyQuoteRequest: _stableCopyQuoteHandler,
          onCopyToast: _showCopyToast,
        ),
      ),
    );
  }

  Widget _buildChunkPostItem(
    BuildContext context,
    ReaderPostChunkItem item,
    TextStyle bodyStyle,
  ) {
    final post = item.post;
    final longData = item.longData;
    final chunk = longData.chunks[item.chunkIndex];
    final callbacks = longData.callbacks;
    final isLastChunk = item.chunkIndex == longData.chunks.length - 1;
    _ensureStableHandlers(post, callbacks);

    return Padding(
      padding: EdgeInsets.only(bottom: isLastChunk ? 22 : 0),
      child: HeadingAnchorScope(
        registry: _headingRegistry,
        child: FluxdoRender(
          cookedHtml: chunk.html,
          parsedNodes: longData.parsedChunkAt(item.chunkIndex),
          baseTextStyle: bodyStyle,
          imageIndexOffset: longData.imageOffsetAt(item.chunkIndex),
          footnotesHtml: longData.footnotesHtml,
          selectionScopeId: post.id,
          chunkIndex: item.chunkIndex,
          trimTopMargin: chunk.joinsPrevious,
          trimBottomMargin: chunk.joinsNext,
          linkHandler: _stableLinkHandler,
          emojiImageBuilder: callbacks.emojiImageBuilder,
          mentionTapHandler: _stableMentionHandler,
          imageContentBuilder: callbacks.imageContentBuilder,
          codeBlockHighlighter: callbacks.codeBlockHighlighter,
          codeBlockBuilder: callbacks.codeBlockBuilder,
          quoteAvatarBuilder: callbacks.quoteAvatarBuilder,
          quoteCardBuilder: callbacks.quoteCardBuilder,
          footnoteTapHandler: callbacks.footnoteTapHandler,
          lazyVideoBuilder: callbacks.lazyVideoBuilder,
          iframeBuilder: callbacks.iframeBuilder,
          localDateBuilder: callbacks.localDateBuilder,
          mathBlockBuilder: callbacks.mathBlockBuilder,
          mathInlineBuilder: callbacks.mathInlineBuilder,
          oneboxBuilder: callbacks.oneboxBuilder,
          imageGridBuilder: callbacks.imageGridBuilder,
          policyBuilder: callbacks.policyBuilder,
          pollBuilder: callbacks.pollBuilder,
          chatTranscriptBuilder: callbacks.chatTranscriptBuilder,
          svgBuilder: callbacks.svgBuilder,
          videoBuilder: callbacks.videoBuilder,
          audioBuilder: callbacks.audioBuilder,
          onDownloadAttachment: callbacks.onDownloadAttachment,
          selectionEnabled: true,
          onCopyQuoteRequest: _stableCopyQuoteHandler,
          onCopyToast: _showCopyToast,
        ),
      ),
    );
  }

  Widget _buildFooterItem(
    BuildContext context,
    ReaderFooterItem item,
    ReaderPalette palette,
  ) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final bottomPadding = MediaQuery.paddingOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(0, 24, 0, bottomPadding + 84),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Divider(
                  height: 1,
                  thickness: 0.6,
                  color: palette.outline.withValues(alpha: 0.6),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Text(
                  l10n.reader_endOfMainPost,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: palette.mutedInk,
                  ),
                ),
              ),
              Expanded(
                child: Divider(
                  height: 1,
                  thickness: 0.6,
                  color: palette.outline.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          FilledButton.tonalIcon(
            key: const ValueKey('reader_footer_back_to_discussion'),
            onPressed: () {
              _markInteractiveTap();
              Navigator.of(context).pop();
            },
            icon: const Icon(Symbols.forum_rounded, size: 18),
            label: Text(
              item.replyCount > 0
                  ? l10n.reader_backToDiscussionCount(item.replyCount)
                  : l10n.reader_backToDiscussion,
            ),
          ),
        ],
      ),
    );
  }
}
