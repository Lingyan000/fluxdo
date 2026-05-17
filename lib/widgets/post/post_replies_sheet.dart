import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/s.dart';
import '../../utils/dialog_utils.dart';
import '../../models/topic.dart';
import '../../providers/discourse_providers.dart';
import '../../services/app_error_handler.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/screen_track.dart';
import '../../utils/code_selection_context.dart';
import '../../utils/html_text_mapper.dart';
import '../../utils/html_to_markdown.dart';
import '../../utils/quote_builder.dart';
import '../common/loading_spinner.dart';
import '../content/discourse_html_content/discourse_html_content.dart';
import 'post_item/quote_selection_helper.dart';
import 'post_item/widgets/post_footer_section/post_footer_section.dart';
import 'post_item/widgets/post_header_section.dart';
import 'reply_sheet.dart';

/// 打开帖子递归回复弹框
void showPostRepliesSheet({
  required BuildContext context,
  required Post post,
  required int topicId,
  String? topicTitle,
  bool isPrivateMessageTopic = false,
  void Function(int postNumber)? onJumpToPost,
}) {
  showAppBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => _PostRepliesSheetContent(
      post: post,
      topicId: topicId,
      topicTitle: topicTitle,
      isPrivateMessageTopic: isPrivateMessageTopic,
      onJumpToPost: onJumpToPost,
    ),
  );
}

class _PostRepliesSheetContent extends ConsumerStatefulWidget {
  final Post post;
  final int topicId;
  final String? topicTitle;
  final bool isPrivateMessageTopic;
  final void Function(int postNumber)? onJumpToPost;

  const _PostRepliesSheetContent({
    required this.post,
    required this.topicId,
    this.topicTitle,
    this.isPrivateMessageTopic = false,
    this.onJumpToPost,
  });

  @override
  ConsumerState<_PostRepliesSheetContent> createState() =>
      _PostRepliesSheetContentState();
}

class _PostRepliesSheetContentState
    extends ConsumerState<_PostRepliesSheetContent> {
  static const int _batchSize = 20;

  final DiscourseService _service = DiscourseService();
  final List<Post> _replies = [];
  List<int> _allReplyIds = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  String? _error;

  // 引用回复相关
  SelectedContent? _lastSelectedContent;
  CodeSelectionContext? _lastCodeSelectionContext;

  // 弹框内跳转高亮
  final Map<int, GlobalKey> _postKeys = {};
  int? _highlightPostNumber;

  // 阅读时长上报
  late final ScreenTrack _screenTrack;
  final Set<int> _visiblePostNumbers = {};

  bool get _canLoadMore => _replies.length < _allReplyIds.length;
  bool get _isLoggedIn => ref.read(currentUserProvider).value != null;

  @override
  void initState() {
    super.initState();
    _screenTrack = ScreenTrack(
      _service,
      onTimingsSent: (topicId, postNumbers, highestSeen) {
        if (!mounted) return;
        // 更新会话已读状态，消除蓝点
        ref
            .read(topicSessionProvider(topicId).notifier)
            .markAsRead(postNumbers);
      },
    );
    if (_isLoggedIn) {
      _screenTrack.start(widget.topicId);
    }
    _loadInitial();
  }

  @override
  void dispose() {
    _screenTrack.stop();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    try {
      _allReplyIds = await _service.getPostReplyIds(widget.post.id);

      if (_allReplyIds.isEmpty) {
        final replies = await _service.getPostReplies(widget.post.id, after: 1);
        if (mounted) {
          setState(() {
            _replies.addAll(replies);
            _allReplyIds = replies.map((r) => r.id).toList();
            _isLoading = false;
          });
          _reportVisiblePosts();
        }
        return;
      }

      final firstBatch = _allReplyIds.take(_batchSize).toList();
      final postStream = await _service.getPosts(widget.topicId, firstBatch);
      if (mounted) {
        setState(() {
          _replies.addAll(postStream.posts);
          _isLoading = false;
        });
        _reportVisiblePosts();
      }
    } on DioException catch (_) {
      if (mounted) {
        setState(() {
          _error = S.current.error_networkRequestFailed;
          _isLoading = false;
        });
      }
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_canLoadMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final nextBatch = _allReplyIds
          .skip(_replies.length)
          .take(_batchSize)
          .toList();
      if (nextBatch.isNotEmpty) {
        final postStream = await _service.getPosts(widget.topicId, nextBatch);
        if (mounted) setState(() => _replies.addAll(postStream.posts));
      }
    } on DioException catch (_) {
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  bool _isDirectReply(Post reply) {
    return reply.replyToPostNumber == widget.post.postNumber ||
        reply.replyToPostNumber == 0;
  }

  void _jumpToPost(int postNumber) {
    Navigator.of(context).pop();
    widget.onJumpToPost?.call(postNumber);
  }

  GlobalKey _keyForPost(int postNumber) {
    return _postKeys.putIfAbsent(postNumber, () => GlobalKey());
  }

  void _scrollToAndHighlight(int postNumber) {
    final key = _postKeys[postNumber];
    if (key?.currentContext == null) return;
    Scrollable.ensureVisible(
      key!.currentContext!,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    );
    setState(() => _highlightPostNumber = postNumber);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _highlightPostNumber = null);
    });
  }

  void _handleReply(Post post, {String? initialContent}) {
    final replyToPost = post.postNumber == 1 ? null : post;
    showReplySheet(
      context: context,
      topicId: widget.topicId,
      replyToPost: replyToPost,
      initialContent: initialContent,
      topicTitle: widget.topicTitle,
      isPrivateMessageTopic: widget.isPrivateMessageTopic,
    );
  }

  void _handleQuoteSelection(String selectedText, Post post) {
    final codePayload = CodeSelectionContextTracker.instance.decodePayload(
      selectedText,
    );
    final plainSelectedText = codePayload?.text ?? selectedText;

    // 从 HTML 提取并转为 Markdown
    String markdown;
    final htmlFragment = HtmlTextMapper.extractHtml(
      post.cooked,
      plainSelectedText,
    );
    if (htmlFragment != null) {
      markdown = HtmlToMarkdown.convert(htmlFragment);
      if (markdown.trim().isEmpty) {
        markdown = codePayload != null
            ? CodeSelectionContextTracker.instance.toMarkdown(
                plainSelectedText,
                context: codePayload.context,
              )
            : plainSelectedText;
      }
    } else if (codePayload != null) {
      markdown = CodeSelectionContextTracker.instance.toMarkdown(
        plainSelectedText,
        context: codePayload.context,
      );
    } else {
      markdown = plainSelectedText;
    }

    // 构建 Discourse 引用格式
    final quote = QuoteBuilder.build(
      markdown: markdown,
      username: post.username,
      postNumber: post.postNumber,
      topicId: widget.topicId,
    );

    showReplySheet(
      context: context,
      topicId: widget.topicId,
      replyToPost: post,
      initialContent: quote,
      topicTitle: widget.topicTitle,
      isPrivateMessageTopic: widget.isPrivateMessageTopic,
    );
  }

  /// 上报可见帖子用于阅读时长统计
  void _reportVisiblePosts() {
    if (!_isLoggedIn) return;
    final postNumbers = <int>{widget.post.postNumber};
    for (final reply in _replies) {
      postNumbers.add(reply.postNumber);
    }
    _visiblePostNumbers
      ..clear()
      ..addAll(postNumbers);
    _screenTrack.setOnscreen(_visiblePostNumbers);
    _screenTrack.scrolled();
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification && _isLoggedIn) {
      _screenTrack.scrolled();
      _reportVisiblePosts();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            _buildHandle(theme),
            _buildTitleBar(context, theme),
            const Divider(height: 1),
            Expanded(child: _buildContent(context, theme, scrollController)),
          ],
        );
      },
    );
  }

  Widget _buildHandle(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildTitleBar(BuildContext context, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            '#${widget.post.postNumber} ${context.l10n.post_detail}',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => Navigator.of(context).pop(),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    ThemeData theme,
    ScrollController scrollController,
  ) {
    if (_isLoading) return const Center(child: LoadingSpinner());

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  setState(() {
                    _isLoading = true;
                    _error = null;
                  });
                  _loadInitial();
                },
                child: Text(S.current.common_retry),
              ),
            ],
          ),
        ),
      );
    }

    final hasReplies = _replies.isNotEmpty;
    // 帖子本身 + (有回复时: 分隔标题 + 回复列表 + 可能的加载更多)
    final itemCount =
        1 + (hasReplies ? 1 + _replies.length + (_canLoadMore ? 1 : 0) : 0);

    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: ListView.builder(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          // 第 0 项：始终显示当前帖子
          if (index == 0) return _buildPostCard(theme, widget.post);
          if (!hasReplies) return const SizedBox.shrink();
          // 第 1 项：回复分隔标题
          if (index == 1) return _buildRepliesDivider(theme);
          final replyIndex = index - 2;
          if (replyIndex == _replies.length) return _buildLoadMore(theme);
          final reply = _replies[replyIndex];
          return _isDirectReply(reply)
              ? _buildPostCard(theme, reply)
              : _buildNestedReplyCard(theme, reply);
        },
      ),
    );
  }

  /// 回复分隔标题
  Widget _buildRepliesDivider(ThemeData theme) {
    final totalCount = _allReplyIds.isNotEmpty
        ? _allReplyIds.length
        : widget.post.replyCount;
    return SelectionContainer.disabled(
      child: Padding(
        padding: const EdgeInsets.only(left: 4, top: 4, bottom: 8),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 14,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              S.current.post_relatedRepliesCount(totalCount),
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 帖子卡片（当前帖子 & 直接回复共用）
  Widget _buildPostCard(ThemeData theme, Post post) {
    final isHighlighted = _highlightPostNumber == post.postNumber;
    return AnimatedContainer(
      key: _keyForPost(post.postNumber),
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: isHighlighted
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
            : theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: _buildPostContent(post),
    );
  }

  /// 嵌套回复卡片（回复的回复，缩进 + 左边框）
  Widget _buildNestedReplyCard(ThemeData theme, Post reply) {
    final isHighlighted = _highlightPostNumber == reply.postNumber;
    return Padding(
      padding: const EdgeInsets.only(left: 20),
      child: AnimatedContainer(
        key: _keyForPost(reply.postNumber),
        duration: const Duration(milliseconds: 300),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: isHighlighted
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
              : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border(
            left: BorderSide(
              color: theme.colorScheme.primary.withValues(alpha: 0.3),
              width: 3,
            ),
          ),
        ),
        child: _buildPostContent(reply),
      ),
    );
  }

  /// 帖子内容：头部 + 正文（可引用） + 操作栏
  Widget _buildPostContent(Post post) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectionContainer.disabled(
          child: PostHeaderSection(
            post: post,
            topicId: widget.topicId,
            isTopicOwner: false,
            showStamp: false,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            onJumpToPost: _jumpToPost,
            disableReplyHistory: true,
            onReplyIndicatorTap: _scrollToAndHighlight,
            hideReplyToPostNumber: widget.post.postNumber,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: DiscourseHtmlContent(
            html: post.cooked,
            textStyle: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontSize: 14, height: 1.5),
            compact: true,
            onSelectionChanged: (content) {
              _lastSelectedContent = content;
              _lastCodeSelectionContext = content == null
                  ? null
                  : CodeSelectionContextTracker.instance.current;
            },
            contextMenuBuilder: _isLoggedIn
                ? (context, state) {
                    final items = QuoteSelectionHelper.buildMenuItems(
                      baseItems: state.contextMenuButtonItems,
                      plainText: _lastSelectedContent?.plainText,
                      post: post,
                      hideToolbar: state.hideToolbar,
                      topicId: widget.topicId,
                      onQuoteSelection: _handleQuoteSelection,
                      codeContext: _lastCodeSelectionContext,
                    );
                    return AdaptiveTextSelectionToolbar.buttonItems(
                      anchors: state.contextMenuAnchors,
                      buttonItems: items,
                    );
                  }
                : null,
          ),
        ),
        SelectionContainer.disabled(
          child: PostFooterSection(
            post: post,
            topicId: widget.topicId,
            topicHasAcceptedAnswer: false,
            acceptedAnswerPostNumber: null,
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            onReply: _isLoggedIn
                ? ({initialContent}) =>
                      _handleReply(post, initialContent: initialContent)
                : null,
            onEdit: null,
            onShareAsImage: null,
            onRefreshPost: null,
            onJumpToPost: _jumpToPost,
            onSolutionChanged: null,
            topicTitle: widget.topicTitle,
            isPrivateMessageTopic: widget.isPrivateMessageTopic,
            hideRepliesButton: true,
            onShowPostDetail: () => _jumpToPost(post.postNumber),
            postDetailLabel: S.current.topic_jump,
          ),
        ),
      ],
    );
  }

  Widget _buildLoadMore(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: TextButton.icon(
          onPressed: _isLoadingMore ? null : _loadMore,
          icon: _isLoadingMore
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.expand_more, size: 16),
          label: Text(S.current.post_loadMoreReplies),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        ),
      ),
    );
  }
}
